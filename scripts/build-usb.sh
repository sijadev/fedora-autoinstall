#!/usr/bin/env bash
# build-usb.sh — Erstellt einen bootbaren FEDORA-USB-Stick mit GRUB2 + Kernel.
#
# Ersetzt Ventoy. Einmaliger Aufbau; danach sync-usb.sh für Updates verwenden.
#
# Partitionsschema:
#   Part 1: 256 MB  FAT32  LABEL=EFI         (EFI System Partition)
#   Part 2: Rest    FAT32  LABEL=FEDORA-USB  (Kickstart, Scripts, Kernel)
#
# Kernel: Fedora 43 Mirror (kernel + kernel-modules + kernel-devel)
#   RPMs werden in iso/kernel-cache/ gecacht.
#   Später: Bazzite-Kernel für Blackwell-Support (RTX 9070/50xx) austauschbar.
#
# Stage2: Fedora Mirror (Netzwerk) — kein ISO auf USB nötig.
#
# Usage:
#   sudo scripts/build-usb.sh /dev/sdX
#   sudo scripts/build-usb.sh /dev/sdX --kernel-rpm /path/to/kernel.rpm

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOST_OS="$(uname -s)"

find_tool() {
    local tool
    for tool in "$@"; do
        if command -v "$tool" &>/dev/null; then
            echo "$tool"
            return 0
        fi
    done
    return 1
}

# ── Args ──────────────────────────────────────────────────────────────────────
USB_DEV="${1:-}"
KERNEL_RPM="${2:-}"
if [[ "$KERNEL_RPM" == "--kernel-rpm" ]]; then
    KERNEL_RPM="${3:-}"
fi

if [[ -z "$USB_DEV" ]]; then
    echo "Usage: sudo $0 /dev/sdX [--kernel-rpm /path/to/kernel-bazzite.rpm]" >&2
    exit 1
fi

[[ "$EUID" -ne 0 ]] && { echo "Bitte als root ausführen: sudo $0 $*" >&2; exit 1; }
[[ -b "$USB_DEV" ]] || { echo "Kein Blockgerät: $USB_DEV" >&2; exit 1; }

if [[ -t 1 ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; RESET=""
fi
log()  { echo -e "${GREEN}[build-usb]${RESET} $*"; }
warn() { echo -e "${YELLOW}[build-usb]${RESET} $*" >&2; }
die()  { echo -e "${RED}[build-usb] $*${RESET}" >&2; exit 1; }
step() { echo -e "\n${CYAN}${BOLD}══ $* ══${RESET}"; }
GRUB_INSTALL_CMD=""

ensure_unmounted_part() {
    local part="$1"
    local tries=0

    while findmnt -rn -S "$part" >/dev/null 2>&1; do
        local mnt
        mnt=$(findmnt -rn -o TARGET -S "$part" 2>/dev/null | head -1)
        warn "$part ist gemountet (${mnt:-unbekannt}) - versuche unmount..."

        umount "$part" 2>/dev/null || true
        if command -v udisksctl &>/dev/null; then
            udisksctl unmount -b "$part" >/dev/null 2>&1 || true
        fi
        findmnt -rn -S "$part" >/dev/null 2>&1 && umount -l "$part" 2>/dev/null || true

        command -v udevadm &>/dev/null && udevadm settle || true
        sleep 0.3

        tries=$((tries + 1))
        (( tries >= 8 )) && break
    done

    if findmnt -rn -S "$part" >/dev/null 2>&1; then
        local mnt
        mnt=$(findmnt -rn -o TARGET -S "$part" 2>/dev/null | head -1)
        die "$part ist noch gemountet (${mnt:-unbekannt}). Bitte Dateimanager/Finder schließen und erneut ausfuhren."
    fi
}

build_on_macos() {
    local usb_whole root_whole size_bytes USB_SIZE_GB
    local src_iso KVER ISO_DEV=""
    local parts

    usb_whole="${USB_DEV%%s[0-9]*}"
    [[ "$usb_whole" =~ ^/dev/disk[0-9]+$ ]] || die "Auf macOS bitte das Whole-Disk-Device angeben (z.B. /dev/disk4)."

    step "Sicherheitscheck: $usb_whole"
    size_bytes=$(diskutil info -plist "$usb_whole" 2>/dev/null | plutil -extract TotalSize raw - 2>/dev/null || true)
    [[ -n "$size_bytes" ]] || die "Kann Datentragergroße nicht ermitteln: $usb_whole"
    USB_SIZE_GB=$(( size_bytes / 1024 / 1024 / 1024 ))
    log "Gerät: $usb_whole  (${USB_SIZE_GB} GB)"
    (( USB_SIZE_GB >= 4 ))  || die "USB-Stick zu klein: ${USB_SIZE_GB} GB (min 4 GB)"
    (( USB_SIZE_GB <= 512 )) || die "Gerät mit ${USB_SIZE_GB} GB wirkt suspekt groß — abgebrochen."

    root_whole=$(diskutil info -plist / 2>/dev/null | plutil -extract ParentWholeDisk raw - 2>/dev/null || true)
    if [[ -n "$root_whole" && "$usb_whole" == "/dev/${root_whole}" ]]; then
        die "Verweigert: $usb_whole ist das Root-Gerät."
    fi

    echo ""
    echo -e "${RED}${BOLD}WARNUNG: $usb_whole wird komplett überschrieben!${RESET}"
    echo -e "  Gerät:  $usb_whole  (${USB_SIZE_GB} GB)"
    echo -e "  Inhalt: wird gelöscht und neu partitioniert"
    echo ""
    read -r -p "Wirklich fortfahren? [j/N] " ans
    [[ "${ans,,}" == "j" ]] || die "Abgebrochen."

    WORK_DIR=$(mktemp -d -t build-usb-XXXXXX)
    EFI_MNT="${WORK_DIR}/efi"
    DATA_MNT="${WORK_DIR}/data"
    ISO_MNT="${WORK_DIR}/iso-mnt"
    mkdir -p "$EFI_MNT" "$DATA_MNT" "$ISO_MNT"

    EFI_PART=""
    DATA_PART=""
    cleanup() {
        [[ -n "$ISO_DEV" ]] && hdiutil detach "$ISO_DEV" >/dev/null 2>&1 || true
        [[ -n "$DATA_PART" ]] && diskutil unmount "$DATA_PART" >/dev/null 2>&1 || true
        [[ -n "$EFI_PART" ]] && diskutil unmount "$EFI_PART" >/dev/null 2>&1 || true
        rm -rf "$WORK_DIR"
    }
    trap cleanup EXIT

    step "Kernel + initrd aus Fedora-netinstall-ISO extrahieren"
    src_iso=$(ls -t "${PROJECT_DIR}"/iso/Fedora-Everything-netinst-*.iso 2>/dev/null | head -1 || true)
    [[ -z "$src_iso" ]] && die "Keine Fedora-Netinst-ISO unter iso/ — z.B. Fedora-Everything-netinst-x86_64-43-1.6.iso"
    log "Source-ISO: $src_iso"

    ISO_DEV=$(hdiutil attach -readonly -nobrowse -mountpoint "$ISO_MNT" "$src_iso" | awk 'NR==1{print $1}')
    [[ -n "$ISO_DEV" ]] || die "ISO konnte nicht gemountet werden: $src_iso"

    [[ -f "${ISO_MNT}/images/pxeboot/vmlinuz" ]]    || die "vmlinuz nicht in ISO gefunden."
    [[ -f "${ISO_MNT}/images/pxeboot/initrd.img" ]] || die "initrd.img nicht in ISO gefunden."

    cp "${ISO_MNT}/images/pxeboot/vmlinuz"    "${WORK_DIR}/vmlinuz"
    cp "${ISO_MNT}/images/pxeboot/initrd.img" "${WORK_DIR}/initrd.img"
    hdiutil detach "$ISO_DEV" >/dev/null || true
    ISO_DEV=""

    KVER=$(file "${WORK_DIR}/vmlinuz" | grep -oE 'version [^ ]+' | awk '{print $2}' || echo "unbekannt")
    log "Fedora-Installer-Kernel: ${KVER}"
    log "vmlinuz:   $(du -h "${WORK_DIR}/vmlinuz"    | cut -f1)"
    log "initrd.img: $(du -h "${WORK_DIR}/initrd.img" | cut -f1)"

    step "USB-Stick partitionieren: $usb_whole"
    diskutil unmountDisk force "$usb_whole" >/dev/null 2>&1 || true
    diskutil partitionDisk "$usb_whole" GPT FAT32 EFI 256M FAT32 FEDORA-USB R >/dev/null || die "Partitionierung fehlgeschlagen."

    parts=$(diskutil list "$usb_whole" | awk '/disk[0-9]+s[0-9]+$/ {print $NF}')
    EFI_PART="/dev/$(echo "$parts" | sed -n '1p')"
    DATA_PART="/dev/$(echo "$parts" | sed -n '2p')"
    [[ "$EFI_PART" != "/dev/" && "$DATA_PART" != "/dev/" ]] || die "Konnte Partitionen nicht ermitteln."

    diskutil mount "$EFI_PART" >/dev/null 2>&1 || true
    diskutil mount "$DATA_PART" >/dev/null 2>&1 || true
    EFI_MNT=$(diskutil info -plist "$EFI_PART" 2>/dev/null | plutil -extract MountPoint raw - 2>/dev/null || true)
    DATA_MNT=$(diskutil info -plist "$DATA_PART" 2>/dev/null | plutil -extract MountPoint raw - 2>/dev/null || true)
    [[ -n "$EFI_MNT" && -n "$DATA_MNT" ]] || die "Partitionen konnten nicht gemountet werden."

    log "EFI-Partition:  $EFI_PART"
    log "Daten-Partition: $DATA_PART"

    step "GRUB2 EFI installieren"
    "$GRUB_INSTALL_CMD" \
        --target=x86_64-efi \
        --efi-directory="$EFI_MNT" \
        --boot-directory="${DATA_MNT}/boot" \
        --removable \
        --no-nvram \
        --force \
        || die "${GRUB_INSTALL_CMD} fehlgeschlagen."
    log "GRUB2 installiert."

    mkdir -p "${EFI_MNT}/EFI/BOOT"
    install -m 0644 "${PROJECT_DIR}/boot/grub.cfg" "${EFI_MNT}/EFI/BOOT/grub.cfg"
    mkdir -p "${DATA_MNT}/boot/grub2"
    install -m 0644 "${PROJECT_DIR}/boot/grub.cfg" "${DATA_MNT}/boot/grub2/grub.cfg"
    log "grub.cfg kopiert (EFI/BOOT/ + boot/grub2/)."

    step "Kernel + initrd auf USB kopieren"
    mkdir -p "${DATA_MNT}/boot"
    install -m 0644 "${WORK_DIR}/vmlinuz"    "${DATA_MNT}/boot/vmlinuz"
    install -m 0644 "${WORK_DIR}/initrd.img" "${DATA_MNT}/boot/initrd.img"
    log "vmlinuz: $(du -h "${DATA_MNT}/boot/vmlinuz"  | cut -f1)"
    log "initrd:  $(du -h "${DATA_MNT}/boot/initrd.img" | cut -f1)"

    step "Kickstart + Scripts + Systemd auf USB kopieren"
    mkdir -p "${DATA_MNT}/kickstart" "${DATA_MNT}/scripts" "${DATA_MNT}/systemd"
    cp "${PROJECT_DIR}/kickstart/common-post.inc" "${DATA_MNT}/kickstart/"
    cp "${PROJECT_DIR}"/kickstart/*.ks "${DATA_MNT}/kickstart/" 2>/dev/null || true
    cp -r "${PROJECT_DIR}/scripts/." "${DATA_MNT}/scripts/"
    install -m 0750 "${PROJECT_DIR}/fedora-provision.sh" "${DATA_MNT}/fedora-provision.sh"
    if [[ -d "${PROJECT_DIR}/systemd" ]]; then
        cp -r "${PROJECT_DIR}/systemd/." "${DATA_MNT}/systemd/"
    fi
    log "Dateien kopiert."

    step "Sync"
    sync
    log "USB-Stick fertig: $usb_whole"

    echo ""
    echo -e "  ${BOLD}Partitionen:${RESET}"
    echo -e "    EFI:       $EFI_PART  (LABEL=EFI, GRUB2 BOOTX64.EFI)"
    echo -e "    FEDORA-USB: $DATA_PART (LABEL=FEDORA-USB, Kernel + KS + Scripts)"
    echo ""
    echo -e "  ${BOLD}Kernel:${RESET} ${KVER} (Fedora-Installer-Standard)"
    echo ""
    echo -e "  ${BOLD}Nächste Schritte:${RESET}"
    echo -e "    USB einstecken → UEFI Boot → GRUB2-Menü erscheint"
    echo -e "    [f] Vollinstallation  →  Anaconda startet mit Fedora-Standard-Kernel"
    echo ""
    echo -e "  ${BOLD}Updates:${RESET}  scripts/sync-usb.sh"
}

# ── Voraussetzungen ───────────────────────────────────────────────────────────
step "Voraussetzungen"
missing=()
if [[ "$HOST_OS" == "Darwin" ]]; then
    for cmd in diskutil hdiutil cpio file xz zstd; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
else
    for cmd in sgdisk mkfs.fat cpio file xz zstd; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
fi
GRUB_INSTALL_CMD="$(find_tool grub2-install grub-install || true)"
if [[ -z "$GRUB_INSTALL_CMD" ]]; then
    missing+=("grub2-install/grub-install")
fi
if [[ ${#missing[@]} -gt 0 ]]; then
    if [[ "$HOST_OS" == "Darwin" ]]; then
        die "Fehlende Tools: ${missing[*]}. Installieren: brew install grub cpio file-formula xz zstd"
    else
        die "Fehlende Tools: ${missing[*]}. Installieren: sudo dnf install gdisk dosfstools grub2-efi-x64 grub2-tools cpio file xz zstd"
    fi
done
log "Alle Tools vorhanden."

if [[ "$HOST_OS" == "Darwin" ]]; then
    build_on_macos
    exit 0
fi

# ── Sicherheitscheck ──────────────────────────────────────────────────────────
step "Sicherheitscheck: $USB_DEV"
USB_SIZE_GB=$(( $(blockdev --getsize64 "$USB_DEV") / 1024 / 1024 / 1024 ))
log "Gerät: $USB_DEV  (${USB_SIZE_GB} GB)"
(( USB_SIZE_GB >= 4 ))  || die "USB-Stick zu klein: ${USB_SIZE_GB} GB (min 4 GB)"
(( USB_SIZE_GB <= 512 )) || die "Gerät mit ${USB_SIZE_GB} GB wirkt suspekt groß — abgebrochen."

# Nicht die System-Root überschreiben
ROOT_DEV=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
[[ "$USB_DEV" == "$ROOT_DEV" ]] && die "Verweigert: $USB_DEV ist das Root-Gerät."

echo ""
echo -e "${RED}${BOLD}WARNUNG: $USB_DEV wird komplett überschrieben!${RESET}"
echo -e "  Gerät:  $USB_DEV  (${USB_SIZE_GB} GB)"
echo -e "  Inhalt: wird gelöscht und neu partitioniert"
echo ""
read -r -p "Wirklich fortfahren? [j/N] " ans
[[ "${ans,,}" == "j" ]] || die "Abgebrochen."

# ── Temp-Dirs + Cleanup ───────────────────────────────────────────────────────
WORK_DIR=$(mktemp -d -t build-usb-XXXXXX)
EFI_MNT="${WORK_DIR}/efi"
DATA_MNT="${WORK_DIR}/data"
ISO_MNT="${WORK_DIR}/iso-mnt"
mkdir -p "$EFI_MNT" "$DATA_MNT" "$ISO_MNT"

EFI_PART=""
DATA_PART=""
cleanup() {
    mountpoint -q "$ISO_MNT"  && umount "$ISO_MNT"  || true
    mountpoint -q "$DATA_MNT" && umount "$DATA_MNT" || true
    mountpoint -q "$EFI_MNT"  && umount "$EFI_MNT"  || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ── Kernel + initrd direkt aus Fedora-netinstall-ISO ─────────────────────────
# Kein angepasster Kernel nötig — Fedora-Standard-Installer-Kernel ist
# kompatibel mit Anaconda und allen Dateisystemen (Btrfs, LVM, etc.)
# Bazzite-Kernel wird nach der Installation via first-boot.sh installiert.
step "Kernel + initrd aus Fedora-netinstall-ISO extrahieren"

src_iso=$(ls -t "${PROJECT_DIR}"/iso/Fedora-Everything-netinst-*.iso 2>/dev/null | head -1 || true)
[[ -z "$src_iso" ]] && die "Keine Fedora-Netinst-ISO unter iso/ — z.B. Fedora-Everything-netinst-x86_64-43-1.6.iso"
log "Source-ISO: $src_iso"

mount -o loop,ro "$src_iso" "$ISO_MNT"

[[ -f "${ISO_MNT}/images/pxeboot/vmlinuz" ]]    || die "vmlinuz nicht in ISO gefunden."
[[ -f "${ISO_MNT}/images/pxeboot/initrd.img" ]] || die "initrd.img nicht in ISO gefunden."

cp "${ISO_MNT}/images/pxeboot/vmlinuz"    "${WORK_DIR}/vmlinuz"
cp "${ISO_MNT}/images/pxeboot/initrd.img" "${WORK_DIR}/initrd.img"

umount "$ISO_MNT"

KVER=$(file "${WORK_DIR}/vmlinuz" | grep -oP 'version \K\S+' || echo "unbekannt")
log "Fedora-Installer-Kernel: ${KVER}"
log "vmlinuz:   $(du -h "${WORK_DIR}/vmlinuz"    | cut -f1)"
log "initrd.img: $(du -h "${WORK_DIR}/initrd.img" | cut -f1)"

# Kickstarts werden auf die FEDORA-USB-Partition kopiert.

# ── Partitionieren ────────────────────────────────────────────────────────────
step "USB-Stick partitionieren: $USB_DEV"

# Alle Partitionen aushängen
while IFS= read -r part; do
    [[ "$part" == "$USB_DEV" ]] && continue
    ensure_unmounted_part "$part"
done < <(lsblk -nrpo NAME "$USB_DEV" 2>/dev/null)

sgdisk --zap-all "$USB_DEV" >/dev/null
sgdisk \
    --new=1:0:+256M   --typecode=1:EF00 --change-name=1:"EFI" \
    --new=2:0:0        --typecode=2:0700 --change-name=2:"FEDORA-USB" \
    "$USB_DEV" >/dev/null
partprobe "$USB_DEV"
sleep 1

# Partition-Pfade (sda1/sda2 oder nvme0n1p1/nvme0n1p2)
if [[ "$USB_DEV" =~ nvme|mmcblk ]]; then
    EFI_PART="${USB_DEV}p1"
    DATA_PART="${USB_DEV}p2"
else
    EFI_PART="${USB_DEV}1"
    DATA_PART="${USB_DEV}2"
fi
log "EFI-Partition:  $EFI_PART"
log "Daten-Partition: $DATA_PART"

# Neu erstellte Partitionen aushängen (udisks2/Automounter kann sie sofort mounten)
ensure_unmounted_part "$EFI_PART"
ensure_unmounted_part "$DATA_PART"

mkfs.fat -F 32 -n "EFI"       "$EFI_PART"  >/dev/null
mkfs.fat -F 32 -n "FEDORA-USB" "$DATA_PART" >/dev/null
log "Partitionen formatiert."

# ── GRUB2 installieren ────────────────────────────────────────────────────────
step "GRUB2 EFI installieren"

mount "$EFI_PART"  "$EFI_MNT"
mount "$DATA_PART" "$DATA_MNT"

"$GRUB_INSTALL_CMD" \
    --target=x86_64-efi \
    --efi-directory="$EFI_MNT" \
    --boot-directory="${DATA_MNT}/boot" \
    --removable \
    --no-nvram \
    --force \
    || die "${GRUB_INSTALL_CMD} fehlgeschlagen."

log "GRUB2 installiert."

# grub.cfg auf die EFI-Partition schreiben (BOOTX64.EFI sucht dort zuerst)
mkdir -p "${EFI_MNT}/EFI/BOOT"
install -m 0644 "${PROJECT_DIR}/boot/grub.cfg" "${EFI_MNT}/EFI/BOOT/grub.cfg"
# Auch in boot/grub2/ — grub2-install legt Module dort ab, GRUB sucht cfg dort
mkdir -p "${DATA_MNT}/boot/grub2"
install -m 0644 "${PROJECT_DIR}/boot/grub.cfg" "${DATA_MNT}/boot/grub2/grub.cfg"
log "grub.cfg kopiert (EFI/BOOT/ + boot/grub2/)."

# ── Fedora-Installer-Kernel + initrd kopieren ────────────────────────────────
step "Kernel + initrd auf USB kopieren"

mkdir -p "${DATA_MNT}/boot"
install -m 0644 "${WORK_DIR}/vmlinuz"    "${DATA_MNT}/boot/vmlinuz"
install -m 0644 "${WORK_DIR}/initrd.img" "${DATA_MNT}/boot/initrd.img"
log "vmlinuz: $(du -h "${DATA_MNT}/boot/vmlinuz"  | cut -f1)"
log "initrd:  $(du -h "${DATA_MNT}/boot/initrd.img" | cut -f1)"

# ── Kickstart + Scripts + Systemd-Units kopieren ──────────────────────────────
step "Kickstart + Scripts + Systemd auf USB kopieren"

mkdir -p "${DATA_MNT}/kickstart" "${DATA_MNT}/scripts" "${DATA_MNT}/systemd"

cp "${PROJECT_DIR}/kickstart/common-post.inc" "${DATA_MNT}/kickstart/"
cp "${PROJECT_DIR}"/kickstart/*.ks "${DATA_MNT}/kickstart/" 2>/dev/null || true

cp -r "${PROJECT_DIR}/scripts/." "${DATA_MNT}/scripts/"

install -m 0750 "${PROJECT_DIR}/fedora-provision.sh" "${DATA_MNT}/fedora-provision.sh"

if [[ -d "${PROJECT_DIR}/systemd" ]]; then
    cp -r "${PROJECT_DIR}/systemd/." "${DATA_MNT}/systemd/"
fi

log "Dateien kopiert."

# ── Sync + Ergebnis ───────────────────────────────────────────────────────────
step "Sync"
sync
log "USB-Stick fertig: $USB_DEV"

echo ""
echo -e "  ${BOLD}Partitionen:${RESET}"
echo -e "    EFI:       $EFI_PART  (LABEL=EFI, GRUB2 BOOTX64.EFI)"
echo -e "    FEDORA-USB: $DATA_PART (LABEL=FEDORA-USB, Kernel + KS + Scripts)"
echo ""
echo -e "  ${BOLD}Kernel:${RESET} ${KVER} (Fedora-Installer-Standard)"
echo ""
echo -e "  ${BOLD}Nächste Schritte:${RESET}"
echo -e "    USB einstecken → UEFI Boot → GRUB2-Menü erscheint"
echo -e "    [f] Vollinstallation  →  Anaconda startet mit Fedora-Standard-Kernel"
echo ""
echo -e "  ${BOLD}Updates:${RESET}  scripts/sync-usb.sh"
