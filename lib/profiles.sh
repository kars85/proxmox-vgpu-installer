# shellcheck shell=bash
# lib/profiles.sh — vGPU profile compatibility explorer.
#
# Answers "which vGPU profiles can this card run?" in two modes:
#   * static  (pre-install): from data/profiles/*.json — no driver required.
#   * live    (post-install): mdevctl types (Turing/older) or SR-IOV
#     creatable_vgpu_types + nvidia-smi vgpu (Ampere+).

CURATED_PROFILES="${DATA_DIR:-}/profiles/curated.json"

# Public entry point. profiles_show [devid] [branch]
profiles_show() {
    local devid="${1:-${SELECTED_DEVID:-}}"
    local branch="${2:-${DRIVER_RELEASE%%.*}}"

    echo ""
    log_step "vGPU profile compatibility"
    if [ -z "$devid" ]; then
        detect_and_select_gpu
        devid="${SELECTED_DEVID}"
    fi

    # Prefer live data if the driver stack is up; otherwise fall back to static.
    if _profiles_live_available; then
        _profiles_show_live
    else
        _profiles_show_static "$devid" "$branch"
    fi
}

_profiles_live_available() {
    need_cmd mdevctl && mdevctl types >/dev/null 2>&1 && return 0
    need_cmd nvidia-smi && nvidia-smi vgpu >/dev/null 2>&1 && return 0
    [ -d /sys/bus/pci/devices ] && ls /sys/bus/pci/devices/*/nvidia/creatable_vgpu_types >/dev/null 2>&1
}

# ---- Static (pre-install) --------------------------------------------------
_profiles_show_static() {
    local devid="$1" branch="$2"
    devid="$(echo "$devid" | tr 'A-F' 'a-f')"

    # For unlock cards, resolve to the spoof target's family.
    if [ "${VGPU_SUPPORT:-}" = "Yes" ]; then
        local spoof
        spoof="$(jq -r --arg a "${GPU_ARCH:-turing}" '._unlock_spoof_targets[$a].spoof_as // empty' "$CURATED_PROFILES" 2>/dev/null)"
        if [ -n "$spoof" ]; then
            log_info "This is a consumer card unlocked via vgpu_unlock — it exposes the profile set of: ${spoof}"
            log_warn "Exact instances/framebuffer follow the spoofed enterprise card; tune with /etc/vgpu_unlock/profile_override.toml."
        fi
    fi

    # Prefer an extracted per-branch table if present.
    local src=""
    if [ -n "$branch" ] && [ -f "${DATA_DIR}/profiles/${branch}.json" ]; then
        src="${DATA_DIR}/profiles/${branch}.json"
    elif jq -e --arg d "$devid" '.devices[$d]' "$CURATED_PROFILES" >/dev/null 2>&1; then
        src="$CURATED_PROFILES"
    fi

    if [ -z "$src" ]; then
        log_warn "No pre-install profile table for device ${devid}${branch:+ (branch $branch)}."
        log_warn "After installing the driver, re-run 'profiles' for the live list, or run tools/extract_profiles.sh on the host .run."
        return 0
    fi

    local name total
    name="$(jq -r --arg d "$devid" '.devices[$d].name // "device '"$devid"'"' "$src")"
    total="$(jq -r --arg d "$devid" '.devices[$d].total_fb_mb // empty' "$src")"
    echo ""
    log_info "Profiles for ${name}${total:+ (${total} MiB total)} — source: $(basename "$src")"
    echo ""
    printf '    %-10s %-5s %10s %6s   %-8s %s\n' "PROFILE" "TYPE" "FB(MiB)" "MAX#" "CLASS" "MAX RES"
    printf '    %-10s %-5s %10s %6s   %-8s %s\n' "-------" "----" "-------" "----" "-----" "-------"
    jq -r --arg d "$devid" '
        .devices[$d].profiles[]?
        | [.name, .type, (.framebuffer_mb|tostring), (.max_instances|tostring), (.class // "-"), (.max_resolution // "-")]
        | @tsv' "$src" \
    | while IFS=$'\t' read -r pn pt fb mi cl mr; do
        printf '    %-10s %-5s %10s %6s   %-8s %s\n' "$pn" "$pt" "$fb" "$mi" "$cl" "$mr"
    done
    echo ""
    log_info "Profile letters: Q=vWS/vDWS (pro gfx), B=vPC (VDI), C=vCS (compute), A=vApps (RDSH)."
}

# ---- Live (post-install) ---------------------------------------------------
_profiles_show_live() {
    if gpu_uses_sriov; then
        _profiles_live_sriov
    else
        _profiles_live_mdev
    fi
}

_profiles_live_mdev() {
    log_info "Live mdev types (Turing/older) — from mdevctl:"
    echo ""
    if ! need_cmd mdevctl; then
        log_warn "mdevctl not installed."; return 0
    fi
    # Group by PCI address; print name + available/total instances.
    mdevctl types 2>/dev/null | awk '
        /^0000:/ { addr=$1; print "  PCI " addr; next }
        /Available instances:/ { ai=$3 }
        /Device API:/ {}
        /Name:/ { sub(/^[ \t]*Name:[ \t]*/,""); name=$0 }
        /nvidia-[0-9]+/ { gsub(/^[ \t]+/,""); type=$1 }
        /Description:/ {
            sub(/^[ \t]*Description:[ \t]*/,"");
            printf "    %-14s %-22s available:%s  {%s}\n", type, name, ai, $0
        }
    '
    echo ""
    log_info "Create one by assigning its mdev type to a VM (Hardware -> Add -> PCI Device -> mediated)."
}

_profiles_live_sriov() {
    log_info "Live creatable vGPU types (Ampere+, SR-IOV):"
    echo ""
    local addr="0000:${SELECTED_PCI:-}" vf found=0
    # Iterate this card's virtual functions.
    for vf in /sys/bus/pci/devices/0000:${SELECTED_PCI%.*}.*/nvidia/creatable_vgpu_types; do
        [ -f "$vf" ] || continue
        found=1
        local vfaddr; vfaddr="$(echo "$vf" | grep -oE '0000:[0-9a-f:.]+' | head -1)"
        local n; n="$(grep -c 'ID' "$vf" 2>/dev/null || true)"
        printf '  VF %s — creatable now:\n' "$vfaddr"
        sed 's/^/      /' "$vf"
        break
    done
    if [ "$found" -eq 0 ]; then
        if need_cmd nvidia-smi; then
            log_info "Supported types via nvidia-smi vgpu:"
            nvidia-smi vgpu -s 2>/dev/null | sed 's/^/    /'
            echo ""
            log_info "Creatable types depend on SR-IOV being enabled (see the SR-IOV step)."
        else
            log_warn "No creatable_vgpu_types files found and nvidia-smi unavailable. Enable SR-IOV first."
        fi
    fi
    echo ""
    log_info "Assign a type via Datacenter -> Resource Mappings (enable 'Use with mediated devices'), then add the mapping to the VM."
}

module_init "profiles.sh"
