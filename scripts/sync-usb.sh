#!/usr/bin/env bash
# sync-usb.sh — synchronisiert das Repo auf den Ventoy USB-Stick.
# - Kopiert kickstart/, scripts/, systemd/, ventoy/ und fedora-provision.sh
# - Entfernt veraltete Dateien (alte Nobara-Service, alte statische vLLM-Quadlets)
# - Wird von vm-test.sh aufgerufen, kann aber auch standalone laufen
#
# Usage:
#   scripts/sync-usb.sh                 # interaktiv, mit Diff-Anzeige
#   scripts/sync-usb.sh --check         # nur prüfen (Exit 1 bei Drift), kein Schreiben
#   scripts/sync-usb.sh --force         # ohne Rückfrage, ohne Diff

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

# ── Ventoy-Stick mounten ─────────────────────────────────────────────────────
VENTOY_MNT="/run/media/$(whoami)/Ventoy"
self_mounted=0

if ! findmnt "$VENTOY_MNT" &>/dev/null; then
    dev=$(lsblk -o NAME,LABEL -rn | awk '$2=="Ventoy"{print "/dev/"$1}' | head -1)
    [[ -n "$dev" ]] || die "Ventoy USB-Stick nicht gefunden."
    udisksctl mount -b "$dev" &>/dev/null || die "Kann ${dev} nicht mounten."
    self_mounted=1
fi
findmnt "$VENTOY_MNT" &>/dev/null || die "Ventoy nicht erreichbar: ${VENTOY_MNT}"

cleanup() {
    if (( self_mounted )); then
        sync
        udisksctl unmount -b "$(findmnt -n -o SOURCE "$VENTOY_MNT")" &>/dev/null || true
    fi
}
trap cleanup EXIT

# ── ISO-Name für Template-Substitution ───────────────────────────────────────
# Netinst hat Vorrang (Kickstart-Injection via ventoy.json); Custom-ISOs (Fedora-Auto-*)
# haben den Kickstart bereits eingebettet und brauchen keine Substitution.
ISO_NAME=$(ls "${VENTOY_MNT}/"Fedora-Everything-netinst-*.iso 2>/dev/null | head -1 | xargs -r basename || true)
[[ -z "$ISO_NAME" ]] && ISO_NAME=$(ls "${VENTOY_MNT}/"Fedora-*.iso 2>/dev/null | grep -v 'Fedora-Auto-' | head -1 | xargs -r basename || true)
[[ -n "$ISO_NAME" ]] || warn "Keine Fedora-Netinst-ISO auf dem Stick gefunden — ventoy-Templates werden ohne Substitution kopiert."

# ── Plan: SRC → DST (relativer Pfad auf USB) ──────────────────────────────────
# Format: "src_rel|dst_rel|mode"  (mode: copy|template)
PLAN=(
    "fedora-provision.sh|fedora-provision.sh|copy"
    "kickstart/common-post.inc|kickstart/common-post.inc|copy"
    "kickstart/fedora-vm.ks|kickstart/fedora-vm.ks|copy"
    "kickstart/fedora-full.ks|kickstart/fedora-full.ks|copy"
    "kickstart/fedora-headless-vllm.ks|kickstart/fedora-headless-vllm.ks|copy"
    "kickstart/fedora-theme-bash.ks|kickstart/fedora-theme-bash.ks|copy"
    "scripts/first-boot.sh|scripts/first-boot.sh|copy"
    "scripts/first-login.sh|scripts/first-login.sh|copy"
    "scripts/vllm-router.py|scripts/vllm-router.py|copy"
    "scripts/welcome-dialog.sh|scripts/welcome-dialog.sh|copy"
    "scripts/fedora-provision.desktop|scripts/fedora-provision.desktop|copy"
    "systemd/fedora-first-boot.service|systemd/fedora-first-boot.service|copy"
    "systemd/vllm@.container|systemd/vllm@.container|copy"
    "systemd/vllm-router.service|systemd/vllm-router.service|copy"
    "ventoy/ventoy_grub.cfg.tpl|ventoy/ventoy_grub.cfg|template"
    "ventoy/ventoy.json.tpl|ventoy/ventoy.json|template"
)

# ── Obsolete Dateien (werden entfernt falls vorhanden) ────────────────────────
OBSOLETE=(
    "systemd/nobara-first-boot.service"
    "systemd/vllm-audio.container"
    "systemd/vllm-agent.container"
    "systemd/vllm-audio.service"
    "systemd/vllm-agent.service"
    "scripts/bitwig-pipeline.sh"
)

# ── Custom-ISOs (Fedora-Auto-<profile>.iso) auf Stick spiegeln ────────────────
# -vm wird ausgenommen (internes vm-test Artefakt).
ISO_PROFILES=(full theme-bash headless-vllm)

# ── Diff-Phase ────────────────────────────────────────────────────────────────
to_copy=()
to_remove=()

render_template() {
    local src="$1" dst="$2"
    if [[ -n "$ISO_NAME" ]]; then
        sed "s/FEDORA_ISO_FILENAME/${ISO_NAME}/g" "$src"
    else
        cat "$src"
    fi
}

for entry in "${PLAN[@]}"; do
    IFS='|' read -r src_rel dst_rel mode <<<"$entry"
    src="${PROJECT_DIR}/${src_rel}"
    dst="${VENTOY_MNT}/${dst_rel}"
    [[ -f "$src" ]] || { warn "Quelle fehlt: ${src_rel} — übersprungen"; continue; }

    if [[ "$mode" == "template" ]]; then
        if [[ ! -f "$dst" ]] || ! diff -q <(render_template "$src" "$dst") "$dst" &>/dev/null; then
            to_copy+=("$entry")
        fi
    else
        if [[ ! -f "$dst" ]] || ! diff -q "$src" "$dst" &>/dev/null; then
            to_copy+=("$entry")
        fi
    fi
done

for f in "${OBSOLETE[@]}"; do
    [[ -e "${VENTOY_MNT}/${f}" ]] && to_remove+=("$f")
done

# ── ISO-Diff (Größe+mtime statt cmp wegen >1 GB) ──────────────────────────────
to_copy_iso=()
for prof in "${ISO_PROFILES[@]}"; do
    src="${PROJECT_DIR}/iso/Fedora-Auto-${prof}.iso"
    dst="${VENTOY_MNT}/Fedora-Auto-${prof}.iso"
    [[ -f "$src" ]] || continue
    if [[ ! -f "$dst" ]] \
       || [[ "$(stat -c '%s' "$src")" != "$(stat -c '%s' "$dst")" ]] \
       || [[ "$src" -nt "$dst" ]]; then
        to_copy_iso+=("$prof")
    fi
done

# ── Report ────────────────────────────────────────────────────────────────────
if [[ ${#to_copy[@]} -eq 0 && ${#to_remove[@]} -eq 0 && ${#to_copy_iso[@]} -eq 0 ]]; then
    log "USB-Stick ist aktuell ✓"
    exit 0
fi

echo -e "\n${BOLD}USB-Stick Drift:${RESET}"
for entry in "${to_copy[@]}"; do
    IFS='|' read -r src_rel dst_rel _ <<<"$entry"
    dst="${VENTOY_MNT}/${dst_rel}"
    if [[ -f "$dst" ]]; then
        echo -e "  ${YELLOW}~${RESET} ${src_rel} → ${dst_rel}"
    else
        echo -e "  ${GREEN}+${RESET} ${src_rel} → ${dst_rel}  (neu)"
    fi
done
for prof in "${to_copy_iso[@]}"; do
    dst="${VENTOY_MNT}/Fedora-Auto-${prof}.iso"
    src="${PROJECT_DIR}/iso/Fedora-Auto-${prof}.iso"
    size_mb=$(( $(stat -c '%s' "$src") / 1024 / 1024 ))
    if [[ -f "$dst" ]]; then
        echo -e "  ${YELLOW}~${RESET} iso/Fedora-Auto-${prof}.iso  (${size_mb} MB, aktualisiert)"
    else
        echo -e "  ${GREEN}+${RESET} iso/Fedora-Auto-${prof}.iso  (${size_mb} MB, neu)"
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
    read -r -t 15 -p "Jetzt synchronisieren? [J/n] " ans 2>/dev/tty || ans="J"
    [[ "${ans,,}" == "n" ]] && die "Sync abgebrochen."
fi

# ── Apply ─────────────────────────────────────────────────────────────────────
for entry in "${to_copy[@]}"; do
    IFS='|' read -r src_rel dst_rel mode <<<"$entry"
    src="${PROJECT_DIR}/${src_rel}"
    dst="${VENTOY_MNT}/${dst_rel}"
    mkdir -p "$(dirname "$dst")"
    if [[ "$mode" == "template" ]]; then
        render_template "$src" "$dst" > "$dst"
        log "Template kopiert (ISO=${ISO_NAME:-<keine>}): ${dst_rel}"
    else
        cp "$src" "$dst"
        log "Kopiert: ${dst_rel}"
    fi
done

for f in "${to_remove[@]}"; do
    rm -f "${VENTOY_MNT}/${f}"
    log "Entfernt: ${f}"
done

for prof in "${to_copy_iso[@]}"; do
    src="${PROJECT_DIR}/iso/Fedora-Auto-${prof}.iso"
    dst="${VENTOY_MNT}/Fedora-Auto-${prof}.iso"
    size_mb=$(( $(stat -c '%s' "$src") / 1024 / 1024 ))
    log "Kopiere ISO (${size_mb} MB): Fedora-Auto-${prof}.iso ..."
    cp "$src" "$dst"
    log "ISO kopiert: Fedora-Auto-${prof}.iso"
done

sync
log "USB-Stick synchronisiert ✓"
