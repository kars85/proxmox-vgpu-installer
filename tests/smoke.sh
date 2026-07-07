#!/usr/bin/env bash
# tests/smoke.sh — host-independent checks that run anywhere (CI, dev laptop).
# Exercises the data-driven logic without needing a Proxmox host or GPU.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VGPU_DIR="$here" DATA_DIR="$here/data" LOG_FILE="/tmp/vgpu-smoke.log" STATE_FILE="/tmp/vgpu-smoke.state"
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "== syntax =="
for f in "$here"/installer.sh "$here"/lib/*.sh "$here"/tools/*.sh; do
    if bash -n "$f"; then ok "syntax $(basename "$f")"; else bad "syntax $(basename "$f")"; fi
done

echo "== data files =="
check "catalog is valid json"      "jq -e '.drivers|length>0' '$DATA_DIR/driver_catalog.json' >/dev/null"
check "curated profiles valid"     "jq -e '.devices' '$DATA_DIR/profiles/curated.json' >/dev/null"
check "gpu_db.csv has header"      "head -1 '$DATA_DIR/gpu_db.csv' | grep -q '^vendorid,deviceid'"
check "gpu_db.csv has T4"          "grep -qi ',1eb8,' '$DATA_DIR/gpu_db.csv'"
check "gpu_db.csv has blackwell"   "grep -qi 'blackwell' '$DATA_DIR/gpu_db.csv'"

echo "== module logic =="
# shellcheck disable=SC1090
source "$here/lib/common.sh"; source "$here/lib/detect.sh"; source "$here/lib/gpu.sh"
source "$here/lib/driver.sh"; source "$here/lib/sriov.sh"; source "$here/lib/profiles.sh"
PVE_MAJOR=9; KERNEL_VERSION="6.14.8-2-pve"

check "T4 lookup -> native"        "gpu_db_lookup 1eb8 | grep -q '|native|'"
check "RTX2070S lookup -> unlock"  "gpu_db_lookup 1ed1 | grep -q '|unlock|'"
check "unknown id -> nonzero"      "! gpu_db_lookup ffff"
check "ver_ge 6.14>=6.2"           "ver_ge 6.14 6.2"
check "ver_ge 6.1<6.2"             "! ver_ge 6.1 6.2"
check "turing uses mdev"           "GPU_ARCH=turing; ! gpu_uses_sriov"
check "ampere uses sriov"          "GPU_ARCH=ampere; gpu_uses_sriov"
check "20.0 has no unlock patch"   "[ -z \"\$(driver_field 20.0 .patch)\" ]"
check "19.0 patch present"         "[ -n \"\$(driver_field 19.0 .patch)\" ]"
check "pve9 unlock excludes 20.0"  "! { GPU_ARCH=ampere MODE=unlock list_compatible_drivers unlock | grep -q '^20.0'; }"
check "pve9 native includes 20.0"  "GPU_ARCH=turing MODE=native list_compatible_drivers native | grep -q '^20.0'"

echo "== new features (override / guest scripts / sriov persistence) =="
source "$here/lib/unlock.sh"; source "$here/lib/licensing.sh"
# TOML profile override generation
export PROFILE_OVERRIDE_FILE="/tmp/vgpu-override.toml"; rm -f "$PROFILE_OVERRIDE_FILE"
write_profile_override nvidia-256 2048 1920 1080 1 0 >/dev/null 2>&1
check "override writes section"        "grep -q '^\[profile.nvidia-256\]' '$PROFILE_OVERRIDE_FILE'"
check "override max_pixels correct"    "grep -q '^max_pixels = 2073600' '$PROFILE_OVERRIDE_FILE'"
check "override cuda enabled"          "grep -q '^cuda_enabled = 1' '$PROFILE_OVERRIDE_FILE'"
check "override framebuffer hex"       "grep -qi '^framebuffer = 0x' '$PROFILE_OVERRIDE_FILE'"
write_profile_override nvidia-256 0 1280 1024 0 1 >/dev/null 2>&1
check "override replace is idempotent" "[ \$(grep -c '^\[profile.nvidia-256\]' '$PROFILE_OVERRIDE_FILE') -eq 1 ]"
check "override replace updated res"   "grep -q '^display_width = 1280' '$PROFILE_OVERRIDE_FILE'"
check "override no-fb omits framebuffer" "! grep -qi '^framebuffer = ' '$PROFILE_OVERRIDE_FILE'"

# Guest license scripts include driver download for a release with known URLs (20.0)
export VGPU_DIR="/tmp/vgpu-lic"; mkdir -p "$VGPU_DIR"; DRIVER_RELEASE=20.0
_write_guest_license_scripts 10.0.0.5 8443 >/dev/null 2>&1
check "linux script has token fetch"   "grep -q 'client-token' /tmp/vgpu-lic/licenses/license_linux.sh"
check "linux script downloads driver"  "grep -q 'grid.run' /tmp/vgpu-lic/licenses/license_linux.sh"
check "linux script gated by flag"     "grep -q 'install-driver' /tmp/vgpu-lic/licenses/license_linux.sh"
check "windows script downloads driver" "grep -qi 'grid_win' /tmp/vgpu-lic/licenses/license_windows.ps1"
# A release with no pinned guest URL (18.4) should degrade to a comment, not a broken curl
DRIVER_RELEASE=18.4; _write_guest_license_scripts 10.0.0.5 8443 >/dev/null 2>&1
check "no-url release: comment, no active dl" "grep -q 'NVIDIA vGPU' /tmp/vgpu-lic/licenses/license_linux.sh && ! grep -q 'curl -fSL' /tmp/vgpu-lic/licenses/license_linux.sh"
check "no-url release: still licenses"        "grep -q 'client-token' /tmp/vgpu-lic/licenses/license_linux.sh"

echo "== licensing: image pin + gridd automation =="
check "image pinned by digest"         "grep -q 'fastapi-dls:2.0.3@sha256:' '$here/lib/licensing.sh'"
check "image env-overridable"          "grep -q 'FASTAPI_DLS_IMAGE:-' '$here/lib/licensing.sh'"
check "gridd url corrected (vgpu)"     "grep -q 'vgpu/gridd-unlock-patcher' '$here/lib/licensing.sh' && ! grep -q 'oscar.krause/gridd-unlock-patcher' '$here/lib/licensing.sh'"
check "health check present"           "grep -q '/-/health' '$here/lib/licensing.sh'"
# R580 (19.0) guest script must fetch root cert + patch gridd
DRIVER_RELEASE=19.0; _write_guest_license_scripts 10.0.0.5 8443 >/dev/null 2>&1
check "R580 linux: fetches root cert"  "grep -q 'root-certificate' /tmp/vgpu-lic/licenses/license_linux.sh"
check "R580 linux: runs patcher"       "grep -q 'gridd-unlock-patcher' /tmp/vgpu-lic/licenses/license_linux.sh"
check "R580 linux: patch cmd -g -c"    "grep -q -- '-g \"\$GRIDD_BIN\" -c /tmp/dls-root.pem' /tmp/vgpu-lic/licenses/license_linux.sh"
check "R580 windows: dll guidance"     "grep -qi 'nvxdapix.dll' /tmp/vgpu-lic/licenses/license_windows.ps1"
# R550 (17.x) guest script must NOT need gridd patching
DRIVER_RELEASE=17.5; _write_guest_license_scripts 10.0.0.5 8443 >/dev/null 2>&1
check "R550 linux: no gridd patch"     "! grep -q 'gridd-unlock-patcher' /tmp/vgpu-lic/licenses/license_linux.sh"
check "R550 linux: still licenses"     "grep -q 'client-token' /tmp/vgpu-lic/licenses/license_linux.sh"

echo ""
echo "Passed: $pass  Failed: $fail"
[ "$fail" -eq 0 ]
