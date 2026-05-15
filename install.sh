#!/usr/bin/env bash
# install.sh — USB-Stick für Fedora-Autoinstall erstellen
#
# Konfiguration (Standard: XML):
#   sudo ./install.sh /dev/sdX                          # XML: config/example.xml
#   sudo ./install.sh /dev/sdX --config mein.xml        # XML: eigene Datei
#   sudo ./install.sh /dev/sdX --custom                 # JSON: config/install.json
#   sudo ./install.sh /dev/sdX --custom mein.json       # JSON: eigene Datei
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
USB_DEV=""
CUSTOM_ISO=""
CONFIG_MODE="xml"                              # "xml" oder "json"
XML_FILE="${SCRIPT_DIR}/config/example.xml"
JSON_FILE="${SCRIPT_DIR}/config/install.json"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso)
            CUSTOM_ISO="${2:?'--iso braucht einen Pfad'}"; shift 2 ;;
        --config)
            CONFIG_MODE="xml"
            XML_FILE="${2:?'--config braucht eine XML-Datei'}"; shift 2 ;;
        --custom)
            CONFIG_MODE="json"
            # optionales zweites Argument: eigene JSON-Datei
            if [[ -n "${2:-}" && "${2}" != -* ]]; then
                JSON_FILE="$2"; shift 2
            else
                shift
            fi ;;
        /dev/*)
            USB_DEV="$1"; shift ;;
        -h|--help)
            sed -n '2,10p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *)
            die "Unbekanntes Argument: $1" ;;
    esac
done

if [[ -z "$USB_DEV" ]]; then
    echo ""
    echo -e "${BOLD}Fedora Autoinstall — USB-Stick erstellen${RESET}"
    echo ""
    echo "Usage: sudo $0 /dev/sdX [OPTIONEN]"
    echo ""
    echo "  (Standard)  XML-Konfiguration: config/example.xml"
    echo "  --config F  Eigene XML-Datei"
    echo "  --custom    JSON-Konfiguration: config/install.json"
    echo "  --custom F  Eigene JSON-Datei"
    echo "  --iso F     Lokale Fedora-ISO statt Download"
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
for cmd in sgdisk mkfs.fat grub2-install cpio file curl python3; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    die "Fehlende Tools: ${missing[*]}
  Installieren: sudo dnf install gdisk dosfstools grub2-efi-x64 grub2-tools cpio file curl python3"
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
        curl -L --progress-bar \
            -o "${ISO_DIR}/Fedora-Everything-netinst-x86_64-${FEDORA_VERSION}-1.6.iso" \
            "$FEDORA_ISO_URL" || die "ISO-Download fehlgeschlagen."
        log "ISO heruntergeladen."
    fi
fi

# ── Konfiguration anwenden ────────────────────────────────────────────────────
step "Konfiguration anwenden (${CONFIG_MODE^^})"

if [[ "$CONFIG_MODE" == "xml" ]]; then
    [[ -f "$XML_FILE" ]] || die "XML-Konfiguration nicht gefunden: $XML_FILE"
    log "XML: $XML_FILE"
    err_out=$(python3 "${SCRIPT_DIR}/lib/xml2ks.py" \
        --config "$XML_FILE" \
        --output "${SCRIPT_DIR}/kickstart/fedora-full.ks" \
        --first-boot-script  "${SCRIPT_DIR}/scripts/first-boot.sh" \
        --first-login-script "${SCRIPT_DIR}/scripts/first-login.sh" \
        --systemd-unit       "${SCRIPT_DIR}/systemd/fedora-first-boot.service" 2>&1) && {
        log "Kickstart aus XML generiert: kickstart/fedora-full.ks"
    } || {
        warn "XML-Konfiguration konnte nicht angewendet werden — Kickstart bleibt unverändert."
        warn "Fehler: $err_out"
    }

elif [[ "$CONFIG_MODE" == "json" ]]; then
    [[ -f "$JSON_FILE" ]] || die "JSON-Konfiguration nicht gefunden: $JSON_FILE"
    log "JSON: $JSON_FILE"
    err_out=$(python3 "${SCRIPT_DIR}/scripts/apply_config.py" \
        --config "$JSON_FILE" 2>&1) && {
        log "Kickstarts aus JSON aktualisiert."
    } || {
        warn "JSON-Konfiguration konnte nicht angewendet werden — Kickstarts bleiben unverändert."
        warn "Fehler: $err_out"
    }
fi

# ── USB-Stick bauen ───────────────────────────────────────────────────────────
step "USB-Stick bauen"
exec "${SCRIPT_DIR}/scripts/build-usb.sh" "$USB_DEV"
