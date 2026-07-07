# shellcheck shell=bash
# lib/sriov.sh — Ampere and newer create vGPUs through SR-IOV virtual functions
# rather than legacy mdev. This module enables and verifies VFs.

# True when the selected GPU uses the SR-IOV path (Ampere+), false for mdev (Turing/older).
gpu_uses_sriov() {
    case "${GPU_ARCH:-unknown}" in
        ampere|ada|blackwell|hopper) return 0 ;;
        *) return 1 ;;
    esac
}

# Enable SR-IOV VFs for the selected card. Prefers the Proxmox-shipped service,
# falls back to NVIDIA's sriov-manage.
enable_sriov() {
    gpu_uses_sriov || { log_raw "sriov: mdev arch, nothing to do"; return 0; }
    local addr="0000:${SELECTED_PCI}"
    log_step "Enabling SR-IOV virtual functions for ${addr} (${GPU_ARCH})"

    if systemctl list-unit-files 2>/dev/null | grep -q '^pve-nvidia-sriov@'; then
        # Proxmox-shipped template unit: already boot-persistent once enabled.
        ALLOW_FAIL=1 run_command "Enabling pve-nvidia-sriov@${addr}" info \
            systemctl enable --now "pve-nvidia-sriov@${addr}.service"
    elif systemctl list-unit-files 2>/dev/null | grep -q '^nvidia-sriov'; then
        ALLOW_FAIL=1 run_command "Enabling nvidia-sriov" info systemctl enable --now nvidia-sriov.service
    elif _find_sriov_manage >/dev/null; then
        # NVIDIA's sriov-manage is one-shot; enable now AND persist across reboots.
        local sm; sm="$(_find_sriov_manage)"
        ALLOW_FAIL=1 run_command "Running ${sm} -e ALL" info "$sm" -e ALL
        _persist_sriov_manage "$sm"
    else
        log_warn "No SR-IOV service or sriov-manage found. On PVE 8.4+/9 install the helper:"
        log_warn "  apt install pve-nvidia-vgpu-helper && pve-nvidia-vgpu-helper setup"
        return 0
    fi
    verify_sriov_vfs
}

# Locate sriov-manage (NVIDIA installs it under /usr/lib/nvidia).
_find_sriov_manage() {
    if [ -x /usr/lib/nvidia/sriov-manage ]; then echo /usr/lib/nvidia/sriov-manage; return 0; fi
    command -v sriov-manage 2>/dev/null && return 0
    return 1
}

# Some cards (e.g. L4) only expose VFs after `sriov-manage -e ALL`, which does not
# persist. Install a oneshot systemd unit that re-runs it on every boot, ordered
# before Proxmox starts guests.
_persist_sriov_manage() {
    local sm="$1" unit=/etc/systemd/system/nvidia-sriov-manage.service
    if [ -f "$unit" ]; then
        log_info "SR-IOV boot unit already present: $unit"
    else
        cat >"$unit" <<EOF
[Unit]
Description=Enable NVIDIA vGPU SR-IOV virtual functions
After=nvidia-vgpu-mgr.service network.target
Before=pve-guests.service
Wants=nvidia-vgpu-mgr.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${sm} -e ALL

[Install]
WantedBy=multi-user.target
EOF
        log_info "Created boot-persistent SR-IOV unit: $unit"
    fi
    run_command "Reloading systemd" info systemctl daemon-reload
    ALLOW_FAIL=1 run_command "Enabling nvidia-sriov-manage.service (persists VFs at boot)" info \
        systemctl enable nvidia-sriov-manage.service
}

verify_sriov_vfs() {
    local addr="0000:${SELECTED_PCI}" vfs
    vfs="$(lspci -d 10de: 2>/dev/null | grep -ci 'Virtual Function' || true)"
    if [ "${vfs:-0}" -gt 0 ]; then
        log_info "Detected ${vfs} NVIDIA virtual function(s)."
    else
        log_warn "No virtual functions detected yet for ${addr}. They may appear after a reboot, or SR-IOV/ARI may need enabling in BIOS."
    fi
}

module_init "sriov.sh"
