#!/usr/bin/env bash
# tools/build_gpu_db.sh — (optional) build gpu_info.db (sqlite) from data/gpu_db.csv.
# The installer itself reads the CSV directly (awk) and does NOT need sqlite3;
# this exists only for tooling that still wants the binary DB.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
csv="$here/data/gpu_db.csv"
db="$here/gpu_info.db"
command -v sqlite3 >/dev/null || { echo "sqlite3 not installed"; exit 1; }
rm -f "$db"
sqlite3 "$db" <<SQL
CREATE TABLE gpu_info (
  vendorid TEXT, deviceid TEXT PRIMARY KEY, description TEXT,
  chip TEXT, arch TEXT, support TEXT, min_branch TEXT, max_branch TEXT, notes TEXT
);
.mode csv
.import --skip 1 '$csv' gpu_info
SQL
echo "[+] Built $db ($(sqlite3 "$db" 'SELECT COUNT(*) FROM gpu_info') rows)"
