#!/usr/bin/env bash
# scripts/setup-ssh-key.sh - One-time SSH key bootstrap for passwordless login.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
HOST=""
USER_NAME="${USER:-fedora}"
PORT="22"
KEY_FILE="${HOME}/.ssh/id_ed25519_fedora_autoinstall"
ALIAS_NAME=""
WRITE_CONFIG="1"

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME --host HOST [options]

Required:
  --host HOST               Remote host (IP or DNS name)

Optional:
  --user USER               SSH user (default: ${USER_NAME})
  --port PORT               SSH port (default: 22)
  --key-file FILE           Private key path (default: ${KEY_FILE})
    --alias NAME              SSH alias to write into ~/.ssh/config
    --no-config               Do not write/update ~/.ssh/config alias
  -h, --help                Show help
EOF
}

log() {
    printf '[setup-ssh-key] %s\n' "$*"
}

die() {
    printf '[setup-ssh-key] ERROR: %s\n' "$*" >&2
    exit 1
}

default_alias_name() {
    local normalized
    normalized="$(printf '%s' "$HOST" | tr '.:' '-' | tr -cd '[:alnum:]_-')"
    printf 'fedora-%s' "$normalized"
}

upsert_ssh_config_alias() {
    local config_file="${HOME}/.ssh/config"
    local marker_begin="# fedora-autoinstall:${ALIAS_NAME}:begin"
    local marker_end="# fedora-autoinstall:${ALIAS_NAME}:end"

    touch "$config_file"
    chmod 600 "$config_file"

    # Replace existing managed block for this alias if present.
    if grep -qF "$marker_begin" "$config_file" 2>/dev/null; then
        awk -v b="$marker_begin" -v e="$marker_end" '
            $0==b {skip=1; next}
            $0==e {skip=0; next}
            skip!=1 {print}
        ' "$config_file" > "${config_file}.tmp"
        mv "${config_file}.tmp" "$config_file"
    fi

    {
        printf '\n%s\n' "$marker_begin"
        printf 'Host %s\n' "$ALIAS_NAME"
        printf '    HostName %s\n' "$HOST"
        printf '    User %s\n' "$USER_NAME"
        printf '    Port %s\n' "$PORT"
        printf '    IdentityFile %s\n' "$KEY_FILE"
        printf '    IdentitiesOnly yes\n'
        printf '%s\n' "$marker_end"
    } >> "$config_file"

    log "SSH alias written: ${ALIAS_NAME} (config: ${config_file})"
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
        --key-file)
            KEY_FILE="${2:-}"
            shift 2
            ;;
        --alias)
            ALIAS_NAME="${2:-}"
            shift 2
            ;;
        --no-config)
            WRITE_CONFIG="0"
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

if [[ -z "$ALIAS_NAME" ]]; then
    ALIAS_NAME="$(default_alias_name)"
fi

command -v ssh >/dev/null 2>&1 || die "ssh command not found"
command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen command not found"

mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"

KNOWN_HOSTS="${HOME}/.ssh/known_hosts"
touch "$KNOWN_HOSTS"
chmod 600 "$KNOWN_HOSTS"

if ! ssh-keygen -F "$HOST" -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
    if command -v ssh-keyscan >/dev/null 2>&1; then
        log "Adding host key to known_hosts: ${HOST}:${PORT}"
        ssh-keyscan -p "$PORT" "$HOST" >> "$KNOWN_HOSTS" 2>/dev/null || true
    fi
fi

if [[ ! -f "$KEY_FILE" ]]; then
    log "Generating passwordless ed25519 key: $KEY_FILE"
    ssh-keygen -t ed25519 -N "" -f "$KEY_FILE" -C "fedora-autoinstall@$(hostname)" >/dev/null
else
    log "Using existing key: $KEY_FILE"
fi

PUB_KEY_FILE="${KEY_FILE}.pub"
[[ -f "$PUB_KEY_FILE" ]] || die "Public key file missing: $PUB_KEY_FILE"

TARGET="${USER_NAME}@${HOST}"
log "Installing key on ${TARGET} (one-time password prompt may appear)"
if command -v ssh-copy-id >/dev/null 2>&1; then
    ssh-copy-id -i "$PUB_KEY_FILE" -p "$PORT" "$TARGET" >/dev/null
else
    PUB_KEY="$(cat "$PUB_KEY_FILE")"
    ssh -o ConnectTimeout=10 -p "$PORT" "$TARGET" \
        "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF '$PUB_KEY' ~/.ssh/authorized_keys || echo '$PUB_KEY' >> ~/.ssh/authorized_keys"
fi

log "Testing key-only SSH login"
ssh -o BatchMode=yes -o IdentitiesOnly=yes -i "$KEY_FILE" -p "$PORT" "$TARGET" 'echo connected' >/dev/null \
    || die "Key login test failed"

if [[ "$WRITE_CONFIG" == "1" ]]; then
    upsert_ssh_config_alias
    log "Testing alias SSH login"
    ssh -o BatchMode=yes "$ALIAS_NAME" 'echo connected' >/dev/null \
        || die "Alias login test failed"
fi

log "Success. Passwordless SSH is ready."
log "Example: ssh -o IdentitiesOnly=yes -i $KEY_FILE -p $PORT $TARGET"
if [[ "$WRITE_CONFIG" == "1" ]]; then
    log "Alias example: ssh ${ALIAS_NAME}"
fi
