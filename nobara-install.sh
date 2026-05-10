#!/usr/bin/env bash
# nobara-install.sh — Main orchestrator
#
# Validates XML config, generates Kickstart, downloads ISO,
# deploys everything to Ventoy USB, and writes ventoy.json.
#
# Usage:
#   sudo ./nobara-install.sh --config config/example.xml [--dry-run] [--reboot]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/usb.sh"

PROGRAM="nobara-install"
VERSION="1.0.0"

LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/logs/nobara-install.log}"

usage() {
    cat <<EOF
Usage: $PROGRAM [OPTIONS]

Options:
  -c, --config FILE    Installation config XML file (required)
  -d, --dry-run        Print all actions without executing
  -l, --log FILE       Log file path (default: logs/nobara-install.log)
  -r, --reboot         Reboot system after deployment (with confirmation)
    -S, --skip-smoke-gate  Bypass required Podman smoke-test gate (not recommended)
       --skip-vm-gate   Alias for --skip-smoke-gate (legacy)
  -h, --help           Show this help

Environment:
  DRY_RUN=1            Equivalent to --dry-run

Examples:
  sudo $PROGRAM --config config/example.xml
  sudo $PROGRAM --config config/example.xml --dry-run
  sudo $PROGRAM --config config/my-config.xml --log /var/log/nobara-deploy.log
    sudo $PROGRAM --config config/example.xml --skip-vm-gate
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
CONFIG_FILE=""
DO_REBOOT=0
SKIP_VM_GATE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)  CONFIG_FILE="$2"; shift 2 ;;
        -d|--dry-run) DRY_RUN=1; shift ;;
        -l|--log)     LOG_FILE="$2"; shift 2 ;;
        -r|--reboot)  DO_REBOOT=1; shift ;;
        -S|--skip-smoke-gate|--skip-vm-gate) SKIP_VM_GATE=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

export DRY_RUN LOG_FILE

[[ -z "$CONFIG_FILE" ]] && { log_error "--config is required."; usage; exit 1; }
[[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"

mkdir -p "$(dirname "$LOG_FILE")"

require_root
require_cmd python3 curl lsblk findmnt sha256sum git

assert_podman_smoke_gate() {
    local stamp_file="$SCRIPT_DIR/.state/podman-smoke-passed.stamp"
    local current_scripts_sha stamp_config_sha stamp_layers stamp_timestamp

    [[ -f "$stamp_file" ]] || die "Podman smoke gate: stamp missing ($stamp_file). Run scripts/podman-pipeline.sh first."

    current_scripts_sha=$(find "$SCRIPT_DIR/config" "$SCRIPT_DIR/scripts" -type f | sort | xargs sha256sum 2>/dev/null | sha256sum | awk '{print $1}')
    stamp_config_sha=$(awk -F= '$1=="config_sha" {print $2}' "$stamp_file" | tail -n1)
    stamp_layers=$(awk -F= '$1=="layers" {print $2}' "$stamp_file" | tail -n1)
    stamp_timestamp=$(awk -F= '$1=="timestamp" {print $2}' "$stamp_file" | tail -n1)

    [[ -n "$stamp_config_sha" ]] || die "Podman smoke gate: invalid stamp (missing config_sha). Re-run scripts/podman-pipeline.sh."
    [[ "$stamp_config_sha" == "$current_scripts_sha" ]] || die "Podman smoke gate: scripts/config changed since last Podman run. Re-run scripts/podman-pipeline.sh."

    log_info "Podman smoke gate passed: layers=${stamp_layers} stamp_time=${stamp_timestamp}"
}

log_step "Nobara Auto-Install Orchestrator v${VERSION}"
[[ "$DRY_RUN" == "1" ]] && log_warn "DRY-RUN mode active — no changes will be made."

# ── Step 1: Validate XML config ───────────────────────────────────────────────
log_step "Validating config: $CONFIG_FILE"
python3 "$SCRIPT_DIR/lib/xml2ks.py" --validate-only "$CONFIG_FILE" \
    || die "Config validation failed."

# ── Step 1a: VM-first gate for live deployments ──────────────────────────────
if [[ "$DRY_RUN" != "1" ]]; then
    log_step "VM-first safety gate"
    if [[ "$SKIP_VM_GATE" == "1" ]]; then
        log_warn "Podman smoke gate bypassed via --skip-smoke-gate"
    else
        assert_podman_smoke_gate
    fi
fi

# ── Step 2: Generate Kickstart ────────────────────────────────────────────────
log_step "Generating Kickstart"
KS_DIR="$SCRIPT_DIR/kickstart"
KS_FILE="$KS_DIR/nobara-autoinstall.ks"

run mkdir -p "$KS_DIR"

if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "python3 lib/xml2ks.py → $KS_FILE"
else
    python3 "$SCRIPT_DIR/lib/xml2ks.py" \
        --config "$CONFIG_FILE" \
        --first-boot-script  "$SCRIPT_DIR/scripts/first-boot.sh" \
        --first-login-script "$SCRIPT_DIR/scripts/first-login.sh" \
        --systemd-unit       "$SCRIPT_DIR/systemd/nobara-first-boot.service" \
        --output "$KS_FILE"
    log_info "Kickstart written: $KS_FILE"
fi

# ── Step 3: Detect Ventoy USB ────────────────────────────────────────────────
log_step "Ventoy USB detection"

if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "Would auto-detect Ventoy USB disk."
    VENTOY_DISK="[DRY-RUN: /dev/sdX]"
    VENTOY_MNT="[DRY-RUN: /mnt/ventoy]"
else
    VENTOY_DISK=$(find_ventoy_disk)
    log_info "Ventoy USB disk: $VENTOY_DISK"
    assert_disk_not_system "$VENTOY_DISK"
    VENTOY_MNT=$(mount_ventoy_data "$VENTOY_DISK")
fi

# ── Step 4: ISO — check Ventoy first, download only if needed ────────────────
log_step "ISO check / download"

ISO_URL=$(python3 "$SCRIPT_DIR/lib/xml2ks.py" --get-field iso_url "$CONFIG_FILE")
ISO_SHA256=$(python3 "$SCRIPT_DIR/lib/xml2ks.py" --get-field iso_sha256 "$CONFIG_FILE" 2>/dev/null || echo "")
ISO_BASENAME=$(basename "$ISO_URL")
ISO_DIR="$SCRIPT_DIR/iso"
ISO_FILE="$ISO_DIR/$ISO_BASENAME"
# ISOs liegen im Ventoy-Root (nicht in iso/), damit alle bestehenden ISOs sichtbar bleiben
ISO_DEST="$VENTOY_MNT/$ISO_BASENAME"

verify_iso() {
    local file="$1" checksum="$2"
    [[ -z "$checksum" ]] && return 0
    [[ "$checksum" == REPLACE_* ]] && { log_warn "SHA256 is placeholder; skipping verification."; return 0; }
    log_info "Verifying SHA256 of $(basename "$file")..."
    echo "${checksum}  ${file}" | sha256sum --check --quiet \
        || return 1
}

if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "Would check ISO on Ventoy → download if missing → $ISO_DEST"
else
    # 1. ISO already on Ventoy and valid → nothing else to do
    if [[ -f "$ISO_DEST" ]] && verify_iso "$ISO_DEST" "$ISO_SHA256"; then
        log_info "ISO already on Ventoy and valid — skipping download: $ISO_DEST"
    else
        [[ -f "$ISO_DEST" ]] && log_warn "ISO on Ventoy failed verification — re-fetching."

        # 2. Fall back to local cache
        if [[ -f "$ISO_FILE" ]] && verify_iso "$ISO_FILE" "$ISO_SHA256"; then
            log_info "ISO found in local cache: $ISO_FILE"
        else
            [[ -f "$ISO_FILE" ]] && log_warn "Local cache invalid — re-downloading."
            log_info "Downloading: $ISO_URL"
            mkdir -p "$ISO_DIR"
            curl -L --retry 5 --continue-at - --progress-bar -o "$ISO_FILE" "$ISO_URL"
            verify_iso "$ISO_FILE" "$ISO_SHA256" || die "SHA256 verification failed."
        fi

        # 3. Copy local cache → Ventoy
        AVAILABLE=$(df --output=avail -B1 "$VENTOY_MNT" | tail -1)
        ISO_SIZE=$(stat -c%s "$ISO_FILE")
        (( ISO_SIZE <= AVAILABLE )) \
            || die "Not enough space on Ventoy USB (need ${ISO_SIZE}B, have ${AVAILABLE}B)."
        log_info "Copying ISO to Ventoy..."
        cp --no-preserve=all "$ISO_FILE" "$ISO_DEST"
        log_info "ISO deployed: $ISO_DEST"
    fi
fi

# ── Step 6: Deploy Kickstart ──────────────────────────────────────────────────
log_step "Kickstart deployment to Ventoy"

KS_DEST_DIR="$VENTOY_MNT/kickstart"
KS_DEST="$KS_DEST_DIR/nobara-autoinstall.ks"

run mkdir -p "$KS_DEST_DIR"
if [[ "$DRY_RUN" != "1" ]]; then
    cp "$KS_FILE" "$KS_DEST"
    log_info "Kickstart deployed: $KS_DEST"
else
    log_dry "cp $KS_FILE → $KS_DEST"
fi

# ── Step 7: Write ventoy.json ─────────────────────────────────────────────────
log_step "ventoy.json auto_install config"

VENTOY_JSON_DIR="$VENTOY_MNT/ventoy"
VENTOY_JSON="$VENTOY_JSON_DIR/ventoy.json"
KS_VENTOY_PATH="/kickstart/nobara-autoinstall.ks"

if [[ "$DRY_RUN" != "1" ]]; then
    mkdir -p "$VENTOY_JSON_DIR"
    cat > "$VENTOY_JSON" <<JSON
{
    "auto_install": [
        {
            "image": "/${ISO_BASENAME}",
            "template": [
                {
                    "path": "${KS_VENTOY_PATH}"
                }
            ]
        }
    ]
}
JSON
    log_info "ventoy.json written: $VENTOY_JSON"
else
    log_dry "Would write ventoy.json → /${ISO_BASENAME} → ${KS_VENTOY_PATH}"
fi

# ── Step 8: Sync and unmount ──────────────────────────────────────────────────
log_step "Sync and unmount"

if [[ "$DRY_RUN" != "1" ]]; then
    sync
    umount_ventoy_data "$VENTOY_MNT"
fi

log_info ""
log_info "Deployment complete."
log_info "  ISO:       /${ISO_BASENAME}"
log_info "  Kickstart: ${KS_VENTOY_PATH}"
log_info ""
log_info "Boot the target machine from the Ventoy USB stick."
log_info "Nobara will install unattended and provision itself on first boot/login."

# ── Step 9: Optional reboot ───────────────────────────────────────────────────
if [[ "$DO_REBOOT" == "1" ]]; then
    if [[ "$DRY_RUN" != "1" ]]; then
        confirm "Reboot this machine now?" && run systemctl reboot
    else
        log_dry "Would reboot system."
    fi
fi
