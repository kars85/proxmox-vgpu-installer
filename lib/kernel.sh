# shellcheck shell=bash
# lib/kernel.sh — kernel cmdline (GRUB or systemd-boot), VFIO modules, nouveau
# blacklist, initramfs, and Secure Boot / DKMS MOK handling.

# Add IOMMU parameters to the correct bootloader for this host.
configure_iommu_cmdline() {
    local params
    case "$CPU_VENDOR" in
        amd)   params="amd_iommu=on iommu=pt" ;;
        intel) params="intel_iommu=on iommu=pt" ;;
        *)     die "Unknown CPU vendor; cannot configure IOMMU cmdline." ;;
    esac
    log_info "CPU vendor: ${CPU_VENDOR} — ensuring '${params}'"

    case "$BOOTLOADER" in
        grub)         _cmdline_grub "$params" ;;
        systemd-boot) _cmdline_systemd_boot "$params" ;;
        *)            log_warn "Unknown bootloader; add '${params}' to your kernel cmdline manually." ;;
    esac
}

_cmdline_grub() {
    local params="$1" f=/etc/default/grub
    [ -f "$f" ] || die "$f not found (GRUB expected)."
    if grep -q "$params" "$f"; then
        log_warn "IOMMU params already present in GRUB_CMDLINE_LINUX_DEFAULT"
    else
        sed -i "/^GRUB_CMDLINE_LINUX_DEFAULT=/s/\"$/ ${params}\"/" "$f"
        log_info "Added IOMMU params to GRUB"
    fi
    run_command "Updating GRUB" info update-grub
}

_cmdline_systemd_boot() {
    local params="$1" f=/etc/kernel/cmdline
    if [ ! -f "$f" ]; then
        # Some setups keep cmdline only in bootloader entries; create a baseline.
        echo "root=ZFS=rpool/ROOT/pve-1 boot=zfs" >"$f"
        log_warn "Created $f (verify root= is correct for your system)."
    fi
    if grep -q "$params" "$f"; then
        log_warn "IOMMU params already present in $f"
    else
        sed -i "s|\$| ${params}|" "$f"
        log_info "Added IOMMU params to $f"
    fi
    run_command "Refreshing boot entries (proxmox-boot-tool)" info proxmox-boot-tool refresh
}

# Load VFIO modules. vfio_virqfd was merged into vfio core in kernel 6.2 and must
# NOT be listed on newer kernels (it fails to load and spams the journal).
configure_vfio_modules() {
    local mods=(vfio vfio_iommu_type1 vfio_pci)
    local km; km="$(kernel_mm)"
    if [ -n "$km" ] && ! ver_ge "$km" "6.2"; then
        mods+=(vfio_virqfd)   # only for kernels < 6.2
    fi
    local changed=0 m
    for m in "${mods[@]}"; do
        if ! grep -qxF "$m" /etc/modules 2>/dev/null; then
            echo "$m" >>/etc/modules; changed=1
        fi
    done
    # Remove a stale vfio_virqfd entry on newer kernels.
    if [ -n "$km" ] && ver_ge "$km" "6.2" && grep -qxF "vfio_virqfd" /etc/modules 2>/dev/null; then
        sed -i '/^vfio_virqfd$/d' /etc/modules
        log_info "Removed obsolete vfio_virqfd from /etc/modules (kernel ${km} >= 6.2)"
        changed=1
    fi
    [ "$changed" -eq 1 ] && log_info "VFIO modules configured in /etc/modules" || log_warn "VFIO modules already present"
}

blacklist_nouveau() {
    local f=/etc/modprobe.d/blacklist.conf
    if grep -qs 'blacklist nouveau' "$f" 2>/dev/null; then
        log_warn "nouveau already blacklisted"
    else
        echo "blacklist nouveau" >>"$f"
        log_info "Blacklisted nouveau"
    fi
}

update_initramfs() {
    run_command "Updating initramfs" info update-initramfs -u -k all
}

# Secure Boot guidance/handling for DKMS-signed NVIDIA modules.
handle_secure_boot() {
    [ "${SECURE_BOOT:-off}" = "on" ] || return 0
    echo ""
    log_warn "Secure Boot is ENABLED. Unsigned DKMS NVIDIA modules will not load."
    echo "    You have two options:"
    echo "      1) Disable Secure Boot in your firmware (simplest), or"
    echo "      2) Enroll a MOK so DKMS-signed modules are trusted."
    if need_cmd mokutil && need_cmd update-secureboot-policy; then
        if ask_yes_no "Enroll a Machine Owner Key (MOK) for module signing now?" y; then
            ALLOW_FAIL=1 run_command "Registering DKMS MOK (you'll set a one-time password)" info \
                update-secureboot-policy --enroll-key
            log_warn "Reboot will prompt (MOK Manager) to enroll the key — choose 'Enroll MOK' and enter the password."
        fi
    else
        log_warn "mokutil/update-secureboot-policy not available; disable Secure Boot or enroll a key manually."
    fi
}

module_init "kernel.sh"
