#!/usr/bin/env bash
# fedora-provision.sh — Provisioniert ein bestehendes Fedora-System
#
# Dieses Skript wird vom Ventoy-USB-Stick aus im LAUFENDEN System gestartet.
# Es installiert KEIN neues OS — es richtet das gewählte Profil auf dem
# bereits installierten System ein und startet die Provisionierung.
#
# Nutzung:
#   sudo bash /run/media/$USER/Ventoy/fedora-provision.sh --profile theme-bash
#   sudo bash /run/media/$USER/Ventoy/fedora-provision.sh --profile headless-vllm
#
# Optionen:
#   --profile   theme-bash | headless-vllm  (erforderlich)
#   --user      Ziel-Benutzer (Standard: $SUDO_USER)
#   --run-now   first-boot sofort starten statt nur einrichten

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ── Argument-Parsing ──────────────────────────────────────────────────────────
PROFILE=""
TARGET_USER="${SUDO_USER:-${USER}}"
RUN_NOW=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)  PROFILE="$2";      shift 2 ;;
        --user)     TARGET_USER="$2";  shift 2 ;;
        --run-now)  RUN_NOW=1;         shift   ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) die "Unbekannte Option: $1" ;;
    esac
done

[[ -z "$PROFILE" ]] && die "--profile fehlt. Erlaubt: theme-bash | headless-vllm"
[[ "$EUID" -ne 0 ]] && die "Bitte als root ausführen: sudo bash $0 --profile $PROFILE"
id "$TARGET_USER" &>/dev/null || die "Benutzer nicht gefunden: $TARGET_USER"

USER_HOME="/home/${TARGET_USER}"

# ── Profil → Umgebungsvariablen ───────────────────────────────────────────────
step "Profil: ${PROFILE}  Benutzer: ${TARGET_USER}"

case "$PROFILE" in
    theme-bash)
        cat > /etc/fedora-provision.env <<ENVEOF
FEDORA_INSTALL_PROFILE="theme-bash"
FEDORA_TARGET_USER="${TARGET_USER}"
FEDORA_OMB_THEME="modern"
FEDORA_WS_GTK_ARGS="-c Dark"
FEDORA_WS_ICON_ARGS=""
FEDORA_WS_WALL_ARGS=""
FEDORA_CUDA_SOURCE="fedora"
FEDORA_KERNEL_SOURCE="bazzite"
ENVEOF
        ;;
    vllm-only)
        die "Profil 'vllm-only' wurde entfernt (keine GPU-Unterstützung ohne NVIDIA). Verwende 'headless-vllm'."
        ;;
    headless-vllm)
        cat > /etc/fedora-provision.env <<ENVEOF
FEDORA_INSTALL_PROFILE="headless-vllm"
FEDORA_TARGET_USER="${TARGET_USER}"
FEDORA_AUDIO_MODEL="moonshotai/Kimi-Audio-7B-Instruct"
FEDORA_AGENT_MODEL="Qwen/Qwen3-8B"
FEDORA_VLLM_ROUTER_PORT="8000"
FEDORA_VLLM_REGISTRY="\$HOME/.config/vllm-router/models.json"
FEDORA_OMB_THEME="modern"
FEDORA_CUDA_SOURCE="fedora"
FEDORA_KERNEL_SOURCE="bazzite"
ENVEOF
        ;;
    *)
        die "Unbekanntes Profil: '${PROFILE}'. Erlaubt: theme-bash | headless-vllm"
        ;;
esac

chmod 0644 /etc/fedora-provision.env
log "/etc/fedora-provision.env geschrieben"

# ── Scripts vom USB installieren ──────────────────────────────────────────────
step "Scripts installieren"

SCRIPTS_SRC="${SCRIPT_DIR}/scripts"
SYSTEMD_SRC="${SCRIPT_DIR}/systemd"

install_file() {
    local src="$1" dest="$2" mode="$3"
    if [[ -f "$src" ]]; then
        cp "$src" "$dest"
        chmod "$mode" "$dest"
        log "  $(basename "$dest")"
    else
        warn "  Nicht gefunden: $src"
    fi
}

install_file "${SCRIPTS_SRC}/first-boot.sh"  /usr/local/sbin/fedora-first-boot.sh  0750
install_file "${SCRIPTS_SRC}/first-login.sh" /usr/local/bin/fedora-first-login.sh  0755

# ── Systemd First-Boot Service ────────────────────────────────────────────────
step "Systemd Service"

if [[ -f "${SYSTEMD_SRC}/fedora-first-boot.service" ]]; then
    cp "${SYSTEMD_SRC}/fedora-first-boot.service" /etc/systemd/system/
else
    cat > /etc/systemd/system/fedora-first-boot.service <<'UNITEOF'
[Unit]
Description=Fedora First-Boot Provisioning (one-shot)
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/fedora-provision/first-boot.done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fedora-first-boot.sh
EnvironmentFile=-/etc/fedora-provision.env
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=3600
RemainAfterExit=yes
User=root

[Install]
WantedBy=multi-user.target
UNITEOF
fi

# Marker zurücksetzen damit first-boot für dieses Profil erneut läuft
rm -f /var/lib/fedora-provision/first-boot.done

systemctl daemon-reload
systemctl enable fedora-first-boot.service
log "fedora-first-boot.service aktiviert"

# ── First-Login: GUI vs. Headless ─────────────────────────────────────────────
step "First-Login einrichten"

# Alten first-login-Marker zurücksetzen
rm -f "${USER_HOME}/.local/share/fedora-provision/first-login.done"

if [[ "$PROFILE" =~ ^(theme-bash)$ ]]; then
    # GUI-Profile: GNOME-Autostart
    AUTOSTART_DIR="${USER_HOME}/.config/autostart"
    mkdir -p "$AUTOSTART_DIR"
    cat > "${AUTOSTART_DIR}/fedora-first-login.desktop" <<DESKTOPEOF
[Desktop Entry]
Type=Application
Name=Fedora First-Login Setup
Exec=/usr/local/bin/fedora-first-login.sh
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
DESKTOPEOF
    chown -R "${TARGET_USER}:${TARGET_USER}" "$AUTOSTART_DIR"
    log "GNOME-Autostart für '${TARGET_USER}' eingerichtet"
else
    # Headless-Profile: systemd User-Service
    cat > /etc/systemd/system/fedora-provision-user.service <<USRUNITEOF
[Unit]
Description=Fedora User Provisioning (${PROFILE})
After=fedora-first-boot.service network-online.target
Requires=fedora-first-boot.service
ConditionPathExists=!${USER_HOME}/.local/share/fedora-provision/first-login.done

[Service]
Type=oneshot
RemainAfterExit=yes
User=${TARGET_USER}
Group=${TARGET_USER}
Environment=HOME=${USER_HOME}
EnvironmentFile=-/etc/fedora-provision.env
ExecStart=/usr/local/bin/fedora-first-login.sh
StandardOutput=journal
StandardError=journal
TimeoutStartSec=7200

[Install]
WantedBy=multi-user.target
USRUNITEOF
    systemctl enable fedora-provision-user.service
    log "fedora-provision-user.service aktiviert"
fi

# ── Flatpak Flathub (GUI-Profile) ─────────────────────────────────────────────
if [[ "$PROFILE" =~ ^(theme-bash)$ ]]; then
    flatpak remote-add --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
fi

# ── Sofort starten (optional) ─────────────────────────────────────────────────
if [[ "$RUN_NOW" == "1" ]]; then
    step "First-Boot sofort starten"
    systemctl start fedora-first-boot.service
    log "first-boot gestartet — Logs: journalctl -fu fedora-first-boot.service"
else
    echo ""
    log "Einrichtung abgeschlossen."
    echo ""
    echo -e "  ${BOLD}Nächster Schritt:${RESET}"
    echo -e "    Neu starten  →  Provisionierung startet automatisch"
    echo ""
    echo -e "  ${BOLD}Oder sofort starten:${RESET}"
    echo -e "    sudo systemctl start fedora-first-boot.service"
    echo -e "    journalctl -fu fedora-first-boot.service"
fi
