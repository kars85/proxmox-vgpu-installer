#!/usr/bin/env bash
# tools/extract_profiles.sh — regenerate data/profiles/<branch>.json from a host driver.
#
# Extracts vgpuConfig.xml from an NVIDIA vGPU host .run package and converts the
# per-device profile definitions into the JSON schema consumed by lib/profiles.sh.
#
# Usage: tools/extract_profiles.sh <NVIDIA-...-vgpu-kvm.run> <branch>
#   e.g. tools/extract_profiles.sh NVIDIA-Linux-x86_64-580.65.05-vgpu-kvm.run 19
#
# Requires: xmllint (libxml2-utils) and jq. The .run self-extracts with -x.
set -Eeuo pipefail

run_file="${1:?usage: extract_profiles.sh <driver.run> <branch>}"
branch="${2:?usage: extract_profiles.sh <driver.run> <branch>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${here}/data/profiles/${branch}.json"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

command -v xmllint >/dev/null || { echo "install libxml2-utils (xmllint)"; exit 1; }
command -v jq >/dev/null || { echo "install jq"; exit 1; }

echo "[*] Extracting $run_file ..."
chmod +x "$run_file"
"./$run_file" -x --target "$work/extracted" >/dev/null 2>&1 || "./$run_file" --extract-only --target "$work/extracted" >/dev/null 2>&1

xml="$(find "$work/extracted" -name vgpuConfig.xml | head -1)"
[ -n "$xml" ] || { echo "vgpuConfig.xml not found in package"; exit 1; }
echo "[*] Parsing $xml ..."

# vgpuConfig.xml structure: <pgpu> entries carry a <devId ...> and multiple
# <vgpuType> children with name / framebuffer / maxInstance / class / maxResolution.
# We emit {devices:{<devid>:{name,arch,total_fb_mb,profiles:[...]}}}.
python3 - "$xml" "$branch" >"$out" <<'PY'
import sys, xml.etree.ElementTree as ET, json
xml, branch = sys.argv[1], sys.argv[2]
tree = ET.parse(xml); root = tree.getroot()
devices = {}
for pgpu in root.iter():
    if pgpu.tag.lower() != 'pgpu':
        continue
    devid = None
    for dev in pgpu.iter():
        if dev.tag.lower() == 'devid':
            devid = (dev.get('deviceId') or dev.text or '').strip().lower().replace('0x','')
            break
    if not devid:
        continue
    devid = devid[-4:]
    profiles = []
    name = None
    for vt in pgpu.iter():
        if vt.tag.lower() != 'vgputype':
            continue
        pname = vt.get('name') or ''
        if name is None and '-' in pname:
            name = pname.split('-')[0]
        fb = vt.get('framebuffer') or vt.get('fb') or '0'
        try:
            fb_mb = int(int(fb) / (1024*1024)) if int(fb) > 100000 else int(fb)
        except ValueError:
            fb_mb = 0
        maxi = vt.get('maxInstance') or vt.get('maxInstancePerGpu') or '0'
        cls = vt.get('class') or '-'
        res = vt.get('maxResolution') or (vt.get('maxPixels') and '-') or '-'
        letter = pname[-1] if pname and pname[-1] in 'QBCA' else '-'
        profiles.append({"name": pname, "type": letter,
                         "framebuffer_mb": fb_mb, "max_instances": int(maxi) if maxi.isdigit() else 0,
                         "class": cls, "max_resolution": res})
    if profiles:
        devices[devid] = {"name": name or f"device {devid}", "branch": branch,
                          "profiles": profiles}
print(json.dumps({"devices": devices}, indent=2))
PY

echo "[+] Wrote $out ($(jq '.devices | length' "$out") devices)"
