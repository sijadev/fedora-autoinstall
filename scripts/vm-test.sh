#!/usr/bin/env bash
# scripts/vm-test.sh — VM-Test-Workflow für das Nobara Install Framework
#
# Befehle:
#   vm-test.sh create          VM anlegen (80 GB, UEFI, VirtIO, Ventoy USB-Passthrough)
#   vm-test.sh snapshot        Snapshot "base-nobara" nach erfolgreicher Installation anlegen
#   vm-test.sh test <profil>   Snapshot zurücksetzen + Provisioner ausführen
#                              Profil: theme-bash | vllm-only | headless-vllm
#   vm-test.sh status          VM-Status und IP anzeigen
#   vm-test.sh ssh             In laufende VM einloggen
#   vm-test.sh destroy         VM und Disk-Image löschen
#
# Voraussetzungen:
#   - virt-manager + libvirt installiert und libvirtd aktiv
#   - Ventoy USB-Stick eingesteckt (/dev/sda, LABEL=Ventoy)
#   - nobara-vm.ks auf dem Ventoy-Stick

set -euo pipefail

# ── Konfiguration ──────────────────────────────────────────────────────────────
VM_NAME="fedora43"
VM_RAM_MB=8192
VM_CPUS=4
VM_DISK_GB=80
VM_STORAGE_DIR="/home/sija/VMs"
VM_DISK="${VM_STORAGE_DIR}/${VM_NAME}.qcow2"
VM_SNAPSHOT="base-nobara"
VM_USER="sija"
VM_OS_VARIANT="fedora43"

OVMF_CODE="/usr/share/edk2/ovmf/OVMF_CODE.fd"
OVMF_VARS="/usr/share/edk2/ovmf/OVMF_VARS.fd"
OVMF_VARS_VM="${VM_STORAGE_DIR}/${VM_NAME}-OVMF_VARS.fd"

# Ventoy USB: Kingston DataTraveler (lsusb: 0930:6545)
# Wird zur Laufzeit neu ermittelt — nur Fallback hartcodiert
VENTOY_USB_VENDOR="0930"
VENTOY_USB_PRODUCT="6545"

# libvirt system URI — verhindert Verwechslung mit qemu:///session
export LIBVIRT_DEFAULT_URI="qemu:///system"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes"
SSH_TIMEOUT=120  # Sekunden bis VM SSH-bereit ist

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

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

# ── Hilfsfunktionen ────────────────────────────────────────────────────────────

vm_exists()     { virsh dominfo "$VM_NAME" &>/dev/null; }
vm_is_running() { virsh domstate "$VM_NAME" 2>/dev/null | grep -q "running"; }

snapshot_exists() {
    virsh snapshot-list "$VM_NAME" 2>/dev/null | grep -q "$VM_SNAPSHOT"
}

get_vm_ip() {
    virsh domifaddr "$VM_NAME" 2>/dev/null \
        | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1
}

wait_for_ssh() {
    local ip="$1"
    log "Warte auf SSH ($ip) ..."
    local elapsed=0
    until ssh $SSH_OPTS "$VM_USER@$ip" true 2>/dev/null; do
        sleep 3; elapsed=$((elapsed + 3))
        [[ $elapsed -gt $SSH_TIMEOUT ]] && die "SSH nicht erreichbar nach ${SSH_TIMEOUT}s"
        echo -n "."
    done
    echo ""
    log "SSH verbunden: $ip"
}

find_ventoy_usb() {
    # Ventoy-Stick per lsusb dynamisch ermitteln (Fallback auf gespeicherte IDs)
    local found
    found=$(lsusb | grep -i "kingston\|ventoy\|datatraveler" \
        | grep -oP 'ID \K[0-9a-f]{4}:[0-9a-f]{4}' | head -1 || true)

    if [[ -n "$found" ]]; then
        VENTOY_USB_VENDOR="${found%:*}"
        VENTOY_USB_PRODUCT="${found#*:}"
        log "Ventoy USB gefunden: ${VENTOY_USB_VENDOR}:${VENTOY_USB_PRODUCT}"
    else
        log "Verwende gespeicherte USB-IDs: ${VENTOY_USB_VENDOR}:${VENTOY_USB_PRODUCT}"
    fi
}

add_usb_passthrough() {
    find_ventoy_usb
    log "USB-Passthrough für Ventoy wird hinzugefügt ..."
    virsh attach-device "$VM_NAME" --persistent /dev/stdin <<XMLEOF
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source>
    <vendor id='0x${VENTOY_USB_VENDOR}'/>
    <product id='0x${VENTOY_USB_PRODUCT}'/>
  </source>
</hostdev>
XMLEOF
    log "USB-Passthrough aktiv: Ventoy-Stick sichtbar in VM"
}

# ── Befehle ────────────────────────────────────────────────────────────────────

cmd_create() {
    step "VM anlegen: ${VM_NAME}"

    vm_exists && die "VM '${VM_NAME}' existiert bereits. Erst 'vm-test.sh destroy' ausführen."
    [[ -f "$OVMF_CODE" ]] || die "OVMF nicht gefunden: $OVMF_CODE"

    # Storage-Verzeichnis anlegen und als libvirt-Pool registrieren
    mkdir -p "$VM_STORAGE_DIR"
    if ! virsh pool-info nobara-vms &>/dev/null; then
        virsh pool-define-as nobara-vms dir --target "$VM_STORAGE_DIR"
        virsh pool-build nobara-vms
        virsh pool-start nobara-vms
        virsh pool-autostart nobara-vms
        log "Storage-Pool 'nobara-vms' angelegt: $VM_STORAGE_DIR"
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

    # Ventoy USB-Passthrough hinzufügen
    add_usb_passthrough

    echo ""
    log "VM '${VM_NAME}' bereit."
    echo ""
    echo -e "  ${BOLD}Nächste Schritte:${RESET}"
    echo -e "  1. virt-manager öffnen → VM '${VM_NAME}' starten"
    echo -e "  2. Im GRUB-Menü ${BOLD}e${RESET} drücken, an die linux-Zeile anhängen:"
    echo -e "     ${CYAN}inst.ks=hd:LABEL=Ventoy:/kickstart/nobara-vm.ks${RESET}"
    echo -e "  3. Installation abwarten, VM startet neu"
    echo -e "  4. Dann: ${BOLD}./scripts/vm-test.sh snapshot${RESET}"
}

cmd_snapshot() {
    step "Snapshot anlegen: ${VM_SNAPSHOT}"

    vm_exists || die "VM '${VM_NAME}' nicht gefunden. Erst 'create' ausführen."
    vm_is_running && die "VM läuft noch. Bitte herunterfahren: virsh shutdown ${VM_NAME}"

    virsh snapshot-create-as "$VM_NAME" "$VM_SNAPSHOT" \
        --description "Frische Nobara 43 Installation — Reset-Punkt für Provisioner-Tests"

    log "Snapshot '${VM_SNAPSHOT}' angelegt."
    virsh snapshot-list "$VM_NAME"
}

cmd_test() {
    local profile="${1:-}"
    [[ -z "$profile" ]] && die "Profil fehlt. Erlaubt: theme-bash | vllm-only | headless-vllm"

    case "$profile" in
        theme-bash|vllm-only|headless-vllm) ;;
        *) die "Unbekanntes Profil: '$profile'. Erlaubt: theme-bash | vllm-only | headless-vllm" ;;
    esac

    step "Test: Profil '${profile}'"

    vm_exists        || die "VM '${VM_NAME}' nicht gefunden."
    snapshot_exists  || die "Snapshot '${VM_SNAPSHOT}' nicht gefunden. Erst 'snapshot' ausführen."

    # Snapshot zurücksetzen
    log "Setze Snapshot '${VM_SNAPSHOT}' zurück ..."
    vm_is_running && virsh shutdown "$VM_NAME" && sleep 3
    virsh snapshot-revert "$VM_NAME" "$VM_SNAPSHOT"
    log "Snapshot zurückgesetzt."

    # VM starten
    virsh start "$VM_NAME"
    log "VM gestartet."

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

    # Ventoy-Pfad in VM ermitteln (USB-Passthrough → automount)
    local ventoy_path
    ventoy_path=$(ssh $SSH_OPTS "$VM_USER@$ip" \
        "findmnt -rno TARGET LABEL=Ventoy 2>/dev/null || echo /run/media/${VM_USER}/Ventoy")
    log "Ventoy-Pfad in VM: $ventoy_path"

    # Provisioner ausführen
    log "Starte nobara-provision.sh --profile ${profile} ..."
    ssh $SSH_OPTS "$VM_USER@$ip" \
        "sudo bash '${ventoy_path}/nobara-provision.sh' --profile '${profile}' --run-now" \
        || warn "Provisioner abgebrochen oder mit Fehler beendet — Logs prüfen"

    echo ""
    log "Logs streamen (Ctrl+C zum Beenden):"
    ssh $SSH_OPTS "$VM_USER@$ip" "journalctl -fu nobara-first-boot.service" || true
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
    ssh $SSH_OPTS "$VM_USER@$ip"
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

# ── Dispatch ───────────────────────────────────────────────────────────────────
COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    create)   cmd_create   ;;
    snapshot) cmd_snapshot ;;
    test)     cmd_test "$@" ;;
    status)   cmd_status   ;;
    ssh)      cmd_ssh      ;;
    destroy)  cmd_destroy  ;;
    ""|--help|-h)
        grep '^#' "$0" | head -20 | sed 's/^# \?//'
        ;;
    *)
        die "Unbekannter Befehl: '$COMMAND'. Erlaubt: create | snapshot | test | status | ssh | destroy"
        ;;
esac
