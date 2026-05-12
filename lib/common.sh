#!/usr/bin/env bash
# lib/common.sh — shared helpers: logging, colors, dry-run, safety checks
# Source this file in all scripts; do NOT execute directly.

# ── Colors (only when stdout is a terminal) ───────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

# ── Global state (can be overridden before sourcing) ──────────────────────────
DRY_RUN="${DRY_RUN:-0}"
LOG_FILE="${LOG_FILE:-/tmp/fedora-install.log}"

# If a previous root-run left an unwritable log file behind, switch to a
# user-specific fallback instead of spamming tee permission warnings.
if ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="/tmp/fedora-install-${UID}.log"
    touch "$LOG_FILE" 2>/dev/null || true
fi

# ── Logging — all output goes to stderr + log file ───────────────────────────
# Sending to stderr ensures $(...) subshells never capture log messages.
_log() { echo -e "$*" | tee -a "$LOG_FILE" >&2; }

log_info()  { _log "${GREEN}[INFO]${RESET}    $*"; }
log_warn()  { _log "${YELLOW}[WARN]${RESET}    $*"; }
log_error() { _log "${RED}[ERROR]${RESET}   $*"; }
log_step()  { _log "\n${CYAN}${BOLD}══ $* ══${RESET}"; }
log_dry()   { _log "${YELLOW}[DRY-RUN]${RESET} Would: $*"; }

die() { log_error "$*"; exit 1; }

# ── run — exec normally, or print in dry-run mode ─────────────────────────────
# Usage: run cmd arg1 arg2 ...
run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        log_dry "$*"
    else
        "$@"
    fi
}

# ── run_as_user — run a command as a specific user (via sudo -u) ──────────────
run_as_user() {
    local user="$1"; shift
    if [[ "$DRY_RUN" == "1" ]]; then
        log_dry "As ${user}: $*"
    else
        sudo -u "$user" "$@"
    fi
}

# ── require_root ──────────────────────────────────────────────────────────────
require_root() {
    [[ "$EUID" -eq 0 ]] || die "This script must be run as root."
}

# ── require_non_root ──────────────────────────────────────────────────────────
require_non_root() {
    [[ "$EUID" -ne 0 ]] || die "Do not run this script as root."
}

# ── require_cmd — abort if a command is missing ───────────────────────────────
require_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
    done
}

# ── confirm — prompt yes/no, return 0 on yes ─────────────────────────────────
confirm() {
    local prompt="${1:-Continue?}"
    local answer
    read -r -p "$(echo -e "${YELLOW}${prompt} [y/N]:${RESET} ")" answer
    [[ "${answer,,}" == "y" ]]
}

# ── marker helpers — idempotency via marker files ────────────────────────────
marker_set()    { mkdir -p "$(dirname "$1")"; touch "$1"; }
marker_exists() { [[ -f "$1" ]]; }
