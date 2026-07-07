# shellcheck shell=bash
# lib/licensing.sh — FastAPI-DLS 2.x licensing server + guest token scripts.
# Modern: `docker compose` plugin (not docker-compose v1), no compose `version:` key,
# reliable host-IP detection, post-deploy health check, and gridd-unlock-patcher
# automation (root-cert fetch + guest patch) for R570/R580/R595 guests.

# Pinned by immutable digest (multi-arch manifest list) for reproducibility; the
# tag is kept in the ref for readability. Matches third_party/fastapi-dls @ 2.0.3.
# Override with FASTAPI_DLS_IMAGE=... to use your own build (e.g. ghcr.io/kars85/...).
FASTAPI_DLS_IMAGE="${FASTAPI_DLS_IMAGE:-collinwebdesigns/fastapi-dls:2.0.3@sha256:e5078363ef86548b41c998367dfa2641015c5b7ffb7b3db280332669f8b1b5f0}"

# Guest-side patcher required for driver branches R570 and newer (vGPU 18.x+).
GRIDD_UNLOCK_PATCHER_URL="https://git.collinwebdesigns.de/vgpu/gridd-unlock-patcher"

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

    _wait_for_dls_health "$ip" "$port"
    _write_guest_license_scripts "$ip" "$port"
    _print_guest_licensing_guidance "$ip" "$port"
}

# Poll the container's /-/health endpoint after startup so failures surface here
# rather than later in a guest.
_wait_for_dls_health() {
    local ip="$1" port="$2" i
    log_info "Waiting for FastAPI-DLS to become healthy on https://${ip}:${port} ..."
    for i in $(seq 1 30); do
        if curl -fsSk "https://${ip}:${port}/-/health" >/dev/null 2>&1; then
            log_info "FastAPI-DLS is healthy."
            return 0
        fi
        sleep 2
    done
    log_warn "FastAPI-DLS did not report healthy within 60s. Check: docker logs fastapi-dls"
    ALLOW_FAIL=1 run_command "Recent container logs" warn docker logs --tail 20 fastapi-dls
    return 0
}

# Emit per-OS scripts into ./licenses. Each script optionally downloads the
# matching guest driver (from the catalog) and then fetches a license token.
_write_guest_license_scripts() {
    local ip="$1" port="$2" dir="$VGPU_DIR/licenses"
    mkdir -p "$dir"

    # Resolve the matching guest driver for the installed release from the catalog.
    local rel="${DRIVER_RELEASE:-}" gl gw gdir base gl_url gw_url branch needs_gridd
    gl="$(driver_field "$rel" '.guest.linux' 2>/dev/null || echo '')"
    gw="$(driver_field "$rel" '.guest.windows' 2>/dev/null || echo '')"
    gdir="$(driver_field "$rel" '.guest_release_dir' 2>/dev/null || echo '')"
    base="https://storage.googleapis.com/nvidia-drivers-us-public/GRID"
    [ -n "$gl" ] && [ -n "$gdir" ] && gl_url="${base}/${gdir}/${gl}"
    [ -n "$gw" ] && [ -n "$gdir" ] && gw_url="${base}/${gdir}/${gw}"

    # R570 and newer guests must patch nvidia-gridd to trust the self-hosted DLS.
    branch="$(driver_field "$rel" '.branch' 2>/dev/null || echo '')"
    case "$branch" in R570|R580|R595) needs_gridd=1 ;; *) needs_gridd=0 ;; esac

    # ---- Linux guest ----
    {
        echo '#!/bin/bash'
        echo '# vGPU guest setup: (optionally) install the guest driver, patch gridd, then license it.'
        echo "# Matches host vGPU release ${rel:-<unknown>} (${branch:-?})."
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
        if [ "$needs_gridd" = "1" ]; then
            echo "# --- ${branch} requires gridd-unlock-patcher so nvidia-gridd trusts this DLS ---"
            echo "echo '[+] Fetching FastAPI-DLS root certificate'"
            echo "curl --insecure -fsSL https://${ip}:${port}/-/config/root-certificate -o /tmp/dls-root.pem"
            echo 'GRIDD_BIN="$(command -v nvidia-gridd || echo /usr/bin/nvidia-gridd)"'
            echo 'PATCHER="$(command -v gridd-unlock-patcher || echo ./gridd-unlock-patcher)"'
            echo 'if [ -x "$PATCHER" ]; then'
            echo '  echo "[+] Backing up $GRIDD_BIN and patching it"'
            echo '  cp -n "$GRIDD_BIN" "${GRIDD_BIN}.bak" || true'
            echo '  "$PATCHER" -g "$GRIDD_BIN" -c /tmp/dls-root.pem'
            echo 'else'
            echo "  echo '[!] gridd-unlock-patcher binary not found. Download the Linux release from:'"
            echo "  echo '    ${GRIDD_UNLOCK_PATCHER_URL}/-/releases'"
            echo "  echo '    then re-run this script (or run: gridd-unlock-patcher -g \$GRIDD_BIN -c /tmp/dls-root.pem)'"
            echo '  exit 1'
            echo 'fi'
            echo ''
        fi
        echo 'echo "[+] Fetching client license token"'
        echo "curl --insecure -L -X GET https://${ip}:${port}/-/client-token \\"
        echo "  -o \"/etc/nvidia/ClientConfigToken/client_configuration_token_\$(date '+%d-%m-%Y-%H-%M-%S').tok\""
        echo 'systemctl restart nvidia-gridd 2>/dev/null || service nvidia-gridd restart'
        echo 'sleep 2; nvidia-smi -q | grep -i License'
    } >"$dir/license_linux.sh"

    # ---- Windows guest ----
    {
        echo "# vGPU guest setup for Windows. Matches host vGPU release ${rel:-<unknown>} (${branch:-?})."
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
        if [ "$needs_gridd" = "1" ]; then
            echo "# --- ${branch} requires patching nvxdapix.dll (gridd-unlock-patcher runs on LINUX only) ---"
            echo "Write-Host '[!] ${branch} guests must patch nvxdapix.dll before licensing.'"
            echo "Write-Host '    1) Download the DLS root cert:'"
            echo "curl.exe --insecure -fsSL https://${ip}:${port}/-/config/root-certificate -o \"\$env:TEMP\\dls-root.pem\""
            echo "Write-Host '    2) Locate the DLL:' "
            echo 'Get-ChildItem -Path "C:\\Windows\\System32\\DriverStore\\FileRepository" -Recurse -Filter "nvxdapix.dll" -ErrorAction SilentlyContinue | Select-Object -First 1'
            echo "Write-Host '    3) Copy nvxdapix.dll to a Linux box, patch with:'"
            echo "Write-Host '       gridd-unlock-patcher -g nvxdapix.dll -c dls-root.pem'"
            echo "Write-Host '    4) Copy the patched DLL back and replace it, then continue below.'"
            echo "Write-Host '    See: ${GRIDD_UNLOCK_PATCHER_URL}'"
            echo ''
        fi
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
    if [ "$needs_gridd" = "1" ]; then
        log_warn "Linux script auto-patches nvidia-gridd if the gridd-unlock-patcher binary is on PATH; otherwise it prints the download link and stops."
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
            log_warn "The generated license_linux.sh fetches the DLS root cert and patches nvidia-gridd automatically if the patcher binary is present."
            log_info  "gridd-unlock-patcher: ${GRIDD_UNLOCK_PATCHER_URL} (Linux release binary; see third_party/gridd-unlock-patcher pinned fork)"
            ;;
        R535|R550)
            log_info "16.x/17.x guests work directly with FastAPI-DLS — just run the license script." ;;
        *)
            log_info "After installing the guest driver, run the matching license script from ./licenses." ;;
    esac
}

module_init "licensing.sh"
