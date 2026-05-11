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
    step "Screenshot: vor Provisioner"
    open_terminal_in_vm "$ip"
    take_screenshot "1-before" "$profile"

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
    step "Screenshot: nach Provisioner"
    # Activities schließen, neue Shell mit Oh-My-Bash öffnen
    $SSH "$VM_USER@$ip" \
        'DISPLAY=:0 xdotool key Escape 2>/dev/null || true' 2>/dev/null || true
    sleep 1
    open_terminal_in_vm "$ip"
    sleep 4  # Oh-My-Bash Prompt aufbauen lassen
    take_screenshot "2-after" "$profile"

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
        # AI-Profil: echter vLLM CPU-Server starten und mit curl testen
        step "Validierung: vLLM CPU-Server + curl-Test"
        local vllm_model="facebook/opt-125m"
        local vllm_port=8000
        local vllm_timeout=300  # 5 Minuten — CPU-Start dauert länger

        # vLLM installiert?
        if ! $SSH "$VM_USER@$ip" \
            "\${HOME}/.venvs/bitwig-omni/bin/python -c 'import vllm; print(\"vLLM\", vllm.__version__)'" 2>/dev/null; then
            warn "✗ vLLM nicht installiert — Test übersprungen"
        else
            log "vLLM gefunden. Starte Server mit CPU-Backend + ${vllm_model}..."

            # vLLM-Server im Hintergrund starten
            $SSH "$VM_USER@$ip" "
nohup \${HOME}/.venvs/bitwig-omni/bin/vllm serve ${vllm_model} \
    --device cpu \
    --dtype float32 \
    --port ${vllm_port} \
    --disable-log-requests \
    &>/tmp/vllm-server.log &
echo \$! > /tmp/vllm-server.pid
echo 'vLLM-Server gestartet (PID: '\$(cat /tmp/vllm-server.pid)')'
" 2>/dev/null || warn "vLLM-Start fehlgeschlagen"

            # Warten bis API antwortet (max 5 Min)
            log "Warte auf vLLM-API (max ${vllm_timeout}s)..."
            local waited=0
            local ready=0
            until [[ $ready -eq 1 || $waited -gt $vllm_timeout ]]; do
                sleep 5; waited=$((waited + 5))
                echo -n "."
                if $SSH "$VM_USER@$ip" \
                    "curl -sf http://localhost:${vllm_port}/v1/models &>/dev/null"; then
                    ready=1
                fi
            done
            echo ""

            if [[ $ready -eq 1 ]]; then
                log "vLLM-Server bereit nach ${waited}s"

                # GET /v1/models
                models_resp=$($SSH "$VM_USER@$ip" \
                    "curl -sf http://localhost:${vllm_port}/v1/models" 2>/dev/null || echo "")
                if echo "$models_resp" | grep -q '"object"'; then
                    log "✓ GET /v1/models:"
                    echo "$models_resp" | python3 -m json.tool 2>/dev/null | sed 's/^/    /' || echo "    $models_resp"
                    test_passed=1
                else
                    warn "✗ GET /v1/models — ungültige Antwort: $models_resp"
                fi

                # POST /v1/chat/completions
                log "POST /v1/chat/completions (Frage: 'Hello')..."
                chat_resp=$($SSH "$VM_USER@$ip" "
curl -sf http://localhost:${vllm_port}/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{\"model\":\"${vllm_model}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello, reply with one word.\"}],\"max_tokens\":10}' 2>/dev/null
" || echo "")
                if echo "$chat_resp" | grep -q '"choices"'; then
                    local reply
                    reply=$(echo "$chat_resp" | python3 -c \
                        "import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null || echo "?")
                    log "✓ POST /v1/chat/completions — Antwort: '${reply}'"
                else
                    warn "✗ POST /v1/chat/completions — ungültige Antwort"
                fi

                # vLLM-Server stoppen
                $SSH "$VM_USER@$ip" \
                    "kill \$(cat /tmp/vllm-server.pid 2>/dev/null) 2>/dev/null; rm -f /tmp/vllm-server.pid" \
                    2>/dev/null || true
                log "vLLM-Server gestoppt."
            else
                warn "✗ vLLM-Server nicht erreichbar nach ${vllm_timeout}s"
                $SSH "$VM_USER@$ip" "tail -20 /tmp/vllm-server.log 2>/dev/null" 2>/dev/null || true
            fi
        fi

        # Log auf ERROR-Zeilen prüfen
        log "Log-Analyse: first-login.log auf Fehler prüfen..."
        error_count=$($SSH "$VM_USER@$ip" \
            "grep -c '\[ERROR\]' \${HOME}/.local/share/nobara-provision/first-login.log 2>/dev/null; true" \
            2>/dev/null | tr -d '[:space:]' || echo "0")
        error_count="${error_count:-0}"
        if [[ "$error_count" -eq 0 ]]; then
            log "✓ Keine ERROR-Einträge im first-login.log"
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
