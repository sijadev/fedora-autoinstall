#!/usr/bin/env bash
# scripts/vm-test.sh — VM-Test-Workflow für das Fedora Install Framework
#
# Befehle:
#   vm-test.sh create          VM anlegen (80 GB, UEFI, VirtIO, FEDORA-USB-Passthrough)
#   vm-test.sh install         Frische Installation: VM vom FEDORA-USB booten,
#                              [m] VM-Test Profil per Hotkey auswählen, Anaconda läuft durch
#   vm-test.sh snapshot        Snapshot "base-fedora" nach erfolgreicher Installation anlegen
#   vm-test.sh test <profil>   Snapshot zurücksetzen + Provisioner ausführen
#                              Profil: theme-bash
#   vm-test.sh status          VM-Status und IP anzeigen
#   vm-test.sh ssh             In laufende VM einloggen
#   vm-test.sh destroy         VM und Disk-Image löschen
#
# Voraussetzungen:
#   - virt-manager + libvirt installiert und libvirtd aktiv
#   - FEDORA-USB-Stick eingesteckt (/dev/sda, LABEL=FEDORA-USB)
#   - fedora-vm.ks auf dem FEDORA-USB-Stick (via scripts/sync-usb.sh)

set -euo pipefail

# ── Konfiguration ──────────────────────────────────────────────────────────────
VM_NAME="fedora43"
VM_RAM_MB=8192
VM_CPUS=4
VM_DISK_GB=100
VM_STORAGE_DIR="/home/sija/VMs"
VM_DISK="${VM_STORAGE_DIR}/${VM_NAME}.qcow2"
VM_SNAPSHOT="fedora43-default"
VM_USER="sija"
VM_PASS="test123"
VM_OS_VARIANT="fedora43"

OVMF_CODE="/usr/share/edk2/ovmf/OVMF_CODE.fd"
OVMF_VARS="/usr/share/edk2/ovmf/OVMF_VARS.fd"
OVMF_VARS_VM="${VM_STORAGE_DIR}/${VM_NAME}-OVMF_VARS.fd"

# FEDORA-USB: Kingston DataTraveler (lsusb: 0930:6545)
# Wird zur Laufzeit neu ermittelt — nur Fallback hartcodiert
USB_VENDOR="0930"
USB_PRODUCT="6545"

# libvirt system URI — verhindert Verwechslung mit qemu:///session
export LIBVIRT_DEFAULT_URI="qemu:///system"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"
SSH_TIMEOUT=1800        # Hard-Cap: Gesamtdauer in Sekunden
SSH_IDLE_TIMEOUT=600    # Idle-Cap: SSH-Abbruch wenn 10 Min ohne VM-Aktivität (Disk-I/O)
# sshpass für Passwort-basiertes SSH (Test-VM)
SSH="sshpass -p ${VM_PASS:-test123} ssh $SSH_OPTS"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Log- und Screenshot-Verzeichnis
TEST_RESULTS_DIR="${PROJECT_DIR}/test-results"

# ── Farben ─────────────────────────────────────────────────────────────────────
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

progress_bar() {
    local waited=$1 total=$2 label=${3:-""}
    local pct=$(( waited * 100 / total ))
    local filled=$(( waited * 40 / total ))
    local bar=""
    for ((i=0; i<filled; i++));   do bar+="█"; done
    for ((i=filled; i<40; i++));  do bar+="░"; done
    local elapsed_min=$(( waited / 60 ))
    local elapsed_sec=$(( waited % 60 ))
    local total_min=$(( total / 60 ))
    printf "\r  ${CYAN}${bar}${RESET} ${BOLD}%3d%%${RESET}  %02d:%02d / %02d:00  ${label}%-30s" \
        "$pct" "$elapsed_min" "$elapsed_sec" "$total_min" ""
}

# ── Hilfsfunktionen ────────────────────────────────────────────────────────────

vm_exists() { virsh dominfo "$VM_NAME" &>/dev/null; }

vm_state() { virsh domstate "$VM_NAME" 2>/dev/null || echo "unknown"; }

# Läuft oder pausiert (beides = Domain aktiv, kein Start nötig)
vm_is_active()  { [[ "$(vm_state)" =~ ^(running|laufend|paused|pausiert) ]]; }
vm_is_running() { [[ "$(vm_state)" =~ ^(running|laufend) ]]; }

snapshot_exists() {
    virsh snapshot-list "$VM_NAME" 2>/dev/null | grep -q "$VM_SNAPSHOT"
}

get_vm_ip() {
    virsh domifaddr "$VM_NAME" 2>/dev/null \
        | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1
}

wait_for_ssh() {
    local ip="$1"
    local vm="${2:-$VM_NAME}"
    log "Warte auf SSH ($ip) — Idle-Timeout ${SSH_IDLE_TIMEOUT}s, Hard-Cap ${SSH_TIMEOUT}s ..."
    local elapsed=0 idle=0
    local last_bytes=0 cur_bytes=0
    echo ""
    until $SSH "$VM_USER@$ip" true 2>/dev/null; do
        sleep 5; elapsed=$((elapsed + 5)); idle=$((idle + 5))

        # Disk-I/O messen: solange VM schreibt, Idle-Counter resetten
        cur_bytes=$(LIBVIRT_DEFAULT_URI="qemu:///system" virsh domstats "$vm" --block 2>/dev/null \
            | awk -F= '/block\.[0-9]+\.wr\.bytes=/{s+=$2} END{print s+0}')
        if (( cur_bytes > last_bytes )); then
            idle=0
            last_bytes=$cur_bytes
        fi

        if (( idle > SSH_IDLE_TIMEOUT )); then
            echo ""; die "SSH nicht erreichbar — VM ${SSH_IDLE_TIMEOUT}s ohne Disk-Aktivität (idle)."
        fi
        if (( elapsed > SSH_TIMEOUT )); then
            echo ""; die "SSH nicht erreichbar nach ${SSH_TIMEOUT}s (Hard-Cap)."
        fi
        progress_bar "$idle" "$SSH_IDLE_TIMEOUT" "SSH wartet (idle ${idle}s/${SSH_IDLE_TIMEOUT}s, total ${elapsed}s)"
    done
    echo ""
    log "SSH verbunden: $ip"
}

# ── Screenshot-Hilfsfunktionen ─────────────────────────────────────────────────

take_screenshot() {
    local label="$1"   # z.B. "before" oder "after"
    local profile="$2"
    local ts; ts=$(date '+%Y%m%d-%H%M%S')
    local out_dir="${TEST_RESULTS_DIR}/${profile}"
    mkdir -p "$out_dir"

    local ppm="${out_dir}/${ts}-${label}.ppm"
    local png="${out_dir}/${ts}-${label}.png"

    virsh screenshot "$VM_NAME" "$ppm" 2>/dev/null || { warn "Screenshot fehlgeschlagen."; return; }

    if command -v convert &>/dev/null; then
        convert "$ppm" "$png" 2>/dev/null && rm -f "$ppm" && log "Screenshot: $png"
    elif command -v ffmpeg &>/dev/null; then
        ffmpeg -y -i "$ppm" "$png" -loglevel quiet && rm -f "$ppm" && log "Screenshot: $png"
    else
        log "Screenshot (PPM): $ppm  (imagemagick/ffmpeg fehlt für PNG-Konversion)"
    fi
}

open_terminal_in_vm() {
    local ip="$1"
    # DBUS-Session des eingeloggten Users ermitteln und Terminal öffnen
    $SSH "$VM_USER@$ip" 'bash -c "
        export DISPLAY=:0
        export DBUS_SESSION_BUS_ADDRESS=$(cat /proc/$(pgrep -u $USER ptyxis gnome-session | head -1)/environ 2>/dev/null | tr \"\\0\" \"\\n\" | grep DBUS_SESSION | cut -d= -f2-)
        nohup ptyxis &>/dev/null &
    "' 2>/dev/null || \
    $SSH "$VM_USER@$ip" \
        'DISPLAY=:0 nohup bash -c "dbus-launch ptyxis" &>/dev/null &' 2>/dev/null || true
    sleep 3  # Fenster aufbauen lassen
}

find_usb_stick() {
    # FEDORA-USB per lsusb dynamisch ermitteln (Fallback auf gespeicherte IDs)
    local found
    found=$(lsusb | grep -i "kingston\|datatraveler" \
        | grep -oP 'ID \K[0-9a-f]{4}:[0-9a-f]{4}' | head -1 || true)

    if [[ -n "$found" ]]; then
        USB_VENDOR="${found%:*}"
        USB_PRODUCT="${found#*:}"
        log "FEDORA-USB gefunden: ${USB_VENDOR}:${USB_PRODUCT}"
    else
        log "Verwende gespeicherte USB-IDs: ${USB_VENDOR}:${USB_PRODUCT}"
    fi
}

add_usb_passthrough() {
    find_usb_stick
    log "USB-Passthrough für FEDORA-USB wird hinzugefügt ..."
    virsh attach-device "$VM_NAME" --persistent /dev/stdin <<XMLEOF
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source>
    <vendor id='0x${USB_VENDOR}'/>
    <product id='0x${USB_PRODUCT}'/>
  </source>
</hostdev>
XMLEOF
    log "USB-Passthrough aktiv: FEDORA-USB sichtbar in VM"
}

# ── Befehle ────────────────────────────────────────────────────────────────────

cmd_create() {
    step "VM anlegen: ${VM_NAME}"

    vm_exists && die "VM '${VM_NAME}' existiert bereits. Erst 'vm-test.sh destroy' ausführen."
    [[ -f "$OVMF_CODE" ]] || die "OVMF nicht gefunden: $OVMF_CODE"

    # Storage-Verzeichnis anlegen und als libvirt-Pool registrieren
    mkdir -p "$VM_STORAGE_DIR"
    if ! virsh pool-info fedora-vms &>/dev/null; then
        virsh pool-define-as fedora-vms dir --target "$VM_STORAGE_DIR"
        virsh pool-build fedora-vms
        virsh pool-start fedora-vms
        virsh pool-autostart fedora-vms
        log "Storage-Pool 'fedora-vms' angelegt: $VM_STORAGE_DIR"
    fi

    # Separate VARS-Datei pro VM (UEFI speichert Boot-Einträge darin)
    cp "$OVMF_VARS" "$OVMF_VARS_VM"
    log "OVMF_VARS kopiert: $OVMF_VARS_VM"

    virt-install \
        --name "$VM_NAME" \
        --memory "$VM_RAM_MB" \
        --vcpus "$VM_CPUS" \
        --disk "path=${VM_DISK},size=${VM_DISK_GB},format=qcow2,bus=virtio" \
        --os-variant "$VM_OS_VARIANT" \
        --boot "uefi,loader=${OVMF_CODE},loader_ro=yes,nvram=${OVMF_VARS_VM}" \
        --network network=default \
        --graphics spice,listen=none \
        --video virtio \
        --noautoconsole \
        --print-xml > /tmp/${VM_NAME}.xml

    # VM aus XML definieren (ohne direkt zu starten)
    virsh define /tmp/${VM_NAME}.xml
    log "VM definiert: ${VM_NAME}"

    # FEDORA-USB USB-Passthrough hinzufügen
    add_usb_passthrough

    echo ""
    log "VM '${VM_NAME}' bereit."
    echo ""
    echo -e "  ${BOLD}Nächste Schritte:${RESET}"
    echo -e "  1. virt-manager öffnen → VM '${VM_NAME}' starten"
    echo -e "  2. GRUB2-Menü erscheint → [m] VM-Test drücken"
    echo -e "  3. Installation abwarten, VM startet neu"
    echo -e "  4. Dann: ${BOLD}./scripts/vm-test.sh snapshot${RESET}"
}

cmd_install() {
    step "Installations-Test: Custom-ISO → Anaconda → fedora-vm.ks"

    local install_vm="fedora-install-test"
    local install_disk="${VM_STORAGE_DIR}/${install_vm}.qcow2"
    local install_nvram="${VM_STORAGE_DIR}/${install_vm}-OVMF_VARS.fd"
    local custom_iso="${PROJECT_DIR}/iso/Fedora-Auto-vm.iso"

    # ── Custom-ISO bauen (immer aktuell mit fedora-vm.ks + Scripts) ───────────
    step "Custom-ISO bauen (fedora-vm.ks eingebettet)"
    if ! command -v mkksiso &>/dev/null; then
        die "mkksiso fehlt. Installiere: sudo dnf install lorax xorriso cpio zstd"
    fi
    local src_iso
    src_iso=$(ls -t "${PROJECT_DIR}"/iso/Fedora-Everything-netinst-*.iso 2>/dev/null | head -1)
    [[ -z "$src_iso" ]] && die "Keine Source-ISO unter iso/ gefunden."

    local stage; stage=$(mktemp -d -t vm-iso-stage-XXXXXX)
    cp "${PROJECT_DIR}/kickstart/fedora-vm.ks" "$stage/ks.cfg"
    mkdir -p "$stage/scripts" "$stage/kickstart"
    cp -r "${PROJECT_DIR}/scripts/." "$stage/scripts/"
    cp "${PROJECT_DIR}/kickstart/common-post.inc" "$stage/kickstart/"
    cp "${PROJECT_DIR}"/kickstart/*.ks "$stage/kickstart/" 2>/dev/null || true
    cp "${PROJECT_DIR}/fedora-provision.sh" "$stage/fedora-provision.sh"
    chmod 0750 "$stage/fedora-provision.sh"

    rm -f "$custom_iso"
    sudo mkksiso \
        --ks "$stage/ks.cfg" \
        -c "inst.ks=cdrom:/ks.cfg" \
        --add "$stage/scripts" \
        --add "$stage/kickstart" \
        --add "$stage/fedora-provision.sh" \
        "$src_iso" \
        "$custom_iso" \
        || { rm -rf "$stage"; die "mkksiso (VM-Variante) fehlgeschlagen."; }
    rm -rf "$stage"
    log "Custom-ISO: $custom_iso ($(stat -c '%s' "$custom_iso" | numfmt --to=iec))"

    # Alte Install-Test-VM bereinigen
    if virsh dominfo "$install_vm" &>/dev/null; then
        virsh domstate "$install_vm" 2>/dev/null | grep -q "laufend\|running" && \
            virsh destroy "$install_vm" 2>/dev/null || true
        virsh undefine "$install_vm" --nvram 2>/dev/null || \
            virsh undefine "$install_vm" 2>/dev/null || true
        log "Alte Install-Test-VM entfernt."
    fi
    [[ -f "$install_disk" ]] && rm -f "$install_disk"
    [[ -f "$install_nvram" ]] && rm -f "$install_nvram"

    # Frische VM mit LEEREM Disk anlegen, ISO als CDROM (boot=cdrom)
    log "Lege neue Install-Test-VM an: ${install_vm} (${VM_DISK_GB}GB, leer)..."
    cp "$OVMF_VARS" "$install_nvram"

    virt-install \
        --name "$install_vm" \
        --memory "$VM_RAM_MB" \
        --vcpus "$VM_CPUS" \
        --disk "path=${install_disk},size=${VM_DISK_GB},format=qcow2,bus=virtio" \
        --cdrom "$custom_iso" \
        --os-variant "$VM_OS_VARIANT" \
        --boot "uefi,loader=${OVMF_CODE},loader_ro=yes,nvram=${install_nvram}" \
        --network network=default \
        --graphics spice,listen=none \
        --video virtio \
        --noautoconsole \
        --print-xml 1 > /tmp/${install_vm}.xml

    virsh define /tmp/${install_vm}.xml
    log "VM '${install_vm}' definiert (Custom-ISO als CDROM)."

    log "Starte VM — UEFI bootet vom Custom-ISO, Anaconda startet automatisch..."
    virsh start "$install_vm"

    local ACTIVE_VM="$install_vm"
    log "Anaconda läuft mit eingebettetem fedora-vm.ks — keine Keystroke-Sequenz nötig."

    # virt-manager öffnen für visuelle Kontrolle
    virt-manager --connect qemu:///system --show-domain-console "$ACTIVE_VM" &
    log "virt-manager geöffnet — Anaconda Installation in Echtzeit sichtbar"

    # Serielle Konsole in eigenem Terminal — zeigt Anaconda Textausgabe
    if command -v gnome-terminal &>/dev/null; then
        gnome-terminal --title="Anaconda: ${ACTIVE_VM}" -- \
            bash -c "virsh --connect qemu:///system console '${ACTIVE_VM}'; echo '--- Konsole beendet ---'; read" &
    elif command -v xterm &>/dev/null; then
        xterm -title "Anaconda: ${ACTIVE_VM}" -e \
            "virsh --connect qemu:///system console '${ACTIVE_VM}'; echo '--- Konsole beendet ---'; read" &
    fi
    log "Serielle Konsole geöffnet — Anaconda Textausgabe sichtbar"

    # Warte auf Abschluss — Anaconda rebootet die VM nach erfolgreicher Installation
    log "Warte auf Anaconda + Fedora-Installation (~15-25 Min über Netzwerk)..."
    local waited=0
    local install_timeout=1800  # 30 Minuten max
    local rebooted=0

    local phases=(
        [0]="Anaconda startet..."
        [60]="Partitionierung + Basisinstallation..."
        [300]="Pakete werden installiert..."
        [600]="Pakete werden installiert..."
        [900]="Pakete werden installiert..."
        [1200]="%post-Skripte laufen..."
        [1500]="Abschluss + Reboot..."
    )
    local current_phase="Anaconda startet..."

    echo ""
    while [[ $waited -lt $install_timeout ]]; do
        sleep 10; waited=$((waited + 10))
        local state; state=$(LIBVIRT_DEFAULT_URI="qemu:///system" virsh domstate "$ACTIVE_VM" 2>/dev/null || echo "unknown")
        if [[ "$state" =~ ^(ausgeschaltet|shut.off) ]]; then
            rebooted=1
            break
        fi
        for key in 0 60 300 600 900 1200 1500; do
            [[ $waited -ge $key ]] && current_phase="${phases[$key]}"
        done
        progress_bar "$waited" "$install_timeout" "$current_phase"
    done
    echo ""

    if [[ $rebooted -eq 1 ]]; then
        log "✓ Installation abgeschlossen — VM hat sich ausgeschaltet (reboot nach Install)"
        log "Starte VM für Post-Install-Check..."
        virsh start "$ACTIVE_VM"

        local ip=""
        local waited_ip=0
        while [[ -z "$ip" ]]; do
            sleep 5; waited_ip=$((waited_ip + 5))
            [[ $waited_ip -gt 120 ]] && die "VM hat keine IP nach 120s — manuell prüfen"
            ip=$(LIBVIRT_DEFAULT_URI="qemu:///system" virsh domifaddr "$ACTIVE_VM" \
                2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1 || echo "")
        done
        wait_for_ssh "$ip"
        log "✓ VM bootet erfolgreich ins installierte System (IP: $ip)"

        # VM sauber herunterfahren für konsistenten Snapshot
        log "Fahre VM herunter für Snapshot ..."
        virsh shutdown "$ACTIVE_VM" &>/dev/null || true
        local i=0
        while LIBVIRT_DEFAULT_URI="qemu:///system" virsh domstate "$ACTIVE_VM" \
                2>/dev/null | grep -qE "running|laufend" && (( i < 30 )); do
            sleep 2; i=$(( i + 1 ))
        done
        LIBVIRT_DEFAULT_URI="qemu:///system" virsh domstate "$ACTIVE_VM" \
            2>/dev/null | grep -qE "running|laufend" && \
            virsh destroy "$ACTIVE_VM" &>/dev/null || true

        # Base-Snapshot anlegen — wird von cmd_base vorausgesetzt
        local snap_name="base-fedora43"
        log "Erstelle Snapshot '${snap_name}' auf '${ACTIVE_VM}' ..."
        virsh snapshot-create-as "$ACTIVE_VM" "$snap_name" \
            --description "Frische Fedora 43 Installation — Reset-Punkt für cmd_base"
        log "✓ Snapshot '${snap_name}' angelegt."
        log ""
        log "Nächster Schritt: ./scripts/vm-test.sh base"
    else
        warn "✗ Installation nicht abgeschlossen nach ${install_timeout}s"
        log "Aktueller Status: $(LIBVIRT_DEFAULT_URI="qemu:///system" virsh domstate "$ACTIVE_VM" 2>/dev/null)"
        log "Prüfe virt-manager für Anaconda-Fehlermeldungen"
    fi
}

cmd_base() {
    step "Neuen Base-Snapshot aus fedora-install-test ableiten"

    local install_vm="fedora-install-test"
    local install_snapshot="base-fedora43"
    local install_disk="${VM_STORAGE_DIR}/${install_vm}.qcow2"
    local install_nvram="${VM_STORAGE_DIR}/${install_vm}-OVMF_VARS.fd"

    # Voraussetzungen prüfen
    virsh dominfo "$install_vm" &>/dev/null || \
        die "VM '${install_vm}' nicht gefunden. Erst './vm-test.sh install' ausführen."
    virsh snapshot-info "$install_vm" "$install_snapshot" &>/dev/null || \
        die "Snapshot '${install_snapshot}' fehlt auf '${install_vm}'. 'install' nochmal ausführen."

    # 1. install_vm stoppen
    if virsh domstate "$install_vm" 2>/dev/null | grep -qE "running|laufend"; then
        log "Stoppe ${install_vm} ..."
        virsh shutdown "$install_vm" &>/dev/null || true
        local i=0
        while virsh domstate "$install_vm" 2>/dev/null | grep -qE "running|laufend" && (( i < 20 )); do
            sleep 2; i=$(( i + 1 ))
        done
        virsh domstate "$install_vm" 2>/dev/null | grep -qE "running|laufend" && \
            virsh destroy "$install_vm" &>/dev/null || true
    fi

    # 2. Alte fedora43-VM ZUERST entfernen (gibt USB-Gerät frei)
    if vm_exists; then
        log "Entferne alte VM '${VM_NAME}' ..."
        vm_is_running && virsh destroy "$VM_NAME" &>/dev/null || true
        virsh undefine "$VM_NAME" --snapshots-metadata --nvram 2>/dev/null || \
            virsh undefine "$VM_NAME" --snapshots-metadata
        [[ -f "$VM_DISK" ]]      && rm -f "$VM_DISK"      && log "Gelöscht: $VM_DISK"
        [[ -f "$OVMF_VARS_VM" ]] && rm -f "$OVMF_VARS_VM" && log "Gelöscht: $OVMF_VARS_VM"
        rm -f "/var/lib/libvirt/images/${VM_NAME}.qcow2" 2>/dev/null || true
    fi

    # 3. Zum Post-Install-Snapshot zurückkehren (Provisioning verwerfen)
    log "Revertiere ${install_vm} → ${install_snapshot} ..."
    virsh snapshot-revert "$install_vm" "$install_snapshot"
    virsh snapshot-delete "$install_vm" "$install_snapshot"
    # Overlay-Datei entfernen (nach Revert nicht mehr aktiv)
    find "${VM_STORAGE_DIR}" -maxdepth 1 -name "${install_vm}.*" \
        ! -name "*.qcow2" ! -name "*.fd" -delete 2>/dev/null || true

    # 4. VM umbenennen: fedora-install-test → fedora43
    log "Benenne ${install_vm} → ${VM_NAME} um ..."
    virsh domrename "$install_vm" "$VM_NAME"

    # 5. Disk- und NVRAM-Pfade in der XML-Konfiguration aktualisieren
    log "Aktualisiere VM-Konfiguration (Disk, NVRAM) ..."
    virsh dumpxml "$VM_NAME" > /tmp/${VM_NAME}-base.xml
    sed -i "s|${install_disk}|${VM_DISK}|g"    /tmp/${VM_NAME}-base.xml
    sed -i "s|${install_nvram}|${OVMF_VARS_VM}|g" /tmp/${VM_NAME}-base.xml
    virsh define /tmp/${VM_NAME}-base.xml
    rm -f /tmp/${VM_NAME}-base.xml

    # 6. Dateien umbenennen (auf btrfs: sofort, kein Kopieren)
    mv "$install_disk" "$VM_DISK"
    mv "$install_nvram" "$OVMF_VARS_VM"
    log "Disk: ${VM_DISK}"
    log "NVRAM: ${OVMF_VARS_VM}"

    virsh pool-refresh fedora-vms &>/dev/null || true

    # 7. Snapshot anlegen
    cmd_snapshot
}

cmd_snapshot() {
    step "Snapshot anlegen: ${VM_SNAPSHOT}"

    vm_exists || die "VM '${VM_NAME}' nicht gefunden. Erst 'create' ausführen."
    vm_is_running && die "VM läuft noch. Bitte herunterfahren: virsh shutdown ${VM_NAME}"

    virsh snapshot-create-as "$VM_NAME" "$VM_SNAPSHOT" \
        --description "Frische Fedora 43 Installation — Reset-Punkt für Provisioner-Tests"

    log "Snapshot '${VM_SNAPSHOT}' angelegt."
    virsh snapshot-list "$VM_NAME"
}

cmd_test() {
    local profile="${1:-}"
    [[ -z "$profile" ]] && die "Profil fehlt. Erlaubt: theme-bash | headless-vllm"

    case "$profile" in
        theme-bash)    ;;
        headless-vllm) ;;
        *) die "Unbekanntes Profil: '$profile'. Erlaubt: theme-bash | headless-vllm" ;;
    esac

    # Log-Datei — ZUERST öffnen damit alle Ausgaben erfasst werden
    local ts; ts=$(date '+%Y%m%d-%H%M%S')
    local log_dir="${TEST_RESULTS_DIR}/${profile}"
    mkdir -p "$log_dir"
    local log_file="${log_dir}/${ts}-test.log"
    exec > >(tee -a "$log_file") 2>&1

    local test_start; test_start=$(date '+%Y-%m-%d %H:%M:%S')
    echo "════════════════════════════════════════════════════"
    echo "  Fedora VM-Test — Profil: ${profile}"
    echo "  Gestartet: ${test_start}"
    echo "  VM: ${VM_NAME}  Snapshot: ${VM_SNAPSHOT}"
    echo "  Log: ${log_file}"
    echo "════════════════════════════════════════════════════"

    step "Test: Profil '${profile}'"

    vm_exists        || die "VM '${VM_NAME}' nicht gefunden."
    snapshot_exists  || die "Snapshot '${VM_SNAPSHOT}' nicht gefunden. Erst 'snapshot' ausführen."

    # Snapshot zurücksetzen — VM hart stoppen damit Revert sofort möglich
    log "Setze Snapshot '${VM_SNAPSHOT}' zurück ..."
    if vm_is_running; then
        virsh destroy "$VM_NAME"
        sleep 1
    fi
    virsh snapshot-revert "$VM_NAME" "$VM_SNAPSHOT"
    log "Snapshot zurückgesetzt."

    # USB-Passthrough: nur hinzufügen/behalten wenn Stick am Host verfügbar
    find_usb_stick
    local usb_on_host=0
    lsusb | grep -q "${USB_VENDOR}:${USB_PRODUCT}" && usb_on_host=1

    if [[ $usb_on_host -eq 1 ]]; then
        if ! virsh dumpxml "$VM_NAME" | grep -q "hostdev"; then
            virsh attach-device "$VM_NAME" --persistent /dev/stdin <<XMLEOF 2>/dev/null || true
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source>
    <vendor id='0x${USB_VENDOR}'/>
    <product id='0x${USB_PRODUCT}'/>
  </source>
</hostdev>
XMLEOF
            log "FEDORA-USB USB-Passthrough wiederhergestellt."
        fi
    else
        # Stick nicht am Host — Passthrough aus VM-XML entfernen damit VM starten kann
        if virsh dumpxml "$VM_NAME" | grep -q "hostdev"; then
            warn "FEDORA-USB nicht am Host — entferne Passthrough aus VM-XML."
            virsh dumpxml "$VM_NAME" > /tmp/${VM_NAME}-nousb.xml
            python3 -c "
import sys, re
xml = open('/tmp/${VM_NAME}-nousb.xml').read()
xml = re.sub(r'<hostdev[^>]*usb[^>]*>.*?</hostdev>', '', xml, flags=re.DOTALL)
open('/tmp/${VM_NAME}-nousb.xml', 'w').write(xml)
"
            virsh define /tmp/${VM_NAME}-nousb.xml &>/dev/null || true
            rm -f /tmp/${VM_NAME}-nousb.xml
            log "USB-Passthrough entfernt — VM kann ohne Stick starten."
        fi
    fi

    # VM in laufenden Zustand bringen (Snapshot kann running/paused/shut-off sein)
    local state; state=$(vm_state)
    case "$state" in
        running|laufend)
            log "VM läuft bereits." ;;
        paused|pausiert)
            virsh resume "$VM_NAME"; log "VM fortgesetzt (war pausiert)." ;;
        *)
            virsh start "$VM_NAME"; log "VM gestartet." ;;
    esac

    # Auf IP warten
    local ip=""
    local waited=0
    while [[ -z "$ip" ]]; do
        sleep 3; waited=$((waited + 3))
        [[ $waited -gt 60 ]] && die "VM hat keine IP bekommen nach 60s"
        ip=$(get_vm_ip)
    done
    log "VM-IP: $ip"

    wait_for_ssh "$ip"

    # Auf GNOME Auto-Login + FEDORA-USB-Automount warten (max 60s)
    log "Warte auf FEDORA-USB-Mount (GNOME Auto-Login)..."
    local usb_path=""
    local mount_waited=0
    until [[ -n "$usb_path" ]]; do
        sleep 3; mount_waited=$((mount_waited + 3))
        usb_path=$($SSH "$VM_USER@$ip" \
            "findmnt -rno TARGET LABEL=FEDORA-USB 2>/dev/null" || true)
        [[ $mount_waited -gt 60 ]] && {
            log "Automount nicht verfügbar — mounte manuell..."
            $SSH "$VM_USER@$ip" "echo '${VM_PASS}' | sudo -S bash -c 'mkdir -p /run/media/${VM_USER}/FEDORA-USB && mount LABEL=FEDORA-USB /run/media/${VM_USER}/FEDORA-USB' 2>/dev/null" || true
            usb_path="/run/media/${VM_USER}/FEDORA-USB"
        }
    done
    log "FEDORA-USB-Pfad in VM: $usb_path"

    # ── Screenshot VORHER (offenes Terminal) ──────────────────────────────────
    # Screenshots nur für GUI-Profile (headless hat keinen Desktop)
    if [[ "$profile" == "theme-bash" ]]; then
        step "Screenshot: vor Provisioner"
        open_terminal_in_vm "$ip"
        take_screenshot "1-before" "$profile"
    fi

    # ── Provisioner ausführen ─────────────────────────────────────────────────
    # Marker VOR provision setzen: Autostart-Version von first-login.sh sieht den
    # Marker und beendet sich sofort (Zeile 43 in first-login.sh). Danach Marker
    # löschen, damit unsere SSH-Version normal durchläuft.
    log "Setze first-login Marker (verhindert Autostart-Konkurrenz) ..."
    $SSH "$VM_USER@$ip" \
        "mkdir -p ~/.local/share/fedora-provision && touch ~/.local/share/fedora-provision/first-login.done"

    log "Starte fedora-provision.sh --profile ${profile} ..."
    $SSH "$VM_USER@$ip" \
        "echo '${VM_PASS}' | sudo -S bash '${usb_path}/fedora-provision.sh' --profile '${profile}' --run-now" \
        || warn "Provisioner abgebrochen oder mit Fehler beendet — Logs prüfen"

    log "Lösche first-login Marker (SSH-Version läuft gleich) ..."
    $SSH "$VM_USER@$ip" "rm -f ~/.local/share/fedora-provision/first-login.done"

    # ── First-Boot Logs abwarten ──────────────────────────────────────────────
    log "Warte auf First-Boot Abschluss..."
    local boot_done=0
    local boot_waited=0
    while [[ $boot_done -eq 0 ]]; do
        sleep 5; boot_waited=$((boot_waited + 5))
        if $SSH "$VM_USER@$ip" "test -f /var/lib/fedora-provision/first-boot.done" 2>/dev/null; then
            boot_done=1
        elif [[ $boot_waited -gt 1800 ]]; then
            warn "First-Boot nicht abgeschlossen nach 1800s."
            break
        fi
    done
    [[ $boot_done -eq 1 ]] && log "First-Boot abgeschlossen."

    # ── Aktuelle Repo-Skripte in VM einspielen (override USB-Version) ─────
    log "Sync: Repo-Skripte → VM ..."
    $SSH "$VM_USER@$ip" "cat > /tmp/fedora-first-login.sh" \
        < "${PROJECT_DIR}/scripts/first-login.sh"
    $SSH "$VM_USER@$ip" \
        "echo '${VM_PASS}' | sudo -S install -m 0755 /tmp/fedora-first-login.sh /usr/local/bin/fedora-first-login.sh"
    log "Sync: fedora-first-login.sh aktualisiert."

    # ── GDM stoppen — konfliktfreie dconf-Schreibung ──────────────────────────
    # ── Fehlende Pakete aus Repo-first-boot.sh nachinstallieren ──────────────
    # Falls USB-first-boot.sh neue Pakete nicht kennt, hier nachholen.
    # Muss VOR GDM-Stop passieren damit GNOME beim Neustart die Extensions findet.
    if ! $SSH "$VM_USER@$ip" "rpm -q gnome-shell-extension-dash-to-dock &>/dev/null" 2>/dev/null; then
        log "Nachinstallation: gnome-shell-extension-dash-to-dock ..."
        $SSH "$VM_USER@$ip" \
            "echo '${VM_PASS}' | sudo -S dnf install -y gnome-shell-extension-dash-to-dock 2>/dev/null" \
            && log "gnome-shell-extension-dash-to-dock installiert." \
            || warn "Installation fehlgeschlagen."
    fi

    # first-boot.sh installiert Extensions nachdem GNOME bereits läuft. Im Test
    # stoppen wir GDM vor first-login.sh: ohne laufende GNOME Shell gehen alle
    # dconf-Schreibungen direkt in die Datei — keine Race Conditions.
    # (Auf echter Hardware läuft first-boot vor dem ersten GDM-Start.)
    log "Stoppe GDM für konfliktfreie first-login Ausführung ..."
    $SSH "$VM_USER@$ip" \
        "echo '${VM_PASS}' | sudo -S systemctl stop gdm" 2>/dev/null || true
    sleep 3
    log "GDM gestoppt."

    # ── First-Login ausführen (Themes, Oh-My-Bash, GNOME Extensions) ─────────
    if [[ "$profile" == "theme-bash" ]]; then
        step "First-Login: Themes + Oh-My-Bash installieren"
        log "Starte fedora-first-login.sh als User '${VM_USER}' ..."
        $SSH "$VM_USER@$ip" \
            "bash /usr/local/bin/fedora-first-login.sh 2>&1" \
            | while IFS= read -r line; do log "  first-login: $line"; done || \
            warn "First-Login mit Fehler beendet — Logs prüfen"
        log "First-Login abgeschlossen."
        EXT_DCONF_AFTER=$($SSH "$VM_USER@$ip" \
            "dconf read /org/gnome/shell/enabled-extensions 2>/dev/null" 2>/dev/null || true)
        log "Extensions nach first-login (dconf): ${EXT_DCONF_AFTER}"
    fi

    # ── GDM wieder starten — GNOME liest frische dconf-Config ────────────────
    log "Starte GDM (Autologin mit neuer Config) ..."
    $SSH "$VM_USER@$ip" \
        "echo '${VM_PASS}' | sudo -S systemctl start gdm" 2>/dev/null || true
    # Warten bis GNOME-Session wieder läuft (Autologin + FEDORA-USB-Mount)
    local usb_path2=""
    local gdm_waited=0
    until [[ -n "$usb_path2" ]]; do
        sleep 5; gdm_waited=$((gdm_waited + 5))
        usb_path2=$($SSH "$VM_USER@$ip" \
            "findmnt -rno TARGET LABEL=FEDORA-USB 2>/dev/null" 2>/dev/null || true)
        [[ $gdm_waited -gt 120 ]] && { warn "GNOME Session nicht bereit nach 120s."; break; }
    done
    log "GNOME Session bereit (${gdm_waited}s)."

    # ── Screenshot NACHHER ────────────────────────────────────────────────────
    if [[ "$profile" == "theme-bash" ]]; then
        step "Screenshot: nach Provisioner"
        $SSH "$VM_USER@$ip" \
            'DISPLAY=:0 xdotool key Escape 2>/dev/null || true' 2>/dev/null || true
        sleep 1
        open_terminal_in_vm "$ip"
        sleep 4
        take_screenshot "2-after" "$profile"
    fi

    # ── Profil-spezifische Validierung ───────────────────────────────────────
    local test_passed=0

    if [[ "$profile" == "theme-bash" ]]; then
        # GUI-Profil: Theme + Extensions + Wallpaper prüfen
        step "Validierung: theme-bash"
        $SSH "$VM_USER@$ip" "
echo '  Installierte Komponenten:'
[ -f /var/lib/fedora-provision/first-boot.done ] && echo '  ✓ First-Boot'           || echo '  ✗ First-Boot fehlt'
[ -d \${HOME}/.config/gtk-4.0 ]                  && echo '  ✓ WhiteSur GTK'         || echo '  ✗ WhiteSur GTK fehlt'
[ -d \${HOME}/.local/share/icons/WhiteSur-dark ]  && echo '  ✓ WhiteSur Icons'       || echo '  ✗ WhiteSur Icons fehlen'
[ -d \${HOME}/.local/share/backgrounds/WhiteSur ] && echo '  ✓ WhiteSur Wallpapers'  || echo '  ✗ Wallpapers fehlen'
[ -d \${HOME}/.oh-my-bash ]                       && echo '  ✓ Oh-My-Bash'           || echo '  ✗ Oh-My-Bash fehlt'
sleep 3
wp=\$(dconf read /org/gnome/desktop/background/picture-uri 2>/dev/null)
[ -n \"\$wp\" ] && echo '  ✓ Wallpaper:' \$wp || echo '  ✗ Wallpaper nicht in dconf'
" 2>/dev/null || true
        # Extensions aus dem direkt-nach-first-login gespeicherten Wert prüfen
        echo "  Extensions (direkt nach first-login):"
        if echo "${EXT_DCONF_AFTER:-}" | grep -q 'dash-to-dock'; then
            echo "  ✓ dash-to-dock in dconf konfiguriert"
        else
            echo "  ✗ dash-to-dock fehlt (Hinweis: wirkt nach erstem echten GNOME-Start)"
        fi
        if echo "${EXT_DCONF_AFTER:-}" | grep -q 'dash-to-panel'; then
            echo "  ✗ dash-to-panel noch in dconf"
        else
            echo "  ✓ dash-to-panel aus dconf entfernt"
        fi
        test_passed=1
    fi

    if [[ "$profile" == "headless-vllm" ]]; then
        step "Validierung: headless-vllm"
        $SSH "$VM_USER@$ip" "
echo '  Installierte Komponenten:'
[ -f /var/lib/fedora-provision/first-boot.done ] \
    && echo '  ✓ First-Boot' || echo '  ✗ First-Boot fehlt'
command -v podman &>/dev/null \
    && echo '  ✓ Podman:' \$(podman --version) || echo '  ✗ Podman fehlt'
[ -f \${HOME}/.config/containers/systemd/vllm@.container ] \
    && echo '  ✓ Quadlet-Template: vllm@.container' || echo '  ✗ vllm@.container fehlt'
[ -f \${HOME}/.config/systemd/user/vllm-router.service ] \
    && echo '  ✓ Router-Unit: vllm-router.service' || echo '  ✗ vllm-router.service fehlt'
[ -f \${HOME}/.config/vllm-router/models.json ] \
    && echo '  ✓ Registry: models.json' || echo '  ✗ models.json fehlt'
systemctl --user is-enabled vllm-router.service 2>/dev/null | grep -q enabled \
    && echo '  ✓ vllm-router.service aktiviert' || echo '  ✗ vllm-router.service nicht aktiviert'
[ -f \${HOME}/.local/share/bitwig-agent/run_pipeline.sh ] \
    && echo '  ✓ Bitwig Agent Pipeline' || echo '  ✗ run_pipeline.sh fehlt'
[ -d \${HOME}/bitwig-input ]  && echo '  ✓ ~/bitwig-input/'  || echo '  ✗ ~/bitwig-input/ fehlt'
[ -d \${HOME}/bitwig-output ] && echo '  ✓ ~/bitwig-output/' || echo '  ✗ ~/bitwig-output/ fehlt'
rpm -q nvidia-container-toolkit &>/dev/null \
    && echo '  ✓ NVIDIA Container Toolkit' || echo '  ✗ nvidia-container-toolkit fehlt'
" 2>/dev/null || true
        test_passed=1
    fi

    # ── Test-Zusammenfassung ──────────────────────────────────────────────────
    local test_end; test_end=$(date '+%Y-%m-%d %H:%M:%S')
    echo ""
    echo "════════════════════════════════════════════════════"
    echo "  TEST-ZUSAMMENFASSUNG"
    echo "  Profil:    ${profile}"
    echo "  VM:        ${VM_NAME} (${ip})"
    echo "  Ende:      ${test_end}"
    if [[ "$test_passed" -eq 1 ]]; then
        echo "  Status:    ✓ BESTANDEN"
    else
        echo "  Status:    ✗ FEHLGESCHLAGEN"
    fi
    echo ""
    echo "  Screenshots:"
    ls -lh "${log_dir}/"*.png 2>/dev/null | awk '{print "  " $NF}' || true
    echo "  Log: ${log_file}"
    echo "════════════════════════════════════════════════════"
}

cmd_status() {
    step "VM Status: ${VM_NAME}"
    vm_exists || { warn "VM '${VM_NAME}' nicht vorhanden."; return; }

    virsh dominfo "$VM_NAME"
    echo ""

    if vm_is_running; then
        local ip; ip=$(get_vm_ip)
        if [[ -n "$ip" ]]; then
            log "IP-Adresse: $ip"
            log "SSH:        ssh ${VM_USER}@${ip}"
        else
            warn "Noch keine IP zugewiesen."
        fi
    fi

    echo ""
    log "Snapshots:"
    virsh snapshot-list "$VM_NAME" || true
}

cmd_ssh() {
    vm_is_running || die "VM '${VM_NAME}' läuft nicht."
    local ip; ip=$(get_vm_ip)
    [[ -n "$ip" ]] || die "Keine IP-Adresse."
    wait_for_ssh "$ip"
    $SSH "$VM_USER@$ip"
}

cmd_destroy() {
    step "VM löschen: ${VM_NAME}"
    vm_exists || { warn "VM '${VM_NAME}' nicht vorhanden."; return; }

    echo -e "${RED}ACHTUNG: VM '${VM_NAME}' und Disk-Image werden unwiderruflich gelöscht.${RESET}"
    read -r -p "Wirklich löschen? [y/N] " answer
    [[ "${answer,,}" == "y" ]] || { log "Abgebrochen."; exit 0; }

    vm_is_running && virsh destroy "$VM_NAME"
    virsh undefine "$VM_NAME" --snapshots-metadata --nvram 2>/dev/null || \
        virsh undefine "$VM_NAME" --snapshots-metadata

    [[ -f "$VM_DISK" ]]        && rm -f "$VM_DISK"        && log "Gelöscht: $VM_DISK"
    [[ -f "$OVMF_VARS_VM" ]]   && rm -f "$OVMF_VARS_VM"   && log "Gelöscht: $OVMF_VARS_VM"

    log "VM '${VM_NAME}' vollständig entfernt."
}

# ── Smoke-Test: USB-Stick Sync-Prüfung ────────────────────────────────────────
# $1: Kontext ("install" oder "test") — beeinflusst Fehlermeldung
# Delegiert die eigentliche Synchronisierung an scripts/sync-usb.sh.
cmd_smoke() {
    local context="${1:-test}"
    step "Smoke-Test: USB-Stick vs. Repo"

    # USB-Stick in laufender VM = hartes Gate — kein Start möglich
    local usb_vm
    usb_vm=$(virsh list --name 2>/dev/null | while read -r vm; do
        [[ -z "$vm" ]] && continue
        virsh dumpxml "$vm" 2>/dev/null | grep -q "${USB_VENDOR}.*${USB_PRODUCT}\|${USB_PRODUCT}.*${USB_VENDOR}" && echo "$vm"
    done | head -1 || true)

    if [[ -n "$usb_vm" ]]; then
        if [[ "$context" == "install" ]]; then
            die "USB-Stick ist an VM '${usb_vm}' weitergeleitet — Installation kann nicht starten. VM '${usb_vm}' stoppen und erneut versuchen."
        else
            die "USB-Stick ist an VM '${usb_vm}' weitergeleitet — Test kann nicht starten. VM '${usb_vm}' stoppen und erneut versuchen."
        fi
    fi

    local sync_script="${PROJECT_DIR}/scripts/sync-usb.sh"
    [[ -x "$sync_script" ]] || die "sync-usb.sh fehlt oder nicht ausführbar: ${sync_script}"

    if "$sync_script" --check &>/dev/null; then
        log "USB-Stick ist aktuell ✓"
        return 0
    fi

    # Drift erkannt — interaktive Sync starten (sync-usb.sh fragt selbst)
    "$sync_script" || die "USB-Stick veraltet — Test abgebrochen."
}

# ── Dispatch ───────────────────────────────────────────────────────────────────
COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    create)   cmd_create   ;;
    install)  cmd_install  ;;
    base)     cmd_base     ;;
    snapshot) cmd_snapshot ;;
    test)     cmd_smoke test; cmd_test "$@" ;;
    status)   cmd_status   ;;
    ssh)      cmd_ssh      ;;
    destroy)  cmd_destroy  ;;
    smoke)    cmd_smoke    ;;
    ""|--help|-h)
        grep '^#' "$0" | head -20 | sed 's/^# \?//'
        ;;
    *)
        die "Unbekannter Befehl: '$COMMAND'. Erlaubt: create | install | base | snapshot | test | status | ssh | destroy | smoke"
        ;;
esac
