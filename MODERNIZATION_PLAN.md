# Modernization & Refactor Plan — proxmox-vgpu-installer

**Status:** Proposed · **Current script version:** 1.1 (last real update ~early 2024)
**Target:** version 2.0 supporting Proxmox VE 8.4+ / 9.x and NVIDIA vGPU 16.x–20.x

---

## 1. Why this is needed (verified ecosystem drift)

The script was written for Proxmox VE 7/8 (Debian bullseye/bookworm) and vGPU drivers
16.0–17.0. As of mid-2026 the ground has shifted under every one of its assumptions:

| Area | Script assumes (v1.1) | Reality (July 2026) |
|---|---|---|
| Proxmox | PVE 7/8, `sources.list` one-liners, Ceph quincy | **PVE 9.x** on Debian 13 "trixie", **deb822 `.sources` format** (`apt modernize-sources`), Ceph squid, kernel **6.14+** default |
| Kernel | Pins kernel **6.5** and installs `proxmox-kernel-6.5` (no longer exists on trixie) | Modern host drivers (18.x+) build fine on 6.8/6.14; **no downgrade/pin needed**; pinning 6.5 on PVE 9 is impossible and would be harmful |
| Drivers | 16.0–17.0 (535.54.06–550.54.10), hardcoded mega.nz links (mostly dead) | Branches now: **16.x=R535 (LTS, EOL Jul 2026), 17.x=R550, 18.x=R570, 19.x=R580, 20.x=R595**. polloloco patches exist through **580.65.05 (19.0)**; no 595 patch yet |
| Unlock | vgpu_unlock-rs implied to work for anything flagged "Yes" in db | Consumer unlock is **Maxwell 2.0 → Turing only**, forever (Ampere+ consumer cards cannot be unlocked). 17.x dropped Pascal (needs 16.x `vgpuConfig.xml` workaround); **R580 dropped Maxwell/Pascal/Volta entirely** |
| vGPU creation | `mdevctl types` universally | mdev only for **pre-Ampere**. Ampere/Ada/Blackwell use **SR-IOV** (`pve-nvidia-sriov@ALL.service`, `nvidia-smi vgpu`, `/sys/.../nvidia/creatable_vgpu_types`). PVE ships **`pve-nvidia-vgpu-helper`** which automates deps + SR-IOV; vGPU is *officially* supported on PVE 8.4.1+/9 since v18 |
| Licensing | FastAPI-DLS 1.x flow, `docker-compose` v1, compose `version:` key | **FastAPI-DLS 2.x** required for 18.x/19.x guests, plus **gridd-unlock-patcher** on 18.x+ guest drivers; `docker-compose` (v1) is gone from Debian 13 — use `docker compose` plugin; `version:` key is deprecated |
| Integrity | MD5, "continue anyway?" on mismatch | Use **SHA256**, hard-fail by default |
| GPU DB | `gpu_info.db` caps out at driver "17" | Deprecated: no Ada/Blackwell coverage for new branches, driver column values stale, some garbage rows (`vgpu` column contains `'TDP 700W'`, `'PG506-230 …'`) |
| Guest drivers | Hardcoded `storage.googleapis.com/nvidia-drivers-us-public` URLs for 16.0–17.0 only | Many links dead; no 17.1+–20.x entries |

> **Prior art:** a maintained fork already exists — `anomixer/proxmox-vgpu-installer`
> (v1.82: PVE 9 + deb822 support, drivers through 20.1, secure-boot/MOK handling,
> refreshed gpu_info.db, download caching, ZFS kernel-downgrade guard). Decide early
> whether to **rebase on / merge from that fork** or treat it as a reference
> implementation while refactoring this repo. Recommendation: use it as a reference and
> cherry-pick data (driver catalog, PCI IDs), but do the structural refactor here.

---

## 2. Current-state audit — bugs and deprecations in `proxmox-installer.sh`

### Outright bugs (fix regardless of modernization)
1. **`extract_filename_from_url` is called but never defined** (`proxmox-installer.sh:981`) — the entire `--url` code path in step 2 dies with "command not found".
2. **Typo `vgpu-promox`** in the two removal paths (`:717`, `:798`) — `rm -rf $VGPU_DIR/vgpu-promox` never removes the real `vgpu-proxmox` directory.
3. **Multi-GPU selection uses a stale variable** (`:588`): after the user picks a GPU, `DRIVER_VERSION=$driver` takes `$driver` from the *last GPU iterated in the display loop*, not the selected one (the re-query at `:583` only extracts `description`).
4. **Off-by-one + >9 GPU breakage in selection validation** (`:567`): `^[1-$index]$` is a character class, not a range — wrong for `index ≥ 10`, and after the loop `index` is N+1 so N+1 passes validation.
5. **Duplicate condition** `[ "$VGPU_SUPPORT" = "Native" ] || [ "$VGPU_SUPPORT" = "Native" ]` (`:1170`); "Unknown" silently gets a native, unpatched install.
6. **`--url`/`--file` append duplicates to `config.txt`** on every invocation (`:50`, `:55`) — the sourced config then keeps stale values.
7. **`VGPU_DIR=$(pwd)`** (`:13`) — running the script from any other directory breaks the sqlite lookup, config, and patches. Should resolve the script's own directory.
8. **`hostname -i`** (`:168`) frequently returns `127.0.1.1` (or multiple addresses) on Debian — the generated DLS URL then points at loopback. Use `hostname -I | awk '{print $1}'` or ask the user.
9. **`vfio_virqfd` no longer exists** (kernel ≥ 6.2 merged it into vfio core) — `/etc/modules` entry (`:721-726`) generates boot-time module-load failures on every current PVE.
10. **sqlite3 CLI is used but never installed** (`:416`) — not guaranteed present; it's not in the `apt install` list at `:382`.
11. **MD5 mismatch offers "continue anyway"** (`:900-908`) — installing a corrupt kernel driver should be a hard stop.
12. **GRUB-only cmdline handling** (`update_grub`, `:621`) — hosts using **systemd-boot** (UEFI + ZFS root) need `/etc/kernel/cmdline` + `proxmox-boot-tool refresh`; the script silently does nothing effective for them.

### Deprecated / stale elements
- PVE version gate rejects anything but 7/8 (`:330-341`) — **PVE 9 exits immediately**.
- Repo rewriting assumes `.list` files and bullseye/bookworm/quincy strings only (`:344-352`); PVE 9 uses deb822 `.sources` (and the enterprise repo file is `pve-enterprise.sources`).
- `apt install … proxmox-kernel-6.5 proxmox-headers-6.5` + 6.5 pinning (`:382-411`).
- `megatools`/mega.nz driver distribution (`:864-878`, `:1101-1115`) — links rot; also questionable to hardcode.
- Driver list caps at 17.0 (`:826-848`); patch filenames map only 16.0–17.0 (`map_filename_to_version`, `:102`).
- Guest-driver URL table caps at 17.0 (`:1203-1225`).
- `docker-compose` v1 binary + `version: '3.9'` compose key (`:152`, `:183`, `:215`).
- FastAPI-DLS `:latest` image with 1.x-era instructions; no gridd-unlock-patcher guidance for 18.x+ guests (`:139-259`).
- Final instructions say only `mdevctl types` (`:1230`) — wrong for Ampere+/SR-IOV, no mention of PVE resource mappings.
- `nvidia-smi vgpu` version check parses human output loosely (`:1185-1196`).
- Rust toolchain via `curl | sh` for vgpu_unlock-rs build (`:673`) — prefer a pinned rustup or distro cargo; also build fails are swallowed by `run_command`'s eval-with-redirect.
- `eval`-based `run_command`, no `set -Eeuo pipefail`, unquoted expansions throughout — shellcheck reports dozens of issues.
- No secure-boot detection (`mokutil --sb-state`) — DKMS module simply fails to load on SB-enabled hosts.

---

## 3. Target architecture

Keep it a Bash project (its audience runs it on bare PVE hosts), but split the 1,246-line
monolith:

```
proxmox-vgpu-installer/
├── installer.sh                  # entry point: arg parsing, step dispatch, TUI menus
├── lib/
│   ├── common.sh                 # logging, run_command (no eval), prompts, state file
│   ├── detect.sh                 # PVE version, boot loader, secure boot, kernel, CPU, IOMMU
│   ├── repos.sh                  # deb822-aware repo setup (PVE 8 .list / PVE 9 .sources)
│   ├── gpu.sh                    # lspci scan, db lookup, multi-GPU select, passthrough udev
│   ├── driver.sh                 # catalog lookup, download (--url/--file), sha256, patch, install
│   ├── profiles.sh               # NEW: vGPU profile compatibility feature (§5)
│   ├── unlock.sh                 # vgpu_unlock-rs install/build, profile_override.toml helpers
│   ├── sriov.sh                  # Ampere+ path: pve-nvidia-vgpu-helper / sriov service
│   └── licensing.sh              # FastAPI-DLS 2.x, docker compose v2, gridd-unlock-patcher
├── data/
│   ├── driver_catalog.json       # single source of truth (§4.1)
│   ├── gpu_db.csv                # human-diffable source for gpu_info.db (§4.2)
│   └── profiles/                 # generated per-branch profile tables (§5)
├── tools/
│   ├── build_gpu_db.sh           # csv -> sqlite (or ship csv only and grep it)
│   └── extract_profiles.sh       # vgpuConfig.xml -> data/profiles/*.json
├── tests/                        # bats + shellcheck
└── .github/workflows/ci.yml     # shellcheck, shfmt, bats, db build
```

Principles:
- `set -Eeuo pipefail`, no `eval`, all expansions quoted; shellcheck-clean in CI.
- All version/URL/hash knowledge lives in `data/`, not in `case` statements.
- Idempotent steps; `config.txt` replaced by a proper key=value state file written
  atomically (`state.env`), rooted at the script dir, not `$(pwd)`.
- Non-interactive mode (`--yes`, env-var answers) so it's automatable.

---

## 4. Data model changes

### 4.1 Driver catalog (`data/driver_catalog.json`)
Replaces `map_filename_to_version`, the mega.nz URL tables, and the guest-driver URL
table. One record per host driver:

```json
{
  "vgpu_release": "18.4",
  "branch": "R570",
  "host_filename": "NVIDIA-Linux-x86_64-570.172.07-vgpu-kvm.run",
  "sha256": "<hash>",
  "patch": "570.172.07.patch",
  "patch_required_for": ["unlock"],
  "min_kernel": "6.1", "max_kernel": "6.14",
  "pve": ["8", "9"],
  "arch_support": ["turing", "ampere", "ada"],
  "unlock_supported": true,
  "guest": {
    "linux": "NVIDIA-Linux-x86_64-570.172.08-grid.run",
    "windows": "573.xx_grid_win10_win11_server2022_dch_64bit_international.exe"
  },
  "eol": "2026-xx-xx"
}
```

- Populate for: 16.9 (535.230.02, last LTS — final Pascal/Maxwell option),
  17.5/17.6 (550.144.02/550.163.02), 18.x (570.124.03 → 570.172.07),
  19.x (580.65.05+), 20.x (595.x — **native-only until a patch exists**).
- **Stop hardcoding mega.nz links.** Default flow: user supplies `--url` (their NVIDIA
  enterprise portal download or their own mirror) or `--file`; the catalog validates by
  filename + sha256. Optionally keep community mirror URLs in a separate, clearly
  labeled `data/mirrors.json` the user must opt into.
- MD5 → **SHA256**, mismatch = abort (no "continue anyway").
- Menu is generated from the catalog and **filtered** by: detected PVE major, running
  kernel, GPU architecture, and unlock-vs-native mode. This kills the "pick 17.0 on a
  Pascal card and brick your install" class of error.

### 4.2 GPU database
- Convert `gpu_info.db` (binary in git) to `data/gpu_db.csv` as the reviewed source of
  truth; build the sqlite file at release time or just query the CSV with awk (1,070
  rows — sqlite is overkill).
- Schema cleanup: `vgpu` column becomes a strict enum (`native|unlock|none|unknown`);
  move the stray notes (`TDP 700W`, board SKU strings) to a `notes` column; replace the
  `driver` semicolon list with `min_branch`/`max_branch` (e.g. GTX 1080: `max_branch=16`;
  RTX 2070S: `max_branch=19-unlock`; A5000: `max_branch=20`).
- Refresh device IDs for Ada and Blackwell (RTX PRO) from current pci.ids + NVIDIA
  support matrix (cherry-pick from the anomixer fork's refreshed db, then verify).
- Add `arch` normalization (Turing/Ampere/Ada/Blackwell) so the SR-IOV-vs-mdev decision
  and unlock eligibility come from the db, not guesses.

---

## 5. New feature: vGPU profile compatibility explorer

There is currently **no way to see which vGPU profiles a GPU supports** until after a
successful install (`mdevctl types` — and that's wrong for Ampere+). Add a first-class
`Profiles` menu option / `installer.sh profiles` subcommand with two modes:

### 5.1 Pre-install (static, from data)
- `tools/extract_profiles.sh` extracts `vgpuConfig.xml` from each host `.run` package
  (`./NVIDIA-…-vgpu-kvm.run -x` → `vgpuConfig.xml`) and generates
  `data/profiles/<branch>.json`: per device-id list of profiles with
  `name` (e.g. `GRID T4-2Q`), `framebuffer_mb`, `max_instances`, `type letter`
  (Q/A/B/C), `display heads`, `max resolution`, `license feature`.
- `profiles --gpu <devid> --branch 19` prints a table *before the user commits to a
  driver*, e.g. for a T4: `T4-1Q ×16, T4-2Q ×8 (2048 MiB), T4-4Q ×4, … T4-16Q ×1`.
- For **unlocked consumer cards**, resolve through the spoof target (e.g. RTX 2070S →
  Quadro RTX 6000/8000 profile set) and label it as such, since that's what
  vgpu_unlock exposes. Include guidance + generation of
  `/etc/vgpu_unlock/profile_override.toml` (framebuffer, cuda_enabled, frl) for the
  chosen profile.
- Filter/annotate by chosen driver branch: warn when a profile set changes across
  branches (e.g. Pascal profiles absent ≥ 17.x).

### 5.2 Post-install (live)
- Pre-Ampere: parse `mdevctl types` per PCI address.
- Ampere+: read `/sys/bus/pci/devices/<VF>/nvidia/creatable_vgpu_types` and
  `nvidia-smi vgpu -s -v` (requires SR-IOV enabled — offer to run
  `systemctl enable --now pve-nvidia-sriov@<addr>.service` first).
- Show "creatable now" vs "theoretical" (profiles become uncreatable once a
  heterogeneous instance exists) and the remaining instance counts.
- End-of-install summary replaces the current static "run mdevctl types" text with the
  actual table for the installed GPU + a pointer to PVE **Datacenter → Resource
  Mappings** ("Use with mediated devices") which is the modern way to assign vGPUs.

---

## 6. Phased implementation plan

### Phase 0 — Hygiene & safety net (small, do first)
- Fix the outright bugs from §2 (undefined function, `vgpu-promox` typo, stale
  `$driver`, selection validation, config duplication, script-dir resolution).
- Add shellcheck + shfmt CI; `set -Eeuo pipefail`; replace `eval` in `run_command` with
  array-based execution + tee'd logging.
- Tag current state as `v1.1-legacy` branch before restructuring.
- **Acceptance:** shellcheck clean; existing PVE 8 flow still works end-to-end.

### Phase 1 — Platform detection & PVE 9 support
- `detect.sh`: PVE major (7=refuse with message, 8, 9), Debian codename, kernel,
  boot loader (GRUB vs systemd-boot via `proxmox-boot-tool status`), secure boot
  (`mokutil --sb-state`), CPU vendor, IOMMU state.
- `repos.sh`: on PVE 9 write deb822 `.sources` (trixie, `pve-no-subscription`,
  Ceph squid), disable `pve-enterprise.sources`; on PVE 8 keep `.list` handling; never
  blind-`sed` user repo files — detect and disable enterprise entries properly.
- Remove kernel 6.5 pin/downgrade entirely; replace with catalog-driven
  kernel-compat check (only warn/pin when the *chosen driver* requires it, e.g. 16.x on
  PVE 8). On PVE 9, prefer `apt install pve-nvidia-vgpu-helper` +
  `pve-nvidia-vgpu-helper setup` for dependencies where available.
- `/etc/modules`: drop `vfio_virqfd` on kernel ≥ 6.2.
- Cmdline editing for both GRUB and systemd-boot (`/etc/kernel/cmdline`) +
  `proxmox-boot-tool refresh`.
- Secure boot: either guided MOK enrollment for the DKMS key or clear instruction to
  disable SB — no more silent module-load failure.
- **Acceptance:** fresh PVE 9.x host passes step 1 and reboots with IOMMU active;
  PVE 8.4 regression-tested.

### Phase 2 — Driver management modernization
- Implement `data/driver_catalog.json` + `driver.sh` (§4.1); delete
  `map_filename_to_version` and all hardcoded URL tables.
- SHA256 verification, hard fail; resumable/cached downloads (skip if file present and
  hash-valid).
- Patch flow: clone/refresh polloloco repo pinned to a known commit; apply patch only
  when `mode=unlock`; native cards install unpatched.
- Guest-driver guidance emitted from catalog (matching guest version per host driver).
- **Acceptance:** T4 (native) on PVE 9 installs 18.x/19.x unpatched; RTX 20xx installs
  17.x/18.x patched; 20.x offered only as native.

### Phase 3 — GPU DB refresh + profile explorer
- Migrate db to CSV source (§4.2), refresh Ada/Blackwell IDs, normalize columns,
  regenerate; add `arch` + `min/max branch`.
- Implement `profiles.sh` + `tools/extract_profiles.sh` (§5) and wire into: pre-install
  menu (branch choice), post-install summary, and standalone subcommand.
- **Acceptance:** `installer.sh profiles` shows correct table for T4 (native, mdev) and
  for an unlocked Turing consumer card (spoofed profile set); Ampere+ live mode reads
  `creatable_vgpu_types` correctly.

### Phase 4 — Licensing modernization
- FastAPI-DLS: pin image `collinwebdesigns/fastapi-dls:2.x`, `docker compose` (plugin)
  instead of `docker-compose`, drop `version:` key, fix host-IP detection, port-conflict
  check.
- Guest tooling: 17.x guests keep current token flow; **18.x/19.x guests need
  gridd-unlock-patcher** — generate per-OS instructions/scripts accordingly, and say so
  in the driver menu ("licensing for this branch requires patching the guest gridd").
- Offer LXC/VM placement note instead of installing Docker on the PVE host by default
  (installing Docker on a hypervisor is a smell — keep it as an explicit opt-in).
- **Acceptance:** Windows + Linux guest acquire licenses on 17.x and 18.x branches.

### Phase 5 — Ampere+/SR-IOV path
- `sriov.sh`: detect arch ≥ Ampere → enable `pve-nvidia-sriov@.service` (or
  `sriov-manage` fallback), verify VFs appear, then route profile/assignment guidance
  through the SR-IOV path; mdev path retained for Turing and older.
- Final instructions: PVE Resource Mappings walkthrough for both paths.
- **Acceptance:** A-series/Ada card gets VFs on boot and a vGPU-attached VM starts.

### Phase 6 — UX & robustness
- Non-interactive mode (`--yes --mode unlock --driver 18.4 --gpu 01:00.0 …`).
- `remove`/`upgrade` paths rebuilt on the new modules (and actually removing the right
  directories); `nvidia-uninstall`, dkms cleanup, service disablement, cmdline revert.
- Structured logging to `debug.log` with timestamps; `--debug` streams.
- README rewrite: supported matrix table, PVE 9 quickstart, unlock-eligibility table,
  licensing caveats per branch, link to upstream wiki/polloloco guide.
- **Acceptance:** bats test suite green; end-to-end runs on PVE 8.4 and 9.x documented.

---

## 7. Risks & open decisions

| Decision | Recommendation |
|---|---|
| Merge from anomixer fork vs refactor here | Refactor here; cherry-pick its data (driver catalog entries, refreshed PCI IDs, secure-boot handling ideas). Credit upstream. |
| Keep PVE 7 support | Drop (EOL); print a clear message. |
| Maxwell/Pascal users | Supported only via 16.9 on PVE 8 (kernel constraints apply); on PVE 9 print honest "not supportable" guidance. R580+ removed these arches. |
| Hosting driver binaries / mirrors | Don't embed links to proprietary blobs by default; `--url/--file` + opt-in community mirror file keeps the repo clean. |
| vGPU 20.x (R595) unlock | No community patch yet — expose native-only; revisit when polloloco publishes a 595 patch. |
| sqlite vs CSV lookup | CSV + awk (removes sqlite3 dependency entirely); keep a build script if sqlite output is still wanted. |
| Docker-on-host for DLS | Keep but opt-in; document LXC alternative. |

## 8. Reference facts (verified July 2026)

- PVE 9.0 released 2025-08-05: Debian 13, kernel 6.14.8-2 default, deb822 `.sources`,
  `apt modernize-sources`.
- PVE officially supports NVIDIA vGPU since v18 on PVE 8.4.1+/9 with
  `pve-nvidia-vgpu-helper` (`setup` subcommand, `pve-nvidia-sriov@ALL.service`).
- polloloco/vgpu-proxmox patches currently end at `580.65.05.patch` (19.0); 570.x has
  five patch revisions incl. kernel-6.14 fixes.
- FastAPI-DLS 2.x supports 18.x/19.x but those guest drivers additionally require
  gridd-unlock-patcher; 1.x tops out at 17.x.
- R580 branch dropped Maxwell/Pascal/Volta; consumer unlock remains Maxwell 2.0–Turing.
- vGPU release ↔ driver branch: 16=R535 (LTS), 17=R550, 18=R570, 19=R580, 20=R595
  (e.g. host 595.71.03 / guest 595.71.05, CUDA 13.2).
