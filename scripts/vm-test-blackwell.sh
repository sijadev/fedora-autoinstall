#!/usr/bin/env bash
# vm-test-blackwell.sh — Simuliert die Blackwell-Boot-Topologie in KVM.
#
# Echtes sm_120 lässt sich nicht emulieren — aber die problematische Boot-Umgebung
# (kein VGA, kein efifb, kein simpledrm, nur serielle Console) schon. Genau dort
# zeigt sich ob:
#   - inst.ks=cdrom:/ks.cfg gefunden wird
#   - Kernel mit den Blackwell-Args bootet (nomodeset, video=efifb:off, ...)
#   - Anaconda Text-Mode + Serial-Console findet
#   - Kickstart geparst wird, %pre/%post laufen
#   - Kein Hang in den ersten 60 s (Black-Screen-Äquivalent)
#
# Was NICHT geprüft wird: echte NVIDIA-Driver-Hangs (braucht Hardware).
#
# Usage:
#   scripts/vm-test-blackwell.sh              # embedded ks.cfg im ISO (default)
#   scripts/vm-test-blackwell.sh --keep       # VM nach Test behalten
#   scripts/vm-test-blackwell.sh --usb        # ks.cfg von USB (via /run/install/source)
#   scripts/vm-test-blackwell.sh --http       # ks.cfg von HTTP-Server

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP=0
HTTP_MODE=0
USB_MODE=0

for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=1 ;;
        --http) HTTP_MODE=1 ;;
        --usb)  USB_MODE=1 ;;
        *)      echo "Unbekanntes Argument: $arg" >&2; exit 2 ;;
    esac
done

# HTTP und USB sind Alternativen
if (( HTTP_MODE && USB_MODE )); then
    echo "Fehler: --http und --usb sind Alternativen, nicht kombinierbar" >&2; exit 2
fi

if [[ -t 1 ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; RESET=""
fi
log()  { echo -e "${GREEN}[blackwell-test]${RESET} $*"; }
warn() { echo -e "${YELLOW}[blackwell-test]${RESET} $*" >&2; }
die()  { echo -e "${RED}[blackwell-test] $*${RESET}" >&2; exit 1; }
step() { echo -e "\n${CYAN}${BOLD}══ $* ══${RESET}"; }

export LIBVIRT_DEFAULT_URI="qemu:///session"

VM_NAME="fedora-blackwell-sim"
VM_RAM_MB=8192
VM_CPUS=4
VM_DISK_GB=30
VM_STORAGE_DIR="${VM_STORAGE_DIR:-/home/sija/VMs}"
VM_DISK="${VM_STORAGE_DIR}/${VM_NAME}.qcow2"
VM_NVRAM="${VM_STORAGE_DIR}/${VM_NAME}-OVMF_VARS.fd"
SERIAL_LOG="${VM_STORAGE_DIR}/${VM_NAME}.serial.log"

OVMF_CODE="/usr/share/edk2/ovmf/OVMF_CODE.fd"
OVMF_VARS="/usr/share/edk2/ovmf/OVMF_VARS.fd"
[[ -f "$OVMF_CODE" ]] || OVMF_CODE="/usr/share/OVMF/OVMF_CODE.fd"
[[ -f "$OVMF_VARS" ]] || OVMF_VARS="/usr/share/OVMF/OVMF_VARS.fd"
[[ -f "$OVMF_CODE" ]] || die "OVMF nicht gefunden — installiere edk2-ovmf"

# Identische Blackwell-Args wie ventoy/ventoy_grub.cfg.tpl + Serial-Console-Forcing
BLACKWELL_ARGS="nomodeset rd.driver.blacklist=nouveau modprobe.blacklist=nouveau nvidia-drm.modeset=0 video=efifb:off video=simpledrm:off"
SERIAL_ARGS="console=tty0 console=ttyS0,115200 inst.text"
TIMEOUT_BOOT_S=180     # Bis Anaconda startet
TIMEOUT_TOTAL_S=1800   # Gesamt-Install max 30 Min
HANG_DETECT_S=300      # Keine neue Serial-Zeile in 300 s = Hang

# ── 1. Custom-ISO mit Blackwell-Args bauen ────────────────────────────────────
step "Custom-ISO mit Blackwell-Boot-Args bauen"
command -v mkksiso &>/dev/null || die "mkksiso fehlt: sudo dnf install lorax xorriso cpio zstd"

src_iso=$(ls -t "${PROJECT_DIR}"/iso/Fedora-Everything-netinst-*.iso 2>/dev/null | head -1)
[[ -z "$src_iso" ]] && die "Keine Source-ISO unter iso/ — manuell holen oder fedora-iso-build.sh laufen lassen"

out_iso="${PROJECT_DIR}/iso/Fedora-Auto-blackwell-sim.iso"
stage=$(mktemp -d -t blackwell-stage-XXXXXX)
trap 'rm -rf "$stage"' EXIT

cp "${PROJECT_DIR}/kickstart/fedora-vm.ks" "$stage/ks.cfg"
mkdir -p "$stage/scripts" "$stage/kickstart"
cp -r "${PROJECT_DIR}/scripts/." "$stage/scripts/"
cp "${PROJECT_DIR}/kickstart/common-post.inc" "$stage/kickstart/"
cp "${PROJECT_DIR}"/kickstart/*.ks "$stage/kickstart/" 2>/dev/null || true
cp "${PROJECT_DIR}/fedora-provision.sh" "$stage/fedora-provision.sh"
chmod 0750 "$stage/fedora-provision.sh"

rm -f "$out_iso"
log "Baue ISO mit Args: ${BLACKWELL_ARGS} ${SERIAL_ARGS}"

# Boot-Argument basierend auf Modus
if (( HTTP_MODE )); then
    KS_ARG="inst.ks=http://192.168.122.1:8000/kickstart/fedora-vm.ks"
    log "HTTP-Mode: Kickstart kommt vom Host-Server"
    # Für HTTP: nicht in ISO einbauen
    sudo mkksiso \
        -c "${KS_ARG} ${BLACKWELL_ARGS} ${SERIAL_ARGS}" \
        --add "$stage/scripts" \
        --add "$stage/kickstart" \
        --add "$stage/fedora-provision.sh" \
        "$src_iso" "$out_iso" \
        || die "mkksiso fehlgeschlagen."
elif (( USB_MODE )); then
    KS_ARG="inst.ks=file:///run/install/source/fedora-vm.ks"
    log "USB-Mode: Kickstart kommt von USB /run/install/source"
    # Für USB: auch in ISO falls USB nicht vorhanden
    sudo mkksiso \
        --ks "$stage/ks.cfg" \
        -c "${KS_ARG} ${BLACKWELL_ARGS} ${SERIAL_ARGS}" \
        --add "$stage/scripts" \
        --add "$stage/kickstart" \
        --add "$stage/fedora-provision.sh" \
        "$src_iso" "$out_iso" \
        || die "mkksiso fehlgeschlagen."
else
    # Default: embedded
    sudo mkksiso \
        --ks "$stage/ks.cfg" \
        -c "inst.ks=cdrom:/ks.cfg ${BLACKWELL_ARGS} ${SERIAL_ARGS}" \
        --add "$stage/scripts" \
        --add "$stage/kickstart" \
        --add "$stage/fedora-provision.sh" \
        "$src_iso" "$out_iso" \
        || die "mkksiso fehlgeschlagen."
fi
log "ISO: $out_iso ($(stat -c '%s' "$out_iso" | numfmt --to=iec))"

# ── 2. Alte VM bereinigen + frische headless-VM anlegen ───────────────────────
step "Headless-VM definieren (kein VGA, nur Serial)"
mkdir -p "$VM_STORAGE_DIR"

if virsh dominfo "$VM_NAME" &>/dev/null; then
    virsh domstate "$VM_NAME" 2>/dev/null | grep -qE 'laufend|running' \
        && virsh destroy "$VM_NAME" 2>/dev/null || true
    virsh undefine "$VM_NAME" --nvram 2>/dev/null || virsh undefine "$VM_NAME" 2>/dev/null || true
fi
rm -f "$VM_DISK" "$VM_NVRAM" "$SERIAL_LOG"
cp "$OVMF_VARS" "$VM_NVRAM"

# Kein VGA, keine Grafik, keine virtio-gpu — Console = Serial-File
virt-install \
    --name "$VM_NAME" \
    --memory "$VM_RAM_MB" \
    --vcpus "$VM_CPUS" \
    --cpu host-passthrough \
    --disk "path=${VM_DISK},size=${VM_DISK_GB},format=qcow2,bus=virtio" \
    --cdrom "$out_iso" \
    --os-variant "fedora42" \
    --boot "uefi,loader=${OVMF_CODE},loader_ro=yes,nvram=${VM_NVRAM}" \
    --network user \
    --graphics none \
    --console "pty,target_type=serial" \
    --serial "file,path=${SERIAL_LOG}" \
    --noautoconsole \
    --print-xml 1 > /tmp/${VM_NAME}.xml

virsh define /tmp/${VM_NAME}.xml
log "VM definiert (headless): ${VM_NAME}"
log "Serial-Log: $SERIAL_LOG"

# ── 3. Boot + Monitoring ──────────────────────────────────────────────────────
step "VM starten und Serial-Console beobachten"

# HTTP-Server für HTTP-Mode starten
HTTP_PID=""
if (( HTTP_MODE )); then
    log "Starte HTTP-Server auf Port 8000 ..."
    cd "$PROJECT_DIR"
    python3 -m http.server 8000 &>/dev/null &
    HTTP_PID=$!
    trap "kill $HTTP_PID 2>/dev/null || true" EXIT
    sleep 1
    log "HTTP-Server aktiv (PID=$HTTP_PID)"
fi

virsh start "$VM_NAME"
log "VM gestartet — beobachte Serial-Output (Hang-Erkennung: ${HANG_DETECT_S}s ohne neue Zeile)"

declare -A markers=(
    [boot]="dracut-pre-udev|Booting|EFI"
    [anaconda]="anaconda.*43.*started"
    [kickstart]="anaconda-pre.service|anaconda-nm-config"
    [packages]="Installing|Downloading|transaction|Processing|package|Installieren"
    [post]="anaconda.target|anaconda.service"
    [done]="Reboot|reboot|Power down"
)
declare -A seen=()

start_ts=$(date +%s)
last_size=0
last_change_ts=$start_ts

while true; do
    now=$(date +%s)
    elapsed=$(( now - start_ts ))

    # Gesamt-Timeout
    if (( elapsed > TIMEOUT_TOTAL_S )); then
        warn "Gesamt-Timeout (${TIMEOUT_TOTAL_S}s) erreicht."
        break
    fi

    if [[ -f "$SERIAL_LOG" ]]; then
        cur_size=$(stat -c '%s' "$SERIAL_LOG" 2>/dev/null || echo 0)
        if (( cur_size > last_size )); then
            last_change_ts=$now
            last_size=$cur_size
            # Marker-Erkennung
            for m in "${!markers[@]}"; do
                if [[ -z "${seen[$m]:-}" ]] && grep -qE "${markers[$m]}" "$SERIAL_LOG" 2>/dev/null; then
                    seen[$m]=$elapsed
                    log "✓ Marker [${m}] erreicht nach ${elapsed}s"
                fi
            done
        fi
        idle=$(( now - last_change_ts ))
        if (( idle > HANG_DETECT_S )); then
            warn "Black-Screen-Äquivalent: keine Serial-Aktivität seit ${idle}s."
            echo -e "\n${RED}${BOLD}── Letzte 30 Serial-Zeilen ──${RESET}"
            tail -30 "$SERIAL_LOG" || true
            break
        fi
    fi

    # VM beendet?
    state=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "unknown")
    if [[ "$state" =~ shut|abgeschaltet ]]; then
        log "VM beendet (state=${state}) nach ${elapsed}s."
        break
    fi

    sleep 5
done

# ── 4. Auswertung ─────────────────────────────────────────────────────────────
step "Auswertung"
echo ""
echo "  ${BOLD}Marker-Übersicht:${RESET}"
status=0
for m in boot anaconda kickstart packages post done; do
    if [[ -n "${seen[$m]:-}" ]]; then
        echo -e "    ${GREEN}✓${RESET} ${m}  (${seen[$m]}s)"
    else
        echo -e "    ${RED}✗${RESET} ${m}  (nicht erreicht)"
        status=1
    fi
done
echo ""
echo "  ${BOLD}Serial-Log:${RESET} $SERIAL_LOG ($(stat -c '%s' "$SERIAL_LOG" 2>/dev/null || echo 0) bytes)"

if (( status == 0 )); then
    log "Test erfolgreich: alle Marker erreicht."
elif [[ -n "${seen[anaconda]:-}" && -n "${seen[kickstart]:-}" ]]; then
    warn "Anaconda + Kickstart geladen, aber kein vollständiger Install-Durchlauf — siehe Serial-Log."
else
    warn "Boot-Pfad gebrochen: Anaconda oder Kickstart nicht erreicht — das ist der Black-Screen-Pfad."
fi

# ── 5. Cleanup ────────────────────────────────────────────────────────────────
if (( KEEP == 1 )); then
    log "VM behalten (--keep). State: $(virsh domstate "$VM_NAME" 2>/dev/null || echo unknown)"
    log "Serial weiterlesen: tail -f $SERIAL_LOG"
else
    virsh destroy "$VM_NAME" 2>/dev/null || true
    virsh undefine "$VM_NAME" --nvram 2>/dev/null || virsh undefine "$VM_NAME" 2>/dev/null || true
    rm -f "$VM_DISK" "$VM_NVRAM"
    log "VM entfernt (Serial-Log bleibt: $SERIAL_LOG)"
fi

exit $status
