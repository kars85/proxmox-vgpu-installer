# shellcheck shell=bash
# lib/detect.sh — host platform detection.
# Populates: PVE_VERSION, PVE_MAJOR, DEBIAN_CODENAME, KERNEL_VERSION,
#            BOOTLOADER (grub|systemd-boot|unknown), SECURE_BOOT (on|off|unknown),
#            CPU_VENDOR (intel|amd|unknown), IOMMU_STATE (on|off|unknown).

# Compare dotted versions: ver_ge A B  -> true if A >= B
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

detect_pve() {
    if ! need_cmd pveversion; then
        die "pveversion not found — this script must run on a Proxmox VE host."
    fi
    local info; info="$(pveversion 2>/dev/null)"
    PVE_VERSION="$(echo "$info" | sed -n 's#^pve-manager/\([0-9.]*\).*#\1#p')"
    PVE_MAJOR="${PVE_VERSION%%.*}"
    KERNEL_VERSION="$(echo "$info" | sed -n 's#^.*kernel: \([0-9][0-9.-]*\).*#\1#p')"
    [ -n "$KERNEL_VERSION" ] || KERNEL_VERSION="$(uname -r)"
    DEBIAN_CODENAME="$( . /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")"
    log_raw "PVE_VERSION=$PVE_VERSION PVE_MAJOR=$PVE_MAJOR KERNEL=$KERNEL_VERSION CODENAME=$DEBIAN_CODENAME"
}

# Numeric kernel like 6.14 (major.minor) for range comparisons.
kernel_mm() { echo "$KERNEL_VERSION" | grep -oE '^[0-9]+\.[0-9]+' | head -1; }

detect_bootloader() {
    BOOTLOADER="unknown"
    if need_cmd proxmox-boot-tool && proxmox-boot-tool status >/dev/null 2>&1; then
        # systemd-boot / uefi entries are managed by proxmox-boot-tool
        if proxmox-boot-tool status 2>/dev/null | grep -qiE 'uefi|systemd-boot'; then
            BOOTLOADER="systemd-boot"
        elif proxmox-boot-tool status 2>/dev/null | grep -qi 'grub'; then
            BOOTLOADER="grub"
        fi
    fi
    # Fallbacks
    if [ "$BOOTLOADER" = "unknown" ]; then
        if [ -d /sys/firmware/efi ] && [ -f /etc/kernel/cmdline ]; then
            BOOTLOADER="systemd-boot"
        elif [ -f /etc/default/grub ]; then
            BOOTLOADER="grub"
        fi
    fi
    log_raw "BOOTLOADER=$BOOTLOADER"
}

detect_secure_boot() {
    SECURE_BOOT="unknown"
    if need_cmd mokutil; then
        case "$(mokutil --sb-state 2>/dev/null)" in
            *enabled*) SECURE_BOOT="on" ;;
            *disabled*) SECURE_BOOT="off" ;;
        esac
    elif [ -d /sys/firmware/efi ]; then
        # SecureBoot efivar: last byte 1 = on
        local f; f="$(find /sys/firmware/efi/efivars -name 'SecureBoot-*' 2>/dev/null | head -1)"
        if [ -n "$f" ]; then
            od -An -t u1 "$f" 2>/dev/null | awk '{print $NF}' | grep -q '^1$' && SECURE_BOOT="on" || SECURE_BOOT="off"
        fi
    fi
    log_raw "SECURE_BOOT=$SECURE_BOOT"
}

detect_cpu() {
    CPU_VENDOR="unknown"
    case "$(awk -F': ' '/vendor_id/{print $2; exit}' /proc/cpuinfo)" in
        AuthenticAMD) CPU_VENDOR="amd" ;;
        GenuineIntel) CPU_VENDOR="intel" ;;
    esac
    log_raw "CPU_VENDOR=$CPU_VENDOR"
}

detect_iommu() {
    IOMMU_STATE="off"
    if dmesg 2>/dev/null | grep -qE 'Detected AMD IOMMU|Adding to iommu group|Intel-IOMMU|DMAR: IOMMU enabled'; then
        IOMMU_STATE="on"
    fi
    if [ -d /sys/class/iommu ] && [ -n "$(ls -A /sys/class/iommu 2>/dev/null)" ]; then
        IOMMU_STATE="on"
    fi
    log_raw "IOMMU_STATE=$IOMMU_STATE"
}

detect_all() {
    detect_pve
    detect_bootloader
    detect_secure_boot
    detect_cpu
    detect_iommu
}

# Human summary block printed at startup.
print_host_summary() {
    echo ""
    log_step "Host summary"
    printf '    %-16s %s\n' "Proxmox VE:" "${PVE_VERSION:-?} (major ${PVE_MAJOR:-?}, ${DEBIAN_CODENAME:-?})"
    printf '    %-16s %s\n' "Kernel:" "${KERNEL_VERSION:-?}"
    printf '    %-16s %s\n' "Bootloader:" "${BOOTLOADER:-?}"
    printf '    %-16s %s\n' "Secure Boot:" "${SECURE_BOOT:-?}"
    printf '    %-16s %s\n' "CPU vendor:" "${CPU_VENDOR:-?}"
    printf '    %-16s %s\n' "IOMMU:" "${IOMMU_STATE:-?}"
    echo ""
}

# Guard: refuse unsupported Proxmox majors with a clear message.
assert_supported_pve() {
    case "${PVE_MAJOR:-}" in
        8|9) : ;;
        7)  log_warn "Proxmox 7 is end-of-life. Only legacy 16.x drivers may work; upgrade to PVE 8/9 is strongly recommended." ;;
        *)  die "Unsupported or undetected Proxmox version '${PVE_VERSION:-?}'. This installer supports PVE 8 and 9 (7 is legacy)." ;;
    esac
}

module_init "detect.sh"
