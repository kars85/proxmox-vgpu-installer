# Proxmox NVIDIA vGPU Installer

A Bash tool that configures a **Proxmox VE 8.x or 9.x** host for NVIDIA vGPU —
native (enterprise/data-center cards) or via `vgpu_unlock` on supported consumer
cards. This is the modular **v2.0** rewrite; the original single-file script by
[wvthoog.nl](https://wvthoog.nl/proxmox-7-vgpu-v3/) is preserved under `old/`.

> Original concept and guide by wvthoog. vGPU unlock patches by
> [PolloLoco / vgpu-proxmox](https://gitlab.com/polloloco/vgpu-proxmox). Refreshed
> PCI IDs and driver-catalog data cross-checked against the
> [anomixer fork](https://github.com/anomixer/proxmox-vgpu-installer). Licensing via
> [FastAPI-DLS](https://git.collinwebdesigns.de/oscar.krause/fastapi-dls).

## What's new in v2.0

- **Proxmox VE 9 support** (Debian 13 "trixie"): deb822 `.sources` repositories,
  no more kernel-6.5 pinning/downgrade, kernel 6.8–7.x.
- **Driver catalog through vGPU 20.x** (`data/driver_catalog.json`) replacing all
  the hardcoded `case` tables. Branch map: 16=R535, 17=R550, 18=R570, 19=R580, 20=R595.
- **vGPU profile explorer** — see exactly which profiles a card supports, *before*
  installing (static tables) and *after* (live `mdevctl` / SR-IOV query).
- **SR-IOV path for Ampere and newer** (`pve-nvidia-sriov@.service`) alongside the
  legacy mdev path for Turing and older.
- **SHA256 integrity** (hard-fail) instead of MD5-with-"continue anyway".
- **Modern licensing**: FastAPI-DLS 2.x, `docker compose` v2, and guest
  `gridd-unlock-patcher` guidance for R570+/R580 branches.
- Refreshed GPU database (Ada + Blackwell / RTX 50-series and RTX PRO), normalized
  to a diffable CSV (`data/gpu_db.csv`) — no runtime `sqlite3` dependency.
- Modular `lib/`, `set -Eeuo pipefail`, no `eval`, atomic state file, CI + smoke tests.

## Requirements

- Proxmox VE 8.x or 9.x, root shell.
- An NVIDIA GPU that is either vGPU-native or unlock-eligible (Maxwell 2.0 → Turing).
- IOMMU (VT-d / AMD-Vi) available in firmware.

## Quick start

```bash
git clone <this-repo> && cd proxmox-vgpu-installer
chmod +x installer.sh
./installer.sh install        # phase 1: repos, deps, IOMMU, (unlock), reboot
# ... reboot ...
./installer.sh install        # phase 2: driver, SR-IOV, profiles, licensing
```

You supply the NVIDIA host driver `.run` yourself (this repo does **not** embed
links to NVIDIA's proprietary blobs):

```bash
./installer.sh install --file /root/NVIDIA-Linux-x86_64-580.65.05-vgpu-kvm.run
# or
./installer.sh install --url https://your-mirror/....run
```

## Subcommands

| Command | What it does |
|---|---|
| `install` | Two-phase new installation (reboot between phases). |
| `upgrade` | Remove the current driver and install a new one. |
| `remove`  | Uninstall driver, unlock, patches, licensing. |
| `download`| Fetch + verify a host driver only. |
| `license` | Configure the FastAPI-DLS licensing server. |
| `profiles`| Show vGPU profiles a GPU supports (pre-/post-install). |
| `override`| Create a `vgpu_unlock` profile override (TOML) for an mdev type. |
| `menu`    | Interactive menu (default with no subcommand). |

Flags: `--mode native|unlock`, `--url`, `--file`, `--step 1|2`, `--yes`, `--debug`.

## vGPU profile explorer

```bash
./installer.sh profiles
```

Before install it prints a static table (framebuffer, max instances, class, max
resolution) for your device id; for `vgpu_unlock` cards it resolves the profile
family of the spoofed enterprise card. After install it queries live mdev types
(Turing/older) or SR-IOV `creatable_vgpu_types` (Ampere+). Example for a Tesla T4:

```
PROFILE    TYPE     FB(MiB)   MAX#   CLASS    MAX RES
T4-1Q      Q           1024     16   vDWS     5120x2880
T4-2Q      Q           2048      8   vDWS     7680x4320
...
```

Regenerate authoritative per-branch tables from a host driver:

```bash
tools/extract_profiles.sh NVIDIA-Linux-x86_64-580.65.05-vgpu-kvm.run 19
```

## Driver / branch support matrix

| vGPU | Branch | Host GPUs | Unlock patch? | PVE | Notes |
|---|---|---|---|---|---|
| 16.x | R535 | Maxwell → Ada | yes | 7, 8 | LTS (EOL ~Jul 2026); last Pascal/Maxwell option |
| 17.x | R550 | Turing → Ada | yes | 7, 8 | Pascal host support dropped |
| 18.x | R570 | Turing → Blackwell | yes | 8, 9 | First branch officially supported by Proxmox |
| 19.0 | R580 | Turing → Blackwell | yes | 8, 9 | Dropped Maxwell/Pascal/Volta |
| 20.x | R595 | Turing → Blackwell | **no** | 9 | Native/enterprise cards only (no community patch yet) |

Consumer **unlock is limited to Maxwell 2.0 through Turing**. Ampere and newer
consumer cards cannot be unlocked; they need native/enterprise-qualified GPUs.

## vgpu_unlock profile overrides

For unlocked consumer cards, `./installer.sh override` writes an
`/etc/vgpu_unlock/profile_override.toml` section for a chosen mdev type: enable
CUDA, drop the frame-rate limiter, set resolution, or (advanced) resize the
framebuffer. A commented template is seeded during unlock setup, and the override
builder is also offered at the end of an unlock install.

## Licensing note

FastAPI-DLS 2.x serves 16.x–19.x. **18.x and 19.x guests additionally require
`gridd-unlock-patcher` inside the guest** before tokens are accepted. The installer
writes `licenses/license_linux.sh` and `licenses/license_windows.ps1` for you; run
them with `--install-driver` (Linux) / `-InstallDriver` (Windows) to also download
and install the matching guest driver where the catalog has a pinned URL.

## SR-IOV persistence

Ampere+ cards create vGPUs through SR-IOV virtual functions. Where Proxmox ships
`pve-nvidia-sriov@.service` the installer enables it (already boot-persistent).
On hosts that fall back to NVIDIA's one-shot `sriov-manage -e ALL` (e.g. some L4
setups), it installs a `nvidia-sriov-manage.service` unit so the VFs are recreated
on every boot before guests start.

## Project layout

```
installer.sh              # entry point (menu + subcommands + phase dispatch)
lib/                      # common, detect, repos, gpu, driver, kernel, unlock,
                          #   sriov, profiles, licensing
data/driver_catalog.json  # driver/branch/patch/kernel/arch source of truth
data/gpu_db.csv           # normalized GPU database (arch, support, branches)
data/profiles/            # vGPU profile tables (curated + extracted per branch)
tools/                    # extract_profiles.sh, build_gpu_db.sh
tests/smoke.sh            # host-independent CI checks
old/                      # preserved legacy v1.1 script + README
```

## Disclaimer

vGPU unlocking uses unofficial patches and may violate NVIDIA's EULA; use on
hardware you own for testing/lab purposes. Downloading NVIDIA drivers requires an
appropriate NVIDIA Licensing Portal entitlement.
