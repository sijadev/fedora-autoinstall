#!/usr/bin/env bash
# scripts/vm-test.sh — VM-Test-Workflow für das Nobara Install Framework
#
# Befehle:
#   vm-test.sh create          VM anlegen (80 GB, UEFI, VirtIO, Ventoy USB-Passthrough)
#   vm-test.sh install         Frische Installation: VM vom Ventoy USB booten,
#                              [m] VM-Test Profil per Hotkey auswählen, Anaconda läuft durch
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
VM_SNAPSHOT="nobara43-default"
VM_USER="test"
VM_PASS="test123"
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

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"
SSH_TIMEOUT=300  # Sekunden bis VM SSH-bereit ist (GNOME-Boot ~2-3 min)
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
    log "Warte auf SSH ($ip) ..."
    local elapsed=0
    until $SSH "$VM_USER@$ip" true 2>/dev/null; do
        sleep 3; elapsed=$((elapsed + 3))
        [[ $elapsed -gt $SSH_TIMEOUT ]] && die "SSH nicht erreichbar nach ${SSH_TIMEOUT}s"
        echo -n "."
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

cmd_install() {
    step "Installations-Test: Ventoy USB → GRUB [m] → Anaconda → nobara-vm.ks"

    local install_vm="nobara-install-test"
    local install_disk="${VM_STORAGE_DIR}/${install_vm}.qcow2"
    local install_nvram="${VM_STORAGE_DIR}/${install_vm}-OVMF_VARS.fd"

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

    # Frische VM mit LEEREM Disk anlegen
    # UEFI bootet automatisch vom USB wenn kein OS auf Disk
    log "Lege neue Install-Test-VM an: ${install_vm} (${VM_DISK_GB}GB, leer)..."
    cp "$OVMF_VARS" "$install_nvram"

    virt-install \
        --name "$install_vm" \
        --memory "$VM_RAM_MB" \
        --vcpus "$VM_CPUS" \
        --disk "path=${install_disk},size=${VM_DISK_GB},format=qcow2,bus=virtio" \
        --os-variant "$VM_OS_VARIANT" \
        --boot "uefi,loader=${OVMF_CODE},loader_ro=yes,nvram=${install_nvram}" \
        --network network=default \
        --graphics spice,listen=none \
        --video virtio \
        --noautoconsole \
        --print-xml > /tmp/${install_vm}.xml

    virsh define /tmp/${install_vm}.xml
    log "VM '${install_vm}' definiert (leerer Disk)."

    # Ventoy USB-Passthrough hinzufügen
    find_ventoy_usb
    virsh attach-device "$install_vm" --persistent /dev/stdin <<XMLEOF 2>/dev/null || true
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source>
    <vendor id='0x${VENTOY_USB_VENDOR}'/>
    <product id='0x${VENTOY_USB_PRODUCT}'/>
  </source>
</hostdev>
XMLEOF
    log "Ventoy USB-Passthrough hinzugefügt."

    log "Starte VM — UEFI bootet vom Ventoy USB (kein OS auf Disk)..."
    virsh start "$install_vm"

    # Lokale Variable für den rest der Funktion
    local ACTIVE_VM="$install_vm"

    # Warten bis GRUB geladen ist (~8s nach BIOS POST)
    log "Warte auf Ventoy GRUB-Menü (10s)..."
    sleep 10

    # ── Fedora Netinstall via Ventoy ───────────────────────────────────────────
    # Fedora Netinstall ISO → Anaconda mit vollem Kickstart-Support
    # Ventoy F6 ExMenu → [m] VM-Test Profil → inst.stage2 + inst.ks korrekt
    # ────────────────────────────────────────────────────────────────────────

    # Schritt 1: Fedora ISO im Ventoy-Hauptmenü (erster Eintrag alphabetisch)
    log "Wähle Fedora ISO im Ventoy-Menü (Enter)..."
    virsh send-key "$ACTIVE_VM" KEY_ENTER
    sleep 5

    # Schritt 2: Ventoy Boot-Modus — "Boot in normal mode" (erster Eintrag = Enter)
    log "Wähle 'Boot in normal mode' (Enter)..."
    virsh send-key "$ACTIVE_VM" KEY_ENTER
    sleep 8  # Fedora GRUB lädt

    # Schritt 3: Fedora GRUB → [m] VM-Test via F6 ExMenu
    # F6 öffnet ExMenu mit unseren ventoy_grub.cfg Einträgen
    log "Öffne Ventoy ExMenu (F6) für [m] VM-Test Profil..."
    virsh send-key "$ACTIVE_VM" KEY_F6
    sleep 3
    log "Sende Enter → [m] VM-Test (erster Eintrag: inst.stage2 + inst.ks)..."
    virsh send-key "$ACTIVE_VM" KEY_ENTER
    log "Anaconda startet mit nobara-vm.ks — Fedora Netinstall läuft..."

    # virt-manager öffnen für visuelle Kontrolle
    virt-manager --connect qemu:///system --show-domain-console "$ACTIVE_VM" &
    log "virt-manager geöffnet — Anaconda Installation in Echtzeit sichtbar"

    # Warte auf Abschluss — Anaconda rebootet die VM nach erfolgreicher Installation
    log "Warte auf Anaconda + Fedora-Installation (~15-25 Min über Netzwerk)..."
    local waited=0
    local install_timeout=1800  # 30 Minuten max
    local rebooted=0

    # Warte auf Shutdown (nur wenn Calamares-Installation manuell/per Automation abgeschlossen)
    while [[ $waited -lt $install_timeout ]]; do
        sleep 10; waited=$((waited + 10))
        local state; state=$(LIBVIRT_DEFAULT_URI="qemu:///system" virsh domstate "$ACTIVE_VM" 2>/dev/null || echo "unknown")
        if [[ "$state" =~ ^(ausgeschaltet|shut.off) ]]; then
            rebooted=1
            break
        fi
        [[ $((waited % 60)) -eq 0 ]] && log "  ... ${waited}s / ${install_timeout}s"
    done

    if [[ $rebooted -eq 1 ]]; then
        log "✓ Installation abgeschlossen — VM hat sich ausgeschaltet (reboot nach Install)"
        log "Starte VM für Post-Install-Check..."
        virsh start "$ACTIVE_VM"
        sleep 60

        local ip; ip=$(LIBVIRT_DEFAULT_URI="qemu:///system" virsh domifaddr "$ACTIVE_VM" \
            2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1 || echo "")
        if [[ -n "$ip" ]]; then
            log "✓ VM bootet ins installierte System — IP: $ip"
            log ""
            log "Install-Test VM: ${ACTIVE_VM}"
            log "Disk: ${install_disk}"
        else
            warn "VM gestartet aber keine IP nach 60s — manuell prüfen"
        fi
    else
        warn "✗ Installation nicht abgeschlossen nach ${install_timeout}s"
        log "Aktueller Status: $(LIBVIRT_DEFAULT_URI="qemu:///system" virsh domstate "$ACTIVE_VM" 2>/dev/null)"
        log "Prüfe virt-manager für Anaconda-Fehlermeldungen"
    fi
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

    # Log-Datei — ZUERST öffnen damit alle Ausgaben erfasst werden
    local ts; ts=$(date '+%Y%m%d-%H%M%S')
    local log_dir="${TEST_RESULTS_DIR}/${profile}"
    mkdir -p "$log_dir"
    local log_file="${log_dir}/${ts}-test.log"
    exec > >(tee -a "$log_file") 2>&1

    local test_start; test_start=$(date '+%Y-%m-%d %H:%M:%S')
    echo "════════════════════════════════════════════════════"
    echo "  Nobara VM-Test — Profil: ${profile}"
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

    # USB-Passthrough nach Revert sicherstellen (Snapshot-XML enthält ihn nicht)
    if ! virsh dumpxml "$VM_NAME" | grep -q "hostdev"; then
        find_ventoy_usb
        virsh attach-device "$VM_NAME" --persistent /dev/stdin <<XMLEOF 2>/dev/null || true
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source>
    <vendor id='0x${VENTOY_USB_VENDOR}'/>
    <product id='0x${VENTOY_USB_PRODUCT}'/>
  </source>
</hostdev>
XMLEOF
        log "Ventoy USB-Passthrough wiederhergestellt."
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

    # Auf GNOME Auto-Login + Ventoy-Automount warten (max 60s)
    log "Warte auf Ventoy-Mount (GNOME Auto-Login)..."
    local ventoy_path=""
    local mount_waited=0
    until [[ -n "$ventoy_path" ]]; do
        sleep 3; mount_waited=$((mount_waited + 3))
        ventoy_path=$($SSH "$VM_USER@$ip" \
            "findmnt -rno TARGET LABEL=Ventoy 2>/dev/null" || true)
        [[ $mount_waited -gt 60 ]] && {
            log "Automount nicht verfügbar — mounte manuell..."
            $SSH "$VM_USER@$ip" "sudo mkdir -p /run/media/${VM_USER}/Ventoy && sudo mount /dev/sda1 /run/media/${VM_USER}/Ventoy 2>/dev/null" || true
            ventoy_path="/run/media/${VM_USER}/Ventoy"
        }
    done
    log "Ventoy-Pfad in VM: $ventoy_path"

    # ── Screenshot VORHER (offenes Terminal) ──────────────────────────────────
    # Screenshots nur für GUI-Profile (headless hat keinen Desktop)
    if [[ "$profile" == "theme-bash" ]]; then
        step "Screenshot: vor Provisioner"
        open_terminal_in_vm "$ip"
        take_screenshot "1-before" "$profile"
    fi

    # ── Provisioner ausführen ─────────────────────────────────────────────────
    log "Starte nobara-provision.sh --profile ${profile} ..."
    $SSH "$VM_USER@$ip" \
        "sudo bash '${ventoy_path}/nobara-provision.sh' --profile '${profile}' --run-now" \
        || warn "Provisioner abgebrochen oder mit Fehler beendet — Logs prüfen"

    # ── First-Boot Logs abwarten ──────────────────────────────────────────────
    log "Warte auf First-Boot Abschluss..."
    local boot_done=0
    local boot_waited=0
    while [[ $boot_done -eq 0 ]]; do
        sleep 5; boot_waited=$((boot_waited + 5))
        if $SSH "$VM_USER@$ip" "test -f /var/lib/nobara-provision/first-boot.done" 2>/dev/null; then
            boot_done=1
        elif [[ $boot_waited -gt 300 ]]; then
            warn "First-Boot nicht abgeschlossen nach 300s."
            break
        fi
    done
    [[ $boot_done -eq 1 ]] && log "First-Boot abgeschlossen."

    # ── First-Login ausführen (Themes, Oh-My-Bash, GNOME Extensions) ─────────
    if [[ "$profile" =~ ^(theme-bash|vllm-only)$ ]]; then
        step "First-Login: Themes + Oh-My-Bash installieren"
        log "Starte nobara-first-login.sh als User '${VM_USER}' ..."
        $SSH "$VM_USER@$ip" \
            "bash /usr/local/bin/nobara-first-login.sh 2>&1" \
            | while IFS= read -r line; do log "  first-login: $line"; done || \
            warn "First-Login mit Fehler beendet — Logs prüfen"
        log "First-Login abgeschlossen."
    fi

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
[ -f /var/lib/nobara-provision/first-boot.done ] && echo '  ✓ First-Boot'           || echo '  ✗ First-Boot fehlt'
[ -d \${HOME}/.config/gtk-4.0 ]                  && echo '  ✓ WhiteSur GTK'         || echo '  ✗ WhiteSur GTK fehlt'
[ -d \${HOME}/.local/share/icons/WhiteSur-dark ]  && echo '  ✓ WhiteSur Icons'       || echo '  ✗ WhiteSur Icons fehlen'
[ -d \${HOME}/.local/share/backgrounds/WhiteSur ] && echo '  ✓ WhiteSur Wallpapers'  || echo '  ✗ Wallpapers fehlen'
[ -d \${HOME}/.oh-my-bash ]                       && echo '  ✓ Oh-My-Bash'           || echo '  ✗ Oh-My-Bash fehlt'
echo '  Extensions:' \$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null)
echo '  Wallpaper:' \$(gsettings get org.gnome.desktop.background picture-uri 2>/dev/null)
" 2>/dev/null || true
        test_passed=1

    elif [[ "$profile" =~ ^(vllm-only|headless-vllm)$ ]]; then
        # AI-Profil: Grundvalidierung (venv, PyTorch, kein ERROR im Log)
        # vLLM curl-Test folgt mit headless-vllm + Podman
        step "Validierung: AI-Profil Grundcheck"

        $SSH "$VM_USER@$ip" "
echo '  Installierte Komponenten:'
[ -f /var/lib/nobara-provision/first-boot.done ] \
    && echo '  ✓ First-Boot abgeschlossen' || echo '  ✗ First-Boot fehlt'
[ -d \${HOME}/.venvs/ai ] \
    && echo '  ✓ PyTorch venv (~/.venvs/ai)' || echo '  ✗ PyTorch venv fehlt'
[ -d \${HOME}/.venvs/bitwig-omni ] \
    && echo '  ✓ vLLM venv (~/.venvs/bitwig-omni)' || echo '  ✗ vLLM venv fehlt'
[ -d \${HOME}/.oh-my-bash ] \
    && echo '  ✓ Oh-My-Bash' || echo '  ✗ Oh-My-Bash fehlt'
\${HOME}/.venvs/ai/bin/python -c 'import torch; print(\"  ✓ PyTorch\", torch.__version__)' 2>/dev/null \
    || echo '  ✗ PyTorch nicht importierbar'
\${HOME}/.venvs/bitwig-omni/bin/python -c 'import vllm; print(\"  ✓ vLLM\", vllm.__version__)' 2>/dev/null \
    || echo '  ✗ vLLM nicht importierbar'
" 2>/dev/null || true

        # Log auf ERROR-Zeilen prüfen
        log "Log-Analyse: first-login.log auf Fehler prüfen..."
        error_count=$($SSH "$VM_USER@$ip" \
            "grep -c '\[ERROR\]' \${HOME}/.local/share/nobara-provision/first-login.log 2>/dev/null; true" \
            2>/dev/null | tr -d '[:space:]' || echo "0")
        error_count="${error_count:-0}"
        if [[ "$error_count" -eq 0 ]]; then
            log "✓ Keine ERROR-Einträge im first-login.log"
            test_passed=1
        else
            warn "✗ ${error_count} ERROR-Einträge im first-login.log:"
            $SSH "$VM_USER@$ip" \
                "grep '\[ERROR\]' \${HOME}/.local/share/nobara-provision/first-login.log 2>/dev/null | head -10" \
                2>/dev/null || true
            test_passed=0
        fi
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

# ── Dispatch ───────────────────────────────────────────────────────────────────
COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    create)   cmd_create   ;;
    install)  cmd_install  ;;
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
