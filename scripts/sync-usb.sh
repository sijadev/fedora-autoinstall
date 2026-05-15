#!/usr/bin/env bash
# sync-usb.sh — prüft ob der FEDORA-USB-Stick aktuell ist.
#
# WICHTIG: Kickstarts und Scripts sind in der initrd eingebettet.
# Änderungen daran werden erst nach einem USB-Rebuild wirksam:
#   sudo ./install.sh /dev/sdX
#
# sync-usb.sh ist nur noch nützlich für:
#   - --check: Drift erkennen (wird von vm-test.sh als Gate genutzt)
#   - grub.cfg und Dateien die nach der Installation vom USB gelesen werden
#
# Usage:
#   scripts/sync-usb.sh                 # interaktiv, zeigt Drift + Hinweis auf install.sh
#   scripts/sync-usb.sh --check         # nur prüfen (Exit 1 bei Drift), kein Schreiben
#   scripts/sync-usb.sh --force         # Dateien kopieren (ohne initrd-Rebuild)

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="interactive"
case "${1:-}" in
    --check) MODE="check" ;;
    --force) MODE="force" ;;
    "")      ;;
    *) echo "Usage: $0 [--check|--force]" >&2; exit 2 ;;
esac

if [[ -t 1 ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi

log()  { echo -e "${GREEN}[sync-usb]${RESET} $*"; }
warn() { echo -e "${YELLOW}[sync-usb]${RESET} $*" >&2; }
die()  { echo -e "${RED}[sync-usb] $*${RESET}" >&2; exit 1; }

# ── FEDORA-USB-Stick mounten ──────────────────────────────────────────────────
USB_MNT="/run/media/$(whoami)/FEDORA-USB"
self_mounted=0

if ! findmnt "$USB_MNT" &>/dev/null; then
    dev=$(lsblk -o NAME,LABEL -rn | awk '$2=="FEDORA-USB"{print "/dev/"$1}' | head -1)
    [[ -n "$dev" ]] || die "FEDORA-USB-Stick nicht gefunden. Stick einstecken oder mit build-usb.sh einrichten."
    udisksctl mount -b "$dev" &>/dev/null || die "Kann ${dev} nicht mounten."
    self_mounted=1
fi
findmnt "$USB_MNT" &>/dev/null || die "FEDORA-USB nicht erreichbar: ${USB_MNT}"

cleanup() {
    if (( self_mounted )); then
        sync
        udisksctl unmount -b "$(findmnt -n -o SOURCE "$USB_MNT")" &>/dev/null || true
    fi
}
trap cleanup EXIT

# Kernel-Freshness prüfen
if [[ ! -f "${USB_MNT}/boot/vmlinuz" ]]; then
    warn "Kein Bazzite-Kernel auf USB gefunden!"
    warn "Einmalig ausführen: sudo scripts/build-usb.sh /dev/sdX"
fi

# ── Plan: SRC → DST ───────────────────────────────────────────────────────────
# Format: "src_rel|dst_rel"
PLAN=(
    "fedora-provision.sh|fedora-provision.sh"
    "kickstart/common-post.inc|kickstart/common-post.inc"
    "kickstart/fedora-vm.ks|kickstart/fedora-vm.ks"
    "kickstart/fedora-full.ks|kickstart/fedora-full.ks"
    "kickstart/fedora-headless-vllm.ks|kickstart/fedora-headless-vllm.ks"
    "kickstart/fedora-theme-bash.ks|kickstart/fedora-theme-bash.ks"
    "scripts/first-boot.sh|scripts/first-boot.sh"
    "scripts/first-login.sh|scripts/first-login.sh"
    "scripts/vllm-router.py|scripts/vllm-router.py"
    "scripts/welcome-dialog.sh|scripts/welcome-dialog.sh"
    "scripts/fedora-provision.desktop|scripts/fedora-provision.desktop"
    "systemd/fedora-first-boot.service|systemd/fedora-first-boot.service"
    "systemd/vllm@.container|systemd/vllm@.container"
    "systemd/vllm-router.service|systemd/vllm-router.service"
    "boot/grub.cfg|boot/grub.cfg"
)

# ── Obsolete Dateien (werden entfernt falls vorhanden) ────────────────────────
OBSOLETE=(
    "systemd/nobara-first-boot.service"
    "systemd/vllm-audio.container"
    "systemd/vllm-agent.container"
    "systemd/vllm-audio.service"
    "systemd/vllm-agent.service"
    "scripts/bitwig-pipeline.sh"
    "ventoy/ventoy_grub.cfg"
    "ventoy/ventoy.json"
)

# ── Diff-Phase ────────────────────────────────────────────────────────────────
to_copy=()
to_remove=()

for entry in "${PLAN[@]}"; do
    IFS='|' read -r src_rel dst_rel <<<"$entry"
    src="${PROJECT_DIR}/${src_rel}"
    dst="${USB_MNT}/${dst_rel}"
    [[ -f "$src" ]] || { warn "Quelle fehlt: ${src_rel} — übersprungen"; continue; }

    if [[ ! -f "$dst" ]] || ! diff -q "$src" "$dst" &>/dev/null; then
        to_copy+=("$entry")
    fi
done

for f in "${OBSOLETE[@]}"; do
    [[ -e "${USB_MNT}/${f}" ]] && to_remove+=("$f")
done

# ── Report ────────────────────────────────────────────────────────────────────
if [[ ${#to_copy[@]} -eq 0 && ${#to_remove[@]} -eq 0 ]]; then
    log "USB-Stick ist aktuell ✓"
    exit 0
fi

echo -e "\n${BOLD}USB-Stick Drift:${RESET}"
for entry in "${to_copy[@]}"; do
    IFS='|' read -r src_rel dst_rel <<<"$entry"
    dst="${USB_MNT}/${dst_rel}"
    if [[ -f "$dst" ]]; then
        echo -e "  ${YELLOW}~${RESET} ${src_rel} → ${dst_rel}"
    else
        echo -e "  ${GREEN}+${RESET} ${src_rel} → ${dst_rel}  (neu)"
    fi
done
for f in "${to_remove[@]}"; do
    echo -e "  ${RED}-${RESET} ${f}  (veraltet, wird entfernt)"
done
echo ""

if [[ "$MODE" == "check" ]]; then
    exit 1
fi

if [[ "$MODE" == "interactive" ]]; then
    echo -e "${YELLOW}Hinweis:${RESET} Kickstarts und Scripts sind in der initrd eingebettet."
    echo -e "         Für einen vollständigen Update: ${BOLD}sudo ./install.sh /dev/sdX${RESET}"
    echo ""
    read -r -t 15 -p "Trotzdem nur Dateien auf USB kopieren? [j/N] " ans 2>/dev/tty || ans="N"
    [[ "${ans,,}" != "j" ]] && die "Abgebrochen — bitte sudo ./install.sh /dev/sdX ausführen."
fi

# ── Apply ─────────────────────────────────────────────────────────────────────
for entry in "${to_copy[@]}"; do
    IFS='|' read -r src_rel dst_rel <<<"$entry"
    src="${PROJECT_DIR}/${src_rel}"
    dst="${USB_MNT}/${dst_rel}"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    log "Kopiert: ${dst_rel}"
done

for f in "${to_remove[@]}"; do
    rm -f "${USB_MNT}/${f}"
    log "Entfernt: ${f}"
done

sync
log "USB-Stick synchronisiert ✓"
