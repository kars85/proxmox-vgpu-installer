# shellcheck shell=bash
# lib/driver.sh — host driver catalog, download, verification, patching, install.
# All version/URL/patch knowledge comes from data/driver_catalog.json (via jq).

DRIVER_CATALOG="${DATA_DIR:-}/driver_catalog.json"
POLLOLOCO_REPO="https://gitlab.com/polloloco/vgpu-proxmox.git"
# Pin to a known-good ref for reproducibility; override with POLLOLOCO_REF env.
POLLOLOCO_REF="${POLLOLOCO_REF:-master}"

_jq() { jq -r "$@" "$DRIVER_CATALOG"; }

driver_field() { # driver_field <release> <jq-path-after-select>
    _jq --arg r "$1" ".drivers[] | select(.vgpu_release==\$r) | $2"
}

# Print the driver menu filtered to what makes sense for this host + GPU.
# A release is offered when: PVE major matches, and (GPU arch unknown OR the
# GPU's architecture is in the release's arch_support), and — for unlock mode —
# unlock_supported is true.
list_compatible_drivers() {
    local mode="${1:-$MODE}"   # native|unlock|any
    local arch="${GPU_ARCH:-unknown}"
    _jq --arg pve "$PVE_MAJOR" --arg arch "$arch" --arg mode "$mode" '
        .drivers[]
        | select(.pve | index($pve))
        | select($arch=="unknown" or ($mode=="native") or (.arch_support | index($arch)))
        | select($mode!="unlock" or .unlock_supported==true)
        | "\(.vgpu_release)\t\(.branch)\t\(.host_filename)\t\(.note)"
    '
}

# Interactive driver picker. Sets DRIVER_RELEASE and DRIVER_FILE.
choose_driver() {
    local mode="${1:-$MODE}"
    echo ""
    log_step "Compatible vGPU driver releases for PVE ${PVE_MAJOR} / arch ${GPU_ARCH:-unknown} / mode ${mode}:"
    echo ""
    local -a rels
    local rel branch file note
    local i=0
    while IFS=$'\t' read -r rel branch file note; do
        [ -n "$rel" ] || continue
        rels[i]="$rel"
        printf '  %d) %-6s (%s)  %s\n' "$((i+1))" "$rel" "$branch" "${note}"
        i=$((i+1))
    done < <(list_compatible_drivers "$mode")

    [ "$i" -gt 0 ] || die "No catalog drivers match this host/GPU/mode combination."

    local n="$i" sel
    echo ""
    sel="$(ask_value "Select a driver release 1-$n" "1")"
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "$n" ]; then
        die "Invalid selection '$sel'."
    fi
    DRIVER_RELEASE="${rels[$((sel-1))]}"
    DRIVER_FILE="$(driver_field "$DRIVER_RELEASE" '.host_filename')"
    log_info "Selected vGPU ${DRIVER_RELEASE} — ${DRIVER_FILE}"

    # Warn loudly about kernel and unlock caveats.
    _warn_kernel_window "$DRIVER_RELEASE"
    if [ "$mode" = "unlock" ] && [ "$(driver_field "$DRIVER_RELEASE" '.unlock_supported')" != "true" ]; then
        die "vGPU ${DRIVER_RELEASE} has no community unlock patch; it supports native/enterprise cards only."
    fi
}

_warn_kernel_window() {
    local rel="$1" mink maxk km
    mink="$(driver_field "$rel" '.min_kernel')"
    maxk="$(driver_field "$rel" '.max_kernel')"
    km="$(kernel_mm)"
    [ -n "$km" ] || return 0
    if [ -n "$maxk" ] && ver_ge "$km" "$maxk" && [ "$km" != "$maxk" ]; then
        log_warn "Running kernel ${km} is newer than driver ${rel}'s tested max (${maxk}). DKMS build may fail; a newer driver may be required."
    fi
    if [ -n "$mink" ] && ! ver_ge "$km" "$mink"; then
        log_warn "Running kernel ${km} is older than driver ${rel}'s minimum (${mink})."
    fi
}

# Resolve the local driver file, downloading if necessary. Honors URL/FILE
# overrides. Sets DRIVER_FILE to the final local path. Verifies integrity.
obtain_driver_file() {
    local dir="${VGPU_DIR}"

    if [ -n "${FILE:-}" ]; then
        [ -f "$FILE" ] || die "--file '$FILE' does not exist."
        DRIVER_FILE="$FILE"
        _identify_local_driver "$DRIVER_FILE" || die "Unrecognized driver file: $FILE"
        log_info "Using provided driver file: $DRIVER_FILE"
    elif [ -n "${URL:-}" ]; then
        local fname; fname="$(_filename_from_url "$URL")"
        log_info "Downloading driver from --url as $fname"
        run_command "Downloading $fname" info curl -fSL "$URL" -o "$dir/$fname"
        DRIVER_FILE="$(_maybe_extract_run "$dir/$fname")"
        _identify_local_driver "$DRIVER_FILE" || die "Unrecognized driver at $URL"
    else
        # Catalog-driven: DRIVER_FILE holds the expected filename from choose_driver.
        local expected="$DRIVER_FILE" target="$dir/$DRIVER_FILE"
        if [ -f "$target" ]; then
            log_info "Driver already present: $target"
        else
            die "Driver file '$expected' not found in $dir.
This installer does not embed download links for NVIDIA's proprietary blobs.
Provide it with:  --file /path/to/${expected}
   or a mirror:  --url https://your-mirror/${expected}
(Download the vGPU host .run from the NVIDIA Licensing Portal for release ${DRIVER_RELEASE}.)"
        fi
        DRIVER_FILE="$target"
    fi

    verify_driver_integrity "$DRIVER_FILE"
    chmod +x "$DRIVER_FILE"
}

# SHA256 (preferred) / MD5 verification. Hard-fail on mismatch; explicit warn +
# confirm when the catalog has no hash for this release.
verify_driver_integrity() {
    local path="$1" base sha md5 want_sha want_md5
    base="$(basename "$path")"
    # Look up expected hashes by matching host_filename across the catalog.
    want_sha="$(_jq --arg f "$base" '.drivers[] | select(.host_filename==$f) | .sha256' | head -1)"
    want_md5="$(_jq --arg f "$base" '.drivers[] | select(.host_filename==$f) | .md5' | head -1)"

    if [ -n "$want_sha" ]; then
        sha="$(sha256sum "$path" | awk '{print $1}')"
        [ "$sha" = "$want_sha" ] || die "SHA256 mismatch for $base
  expected $want_sha
  actual   $sha
Refusing to install a driver that failed integrity verification."
        log_info "SHA256 verified for $base"
        return 0
    fi
    if [ -n "$want_md5" ]; then
        md5="$(md5sum "$path" | awk '{print $1}')"
        [ "$md5" = "$want_md5" ] || die "MD5 mismatch for $base (expected $want_md5, got $md5)."
        log_info "MD5 verified for $base (no SHA256 in catalog)."
        return 0
    fi
    log_warn "No checksum in catalog for $base — integrity cannot be verified."
    ask_yes_no "Continue installing an unverified driver?" n || die "Aborted: unverified driver."
}

# Identify a local driver against the catalog; sets DRIVER_RELEASE if matched.
_identify_local_driver() {
    local base; base="$(basename "$1")"
    local rel; rel="$(_jq --arg f "$base" '.drivers[] | select(.host_filename==$f) | .vgpu_release' | head -1)"
    if [ -n "$rel" ]; then DRIVER_RELEASE="$rel"; return 0; fi
    return 1
}

_filename_from_url() { basename "${1%%\?*}"; }

# If a .zip was downloaded, extract the enclosed *-vgpu-kvm.run and echo its path.
_maybe_extract_run() {
    local f="$1"
    if [[ "$f" == *.zip ]]; then
        ensure_cmd unzip unzip
        unzip -o -q "$f" -d "$(dirname "$f")"
        local run; run="$(find "$(dirname "$f")" -name '*-vgpu-kvm.run' -type f | head -1)"
        [ -n "$run" ] || die "No *-vgpu-kvm.run found inside $f"
        echo "$run"
    else
        echo "$f"
    fi
}

# Clone/refresh the polloloco patch repo (only needed for unlock mode).
ensure_patch_repo() {
    local dest="$VGPU_DIR/vgpu-proxmox"
    if [ -d "$dest/.git" ]; then
        run_command "Updating vgpu-proxmox patches" info git -C "$dest" fetch --depth 1 origin "$POLLOLOCO_REF"
        ALLOW_FAIL=1 run_command "Checking out $POLLOLOCO_REF" info git -C "$dest" checkout -q "$POLLOLOCO_REF"
    else
        rm -rf "$dest"
        run_command "Cloning vgpu-proxmox patches ($POLLOLOCO_REF)" info \
            git clone --depth 1 --branch "$POLLOLOCO_REF" "$POLLOLOCO_REPO" "$dest" \
            || run_command "Cloning vgpu-proxmox patches" info git clone --depth 1 "$POLLOLOCO_REPO" "$dest"
    fi
}

# Patch (unlock mode) + install, or install natively.
install_driver() {
    local mode="${1:-$MODE}" patch
    patch="$(driver_field "$DRIVER_RELEASE" '.patch')"

    if [ "$mode" = "unlock" ]; then
        [ -n "$patch" ] || die "vGPU ${DRIVER_RELEASE} has no unlock patch."
        ensure_patch_repo
        local patch_path="$VGPU_DIR/vgpu-proxmox/$patch"
        [ -f "$patch_path" ] || die "Patch $patch not found in patch repo (branch $POLLOLOCO_REF)."
        local custom="${DRIVER_FILE%.run}-custom.run"
        [ -e "$custom" ] && mv -f "$custom" "$custom.bak"
        run_command "Patching driver with $patch" info "$DRIVER_FILE" --apply-patch "$patch_path"
        run_command "Installing patched driver (DKMS)" info "$custom" --dkms -m=kernel -s
    else
        run_command "Installing native driver (DKMS)" info "$DRIVER_FILE" --dkms -m=kernel -s
    fi
    log_info "Driver install finished."
}

# Print the matching guest driver guidance from the catalog.
print_guest_driver_info() {
    local rel="$DRIVER_RELEASE" gl gw dir
    gl="$(driver_field "$rel" '.guest.linux')"
    gw="$(driver_field "$rel" '.guest.windows')"
    dir="$(driver_field "$rel" '.guest_release_dir')"
    local base="https://storage.googleapis.com/nvidia-drivers-us-public/GRID"
    echo ""
    log_step "Guest drivers for vGPU ${rel} (install inside your VMs):"
    if [ -n "$gl" ]; then log_info "Linux:   ${base}/${dir}/${gl}"; else log_info "Linux:   see NVIDIA vGPU ${rel} package (folder ${dir})"; fi
    if [ -n "$gw" ]; then log_info "Windows: ${base}/${dir}/${gw}"; else log_info "Windows: see NVIDIA vGPU ${rel} package (folder ${dir})"; fi
    local branch; branch="$(driver_field "$rel" '.branch')"
    if [ "$branch" = "R570" ] || [ "$branch" = "R580" ] || [ "$branch" = "R595" ]; then
        log_warn "Licensing for ${branch} guests requires gridd-unlock-patcher in the guest (FastAPI-DLS 2.x). See the licensing step."
    fi
}

module_init "driver.sh"
