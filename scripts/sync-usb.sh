#!/usr/bin/env bash
# sync-usb.sh — prüft USB-Drift und deployed den vollständigen Installer-Stand.
#
# WICHTIG: Der vollständige Installer-Stand liegt auf dem USB-Stick.
# Standard/--force führen ein vollständiges Deploy über install.sh aus,
# damit Kickstarts, Scripts, GRUB und weitere Boot-Artefakte konsistent sind.
#
# Usage:
#   scripts/sync-usb.sh                 # interaktiv, vollständiges Deploy via install.sh
#   scripts/sync-usb.sh --check         # nur Drift prüfen (Exit 1 bei Drift)
#   scripts/sync-usb.sh --check-deploy  # Drift prüfen und bei Bedarf deployen
#   scripts/sync-usb.sh --force         # vollständiges Deploy ohne Nachfrage
#   scripts/sync-usb.sh --files-only    # nur Dateien kopieren (Legacy-Modus)

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_OS="$(uname -s)"
MODE="interactive"
case "${1:-}" in
    --check) MODE="check-only" ;;
    --check-deploy) MODE="check-deploy" ;;
    --force) MODE="force" ;;
    --files-only) MODE="files-only" ;;
    "")      ;;
    *) echo "Usage: $0 [--check|--check-deploy|--force|--files-only]" >&2; exit 2 ;;
esac

if [[ -t 1 ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi

log()  { echo -e "${GREEN}[sync-usb]${RESET} $*"; }
warn() { echo -e "${YELLOW}[sync-usb]${RESET} $*" >&2; }
die()  { echo -e "${RED}[sync-usb] $*${RESET}" >&2; exit 1; }

base_device_from_partition() {
    local part="$1"
    if [[ "$HOST_OS" == "Darwin" ]]; then
        # /dev/disk4s1 -> /dev/disk4
        echo "$part" | sed -E 's/s[0-9]+$//'
        return
    fi

    case "$part" in
        /dev/nvme*n*p[0-9]*|/dev/mmcblk*p[0-9]*) echo "${part%p[0-9]*}" ;;
        /dev/*[0-9]) echo "${part%[0-9]*}" ;;
        *) echo "$part" ;;
    esac
}

run_full_deploy() {
    if [[ -n "${FEDORA_SYNC_DEPLOY_COMMAND:-}" ]]; then
        log "Deploy via FEDORA_SYNC_DEPLOY_COMMAND"
        eval "${FEDORA_SYNC_DEPLOY_COMMAND}"
        return
    fi

    local install_sh="${PROJECT_DIR}/install.sh"
    [[ -x "$install_sh" ]] || die "install.sh fehlt oder ist nicht ausführbar: ${install_sh}"

    local usb_part=""
    if [[ "$HOST_OS" == "Darwin" ]]; then
        usb_part="$(diskutil info "$USB_MNT" 2>/dev/null | awk -F': *' '/Device Node/{print $2; exit}')"
    else
        usb_part="$(findmnt -n -o SOURCE "$USB_MNT" 2>/dev/null || true)"
    fi
    [[ -n "$usb_part" ]] || die "Konnte USB-Partition für ${USB_MNT} nicht ermitteln."

    local usb_base
    usb_base="$(base_device_from_partition "$usb_part")"
    [[ -b "$usb_base" ]] || die "Konnte USB-Basisgerät nicht auflösen: ${usb_base} (von ${usb_part})"

    log "Vollständiges Deploy auf ${usb_base} via install.sh"
    if [[ "$EUID" -eq 0 ]]; then
        "${install_sh}" "$usb_base"
    else
        command -v sudo >/dev/null 2>&1 || die "sudo fehlt; bitte als root ausführen."
        sudo "${install_sh}" "$usb_base"
    fi
}

# ── FEDORA-USB-Stick mounten ──────────────────────────────────────────────────
self_mounted=0
USB_DEV=""

if [[ "$HOST_OS" == "Darwin" ]]; then
    USB_MNT="/Volumes/FEDORA-USB"
    if ! mount | grep -q "$USB_MNT"; then
        USB_DEV=$(diskutil list | awk '/FEDORA-USB/{print $NF}' | head -1)
        [[ -n "$USB_DEV" ]] || die "FEDORA-USB-Stick nicht gefunden. Stick einstecken oder mit build-usb.sh einrichten."
        diskutil mount "/dev/${USB_DEV}" &>/dev/null || die "Kann /dev/${USB_DEV} nicht mounten."
        self_mounted=1
    fi
    mount | grep -q "$USB_MNT" || die "FEDORA-USB nicht erreichbar: ${USB_MNT}"
else
    USB_MNT="/run/media/$(whoami)/FEDORA-USB"
    if ! findmnt "$USB_MNT" &>/dev/null; then
        USB_DEV=$(lsblk -o NAME,LABEL -rn | awk '$2=="FEDORA-USB"{print "/dev/"$1}' | head -1)
        [[ -n "$USB_DEV" ]] || die "FEDORA-USB-Stick nicht gefunden. Stick einstecken oder mit build-usb.sh einrichten."
        udisksctl mount -b "$USB_DEV" &>/dev/null || die "Kann ${USB_DEV} nicht mounten."
        self_mounted=1
    fi
    findmnt "$USB_MNT" &>/dev/null || die "FEDORA-USB nicht erreichbar: ${USB_MNT}"
fi

cleanup() {
    local rc=$?
    if (( self_mounted )); then
        sync
        if [[ "$HOST_OS" == "Darwin" ]]; then
            diskutil unmount "$USB_MNT" &>/dev/null || true
        else
            udisksctl unmount -b "$(findmnt -n -o SOURCE "$USB_MNT")" &>/dev/null || true
        fi
    fi
    return "$rc"
}
trap cleanup EXIT

# Kernel-Freshness prüfen
if [[ ! -f "${USB_MNT}/boot/vmlinuz" ]]; then
    warn "Kein Bazzite-Kernel auf USB gefunden!"
    warn "Einmalig ausführen: sudo scripts/build-usb.sh /dev/sdX"
fi

run_preflight_tests() {
    if [[ "${FEDORA_SYNC_SKIP_PREFLIGHT:-0}" == "1" ]]; then
        return 0
    fi

    local tests_runner="${PROJECT_DIR}/tests/run-all.sh"
    [[ -f "$tests_runner" ]] || die "Test-Runner nicht gefunden: ${tests_runner}"

    log "Führe Vorab-Tests aus (tests/run-all.sh --full)..."
    bash "$tests_runner" --full || die "Vorab-Tests fehlgeschlagen — Sync abgebrochen."
    log "Vorab-Tests erfolgreich."
}

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
drift_extra=()

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
if [[ ${#to_copy[@]} -eq 0 && ${#to_remove[@]} -eq 0 && ${#drift_extra[@]} -eq 0 ]]; then
    if [[ "$MODE" == "check-only" || "$MODE" == "check-deploy" || "$MODE" == "files-only" ]]; then
        log "USB-Stick ist aktuell ✓"
        exit 0
    fi
    log "Dateidrift: keine. Starte dennoch vollständiges Deploy."
fi

echo -e "\n${BOLD}USB-Stick Drift:${RESET}"
if [[ ${#to_copy[@]} -gt 0 ]]; then
    for entry in "${to_copy[@]}"; do
        IFS='|' read -r src_rel dst_rel <<<"$entry"
        dst="${USB_MNT}/${dst_rel}"
        if [[ -f "$dst" ]]; then
            echo -e "  ${YELLOW}~${RESET} ${src_rel} → ${dst_rel}"
        else
            echo -e "  ${GREEN}+${RESET} ${src_rel} → ${dst_rel}  (neu)"
        fi
    done
fi
if [[ ${#to_remove[@]} -gt 0 ]]; then
    for f in "${to_remove[@]}"; do
        echo -e "  ${RED}-${RESET} ${f}  (veraltet, wird entfernt)"
    done
fi
if [[ ${#drift_extra[@]} -gt 0 ]]; then
    for d in "${drift_extra[@]}"; do
        echo -e "  ${YELLOW}!${RESET} ${d}"
    done
fi
echo ""

if [[ "$MODE" == "check-only" ]]; then
    exit 1
fi

if [[ "$MODE" == "check-deploy" ]]; then
    log "Drift erkannt — starte vollständiges Deploy."
    run_full_deploy
    exit 0
fi

if [[ "$MODE" == "interactive" ]]; then
    echo -e "${YELLOW}Hinweis:${RESET} Es wird ein vollständiges Deploy via install.sh ausgeführt."
    read -r -t 20 -p "Jetzt vollständiges Deploy starten? [j/N] " ans 2>/dev/tty || ans="N"
    [[ "$(echo "$ans" | tr '[:upper:]' '[:lower:]')" != "j" ]] && die "Abgebrochen."
fi

if [[ "$MODE" != "files-only" ]]; then
    run_full_deploy
    exit 0
fi

run_preflight_tests

# ── Apply ─────────────────────────────────────────────────────────────────────
if [[ ${#to_copy[@]} -gt 0 ]]; then
    for entry in "${to_copy[@]}"; do
        IFS='|' read -r src_rel dst_rel <<<"$entry"
        src="${PROJECT_DIR}/${src_rel}"
        dst="${USB_MNT}/${dst_rel}"
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
        log "Kopiert: ${dst_rel}"
    done
fi

if [[ ${#to_remove[@]} -gt 0 ]]; then
    for f in "${to_remove[@]}"; do
        rm -f "${USB_MNT}/${f}"
        log "Entfernt: ${f}"
    done
fi

sync
log "USB-Stick synchronisiert ✓"
