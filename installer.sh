#!/usr/bin/env bash
#
# installer.sh — NVIDIA vGPU installer for Proxmox VE 8.x / 9.x
# Modular rewrite (v2.0) of proxmox-installer.sh. Original concept by wvthoog.nl.
#
# Subcommands:  install | upgrade | remove | download | license | profiles | menu
# Flags:        --debug  --step N  --mode native|unlock  --url U  --file F  --yes
#
set -Eeuo pipefail

# --- Resolve our own directory (fixes the legacy $(pwd) assumption) ---------
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_SOURCE" ]; do
    dir="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
    SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
    [[ "$SCRIPT_SOURCE" != /* ]] && SCRIPT_SOURCE="$dir/$SCRIPT_SOURCE"
done
VGPU_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
LIB_DIR="$VGPU_DIR/lib"
DATA_DIR="$VGPU_DIR/data"
LOG_FILE="$VGPU_DIR/debug.log"
STATE_FILE="$VGPU_DIR/state.env"
SCRIPT_VERSION="2.0"

# --- Defaults / state -------------------------------------------------------
DEBUG=false
ASSUME_YES=0
STEP="${STEP:-}"
MODE="${MODE:-}"              # native | unlock | any
URL="${URL:-}"
FILE="${FILE:-}"
VGPU_SUPPORT="${VGPU_SUPPORT:-}"
DRIVER_RELEASE="${DRIVER_RELEASE:-}"
GPU_ARCH="${GPU_ARCH:-}"
SELECTED_PCI="${SELECTED_PCI:-}"

# --- Load modules -----------------------------------------------------------
for m in common detect repos gpu driver kernel unlock sriov profiles licensing; do
    # shellcheck source=/dev/null
    source "$LIB_DIR/${m}.sh"
done

trap 'log_error "Unexpected error on line $LINENO (exit $?). See $LOG_FILE."' ERR

# --- Argument parsing -------------------------------------------------------
SUBCOMMAND=""
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            install|upgrade|remove|download|license|profiles|override|menu) SUBCOMMAND="$1"; shift ;;
            --debug) DEBUG=true; shift ;;
            --yes|-y) ASSUME_YES=1; shift ;;
            --step) STEP="$2"; shift 2 ;;
            --mode) MODE="$2"; shift 2 ;;
            --url) URL="$2"; shift 2 ;;
            --file) FILE="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) log_error "Unknown argument: $1"; usage; exit 1 ;;
        esac
    done
}

usage() {
    cat <<EOF
Usage: $0 [subcommand] [options]

Subcommands:
  install     New vGPU installation (default; two-phase, reboots between).
  upgrade     Replace the driver on an existing install.
  remove      Remove drivers, unlock, patches, and licensing.
  download    Fetch/verify a host driver only.
  license     Configure the FastAPI-DLS licensing server.
  profiles    Show vGPU profiles a GPU supports (pre- or post-install).
  override    Create a vgpu_unlock profile override (TOML) for an mdev type.
  menu        Interactive menu (default when no subcommand given).

Options:
  --mode native|unlock   Force install mode (default: auto from GPU database).
  --url  <url>           Host driver download URL (.run or .zip).
  --file <path>          Local host driver .run to use.
  --step <1|2>           Resume a specific install phase.
  --yes, -y              Non-interactive: assume defaults / yes.
  --debug                Stream command output instead of logging quietly.
EOF
}

banner() {
    echo ""
    echo -e "${GREEN}  NVIDIA vGPU installer for Proxmox VE${NC} — version ${SCRIPT_VERSION}"
    echo -e "  ${GRAY}modular rewrite; original concept by wvthoog.nl${NC}"
    print_host_summary
}

# --- Mode resolution --------------------------------------------------------
resolve_mode() {
    # If the user forced a mode, respect it. Otherwise derive from GPU support.
    if [ -n "$MODE" ]; then return; fi
    case "$VGPU_SUPPORT" in
        Native) MODE="native" ;;
        Yes)    MODE="unlock" ;;
        No)     die "Selected GPU is not vGPU-capable; nothing to install." ;;
        *)      log_warn "GPU vGPU capability unknown; defaulting to native install (no unlock)."; MODE="native" ;;
    esac
    log_info "Install mode: ${MODE}"
}

# --- Dependencies -----------------------------------------------------------
install_dependencies() {
    local pkgs=(git build-essential dkms mdevctl jq pciutils unzip)
    # Header package: current-kernel headers, no 6.5 pin/downgrade.
    if apt-cache show proxmox-default-headers >/dev/null 2>&1; then
        pkgs+=(proxmox-default-headers)
    else
        pkgs+=("pve-headers-$(uname -r)")
    fi
    # On PVE 8.4+/9 the helper pulls vGPU deps and provides the SR-IOV service.
    if apt-cache show pve-nvidia-vgpu-helper >/dev/null 2>&1; then
        pkgs+=(pve-nvidia-vgpu-helper)
    fi
    run_command "Installing packages: ${pkgs[*]}" info apt-get install -y "${pkgs[@]}"
    if need_cmd pve-nvidia-vgpu-helper; then
        ALLOW_FAIL=1 run_command "Running pve-nvidia-vgpu-helper setup" info pve-nvidia-vgpu-helper setup
    fi
}

# --- Phase 1: prepare the host ----------------------------------------------
do_step1() {
    local upgrade="${1:-0}"
    banner
    assert_supported_pve
    setup_repositories

    if ask_yes_no "Run 'apt dist-upgrade' now (recommended)?" y; then
        run_command "Running apt dist-upgrade (may take a while)" info apt-get dist-upgrade -y
    fi
    install_dependencies

    if [ "$upgrade" = "1" ]; then
        _remove_driver_only
    fi

    detect_and_select_gpu
    resolve_mode

    if [ "$MODE" = "unlock" ]; then
        install_vgpu_unlock
    fi

    configure_vfio_modules
    blacklist_nouveau
    configure_iommu_cmdline
    handle_secure_boot
    update_initramfs

    STEP=2; state_save
    echo ""
    log_info "Phase 1 complete. Reboot to load IOMMU + VFIO, then re-run to install the driver."
    if ask_yes_no "Reboot now?" n; then
        reboot
    else
        log_info "Reboot later, then run: $0 install"
    fi
}

# --- Phase 2: install the driver --------------------------------------------
do_step2() {
    banner
    _check_iommu_active

    if [ -z "$MODE" ]; then resolve_mode; fi

    # Resolve the driver: explicit file/url, or catalog selection.
    if [ -z "${DRIVER_FILE:-}" ] && [ -z "$FILE" ] && [ -z "$URL" ]; then
        choose_driver "$MODE"
    fi
    obtain_driver_file
    install_driver "$MODE"

    _verify_driver_loaded

    ALLOW_FAIL=1 run_command "Enabling nvidia-vgpud.service" info systemctl enable --now nvidia-vgpud.service
    ALLOW_FAIL=1 run_command "Enabling nvidia-vgpu-mgr.service" info systemctl enable --now nvidia-vgpu-mgr.service

    # Ampere+ needs SR-IOV VFs before profiles are creatable.
    enable_sriov

    print_guest_driver_info
    echo ""
    log_step "Available vGPU profiles for your card:"
    profiles_show "${SELECTED_DEVID:-}" "${DRIVER_RELEASE%%.*}"

    echo ""
    log_info "Assign a vGPU in the Proxmox GUI: Datacenter -> Resource Mappings (enable 'Use with"
    log_info "mediated devices'), then VM -> Hardware -> Add -> PCI Device -> your mapping."
    state_clear

    # Offer a profile override for unlocked cards (custom framebuffer, CUDA, frl).
    if [ "$MODE" = "unlock" ] && ask_yes_no "Create a vgpu_unlock profile override now?" n; then
        configure_profile_override
    fi

    configure_licensing
    echo ""
    log_info "Installation complete."
}

_check_iommu_active() {
    detect_iommu
    if [ "$IOMMU_STATE" = "on" ]; then
        log_info "IOMMU is active."
    else
        log_warn "IOMMU does not appear active. Ensure VT-d/AMD-Vi is enabled in BIOS and the kernel cmdline is set."
        ask_yes_no "Continue anyway?" n || die "Aborted: IOMMU not active."
    fi
}

_verify_driver_loaded() {
    local out; out="$(nvidia-smi 2>&1 || true)"
    if echo "$out" | grep -q 'Driver Version'; then
        log_info "NVIDIA driver loaded: $(echo "$out" | sed -n 's/.*Driver Version: \([0-9.]*\).*/\1/p' | head -1)"
    else
        log_warn "nvidia-smi did not report a driver. It may require the reboot from phase 1, or the DKMS build failed (see $LOG_FILE)."
    fi
}

# --- Removal ----------------------------------------------------------------
_remove_driver_only() {
    ALLOW_FAIL=1 run_command "Removing existing NVIDIA driver" notification nvidia-uninstall -s
}

do_remove() {
    banner
    log_step "Remove vGPU installation"
    if ask_yes_no "Remove the NVIDIA driver (nvidia-uninstall)?" n; then
        _remove_driver_only
    fi
    if ask_yes_no "Remove vgpu_unlock-rs?" n; then
        run_command "Removing vgpu_unlock-rs" notification rm -rf /opt/vgpu_unlock-rs
        rm -f /etc/systemd/system/nvidia-vgpud.service.d/vgpu_unlock.conf \
              /etc/systemd/system/nvidia-vgpu-mgr.service.d/vgpu_unlock.conf
    fi
    if ask_yes_no "Remove the vgpu-proxmox patch repo?" n; then
        # (legacy script had a 'vgpu-promox' typo here that never removed anything)
        run_command "Removing vgpu-proxmox" notification rm -rf "$VGPU_DIR/vgpu-proxmox"
    fi
    if ask_yes_no "Remove the FastAPI-DLS licensing container?" n; then
        ALLOW_FAIL=1 run_command "Removing FastAPI-DLS" notification docker rm -f -v fastapi-dls
    fi
    log_info "Removal complete. A reboot is recommended."
}

# --- download / license / profiles subcommands ------------------------------
do_download() {
    banner
    choose_driver "${MODE:-any}"
    obtain_driver_file
    log_info "Driver ready: $DRIVER_FILE"
}

do_license() { banner; configure_licensing; }

do_override() { banner; configure_profile_override; }

do_profiles() {
    banner
    profiles_show "${SELECTED_DEVID:-}" "${DRIVER_RELEASE%%.*}"
}

# --- Interactive menu -------------------------------------------------------
do_menu() {
    banner
    echo "Select an option:"
    echo "  1) New vGPU installation"
    echo "  2) Upgrade vGPU installation (replace driver)"
    echo "  3) Remove vGPU installation"
    echo "  4) Download vGPU driver only"
    echo "  5) Configure licensing (FastAPI-DLS)"
    echo "  6) Show vGPU profiles for a GPU"
    echo "  7) Create vgpu_unlock profile override"
    echo "  8) Exit"
    echo ""
    local c; c="$(ask_value 'Enter your choice' '1')"
    case "$c" in
        1) STEP=1; do_step1 0 ;;
        2) STEP=1; do_step1 1 ;;
        3) do_remove ;;
        4) do_download ;;
        5) do_license ;;
        6) do_profiles ;;
        7) do_override ;;
        8) log_info "Bye."; exit 0 ;;
        *) die "Invalid choice: $c" ;;
    esac
}

# --- Main -------------------------------------------------------------------
main() {
    : >"$LOG_FILE" 2>/dev/null || true
    parse_args "$@"
    require_root
    state_load
    detect_all

    # Explicit subcommands win; otherwise resume by STEP, else show the menu.
    case "${SUBCOMMAND:-}" in
        install)  [ "${STEP:-1}" = "2" ] && do_step2 || do_step1 0 ;;
        upgrade)  [ "${STEP:-1}" = "2" ] && do_step2 || do_step1 1 ;;
        remove)   do_remove ;;
        download) do_download ;;
        license)  do_license ;;
        profiles) do_profiles ;;
        override) do_override ;;
        menu|"")
            if [ "${STEP:-}" = "2" ]; then
                log_info "Resuming install at phase 2 (from ${STATE_FILE})."
                do_step2
            else
                do_menu
            fi
            ;;
    esac
}

main "$@"
