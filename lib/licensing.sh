# shellcheck shell=bash
# lib/licensing.sh — FastAPI-DLS 2.x licensing server + guest token scripts.
# Modern: `docker compose` plugin (not docker-compose v1), no compose `version:` key,
# reliable host-IP detection, and gridd-unlock-patcher guidance for R570+/R580 guests.

FASTAPI_DLS_IMAGE="collinwebdesigns/fastapi-dls:2"

# Pick a routable host IP (never loopback). Falls back to asking.
_detect_host_ip() {
    local ip
    ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -vE '^(127\.|::1|$)' | head -1)"
    [ -n "$ip" ] || ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)"
    [ -n "$ip" ] || ip="$(ask_value 'Enter this host IP for the license server' '')"
    echo "$ip"
}

_install_docker() {
    if need_cmd docker && docker compose version >/dev/null 2>&1; then
        log_info "Docker + compose plugin already present."
        return 0
    fi
    log_warn "Installing Docker on the Proxmox HOST. (Cleaner alternative: run FastAPI-DLS in a VM/LXC.)"
    ask_yes_no "Install Docker-CE on the Proxmox host?" n || die "Aborted Docker install. Set up FastAPI-DLS in a VM/LXC instead."
    run_shell "Installing Docker-CE" info '
        install -m 0755 -d /etc/apt/keyrings
        apt-get install -y ca-certificates curl
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" >/etc/apt/sources.list.d/docker.list
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin'
}

configure_licensing() {
    echo ""
    if ! ask_yes_no "Set up a FastAPI-DLS licensing server on this host?" n; then
        log_info "Skipping license server."
        echo "To self-host later, see: https://git.collinwebdesigns.de/oscar.krause/fastapi-dls#docker"
        return 0
    fi

    _install_docker

    local ip port tz cert_dir=/opt/docker/fastapi-dls/cert
    ip="$(_detect_host_ip)"
    tz="$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"
    echo ""
    log_warn "Do not use 80/443 — Proxmox already uses them."
    port="$(ask_value 'FastAPI-DLS port' '8443')"

    run_shell "Generating certificates" info "
        mkdir -p '$cert_dir'
        openssl genrsa -out '$cert_dir/instance.private.pem' 2048
        openssl rsa -in '$cert_dir/instance.private.pem' -outform PEM -pubout -out '$cert_dir/instance.public.pem'
        printf '\n\n\n\n\n\n\n' | openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout '$cert_dir/webserver.key' -out '$cert_dir/webserver.crt'
        docker volume create dls-db >/dev/null 2>&1 || true"

    local compose_dir=/opt/docker/fastapi-dls
    mkdir -p "$compose_dir"
    # Note: no `version:` key (obsolete in Compose v2).
    cat >"$compose_dir/docker-compose.yml" <<EOF
x-dls-variables: &dls-variables
  TZ: ${tz}
  DLS_URL: ${ip}
  DLS_PORT: ${port}
  LEASE_EXPIRE_DAYS: 90
  DATABASE: sqlite:////app/database/db.sqlite
  DEBUG: "false"

services:
  fastapi-dls:
    image: ${FASTAPI_DLS_IMAGE}
    restart: always
    container_name: fastapi-dls
    environment:
      <<: *dls-variables
    ports:
      - "${port}:443"
    volumes:
      - ${cert_dir}:/app/cert
      - dls-db:/app/database
    logging:
      driver: "json-file"
      options: { max-file: "5", max-size: "10m" }

volumes:
  dls-db:
EOF
    run_command "Starting FastAPI-DLS (compose v2)" info docker compose -f "$compose_dir/docker-compose.yml" up -d

    _write_guest_license_scripts "$ip" "$port"
    _print_guest_licensing_guidance "$ip" "$port"
}

# Emit per-OS scripts into ./licenses. Each script optionally downloads the
# matching guest driver (from the catalog) and then fetches a license token.
_write_guest_license_scripts() {
    local ip="$1" port="$2" dir="$VGPU_DIR/licenses"
    mkdir -p "$dir"

    # Resolve the matching guest driver for the installed release from the catalog.
    local rel="${DRIVER_RELEASE:-}" gl gw gdir base gl_url gw_url
    gl="$(driver_field "$rel" '.guest.linux' 2>/dev/null || echo '')"
    gw="$(driver_field "$rel" '.guest.windows' 2>/dev/null || echo '')"
    gdir="$(driver_field "$rel" '.guest_release_dir' 2>/dev/null || echo '')"
    base="https://storage.googleapis.com/nvidia-drivers-us-public/GRID"
    [ -n "$gl" ] && [ -n "$gdir" ] && gl_url="${base}/${gdir}/${gl}"
    [ -n "$gw" ] && [ -n "$gdir" ] && gw_url="${base}/${gdir}/${gw}"

    # ---- Linux guest ----
    {
        echo '#!/bin/bash'
        echo '# vGPU guest setup: (optionally) install the guest driver, then license it.'
        echo "# Matches host vGPU release ${rel:-<unknown>}."
        echo 'set -e'
        echo 'INSTALL_DRIVER="${1:-}"   # pass --install-driver to download + install the guest driver'
        echo ''
        if [ -n "${gl_url:-}" ]; then
            echo 'if [ "$INSTALL_DRIVER" = "--install-driver" ]; then'
            echo "  echo '[+] Downloading guest driver ${gl}'"
            echo "  curl -fSL '${gl_url}' -o '/tmp/${gl}'"
            echo "  chmod +x '/tmp/${gl}'"
            echo "  '/tmp/${gl}' --dkms -s"
            echo 'fi'
        else
            echo "# No pinned Linux guest driver URL for ${rel:-this release}; download it from the"
            echo "# NVIDIA vGPU ${gdir:-<release>} package and install with:  ./NVIDIA-...-grid.run --dkms -s"
        fi
        echo ''
        echo '# gridd-unlock-patcher is required for 18.x/19.x guests before tokens are accepted.'
        echo "curl --insecure -L -X GET https://${ip}:${port}/-/client-token \\"
        echo "  -o \"/etc/nvidia/ClientConfigToken/client_configuration_token_\$(date '+%d-%m-%Y-%H-%M-%S').tok\""
        echo 'systemctl restart nvidia-gridd 2>/dev/null || service nvidia-gridd restart'
        echo 'nvidia-smi -q | grep -i License'
    } >"$dir/license_linux.sh"

    # ---- Windows guest ----
    {
        echo "# vGPU guest setup for Windows. Matches host vGPU release ${rel:-<unknown>}."
        echo 'param([switch]$InstallDriver)'
        echo ''
        if [ -n "${gw_url:-}" ]; then
            echo 'if ($InstallDriver) {'
            echo "  Write-Host '[+] Downloading guest driver ${gw}'"
            echo "  curl.exe -fSL '${gw_url}' -o \"\$env:TEMP\\${gw}\""
            echo "  Start-Process -Wait -FilePath \"\$env:TEMP\\${gw}\" -ArgumentList '-s'"
            echo '}'
        else
            echo "# No pinned Windows guest driver URL for ${rel:-this release}; download the installer"
            echo "# from the NVIDIA vGPU ${gdir:-<release>} package and run it before licensing."
        fi
        echo ''
        echo "curl.exe --insecure -L -X GET https://${ip}:${port}/-/client-token \`"
        echo "  -o \"C:\\Program Files\\NVIDIA Corporation\\vGPU Licensing\\ClientConfigToken\\client_configuration_token_\$(Get-Date -f 'dd-MM-yy-hh-mm-ss').tok\""
        echo 'Restart-Service NVDisplay.ContainerLocalSystem'
        echo "& 'nvidia-smi' -q | Select-String 'License'"
    } >"$dir/license_windows.ps1"

    chmod +x "$dir/license_linux.sh"
    log_info "Guest scripts written to $dir (copy into your VMs)."
    if [ -n "${gl_url:-}" ] || [ -n "${gw_url:-}" ]; then
        log_info "Run with --install-driver (Linux) / -InstallDriver (Windows) to also fetch+install the guest driver."
    fi
}

_print_guest_licensing_guidance() {
    local ip="$1" port="$2" branch
    branch="$(driver_field "${DRIVER_RELEASE:-}" '.branch' 2>/dev/null || echo '')"
    echo ""
    log_step "Guest licensing"
    log_info "License server: https://${ip}:${port}"
    case "$branch" in
        R570|R580|R595)
            log_warn "Your driver branch (${branch}) needs gridd-unlock-patcher IN THE GUEST before FastAPI-DLS tokens work."
            log_warn "In each guest: patch nvidia-gridd with gridd-unlock-patcher, then run the license script."
            log_info  "gridd-unlock-patcher: https://git.collinwebdesigns.de/oscar.krause/gridd-unlock-patcher"
            ;;
        R535|R550)
            log_info "16.x/17.x guests work directly with FastAPI-DLS — just run the license script." ;;
        *)
            log_info "After installing the guest driver, run the matching license script from ./licenses." ;;
    esac
}

module_init "licensing.sh"
