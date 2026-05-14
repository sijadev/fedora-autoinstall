#!/usr/bin/env bash
# fedora-iso-build.sh — Erzeugt ein bootbares Custom-Fedora-ISO
#
# Bettet Kickstart + Scripts in die Fedora Everything Netinstall-ISO ein und
# (optional) tauscht den Kernel gegen den Bazzite-Kernel aus, damit
# NVIDIA Blackwell (RTX 50/9070) booten kann.
#
# Vorteile gegenüber Ventoy:
#   - Self-contained: dd if=iso of=/dev/sdX und fertig (kein Ventoy nötig)
#   - Mit --swap-kernel: Blackwell-GPUs booten ohne iGPU-Workaround
#
# Usage:
#   sudo ./fedora-iso-build.sh [OPTIONS]
#
# Options:
#   --profile NAME       full | theme-bash | headless-vllm  (default: full)
#   --iso PATH           Source-ISO  (default: iso/Fedora-Everything-netinst-*.iso)
#   --output PATH        Ziel-ISO   (default: iso/Fedora-Auto-<profile>.iso)
#   --swap-kernel        Kernel+initrd durch Bazzite-Kernel ersetzen (für Blackwell)
#   --kernel-rpm PATH    Bazzite Kernel-RPM (Default: download von COPR)
#   --write DEV          Direkt auf /dev/sdX schreiben (mit dd)
#   --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Farben ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; CYAN=''; BOLD=''; RESET=''
fi

log()  { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
step() { echo -e "\n${CYAN}${BOLD}══ $* ══${RESET}"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
PROFILE="full"
SRC_ISO=""
OUT_ISO=""
SWAP_KERNEL=0
KERNEL_RPM=""
WRITE_DEV=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)      PROFILE="$2";     shift 2 ;;
        --iso)          SRC_ISO="$2";     shift 2 ;;
        --output)       OUT_ISO="$2";     shift 2 ;;
        --swap-kernel)  SWAP_KERNEL=1;    shift   ;;
        --kernel-rpm)   KERNEL_RPM="$2";  shift 2 ;;
        --write)        WRITE_DEV="$2";   shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//' ; exit 0 ;;
        *) die "Unbekannte Option: $1" ;;
    esac
done

[[ "$EUID" -ne 0 ]] && die "Bitte als root ausführen: sudo $0"

# ── Voraussetzungen prüfen ────────────────────────────────────────────────────
step "Voraussetzungen"

for cmd in mkksiso xorriso cpio; do
    if ! command -v "$cmd" &>/dev/null; then
        die "'$cmd' fehlt. Installiere: dnf install lorax xorriso cpio"
    fi
done
log "lorax + xorriso + cpio vorhanden."

# Source-ISO finden
if [[ -z "$SRC_ISO" ]]; then
    SRC_ISO=$(ls -t iso/Fedora-Everything-netinst-*.iso 2>/dev/null | head -1)
    [[ -z "$SRC_ISO" ]] && die "Keine Source-ISO gefunden. Bitte mit --iso angeben oder ISO nach iso/ legen."
fi
[[ ! -f "$SRC_ISO" ]] && die "Source-ISO nicht gefunden: $SRC_ISO"
log "Source-ISO: $SRC_ISO"

# Kickstart-Datei wählen
case "$PROFILE" in
    full)           KS_FILE="kickstart/fedora-full.ks" ;;
    theme-bash)     KS_FILE="kickstart/fedora-theme-bash.ks" ;;
    headless-vllm)  KS_FILE="kickstart/fedora-headless-vllm.ks" ;;
    *) die "Unbekanntes Profil: $PROFILE  (erlaubt: full | theme-bash | headless-vllm)" ;;
esac
[[ ! -f "$KS_FILE" ]] && die "Kickstart fehlt: $KS_FILE"
log "Profil: $PROFILE  →  $KS_FILE"

# Output-ISO
[[ -z "$OUT_ISO" ]] && OUT_ISO="iso/Fedora-Auto-${PROFILE}.iso"
log "Ziel-ISO:   $OUT_ISO"

# ── Kernel-Swap vorbereiten (optional) ────────────────────────────────────────
WORK_DIR=""
cleanup() { [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"; }
trap cleanup EXIT

if [[ "$SWAP_KERNEL" == "1" ]]; then
    step "Kernel-Swap: Bazzite-Kernel besorgen"

    WORK_DIR=$(mktemp -d -t fedora-iso-build-XXXXXX)
    KERNEL_EXTRACT="${WORK_DIR}/kernel-rpm"
    mkdir -p "$KERNEL_EXTRACT"

    if [[ -z "$KERNEL_RPM" ]]; then
        log "Lade aktuellsten kernel-bazzite RPM aus COPR..."
        COPR_REPO="https://copr.fedorainfracloud.org/coprs/bazzite-org/kernel-bazzite/repo/fedora-43/bazzite-org-kernel-bazzite-fedora-43.repo"
        cat > "${WORK_DIR}/copr.repo" <<EOF
[bazzite-org-kernel-bazzite]
name=Bazzite Kernel
baseurl=https://download.copr.fedorainfracloud.org/results/bazzite-org/kernel-bazzite/fedora-43-x86_64/
gpgcheck=0
enabled=1
EOF
        dnf --repofrompath="bazzite,${WORK_DIR}/copr.repo" \
            --disablerepo='*' --enablerepo=bazzite \
            download --destdir="$KERNEL_EXTRACT" kernel-bazzite-core kernel-bazzite-modules \
            || die "Kernel-RPM-Download fehlgeschlagen. Versuche --kernel-rpm <pfad>"
    else
        cp "$KERNEL_RPM" "$KERNEL_EXTRACT/"
    fi

    log "Extrahiere RPMs..."
    pushd "$KERNEL_EXTRACT" >/dev/null
    for rpm in *.rpm; do
        rpm2cpio "$rpm" | cpio -idmu --quiet
    done
    popd >/dev/null

    NEW_VMLINUZ=$(find "$KERNEL_EXTRACT/lib/modules" -name vmlinuz | head -1)
    [[ -z "$NEW_VMLINUZ" ]] && die "vmlinuz nicht in Kernel-RPM gefunden."
    NEW_KVER=$(basename "$(dirname "$NEW_VMLINUZ")")
    log "Bazzite-Kernel: $NEW_KVER"

    # Anaconda-initrd modifizieren: kernel-Module für neuen Kernel einbauen
    step "Anaconda-initrd: Module für Bazzite-Kernel einbetten"
    ISO_MNT="${WORK_DIR}/iso-mnt"
    mkdir -p "$ISO_MNT"
    mount -o loop,ro "$SRC_ISO" "$ISO_MNT"

    INITRD_WORK="${WORK_DIR}/initrd"
    mkdir -p "$INITRD_WORK"
    pushd "$INITRD_WORK" >/dev/null
    log "Entpacke initrd.img..."
    zstdcat "${ISO_MNT}/images/pxeboot/initrd.img" 2>/dev/null | cpio -idm --quiet \
        || xzcat "${ISO_MNT}/images/pxeboot/initrd.img" 2>/dev/null | cpio -idm --quiet \
        || gzip -dc "${ISO_MNT}/images/pxeboot/initrd.img" | cpio -idm --quiet

    OLD_KVER=$(ls usr/lib/modules/ 2>/dev/null | head -1)
    log "Original-Kernel im initrd: $OLD_KVER  →  Ersetze durch $NEW_KVER"

    # Module für neuen Kernel kopieren
    rm -rf "usr/lib/modules/${OLD_KVER}"
    mkdir -p "usr/lib/modules/${NEW_KVER}"
    cp -a "${KERNEL_EXTRACT}/lib/modules/${NEW_KVER}/." "usr/lib/modules/${NEW_KVER}/"

    log "Repacke initrd.img (zstd)..."
    find . | cpio -o -H newc --quiet | zstd -19 -T0 -q > "${WORK_DIR}/initrd.img"
    popd >/dev/null

    umount "$ISO_MNT"

    log "Kernel-Swap vorbereitet: vmlinuz + initrd.img bereit"
fi

# ── Kickstart vorverarbeiten ──────────────────────────────────────────────────
step "Kickstart + Scripts zusammenstellen"

STAGE_DIR=$(mktemp -d -t fedora-iso-stage-XXXXXX)
trap 'rm -rf "$STAGE_DIR"; cleanup' EXIT

mkdir -p "$STAGE_DIR/scripts" "$STAGE_DIR/kickstart" "$STAGE_DIR/systemd"
cp -r scripts/. "$STAGE_DIR/scripts/"
cp kickstart/common-post.inc "$STAGE_DIR/kickstart/"
# Alle .ks für späteren Provisioner-Zugriff einbetten
cp kickstart/*.ks "$STAGE_DIR/kickstart/" 2>/dev/null || true
# fedora-provision.sh in ISO-Root für %post --nochroot
cp fedora-provision.sh "$STAGE_DIR/fedora-provision.sh"
chmod 0750 "$STAGE_DIR/fedora-provision.sh"
[[ -d systemd ]] && cp -r systemd/. "$STAGE_DIR/systemd/" || true

# Kickstart-Path im ISO: /ks.cfg (oben in ISO-Root)
cp "$KS_FILE" "$STAGE_DIR/ks.cfg"
log "Kickstart als /ks.cfg eingebettet"

# ── ISO bauen mit mkksiso ─────────────────────────────────────────────────────
step "ISO bauen"

# Kernel-Args für Blackwell defensiv (auch ohne Swap nützlich)
BLACKWELL_ARGS="nomodeset rd.driver.blacklist=nouveau modprobe.blacklist=nouveau nvidia-drm.modeset=0 video=efifb:off video=simpledrm:off"

# inst.ks=cdrom liest /ks.cfg vom ISO selbst
MKKS_ARGS=(
    --ks "$STAGE_DIR/ks.cfg"
    -c "inst.ks=cdrom:/ks.cfg ${BLACKWELL_ARGS}"
    --add "$STAGE_DIR/scripts"
    --add "$STAGE_DIR/kickstart"
    --add "$STAGE_DIR/fedora-provision.sh"
)
[[ -d "$STAGE_DIR/systemd" ]] && MKKS_ARGS+=(--add "$STAGE_DIR/systemd")

log "Erzeuge: $OUT_ISO"
mkdir -p "$(dirname "$OUT_ISO")"
mkksiso "${MKKS_ARGS[@]}" "$SRC_ISO" "$OUT_ISO" \
    || die "mkksiso fehlgeschlagen."

# ── Kernel-Swap: vmlinuz/initrd im fertigen ISO ersetzen ─────────────────────
if [[ "$SWAP_KERNEL" == "1" ]]; then
    step "Kernel-Swap im fertigen ISO durchführen"

    # ISO neu öffnen und vmlinuz + initrd austauschen (xorriso in-place)
    xorriso -boot_image any keep \
        -dev "$OUT_ISO" \
        -update "$NEW_VMLINUZ"           /images/pxeboot/vmlinuz \
        -update "${WORK_DIR}/initrd.img" /images/pxeboot/initrd.img \
        || die "xorriso vmlinuz/initrd Update fehlgeschlagen."

    log "Kernel ausgetauscht: $NEW_KVER"
fi

# ── Optional: direkt auf USB schreiben ────────────────────────────────────────
ISO_SIZE=$(stat -c '%s' "$OUT_ISO")
ISO_MB=$(( ISO_SIZE / 1024 / 1024 ))
log "ISO fertig: $OUT_ISO  (${ISO_MB} MB)"

if [[ -n "$WRITE_DEV" ]]; then
    [[ ! -b "$WRITE_DEV" ]] && die "Kein Blockgerät: $WRITE_DEV"
    step "ISO auf $WRITE_DEV schreiben"
    echo -e "${RED}${BOLD}WARNUNG: $WRITE_DEV wird komplett überschrieben!${RESET}"
    read -r -p "Wirklich fortfahren? [j/N] " ans
    [[ "${ans,,}" != "j" ]] && die "Abgebrochen."

    umount "${WRITE_DEV}"* 2>/dev/null || true
    dd if="$OUT_ISO" of="$WRITE_DEV" bs=4M status=progress conv=fsync
    sync
    log "Geschrieben auf $WRITE_DEV"
fi

step "Fertig"
echo ""
echo -e "  ${BOLD}Nächste Schritte:${RESET}"
if [[ -z "$WRITE_DEV" ]]; then
    echo -e "    sudo dd if=${OUT_ISO} of=/dev/sdX bs=4M status=progress conv=fsync"
fi
echo -e "    Booten → Anaconda startet automatisch mit ${PROFILE} Kickstart"
if [[ "$SWAP_KERNEL" == "1" ]]; then
    echo -e "    ${GREEN}Bazzite-Kernel aktiv${RESET} — Blackwell sollte direkt booten"
fi
