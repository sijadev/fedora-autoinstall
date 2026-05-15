#!/usr/bin/env bash
# install.sh — USB-Stick für Fedora-Autoinstall erstellen
#
# Workflow:
#   1. Fedora-Netinstall-ISO herunterladen (falls nicht vorhanden)
#   2. USB-Stick partitionieren, GRUB2 + Kernel + Kickstarts einrichten
#
# Usage:
#   sudo ./install.sh /dev/sdX
#   sudo ./install.sh /dev/sdX --iso /pfad/zur/Fedora.iso

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FEDORA_VERSION="43"
FEDORA_ISO_URL="https://dl.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_VERSION}/Everything/x86_64/iso/Fedora-Everything-netinst-x86_64-${FEDORA_VERSION}-1.6.iso"
ISO_DIR="${SCRIPT_DIR}/iso"

if [[ -t 1 ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    CYAN=$'\033[36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; RESET=""
fi
log()  { echo -e "${GREEN}[install]${RESET} $*"; }
warn() { echo -e "${YELLOW}[install]${RESET} $*" >&2; }
die()  { echo -e "${RED}[install] FEHLER: $*${RESET}" >&2; exit 1; }
step() { echo -e "\n${CYAN}${BOLD}══ $* ══${RESET}"; }

# ── Args ──────────────────────────────────────────────────────────────────────
USB_DEV="${1:-}"
CUSTOM_ISO=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso) CUSTOM_ISO="${2:-}"; shift 2 ;;
        /dev/*) USB_DEV="$1"; shift ;;
        *) shift ;;
    esac
done

if [[ -z "$USB_DEV" ]]; then
    echo ""
    echo -e "${BOLD}Fedora Autoinstall — USB-Stick erstellen${RESET}"
    echo ""
    echo "Usage: sudo $0 /dev/sdX [--iso /pfad/zur/Fedora.iso]"
    echo ""
    echo "Verfügbare Geräte:"
    lsblk -o NAME,SIZE,TRAN,LABEL,MOUNTPOINT | grep -v "^loop"
    echo ""
    exit 1
fi

[[ "$EUID" -ne 0 ]] && die "Bitte als root ausführen: sudo $0 $*"
[[ -b "$USB_DEV" ]] || die "Kein Blockgerät: $USB_DEV"

# ── Voraussetzungen ───────────────────────────────────────────────────────────
step "Voraussetzungen prüfen"
missing=()
for cmd in sgdisk mkfs.fat grub2-install cpio file curl; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    die "Fehlende Tools: ${missing[*]}
  Installieren: sudo dnf install gdisk dosfstools grub2-efi-x64 grub2-tools cpio file curl"
fi
log "Alle Voraussetzungen erfüllt."

# ── ISO sicherstellen ─────────────────────────────────────────────────────────
step "Fedora-netinstall-ISO"
mkdir -p "$ISO_DIR"

if [[ -n "$CUSTOM_ISO" ]]; then
    [[ -f "$CUSTOM_ISO" ]] || die "ISO nicht gefunden: $CUSTOM_ISO"
    log "Verwende angegebene ISO: $CUSTOM_ISO"
else
    existing=$(ls -t "${ISO_DIR}"/Fedora-Everything-netinst-*.iso 2>/dev/null | head -1 || true)
    if [[ -n "$existing" ]]; then
        log "ISO vorhanden: $(basename "$existing")"
    else
        log "Lade Fedora ${FEDORA_VERSION} netinstall-ISO herunter..."
        log "URL: $FEDORA_ISO_URL"
        curl -L --progress-bar -o "${ISO_DIR}/Fedora-Everything-netinst-x86_64-${FEDORA_VERSION}-1.6.iso" \
            "$FEDORA_ISO_URL" || die "ISO-Download fehlgeschlagen."
        log "ISO heruntergeladen: $(du -h "${ISO_DIR}/Fedora-Everything-netinst-x86_64-${FEDORA_VERSION}-1.6.iso" | cut -f1)"
    fi
fi

# ── Konfiguration anwenden (optional) ────────────────────────────────────────
CONFIG_FILE="${SCRIPT_DIR}/config/install.json"
if [[ -f "$CONFIG_FILE" ]]; then
    step "Konfiguration anwenden"
    err_out=$(python3 "${SCRIPT_DIR}/scripts/apply-config.py" --config "$CONFIG_FILE" 2>&1) && {
        log "Kickstarts aktualisiert."
    } || {
        warn "config/install.json konnte nicht angewendet werden — Kickstarts bleiben unverändert."
        warn "Fehler: $err_out"
        warn "Zum manuellen Anwenden: python3 scripts/apply-config.py --config config/install.json"
    }
fi

# ── USB-Stick bauen ───────────────────────────────────────────────────────────
step "USB-Stick bauen"
exec "${SCRIPT_DIR}/scripts/build-usb.sh" "$USB_DEV"
