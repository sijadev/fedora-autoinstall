#!/usr/bin/env bash
# scripts/fetch-ssh-logs.sh - Fetch logs from a remote Fedora host via SSH.
#
# What it does:
#   1) Verifies SSH connectivity.
#   2) Tries privileged collection (root or passwordless sudo):
#      - /var/log (recursive)
#      - /etc/fedora-provision.env
#      - journalctl dumps (boot + key units)
#      - known installer/provision logs
#   3) Always collects user-level provisioning logs as fallback.
#
# Usage examples:
#   bash scripts/fetch-ssh-logs.sh --host 192.168.1.50 --user sija
#   bash scripts/fetch-ssh-logs.sh --host fedora-box.local --user sija --port 2222
#   bash scripts/fetch-ssh-logs.sh --host 10.0.0.9 --user root --identity ~/.ssh/id_ed25519
#   bash scripts/fetch-ssh-logs.sh --host 192.168.0.2 --bootstrap-key

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
DEFAULT_DEST_BASE="./logs"

HOST=""
USER_NAME="${USER:-fedora}"
PORT="22"
IDENTITY_FILE=""
DEST_BASE="$DEFAULT_DEST_BASE"
NO_EXTRACT="0"
BOOTSTRAP_KEY="0"
PASSWORD_AUTH="0"
KEY_FILE="${HOME}/.ssh/id_ed25519_fedora_autoinstall"

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME --host HOST [options]

Required:
  --host HOST                 Remote host (IP or DNS name)

Optional:
  --user USER                 SSH user (default: ${USER_NAME})
  --port PORT                 SSH port (default: 22)
  --identity FILE             SSH private key file
    --key-file FILE             Key file used for --bootstrap-key (default: ${KEY_FILE})
    --bootstrap-key             Create/install key once (interactive password), then use key auth
    --password-auth             Allow interactive password SSH auth for this run
  --dest DIR                  Local base directory for downloads (default: ./logs)
  --no-extract                Keep archive only, do not extract locally
  -h, --help                  Show help

Notes:
    - Default mode is key-only SSH (BatchMode=yes).
    - Use --bootstrap-key once to set up passwordless login on the target host.
    - Use --password-auth only for temporary fallback/debug sessions.
  - Full system logs require root or passwordless sudo on remote host.
  - If privileged collection is not possible, the script still downloads
    user-level logs from ~/.local/share/fedora-provision.
EOF
}

log() {
    printf '[fetch-ssh-logs] %s\n' "$*"
}

warn() {
    printf '[fetch-ssh-logs] WARN: %s\n' "$*" >&2
}

die() {
    printf '[fetch-ssh-logs] ERROR: %s\n' "$*" >&2
    exit 1
}

ensure_known_host() {
    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"

    if ! command -v ssh-keyscan >/dev/null 2>&1; then
        warn "ssh-keyscan not found; skipping known_hosts prefill"
        return 0
    fi

    local known_hosts="${HOME}/.ssh/known_hosts"
    touch "$known_hosts"
    chmod 600 "$known_hosts"

    if ! ssh-keygen -F "$HOST" -f "$known_hosts" >/dev/null 2>&1; then
        log "Adding host key to known_hosts: $HOST:$PORT"
        ssh-keyscan -p "$PORT" "$HOST" >> "$known_hosts" 2>/dev/null || true
    fi
}

bootstrap_ssh_key() {
    command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen command not found"

    local pub_key_file="${KEY_FILE}.pub"
    mkdir -p "$(dirname "$KEY_FILE")"
    chmod 700 "$(dirname "$KEY_FILE")"

    if [[ ! -f "$KEY_FILE" ]]; then
        log "Generating passwordless ed25519 key: $KEY_FILE"
        ssh-keygen -t ed25519 -N "" -f "$KEY_FILE" -C "fedora-autoinstall@$(hostname)" >/dev/null
    else
        log "Using existing key: $KEY_FILE"
    fi
    [[ -f "$pub_key_file" ]] || die "Public key file missing: $pub_key_file"

    ensure_known_host

    log "Installing public key on remote host (one-time password prompt may appear)"
    if command -v ssh-copy-id >/dev/null 2>&1; then
        ssh-copy-id -i "$pub_key_file" -p "$PORT" "$TARGET" >/dev/null
    else
        local pub_key
        pub_key="$(cat "$pub_key_file")"
        ssh -o ConnectTimeout=10 -p "$PORT" "$TARGET" \
            "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF '$pub_key' ~/.ssh/authorized_keys || echo '$pub_key' >> ~/.ssh/authorized_keys"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            HOST="${2:-}"
            shift 2
            ;;
        --user)
            USER_NAME="${2:-}"
            shift 2
            ;;
        --port)
            PORT="${2:-}"
            shift 2
            ;;
        --identity)
            IDENTITY_FILE="${2:-}"
            shift 2
            ;;
        --key-file)
            KEY_FILE="${2:-}"
            shift 2
            ;;
        --bootstrap-key)
            BOOTSTRAP_KEY="1"
            shift
            ;;
        --password-auth)
            PASSWORD_AUTH="1"
            shift
            ;;
        --dest)
            DEST_BASE="${2:-}"
            shift 2
            ;;
        --no-extract)
            NO_EXTRACT="1"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

[[ -n "$HOST" ]] || { usage; die "--host is required"; }
[[ -n "$USER_NAME" ]] || die "--user must not be empty"
[[ -n "$PORT" ]] || die "--port must not be empty"

if ! command -v ssh >/dev/null 2>&1; then
    die "ssh command not found"
fi
if ! command -v tar >/dev/null 2>&1; then
    die "tar command not found"
fi

TARGET="${USER_NAME}@${HOST}"

if [[ "$BOOTSTRAP_KEY" == "1" ]]; then
    IDENTITY_FILE="$KEY_FILE"
    bootstrap_ssh_key
fi

if [[ -z "$IDENTITY_FILE" && -f "$KEY_FILE" ]]; then
    IDENTITY_FILE="$KEY_FILE"
fi

ensure_known_host

SSH_OPTS=(-o ConnectTimeout=10 -o IdentitiesOnly=yes -p "$PORT")
if [[ "$PASSWORD_AUTH" == "1" ]]; then
    SSH_OPTS+=(-o BatchMode=no)
else
    SSH_OPTS+=(-o BatchMode=yes)
fi
if [[ -n "$IDENTITY_FILE" ]]; then
    [[ -f "$IDENTITY_FILE" ]] || die "Identity file not found: $IDENTITY_FILE"
    SSH_OPTS+=(-i "$IDENTITY_FILE")
fi

STAMP="$(date '+%Y%m%d-%H%M%S')"
DEST_DIR="${DEST_BASE%/}/ssh-logs-${HOST//[^a-zA-Z0-9_.-]/_}-${STAMP}"
ARCHIVE_FILE="$DEST_DIR/remote-logs.tgz"

mkdir -p "$DEST_DIR"

log "Testing SSH connection to $TARGET:$PORT"
ssh "${SSH_OPTS[@]}" "$TARGET" 'echo connected' >/dev/null \
    || die "SSH connection failed (run with --bootstrap-key for one-time setup or --password-auth for fallback)"

log "Collecting privileged logs (root/sudo)"
set +e
ssh "${SSH_OPTS[@]}" "$TARGET" 'bash -s' > "$ARCHIVE_FILE" <<'REMOTE_SCRIPT'
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    SUDO="sudo -n"
else
    exit 17
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/payload" "$TMP_DIR/meta"

# System logs and key config for provisioning diagnostics.
$SUDO tar -C / -cf "$TMP_DIR/payload/system-files.tar" \
    var/log \
    etc/fedora-provision.env \
    etc/modprobe.d \
    etc/dracut.conf.d \
    2>/dev/null || true

# Known installer/provision logs if present.
for f in /root/ks-post.log /root/ks-common-post.log /var/log/fedora-first-boot.log; do
    if $SUDO test -f "$f"; then
        out_name="$(echo "$f" | sed 's#^/##; s#/#_#g')"
        $SUDO cat "$f" > "$TMP_DIR/meta/${out_name}" 2>/dev/null || true
    fi
done

# Journal exports for quick triage.
if command -v journalctl >/dev/null 2>&1; then
    $SUDO journalctl -b --no-pager > "$TMP_DIR/meta/journal-boot.log" 2>&1 || true
    $SUDO journalctl -u fedora-first-boot.service --no-pager > "$TMP_DIR/meta/journal-fedora-first-boot.log" 2>&1 || true
    $SUDO journalctl -u fedora-provision-user.service --no-pager > "$TMP_DIR/meta/journal-fedora-provision-user.log" 2>&1 || true
    $SUDO journalctl -u sshd --no-pager > "$TMP_DIR/meta/journal-sshd.log" 2>&1 || true
fi

tar -C "$TMP_DIR" -czf - .
REMOTE_SCRIPT
SSH_RC=$?
set -e

if [[ $SSH_RC -eq 0 ]]; then
    log "Privileged collection completed: $ARCHIVE_FILE"
elif [[ $SSH_RC -eq 17 ]]; then
    warn "No root/passwordless sudo on remote host; privileged collection skipped."
    rm -f "$ARCHIVE_FILE"
else
    warn "Privileged collection failed with exit code $SSH_RC"
    rm -f "$ARCHIVE_FILE"
fi

# Always collect user-level logs as fallback/addition.
USER_LOG_DIR="$DEST_DIR/user-fedora-provision"
mkdir -p "$USER_LOG_DIR"
log "Collecting user-level logs (~/.local/share/fedora-provision)"
ssh "${SSH_OPTS[@]}" "$TARGET" 'bash -s' > "$USER_LOG_DIR/user-provision-logs.tgz" <<'REMOTE_USER_LOGS'
set -euo pipefail
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR"
if [[ -d "$HOME/.local/share/fedora-provision" ]]; then
    tar -C "$HOME/.local/share" -czf "$TMP_DIR/user-logs.tgz" fedora-provision
else
    : > "$TMP_DIR/no-user-logs.txt"
fi
tar -C "$TMP_DIR" -czf - .
REMOTE_USER_LOGS

if [[ "$NO_EXTRACT" == "0" ]]; then
    if [[ -f "$ARCHIVE_FILE" ]]; then
        mkdir -p "$DEST_DIR/privileged"
        tar -xzf "$ARCHIVE_FILE" -C "$DEST_DIR/privileged"
    fi
    tar -xzf "$USER_LOG_DIR/user-provision-logs.tgz" -C "$USER_LOG_DIR"
fi

cat > "$DEST_DIR/README.txt" <<EOF
Remote host: $HOST
Remote user: $USER_NAME
SSH port: $PORT
Created at: $(date '+%Y-%m-%d %H:%M:%S')

Files:
- remote-logs.tgz: privileged bundle (if available)
- user-fedora-provision/user-provision-logs.tgz: user-level logs

If privileged bundle is missing, run as root on remote host or configure passwordless sudo.
EOF

log "Done. Logs stored in: $DEST_DIR"
