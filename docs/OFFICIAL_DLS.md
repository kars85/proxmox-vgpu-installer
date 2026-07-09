# Official NVIDIA DLS 3.6.1 (local) — runbook

This is the **official, NVIDIA-signed** licensing path. Unlike the self-hosted
FastAPI-DLS option, it licenses **R570/R580/R595 (vGPU 18/19/20) guests natively —
no `gridd-unlock-patcher`**. It is heavier and requires a one-time NVIDIA Licensing
Portal registration.

> The images are NVIDIA's proprietary software, downloaded under your entitlement.
> They are used **locally only** and are **never published** to any registry.

## Prerequisites

- The `nls-3.6.1-bios` distribution extracted somewhere on the host
  (contains `docker/docker-compose.yml` + `dls_appliance_3.6.1.tar.gz` +
  `dls_pgsql_3.6.1.tar.gz`).
- Docker + the `docker compose` plugin.
- Free ports and RAM: the stack wants **443, 80, 5671, 8080–8085** and ~**6 GB RAM**.
- An NVIDIA Licensing Portal account with vGPU license entitlements.

**Placement:** running NVIDIA's full multi-container stack directly on the Proxmox
host is not ideal (ports + RAM + a fixed `172.16.238.0/24` docker subnet). Prefer a
dedicated **VM or LXC**, or use the **qcow2 appliance** (`nls-3.6.1-bios.qcow2`)
imported as a Proxmox VM instead of the containers.

## Automated stand-up

```bash
./installer.sh official-dls
# or menu option 6
```

This will:
1. `docker load` `dls:appliance_3.6.1` and `dls:pgsql_3.6.1` from the tarballs.
2. Ask for the FQDN and exposed HTTPS/HTTP ports; detect the host IP.
3. Write `nls-3.6.1-bios/docker/.env` with the three required variables
   (`DLS_PUBLIC_IP`, `FQDN`, `DLS_PRIVATE_HOSTNAME`) plus your port choices.
4. `docker compose -p nvidia-dls up -d`.

Set `NLS_DIR=/path/to/nls-3.6.1-bios` to skip the path prompt.

## Manual steps (cannot be scripted)

1. Open the **DLS admin console**: `https://<host-ip>:<https-port>` and set the admin password.
2. In the **NVIDIA Licensing Portal**, create a license server and allocate your licenses.
3. **Register this DLS instance** with the portal: download the DLS instance token and
   upload it in the admin console (or connect the DLS if you use CLS).
4. **Install the license server / bind features** in the console.
5. **Download a client configuration token** (`.tok`) from the console.
6. On each guest, place the token and restart the licensing service:
   ```bash
   # Linux guest
   ./licenses/license_official_linux.sh /path/to/client_configuration_token.tok
   ```
   ```powershell
   # Windows guest
   .\licenses\license_official_windows.ps1 -Token C:\path\client_configuration_token.tok
   ```

Full click-path: [NVIDIA DLS 3.6.1 User Guide](https://docs.nvidia.com/license-system/dls/3.6.1/).

## Managing the stack

```bash
docker compose -p nvidia-dls ps
docker compose -p nvidia-dls logs -f
docker compose -p nvidia-dls down          # stop
```

## Choosing between the two backends

| | FastAPI-DLS (self-hosted) | Official DLS 3.6.1 |
|---|---|---|
| Cost / entitlement | none needed | requires NVIDIA vGPU licenses |
| R595 / vGPU 20 | needs gridd-unlock-patcher (unverified) | **native, supported** |
| Footprint | ~256 MB, 1 container | ~6 GB, postgres + rabbitmq |
| Setup | one command | stand-up + portal registration |
| Publishable | yes (open source) | no (proprietary, local only) |
