# shellcheck shell=bash
# lib/gpu.sh — NVIDIA GPU discovery and classification.
# Uses data/gpu_db.csv (awk lookup — no sqlite3 dependency) to classify each card
# as native / unlock / none, and to resolve its architecture and supported branches.
#
# Sets on selection: SELECTED_PCI, SELECTED_DEVID, SELECTED_DESC, GPU_ARCH,
#                    VGPU_SUPPORT (Native|Yes|No|Unknown), GPU_MIN_BRANCH, GPU_MAX_BRANCH.

GPU_DB="${DATA_DIR:-}/gpu_db.csv"

# gpu_db_lookup <deviceid> -> prints "description|chip|arch|support|min_branch|max_branch|notes"
# or empty when not found. deviceid is the 4-hex NVIDIA device id (lowercase).
gpu_db_lookup() {
    local devid; devid="$(echo "$1" | tr 'A-F' 'a-f')"
    [ -f "$GPU_DB" ] || { log_raw "gpu_db missing: $GPU_DB"; return 1; }
    awk -F',' -v id="$devid" '
        NR==1 { next }
        {
            gsub(/^"|"$/, "", $2)
            if (tolower($2) == id) {
                printf "%s|%s|%s|%s|%s|%s|%s", $3,$4,$5,$6,$7,$8,$9
                found=1; exit
            }
        }
        END { if (!found) exit 1 }
    ' "$GPU_DB"
}

# Map internal support token to VGPU_SUPPORT value used across the installer.
_support_to_vgpu() {
    case "$1" in
        native) echo "Native" ;;
        unlock) echo "Yes" ;;
        none)   echo "No" ;;
        *)      echo "Unknown" ;;
    esac
}

# Return list of "pci_id devid" pairs for NVIDIA display/3D controllers.
_scan_nvidia_gpus() {
    lspci -nn 2>/dev/null | grep -Ei '(VGA compatible controller|3D controller).*NVIDIA Corporation' \
        | while read -r line; do
            local pci devid
            pci="$(echo "$line" | awk '{print $1}')"
            devid="$(echo "$line" | grep -oiE '\[10de:[0-9a-f]{2,4}\]' | cut -d: -f2 | tr -d ']' | tr 'A-F' 'a-f')"
            [ -n "$pci" ] && [ -n "$devid" ] && echo "$pci $devid"
        done
}

# Classify and (if multiple) let the user select the vGPU card. Passthrough is
# offered for the rest.
detect_and_select_gpu() {
    ensure_cmd lspci pciutils
    local gpus; gpus="$(_scan_nvidia_gpus)"
    local count; count="$(printf '%s\n' "$gpus" | grep -c . || true)"

    if [ "$count" -eq 0 ]; then
        VGPU_SUPPORT="No"
        if ask_yes_no "No NVIDIA GPU detected in this system. Continue anyway?" n; then
            VGPU_SUPPORT="Unknown"; return 0
        fi
        die "No NVIDIA GPU found."
    fi

    if [ "$count" -eq 1 ]; then
        local pci devid
        read -r pci devid <<<"$gpus"
        _classify_single "$pci" "$devid"
        return 0
    fi

    _select_from_multiple "$gpus"
}

_classify_single() {
    local pci="$1" devid="$2" row desc chip arch support minb maxb notes
    SELECTED_PCI="$pci"; SELECTED_DEVID="$devid"
    if row="$(gpu_db_lookup "$devid")"; then
        IFS='|' read -r desc chip arch support minb maxb notes <<<"$row"
        SELECTED_DESC="$desc"; GPU_ARCH="$arch"
        GPU_MIN_BRANCH="$minb"; GPU_MAX_BRANCH="$maxb"
        VGPU_SUPPORT="$(_support_to_vgpu "$support")"
        log_step "Found one NVIDIA GPU: ${desc} [${chip}/${arch}] at 0000:${pci}"
        case "$VGPU_SUPPORT" in
            Native) log_info "$desc supports NATIVE vGPU (driver branches ${minb}-${maxb})." ;;
            Yes)    log_info "$desc is vGPU-capable via vgpu_unlock (branches ${minb}-${maxb})." ;;
            No)     log_warn "$desc is NOT vGPU-capable." ;;
            *)      log_warn "$desc vGPU capability is unknown." ;;
        esac
        [ -n "$notes" ] && log_warn "Note: $notes"
    else
        SELECTED_DESC="NVIDIA device $devid"; GPU_ARCH="unknown"; VGPU_SUPPORT="Unknown"
        log_warn "Device ID $devid not in database; capability unknown."
    fi
}

_select_from_multiple() {
    local gpus="$1"
    log_step "Found multiple NVIDIA GPUs:"
    echo ""
    local -a PCIS DEVIDS
    local i=0 pci devid row desc chip arch support minb maxb
    while read -r pci devid; do
        [ -n "$pci" ] || continue
        PCIS[i]="$pci"; DEVIDS[i]="$devid"
        if row="$(gpu_db_lookup "$devid")"; then
            IFS='|' read -r desc chip arch support minb maxb _ <<<"$row"
            printf '  %d) %s [%s/%s] @ 0000:%s — %s\n' "$((i+1))" "$desc" "$chip" "$arch" "$pci" \
                "$(_support_to_vgpu "$support")"
        else
            printf '  %d) NVIDIA device %s @ 0000:%s — Unknown (not in DB)\n' "$((i+1))" "$devid" "$pci"
        fi
        i=$((i+1))
    done <<<"$gpus"
    echo ""

    local n="$i" sel
    log_ask "Select the GPU to enable vGPU on (others can be passed through)."
    sel="$(ask_value "Enter a number 1-$n" "1")"
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "$n" ]; then
        die "Invalid selection '$sel' (expected 1-$n)."
    fi

    local idx=$((sel-1))
    _classify_single "${PCIS[$idx]}" "${DEVIDS[$idx]}"

    # Offer passthrough for the others.
    echo ""
    if ask_yes_no "Enable PCI passthrough (vfio-pci) for the other GPU(s)?" y; then
        local j
        for j in "${!PCIS[@]}"; do
            [ "$j" -eq "$idx" ] && continue
            _passthrough_pci "${PCIS[$j]}"
        done
    else
        log_warn "Skipping passthrough for other GPUs."
    fi
}

# Write a udev rule binding every device in the card's IOMMU group to vfio-pci.
_passthrough_pci() {
    local pci="$1" rules=/etc/udev/rules.d/90-vfio-pci.rules dev
    local grp="/sys/bus/pci/devices/0000:${pci}/iommu_group/devices"
    [ -d "$grp" ] || { log_warn "No IOMMU group for 0000:${pci}; skipping passthrough."; return 0; }
    log_info "Passing through IOMMU group of 0000:${pci}:"
    for dev in $(ls "$grp"); do
        echo "    $dev"
        local rule="ACTION==\"add\", SUBSYSTEM==\"pci\", KERNELS==\"$dev\", DRIVERS==\"*\", ATTR{driver_override}=\"vfio-pci\""
        grep -qF "KERNELS==\"$dev\"" "$rules" 2>/dev/null || echo "$rule" >>"$rules"
    done
}

module_init "gpu.sh"
