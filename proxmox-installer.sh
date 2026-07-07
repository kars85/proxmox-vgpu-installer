#!/usr/bin/env bash
# proxmox-installer.sh — compatibility shim.
#
# The installer was refactored into a modular tool (installer.sh + lib/). This
# wrapper preserves the historical entry-point name and forwards all arguments.
# The legacy monolithic script is preserved at old/proxmox-installer-v1.1.sh.
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "[note] proxmox-installer.sh is now a wrapper around installer.sh (v2.0)." >&2
exec "$here/installer.sh" "$@"
