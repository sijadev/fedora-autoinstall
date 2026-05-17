#!/usr/bin/env bash
# scripts/first-login.sh — User-level one-shot provisioning for the target user
#
# Runs via ~/.config/autostart/fedora-first-login.desktop on first GNOME login.
# Marker: ~/.local/share/fedora-provision/first-login.done
#
# Tasks (in order):
#   1.  Flatpak Extension Manager
#   2.  Enable GNOME extensions
#   3.  WhiteSur GTK theme  (git clone / pull + install)
#   4.  WhiteSur Icon theme
#   5.  WhiteSur Wallpapers
#   6.  Oh My Bash (install + set theme)
#   7.  Python venv ~/.venvs/ai
#   8.  CUDA compat check → PyTorch install
#   9.  vLLM-Omni venv + HuggingFace CLI
#   10. CUDA 13.2 toolchain check/install
#   11. vLLM-Omni source build (sm120 / CUDA 13.2)
#   12. Download Qwen3-14B-AWQ model (lazy HF token)

set -euo pipefail

MARKER_DIR="${HOME}/.local/share/fedora-provision"
MARKER_FILE="${MARKER_DIR}/first-login.done"
LOG_FILE="${MARKER_DIR}/first-login.log"
ENV_FILE="/etc/fedora-provision.env"

mkdir -p "$MARKER_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

# Modell-Verzeichnis von ~/.cache getrennt — überlebt cache-Bereinigungen
export HF_HOME="${HOME}/.models/huggingface"
export TRANSFORMERS_CACHE="${HF_HOME}/hub"
mkdir -p "$HF_HOME"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; }
die()  { err "$*"; exit 1; }
step() { echo; echo "══ $* ══"; }

have_passwordless_sudo() {
    sudo -n true 2>/dev/null
}

# ── Idempotency guard ─────────────────────────────────────────────────────────
if [[ -f "$MARKER_FILE" ]]; then
    log "First-login already completed. Removing autostart entry."
    rm -f "${HOME}/.config/autostart/fedora-first-login.desktop"
    exit 0
fi

# ── Load provisioning env ─────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

INSTALL_PROFILE="${FEDORA_INSTALL_PROFILE:-full}"
log "Install profile: ${INSTALL_PROFILE}"

TARGET_USER="${FEDORA_TARGET_USER:-${USER}}"
PYTORCH_VENV="${FEDORA_PYTORCH_VENV:-${HOME}/.venvs/ai}"
VLLM_VENV="${FEDORA_VLLM_VENV:-${HOME}/.venvs/bitwig-omni}"
VLLM_CUDA_VERSION="${FEDORA_VLLM_CUDA_VERSION:-13.2}"
VLLM_ARCH_LIST="${FEDORA_VLLM_ARCH_LIST:-12.0}"
VLLM_MODEL="${FEDORA_VLLM_MODEL:-Qwen/Qwen3-14B-AWQ}"
WS_GTK_ARGS="${FEDORA_WS_GTK_ARGS:-}"
WS_ICON_ARGS="${FEDORA_WS_ICON_ARGS:-}"
WS_WALL_ARGS="${FEDORA_WS_WALL_ARGS:-}"
OMB_THEME="${FEDORA_OMB_THEME:-modern}"

THEMES_DIR="${HOME}/.cache/fedora-themes-build"

# ── Profile: headless profiles skip all GUI steps ────────────────────────────
if [[ "$INSTALL_PROFILE" =~ ^(headless-vllm)$ ]]; then
    step "Headless profile (${INSTALL_PROFILE}) — skipping GUI provisioning"
    log "GNOME steps 1-5 skipped. Oh-My-Bash + AI steps will run via systemd service."
fi

# ── 1. Flatpak Extension Manager ──────────────────────────────────────────────
step "Flatpak Extension Manager"
if [[ "$INSTALL_PROFILE" =~ ^(headless-vllm)$ ]]; then
    log "Skipped (headless profile)."
elif ! flatpak list --user 2>/dev/null | grep -q 'com.mattjakeman.ExtensionManager'; then
    log "Installing Extension Manager..."
    flatpak install --user --noninteractive flathub com.mattjakeman.ExtensionManager \
        || warn "Extension Manager install failed (non-fatal)."
else
    log "Extension Manager already installed."
fi

# ── 2. GNOME extensions aktivieren ───────────────────────────────────────────
step "GNOME extensions"
if [[ "$INSTALL_PROFILE" =~ ^(headless-vllm)$ ]]; then
    log "Skipped (headless profile)."
else
    EXTENSIONS=(
        "user-theme@gnome-shell-extensions.gcampax.github.com"
        "dash-to-dock@micxgx.gmail.com"
        "blur-my-shell@aunetx"
        "caffeine@patapon.info"
        "appindicatorsupport@rgcjonas.gmail.com"
    )
    # dash-to-panel kollidiert mit dash-to-dock — explizit ausgeschlossen
    CONFLICTING=("dash-to-panel@jderose9.github.com")

    # Nur gsettings schreiben — kein DBUS Enable/Disable.
    # DBUS EnableExtension triggert GNOME Shell zur sofortigen Neubewertung und
    # überschreibt dconf wieder wenn dash-to-dock nicht im laufenden Scan-Ergebnis
    # auftaucht (race condition bei frisch installierten System-Extensions).
    # gsettings-Wert wirkt sicher beim nächsten GNOME-Start.
    if command -v gsettings &>/dev/null; then
        current=$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo "[]")
        current=$(echo "$current" | grep -oP "'[^']+'" | tr -d "'" | grep -v '^$' || true)
        new_list=""
        for ext in "${EXTENSIONS[@]}"; do
            new_list+="'${ext}', "
            echo "$current" | grep -qF "$ext" || log "Füge zur enabled-Liste hinzu: $ext"
        done
        while IFS= read -r e; do
            [[ -z "$e" ]] && continue
            found=0
            for ext in "${EXTENSIONS[@]}"; do [[ "$e" == "$ext" ]] && found=1; done
            for ext in "${CONFLICTING[@]}"; do [[ "$e" == "$ext" ]] && found=1; done
            [[ $found -eq 0 ]] && new_list+="'${e}', "
        done <<< "$current"
        new_list="[${new_list%, }]"
        gsettings set org.gnome.shell enabled-extensions "$new_list" 2>/dev/null \
            && log "Extensions in gsettings gesetzt: $new_list" \
            || warn "gsettings enabled-extensions fehlgeschlagen."
    fi

    # ── Dash-to-Dock Konfiguration (macOS-Stil) ───────────────────────────────
    dtd() { gsettings set org.gnome.shell.extensions.dash-to-dock "$@" 2>/dev/null || true; }
    dtd dock-position            BOTTOM
    dtd dock-fixed               false
    dtd autohide                 true
    dtd intellihide              true
    dtd intellihide-mode         FOCUS_APPLICATION_WINDOWS
    dtd animation-time           0.15
    dtd require-pressure-to-show false
    dtd show-delay               0.1
    dtd hide-delay               0.2
    dtd transparency-mode        DYNAMIC
    dtd min-alpha                0.85
    dtd max-alpha                0.95
    dtd dash-max-icon-size       48
    dtd icon-size-fixed          false
    dtd running-indicator-style  DOTS
    dtd show-running             true
    dtd show-trash               true
    dtd show-mounts              true
    dtd show-apps-at-top         true
    dtd click-action             cycle-windows
    dtd scroll-action            switch-workspace
    dtd hot-keys                 true
    dtd isolate-workspaces       false
    dtd extend-height            false
    dtd disable-overview-on-startup true
    log "Dash-to-Dock konfiguriert (macOS-Stil)."

    # GNOME Shell: Overview beim Login nicht anzeigen → direkt zum Desktop
    gsettings set org.gnome.shell disable-overview-on-startup true 2>/dev/null || true
    log "GNOME Overview-on-startup deaktiviert."
fi

# ── 3-5. WhiteSur themes ──────────────────────────────────────────────────
step "WhiteSur themes"
if [[ "$INSTALL_PROFILE" =~ ^(headless-vllm)$ ]]; then
    log "Skipped (headless profile)."
else

WHITESUR_ERRORS=()

ws_install_theme() {
    local repo_name="$1"       # e.g. WhiteSur-gtk-theme
    local repo_url="$2"
    local install_dest_flag="$3"   # e.g. "-d ~/.local/share/themes"
    local extra_args="$4"
    local install_dir="${THEMES_DIR}/${repo_name}"

    log "WhiteSur: $repo_name"

    # Clone or pull
    if [[ -d "$install_dir/.git" ]]; then
        log "  Updating existing repo..."
        git -C "$install_dir" pull --ff-only 2>&1 | while read -r l; do log "  git: $l"; done || \
            warn "  git pull failed for $repo_name (continuing)."
    else
        mkdir -p "$THEMES_DIR"
        log "  Cloning $repo_url..."
        git clone --depth=1 "$repo_url" "$install_dir" 2>&1 | \
            while read -r l; do log "  git: $l"; done || {
                WHITESUR_ERRORS+=("$repo_name: git clone failed")
                return
            }
    fi

    local args_var="$extra_args"

    # Run installer — cd into repo dir so relative paths (e.g. 'dist/') work
    local install_sh="${install_dir}/install.sh"
    if [[ ! -x "$install_sh" ]]; then
        WHITESUR_ERRORS+=("$repo_name: install.sh not found or not executable")
        return
    fi

    # TERM=xterm: setterm -cursor off inside install.sh fails with TERM=dumb (SSH default), exiting non-zero
    # shellcheck disable=SC2086
    local _tmpout
    _tmpout=$(mktemp)
    if (cd "$install_dir" && TERM=xterm bash "./install.sh" $install_dest_flag $args_var) >"$_tmpout" 2>&1; then
        while IFS= read -r l; do log "  install: $l"; done < "$_tmpout"
        rm -f "$_tmpout"
        log "  $repo_name installed successfully."
    else
        while IFS= read -r l; do log "  install: $l"; done < "$_tmpout"
        rm -f "$_tmpout"
        WHITESUR_ERRORS+=("$repo_name: install.sh exited with error")
    fi
}

GTK_DEST="-d ${HOME}/.local/share/themes"
ICON_DEST="-d ${HOME}/.local/share/icons"

ws_install_theme \
    "WhiteSur-gtk-theme" \
    "https://github.com/vinceliuice/WhiteSur-gtk-theme.git" \
    "$GTK_DEST" \
    "-l -c Dark"

# Icon Theme (kein dark-Variant vorhanden — Standard WhiteSur blau)
ws_install_theme \
    "WhiteSur-icon-theme" \
    "https://github.com/vinceliuice/WhiteSur-icon-theme.git" \
    "$ICON_DEST" \
    ""

# Wallpapers — install-gnome-backgrounds.sh (nicht install.sh!)
walls_dir="${THEMES_DIR}/WhiteSur-wallpapers"
log "WhiteSur: WhiteSur-wallpapers"
mkdir -p "$THEMES_DIR"
# Sicherstellen dass gnome-background-properties ein Verzeichnis ist, nicht eine Datei
[[ -f "${HOME}/.local/share/gnome-background-properties" ]] && \
    rm -f "${HOME}/.local/share/gnome-background-properties"
mkdir -p "${HOME}/.local/share/gnome-background-properties"
if [[ -d "${walls_dir}/.git" ]]; then
    git -C "$walls_dir" pull --ff-only 2>&1 | while read -r l; do log "  git: $l"; done || \
        warn "  git pull failed for wallpapers (continuing)."
else
    git clone --depth=1 "https://github.com/vinceliuice/WhiteSur-wallpapers.git" "$walls_dir" 2>&1 | \
        while read -r l; do log "  git: $l"; done || { WHITESUR_ERRORS+=("WhiteSur-wallpapers: clone failed"); }
fi
if [[ -x "${walls_dir}/install-gnome-backgrounds.sh" ]]; then
    (cd "$walls_dir" && bash install-gnome-backgrounds.sh $WS_WALL_ARGS) 2>&1 | \
        while read -r l; do log "  install: $l"; done \
        && log "  WhiteSur-wallpapers installed successfully." \
        || WHITESUR_ERRORS+=("WhiteSur-wallpapers: install failed")
fi

# WhiteSur Cursor Theme
ws_install_theme \
    "WhiteSur-cursors" \
    "https://github.com/vinceliuice/WhiteSur-cursors.git" \
    "$ICON_DEST" \
    ""


# GNOME theme + Wallpaper anwenden
_dbus_addr="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
gs() { DBUS_SESSION_BUS_ADDRESS="$_dbus_addr" gsettings "$@" 2>/dev/null || true; }

if command -v gsettings &>/dev/null; then
    gs set org.gnome.desktop.interface color-scheme 'prefer-dark'
    gs set org.gnome.desktop.interface icon-theme   'WhiteSur-dark'
    gs set org.gnome.desktop.interface cursor-theme 'WhiteSur-cursors'
    wallpaper=$(find "${HOME}/.local/share/backgrounds/WhiteSur" -name "*.jpg" -o -name "*.png" 2>/dev/null | head -1)
    [[ -n "$wallpaper" ]] && {
        gs set org.gnome.desktop.background picture-uri      "file://${wallpaper}"
        gs set org.gnome.desktop.background picture-uri-dark "file://${wallpaper}"
        # dconf write als direktes Fallback — funktioniert ohne aktive GNOME-Session
        if command -v dconf &>/dev/null; then
            dconf write /org/gnome/desktop/background/picture-uri      "'file://${wallpaper}'" 2>/dev/null || true
            dconf write /org/gnome/desktop/background/picture-uri-dark "'file://${wallpaper}'" 2>/dev/null || true
        fi
        log "Wallpaper gesetzt: $wallpaper"
    }
    log "GNOME theme applied: WhiteSur libadwaita + WhiteSur-dark icons + WhiteSur-cursors"

    # ── GNOME/GTK display tweaks ──────────────────────────────────────────────
    gs set org.gnome.desktop.interface font-antialiasing  'rgba'
    gs set org.gnome.desktop.interface font-hinting       'slight'
    gs set org.gnome.desktop.interface enable-animations  true
    gs set org.gnome.desktop.interface clock-format       '24h'
    gs set org.gnome.desktop.sound     event-sounds       false
    log "GNOME tweaks applied: font-antialiasing=rgba, font-hinting=slight, clock=24h, bell=off."

    # ── Night Light (Blaulichtfilter ab 20:00 bis 07:00) ─────────────────────
    gs set org.gnome.settings-daemon.plugins.color night-light-enabled    true
    gs set org.gnome.settings-daemon.plugins.color night-light-schedule-automatic false
    gs set org.gnome.settings-daemon.plugins.color night-light-schedule-from 20.0
    gs set org.gnome.settings-daemon.plugins.color night-light-schedule-to   7.0
    gs set org.gnome.settings-daemon.plugins.color night-light-temperature  3500
    log "Night Light aktiviert: 20:00–07:00, 3500K."
fi

# Repos nach Installation entfernen — Theme-Dateien sind in ~/.local/share/ installiert
log "Theme-Repos gecacht: $THEMES_DIR (git pull bei nächstem Aufruf)"

fi  # end: WhiteSur themes headless guard

# ── 6. Oh My Bash ─────────────────────────────────────────────────────────────
step "Oh My Bash"

OMB_DIR="${HOME}/.oh-my-bash"
if [[ -d "$OMB_DIR" ]]; then
    log "Oh My Bash already installed."
else
    log "Installing Oh My Bash (unattended)..."
    bash <(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh) \
        --unattended \
        || warn "Oh My Bash install script failed (non-fatal)."
fi

# Set / correct theme in ~/.bashrc
if [[ -f "${HOME}/.bashrc" ]]; then
    if grep -q 'OSH_THEME=' "${HOME}/.bashrc"; then
        sed -i "s|^OSH_THEME=.*|OSH_THEME=\"${OMB_THEME}\"|" "${HOME}/.bashrc"
        log "Updated OSH_THEME to '${OMB_THEME}' in ~/.bashrc"
    else
        echo "OSH_THEME=\"${OMB_THEME}\"" >> "${HOME}/.bashrc"
        log "Appended OSH_THEME='${OMB_THEME}' to ~/.bashrc"
    fi
    # shellcheck source=/dev/null
    source "${HOME}/.bashrc" 2>/dev/null || true
fi

# ── Profile: theme-bash stops after Oh-My-Bash ───────────────────────────────
if [[ "$INSTALL_PROFILE" == "theme-bash" ]]; then
    step "theme-bash profile — skipping AI/vLLM provisioning"
    log "Steps 7-12 skipped (no GPU compute required for theme-bash)."
    touch "$MARKER_FILE"
    rm -f "${HOME}/.config/autostart/fedora-first-login.desktop"
    log "First-login provisioning complete (theme-bash). Log: $LOG_FILE"
    exit 0
fi

# ── 7. CUDA Toolchain (headless-vllm) ──────────────────────────────────────
if [[ "$INSTALL_PROFILE" =~ ^(headless-vllm|vllm-only)$ ]]; then
    step "CUDA Toolchain"
    
    if command -v nvcc &>/dev/null; then
        CUDA_VER=$(nvcc --version 2>/dev/null | grep -oP 'release \K[\d.]+' | head -1 || echo "unknown")
        log "CUDA already available: $CUDA_VER (nvcc found in PATH)"
    else
        # CUDA toolchain prüfen: /usr/local/cuda* oder /usr
        CUDA_HOME=""
        for cuda_dir in /usr/local/cuda-* /usr/local/cuda /usr; do
            if [[ -x "${cuda_dir}/bin/nvcc" ]]; then
                CUDA_HOME="$cuda_dir"
                break
            fi
        done
        
        if [[ -n "$CUDA_HOME" ]]; then
            export CUDA_HOME
            export PATH="${CUDA_HOME}/bin${PATH:+:$PATH}"
            export LD_LIBRARY_PATH="${CUDA_HOME}/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            log "CUDA Umgebung aus System-Installation: CUDA_HOME=${CUDA_HOME}"
            if command -v nvcc &>/dev/null; then
                CUDA_VER=$(nvcc --version | grep -oP 'release \K[\d.]+' | head -1 || echo "unknown")
                log "CUDA verified: $CUDA_VER"
            fi
        else
            warn "CUDA not found in system — User-Builds ohne CUDA-Unterstützung (non-fatal)."
        fi
    fi
fi

# ── Profile: headless-vllm / vllm-only — Multi-Model Router aktivieren ───────
if [[ "$INSTALL_PROFILE" =~ ^(headless-vllm|vllm-only)$ ]]; then
    step "vLLM Multi-Model Router"

    QUADLET_TPL="${HOME}/.config/containers/systemd/vllm@.container"
    ROUTER_UNIT="${HOME}/.config/systemd/user/vllm-router.service"
    REPO_DIR="/usr/local/share/fedora-autoinstall"

    if [[ ! -f "$QUADLET_TPL" || ! -f "$ROUTER_UNIT" ]]; then
        warn "Quadlet-Template oder Router-Unit fehlt — first-boot.sh lief ggf. noch nicht."
    else
        # Image vorab pullen (Custom-Build bevorzugt, sonst Upstream)
        VLLM_IMAGE="localhost/fedora-vllm:latest"
        if ! podman image exists "$VLLM_IMAGE" 2>/dev/null; then
            warn "Custom-Image '${VLLM_IMAGE}' fehlt — bauen mit:"
            warn "  ./scripts/podman-pipeline.sh --build-vllm"
        fi

        # Router-venv + Wrapper
        ROUTER_VENV="${HOME}/.venvs/vllm-router"
        if [[ ! -d "$ROUTER_VENV" ]]; then
            log "Erstelle Router-venv: $ROUTER_VENV"
            python3 -m venv "$ROUTER_VENV"
            "$ROUTER_VENV/bin/pip" install --quiet --upgrade pip
            "$ROUTER_VENV/bin/pip" install --quiet fastapi uvicorn httpx \
                || warn "Router-venv Pip-Install fehlgeschlagen."
        fi

        # Router-Script + Wrapper installieren
        mkdir -p "${HOME}/.local/bin" "${HOME}/.local/share/vllm-router"
        if [[ -f "${REPO_DIR}/scripts/vllm-router.py" ]]; then
            install -m 0644 "${REPO_DIR}/scripts/vllm-router.py" \
                "${HOME}/.local/share/vllm-router/vllm-router.py"
        fi
        cat > "${HOME}/.local/bin/vllm-router" <<WRAPEOF
#!/usr/bin/env bash
exec "${ROUTER_VENV}/bin/python" "${HOME}/.local/share/vllm-router/vllm-router.py"
WRAPEOF
        chmod 0755 "${HOME}/.local/bin/vllm-router"

        # Linger aktivieren, damit User-Services ohne aktive Session laufen
        if have_passwordless_sudo; then
            sudo loginctl enable-linger "$USER" 2>/dev/null \
                && log "Linger aktiviert (Services laufen ohne aktive Session)." \
                || warn "loginctl enable-linger fehlgeschlagen."
        fi

        systemctl --user daemon-reload
        systemctl --user enable --now vllm-router.service 2>/dev/null \
            && log "vllm-router.service aktiviert (Port 8000)." \
            || warn "vllm-router.service enable fehlgeschlagen."

        log "OpenAI-API: http://localhost:8000/v1"
        log "Registry:   ${HOME}/.config/vllm-router/models.json"
        log "Modelle:    curl http://localhost:8000/v1/models"
    fi
fi

# Entfernt: alte venv-basierte vLLM-Source-Builds (PyTorch, CUDA 13.2 toolchain,
# vLLM-Omni source build, Model-Download). vLLM läuft im Podman-Container
# (Containerfile.vllm), aktiviert via vllm-router.service + vllm@.container Template.

# ── Final report ──────────────────────────────────────────────────────────────
step "First-login provisioning complete"

if [[ -v WHITESUR_ERRORS ]] && [[ "${#WHITESUR_ERRORS[@]}" -gt 0 ]]; then
    warn "WhiteSur errors encountered:"
    for e in "${WHITESUR_ERRORS[@]}"; do
        warn "  - $e"
    done
fi

touch "$MARKER_FILE"
log "Marker written: $MARKER_FILE"

# Remove autostart entry — we're done
rm -f "${HOME}/.config/autostart/fedora-first-login.desktop"
log "Autostart entry removed."
log "First-login provisioning finished. Log: $LOG_FILE"
