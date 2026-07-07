# shellcheck shell=bash
# lib/unlock.sh — vgpu_unlock-rs setup for consumer-card (Maxwell 2.0 .. Turing) unlock.
# Only used when MODE=unlock.

VGPU_UNLOCK_REPO="https://github.com/mbilker/vgpu_unlock-rs.git"

# Fail early if the selected card cannot actually be unlocked.
assert_unlock_eligible() {
    case "${GPU_ARCH:-unknown}" in
        maxwell|pascal|turing) : ;;
        ampere|ada|blackwell|hopper)
            die "Architecture '${GPU_ARCH}' cannot be unlocked. Consumer unlock is limited to Maxwell 2.0 through Turing. Ampere and newer require enterprise/native-capable cards." ;;
        *)
            log_warn "GPU architecture unknown; unlock may not work. Proceeding at your own risk." ;;
    esac
}

install_vgpu_unlock() {
    assert_unlock_eligible
    ensure_cmd git git

    run_command "Cloning vgpu_unlock-rs" info \
        bash -c "rm -rf /opt/vgpu_unlock-rs; git clone --depth 1 '$VGPU_UNLOCK_REPO' /opt/vgpu_unlock-rs"

    # Rust toolchain (prefer distro cargo; fall back to rustup minimal).
    if ! need_cmd cargo; then
        if apt-get install -y cargo >>"${LOG_FILE:-/dev/null}" 2>&1; then
            log_info "Installed cargo from distro packages"
        else
            log_warn "Installing Rust via rustup (minimal profile)"
            run_shell "Installing rustup" info \
                "curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal"
            # shellcheck disable=SC1091
            . "$HOME/.cargo/env"
        fi
    fi

    run_command "Building vgpu_unlock-rs (release)" info \
        bash -c "cd /opt/vgpu_unlock-rs && cargo build --release"

    local lib=/opt/vgpu_unlock-rs/target/release/libvgpu_unlock_rs.so
    [ -f "$lib" ] || die "vgpu_unlock-rs build produced no library at $lib"

    mkdir -p /etc/vgpu_unlock
    touch /etc/vgpu_unlock/profile_override.toml

    # LD_PRELOAD the unlock lib into the NVIDIA vGPU services.
    local svc conf
    for svc in nvidia-vgpud nvidia-vgpu-mgr; do
        conf="/etc/systemd/system/${svc}.service.d/vgpu_unlock.conf"
        mkdir -p "$(dirname "$conf")"
        printf '[Service]\nEnvironment=LD_PRELOAD=%s\n' "$lib" >"$conf"
    done
    log_info "Configured LD_PRELOAD override for nvidia-vgpud / nvidia-vgpu-mgr"

    run_command "systemctl daemon-reload" info systemctl daemon-reload
    ALLOW_FAIL=1 run_command "Enabling nvidia-vgpud.service" info systemctl enable nvidia-vgpud.service
    ALLOW_FAIL=1 run_command "Enabling nvidia-vgpu-mgr.service" info systemctl enable nvidia-vgpu-mgr.service

    _seed_profile_override_template
}

PROFILE_OVERRIDE_FILE=/etc/vgpu_unlock/profile_override.toml

# Drop a documented, commented template on first unlock setup (no active overrides).
_seed_profile_override_template() {
    mkdir -p "$(dirname "$PROFILE_OVERRIDE_FILE")"
    [ -s "$PROFILE_OVERRIDE_FILE" ] && return 0   # keep any existing content
    cat >"$PROFILE_OVERRIDE_FILE" <<'EOF'
# vgpu_unlock-rs profile overrides.
# Each section overrides one mdev type (find the type with:  mdevctl types).
# Fill in and uncomment, or generate one with:  ./installer.sh override
#
# [profile.nvidia-256]
# num_displays = 1
# display_width = 1920
# display_height = 1080
# max_pixels = 2073600        # must equal display_width * display_height
# frl_enabled = 0             # 0 = remove the frame-rate limiter
# cuda_enabled = 1            # 1 = enable CUDA on Q/B profiles
# framebuffer = 0x74000000            # optional: custom guest framebuffer (bytes)
# framebuffer_reservation = 0x1000000 # optional: overhead; framebuffer+reservation = physical size
EOF
    log_info "Wrote profile-override template: $PROFILE_OVERRIDE_FILE"
}

# Append/replace an override section for one mdev type. Idempotent per type.
# write_profile_override <mdev_type> <fb_mb|0> <width> <height> <cuda:0|1> <frl:0|1>
write_profile_override() {
    local mtype="$1" fb_mb="${2:-0}" width="${3:-1920}" height="${4:-1080}" cuda="${5:-1}" frl="${6:-0}"
    local file="$PROFILE_OVERRIDE_FILE"
    mkdir -p "$(dirname "$file")"
    touch "$file"

    # Remove any existing [profile.<mtype>] block so re-running replaces it cleanly.
    if grep -q "^\[profile\.${mtype}\]" "$file" 2>/dev/null; then
        awk -v sec="[profile.${mtype}]" '
            $0==sec {skip=1; next}
            skip && /^\[profile\./ {skip=0}
            skip && (/^[[:space:]]*$/) {skip=0}
            !skip {print}
        ' "$file" >"${file}.tmp" && mv "${file}.tmp" "$file"
        log_warn "Replacing existing override for ${mtype}"
    fi

    {
        echo ""
        echo "[profile.${mtype}]"
        echo "num_displays = 1"
        echo "display_width = ${width}"
        echo "display_height = ${height}"
        echo "max_pixels = $(( width * height ))"
        echo "frl_enabled = ${frl}"
        echo "cuda_enabled = ${cuda}"
        if [ "${fb_mb}" -gt 0 ] 2>/dev/null; then
            # framebuffer + reservation must equal the physical per-instance size.
            local reservation=$(( 16 * 1024 * 1024 ))   # 0x1000000 default overhead
            local total=$(( fb_mb * 1024 * 1024 ))
            printf 'framebuffer = 0x%X\n' $(( total - reservation ))
            printf 'framebuffer_reservation = 0x%X\n' "$reservation"
        fi
    } >>"$file"
    log_info "Wrote override for ${mtype} to ${file}"
}

# Interactive override builder. Post-install it lists live mdev types; otherwise
# it writes to the template and reminds the user to confirm the type.
configure_profile_override() {
    echo ""
    log_step "vGPU profile override (vgpu_unlock)"
    if [ ! -d /opt/vgpu_unlock-rs ]; then
        log_warn "vgpu_unlock is not installed; overrides only apply to unlock-mode installs."
    fi

    local mtype
    if need_cmd mdevctl && mdevctl types >/dev/null 2>&1; then
        echo "Available mdev types on this host:"
        mdevctl types 2>/dev/null | awk '
            /nvidia-[0-9]+/ {gsub(/^[ \t]+/,""); t=$1}
            /Name:/ {sub(/^[ \t]*Name:[ \t]*/,""); printf "  %-14s %s\n", t, $0}'
        echo ""
        mtype="$(ask_value 'Enter the mdev type to override (e.g. nvidia-256)' '')"
        [ -n "$mtype" ] || { log_warn "No type entered; aborting override."; return 0; }
    else
        log_warn "mdevctl types unavailable (driver not yet installed?)."
        mtype="$(ask_value 'Enter the mdev type to override (confirm later with mdevctl types)' 'nvidia-256')"
    fi

    local res width height cuda frl fbmb
    res="$(ask_value 'Display resolution WxH' '1920x1080')"
    width="${res%x*}"; height="${res#*x}"
    if ask_yes_no "Enable CUDA on this profile?" y; then cuda=1; else cuda=0; fi
    if ask_yes_no "Disable the frame-rate limiter (frl)?" y; then frl=0; else frl=1; fi
    fbmb=0
    if ask_yes_no "Set a custom framebuffer size? (advanced — wrong values break profile creation)" n; then
        fbmb="$(ask_value 'Framebuffer size in MiB (e.g. 2048)' '2048')"
    fi

    write_profile_override "$mtype" "$fbmb" "$width" "$height" "$cuda" "$frl"
    ALLOW_FAIL=1 run_command "Restarting nvidia-vgpu-mgr" info systemctl restart nvidia-vgpu-mgr.service
    log_info "Override applied. Re-create the vGPU/mdev on the VM for changes to take effect."
}

module_init "unlock.sh"
