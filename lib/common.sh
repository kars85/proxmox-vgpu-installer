# shellcheck shell=bash
# lib/common.sh — logging, command execution, prompts, and state persistence.
# Sourced by installer.sh; never executed directly.

# --- Colors (disabled when not a TTY) ---------------------------------------
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; ORANGE=$'\033[0;33m'; PURPLE=$'\033[0;35m'
    GRAY=$'\033[0;37m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; ORANGE=''; PURPLE=''; GRAY=''; NC=''
fi

# --- Logging ----------------------------------------------------------------
# All log lines are timestamped into $LOG_FILE and mirrored to the console.
_log_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_raw() { # write only to the log file
    [ -n "${LOG_FILE:-}" ] && printf '%s %s\n' "$(_log_ts)" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

log_info()  { echo -e "${GREEN}[+]${NC} $*"; log_raw "INFO  $*"; }
log_warn()  { echo -e "${YELLOW}[-]${NC} $*"; log_raw "WARN  $*"; }
log_error() { echo -e "${RED}[!]${NC} $*" >&2; log_raw "ERROR $*"; }
log_ask()   { echo -e "${BLUE}[?]${NC} $*"; }
log_step()  { echo -e "${PURPLE}[*]${NC} $*"; log_raw "STEP  $*"; }

die() { log_error "$*"; exit 1; }

# --- Command execution ------------------------------------------------------
# run_command <description> <log_level> <cmd> [args...]
# Runs a command as an argv array (no eval). On failure it aborts unless the
# caller sets ALLOW_FAIL=1. stdout/stderr go to the log unless DEBUG=true.
run_command() {
    local description="$1" level="$2"; shift 2
    case "$level" in
        info) log_info "$description" ;;
        notification|warn) log_warn "$description" ;;
        error) log_error "$description" ;;
        *) echo -e "[?] $description" ;;
    esac
    log_raw "EXEC  $*"

    local rc=0
    if [ "${DEBUG:-false}" = "true" ]; then
        "$@" || rc=$?
    else
        "$@" >>"${LOG_FILE:-/dev/null}" 2>&1 || rc=$?
    fi

    if [ "$rc" -ne 0 ]; then
        if [ "${ALLOW_FAIL:-0}" = "1" ]; then
            log_warn "Command exited $rc (continuing): $*"
        else
            die "Command failed (exit $rc): $*  — see ${LOG_FILE:-log} for details"
        fi
    fi
    return "$rc"
}

# run_shell <description> <log_level> <shell-string>
# Escape hatch for pipelines/redirections that genuinely need a shell. Prefer
# run_command. The string is run with `bash -c`, still without interactive eval.
run_shell() {
    local description="$1" level="$2" script="$3"
    run_command "$description" "$level" bash -c "$script"
}

# --- Prompts ----------------------------------------------------------------
# ask_yes_no <question> [default:y|n]  -> returns 0 for yes, 1 for no.
# Honours ASSUME_YES (non-interactive mode).
ask_yes_no() {
    local q="$1" default="${2:-n}" ans
    if [ "${ASSUME_YES:-0}" = "1" ]; then
        log_raw "AUTO-YES $q"; return 0
    fi
    local hint="y/N"; [ "$default" = "y" ] && hint="Y/n"
    read -r -p "$(echo -e "${BLUE}[?]${NC} $q ($hint): ")" ans
    ans="${ans:-$default}"
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ask_value <prompt> <default> -> echoes the answer (or default).
ask_value() {
    local prompt="$1" default="$2" ans
    if [ "${ASSUME_YES:-0}" = "1" ]; then echo "$default"; return; fi
    read -r -p "$(echo -e "${BLUE}[?]${NC} $prompt [${default}]: ")" ans
    echo "${ans:-$default}"
}

# --- State file (replaces the old append-only config.txt) -------------------
# Stored as key=value at $STATE_FILE, always rewritten atomically so keys are
# never duplicated. Keys are a fixed allowlist.
STATE_KEYS=(STEP MODE VGPU_SUPPORT DRIVER_RELEASE DRIVER_FILE URL FILE SELECTED_PCI GPU_ARCH)

state_load() {
    [ -f "${STATE_FILE:-}" ] || return 0
    local key val line
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^[A-Z_]+$ ]] || continue
        # only import known keys
        for k in "${STATE_KEYS[@]}"; do
            if [ "$k" = "$key" ]; then printf -v "$key" '%s' "$val"; break; fi
        done
    done <"$STATE_FILE"
}

state_save() {
    local tmp="${STATE_FILE}.tmp" k
    : >"$tmp"
    for k in "${STATE_KEYS[@]}"; do
        printf '%s=%s\n' "$k" "${!k-}" >>"$tmp"
    done
    mv -f "$tmp" "$STATE_FILE"
    log_raw "STATE saved -> $STATE_FILE"
}

state_clear() { rm -f "${STATE_FILE:-/nonexistent}"; }

# --- Small helpers ----------------------------------------------------------
require_root() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || die "This script must be run as root (use sudo or a root shell)."
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_cmd() { # ensure_cmd <binary> <apt-package>
    local bin="$1" pkg="${2:-$1}"
    need_cmd "$bin" && return 0
    log_warn "Required tool '$bin' not found; installing package '$pkg'"
    run_command "Installing $pkg" info apt-get install -y "$pkg"
}

module_init() { log_raw "module loaded: $1"; }
module_init "common.sh"
