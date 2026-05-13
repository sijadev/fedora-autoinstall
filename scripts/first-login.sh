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

# ── Profile: headless-vllm / vllm-only — Podman vLLM Service aktivieren ──────
if [[ "$INSTALL_PROFILE" =~ ^(headless-vllm|vllm-only)$ ]]; then
    step "Podman vLLM Service"

    QUADLET_FILE="${HOME}/.config/containers/systemd/vllm.container"
    if [[ -f "$QUADLET_FILE" ]]; then
        systemctl --user daemon-reload 2>/dev/null || true

        # Image vorab pullen
        VLLM_IMAGE="fedora-vllm:latest"
        podman image exists "$VLLM_IMAGE" 2>/dev/null || VLLM_IMAGE="vllm/vllm-openai:latest"
        log "Pulling ${VLLM_IMAGE}..."
        podman pull "$VLLM_IMAGE" 2>&1 | while read -r l; do
            [[ "$l" == *"Copying"* || "$l" == *"Writing"* || "$l" == *"manifest"* ]] && log "  $l" || true
        done || warn "Image pull fehlgeschlagen — Service startet beim ersten Aufruf."

        for svc in vllm-audio.service vllm-agent.service; do
            systemctl --user enable "$svc" 2>/dev/null \
                && log "${svc} aktiviert." \
                || warn "${svc} enable fehlgeschlagen (non-fatal)."
        done

        log "Kimi-Audio  API: http://localhost:8000/v1  (Musik-Analyse)"
        log "Qwen3 Agent API: http://localhost:8001/v1  (Reasoning + LangGraph)"
        log "Starten: systemctl --user start vllm-audio.service vllm-agent.service"
    else
        warn "Kein Quadlet-File gefunden — first-boot.sh lief ggf. noch nicht."
    fi
fi

# ── 7. Python venv ~/.venvs/ai ────────────────────────────────────────────────
step "Python AI venv"
if [[ "$INSTALL_PROFILE" == "headless-vllm" ]]; then
    log "Skipped (headless-vllm uses Podman container for AI)."
else

VENV_AI="${PYTORCH_VENV/#\~/$HOME}"
if [[ -d "$VENV_AI" ]]; then
    log "venv already exists: $VENV_AI"
else
    log "Creating venv: $VENV_AI"
    mkdir -p "$(dirname "$VENV_AI")"
    python3 -m venv "$VENV_AI"
fi

# Upgrade pip in venv
"$VENV_AI/bin/pip" install --quiet --upgrade pip

# ── 8. CUDA compatibility → PyTorch ───────────────────────────────────────────
step "PyTorch installation"

detect_cuda_version() {
    local nvcc_path
    for p in /usr/local/cuda/bin/nvcc /usr/bin/nvcc; do
        [[ -x "$p" ]] && { "$p" --version | grep -oP 'release \K[\d.]+' | head -1; return; }
    done
    echo ""
}

resolve_pytorch_index() {
    local cuda_ver="$1"
    local major minor
    major=$(echo "$cuda_ver" | cut -d. -f1)
    minor=$(echo "$cuda_ver" | cut -d. -f2)
    local ver_int=$(( major * 100 + minor ))

    # Map CUDA version → PyTorch wheel index
    # Prefer the highest known cu-tag that is <= installed CUDA
    if   (( ver_int >= 1302 )); then echo "https://download.pytorch.org/whl/cu128"  # cu128 = CUDA 12.8+; best available for 13.x
    elif (( ver_int >= 1206 )); then echo "https://download.pytorch.org/whl/cu126"
    elif (( ver_int >= 1204 )); then echo "https://download.pytorch.org/whl/cu124"
    elif (( ver_int >= 1201 )); then echo "https://download.pytorch.org/whl/cu121"
    elif (( ver_int >= 1200 )); then echo "https://download.pytorch.org/whl/cu118"
    else  echo "https://download.pytorch.org/whl/cpu"
    fi
}

CUDA_VER=$(detect_cuda_version)
if [[ -z "$CUDA_VER" ]]; then
    warn "CUDA not detected; installing CPU-only PyTorch."
    PYTORCH_INDEX="https://download.pytorch.org/whl/cpu"
else
    log "Detected CUDA $CUDA_VER"
    PYTORCH_INDEX=$(resolve_pytorch_index "$CUDA_VER")
fi
log "PyTorch index: $PYTORCH_INDEX"

"$VENV_AI/bin/pip" install --quiet \
    torch torchvision torchaudio \
    --index-url "$PYTORCH_INDEX"

log "Verifying PyTorch..."
"$VENV_AI/bin/python3" -c "
import torch
print(f'  PyTorch {torch.__version__}')
print(f'  CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'  CUDA version: {torch.version.cuda}')
    print(f'  GPU: {torch.cuda.get_device_name(0)}')
" || warn "PyTorch verification script failed (non-fatal)."

# ── 9. vLLM-Omni venv + HuggingFace CLI ──────────────────────────────────────
step "vLLM-Omni venv"

VENV_VLLM="${VLLM_VENV/#\~/$HOME}"
if [[ -d "$VENV_VLLM" ]]; then
    log "vLLM-Omni venv already exists: $VENV_VLLM"
else
    log "Creating vLLM-Omni venv: $VENV_VLLM"
    mkdir -p "$(dirname "$VENV_VLLM")"
    python3 -m venv "$VENV_VLLM"
fi

"$VENV_VLLM/bin/pip" install --quiet --upgrade pip

if lspci -nn 2>/dev/null | grep -qi 'NVIDIA'; then
    log "Installing HuggingFace CLI + autoawq (GPU detected)..."
    "$VENV_VLLM/bin/pip" install --quiet "huggingface_hub" autoawq \
        || warn "HuggingFace CLI / autoawq install failed (non-fatal)."

    log "Installing vLLM (GPU, CUDA)..."
    "$VENV_VLLM/bin/pip" install --quiet vllm \
        || warn "vLLM GPU install failed (non-fatal)."
else
    log "Installing HuggingFace CLI + vLLM CPU-Backend (no GPU)..."
    "$VENV_VLLM/bin/pip" install --quiet "huggingface_hub" \
        || warn "HuggingFace CLI install failed (non-fatal)."

    # vLLM CPU-Backend — TMPDIR auf /home wegen tmpfs /tmp (begrenzt auf 50% RAM)
    mkdir -p "${HOME}/.cache/pip-tmp"
    TMPDIR="${HOME}/.cache/pip-tmp" VLLM_TARGET_DEVICE=cpu \
        "$VENV_VLLM/bin/pip" install --quiet --no-cache-dir vllm \
        || warn "vLLM CPU install failed (non-fatal)."

    # Kleines Testmodell für VM-Tests vorausholen (250MB)
    if "$VENV_VLLM/bin/python" -c "import vllm" 2>/dev/null; then
        log "vLLM CPU-Backend installiert. Lade Test-Modell facebook/opt-125m..."
        TMPDIR="${HOME}/.cache/pip-tmp" \
            "$VENV_VLLM/bin/python" -c "
from huggingface_hub import snapshot_download
snapshot_download('facebook/opt-125m', local_dir='${HOME}/.models/huggingface/hub/facebook--opt-125m')
print('Modell bereit: facebook/opt-125m')
" 2>/dev/null \
            && log "Test-Modell bereit: facebook/opt-125m" \
            || warn "Modell-Download fehlgeschlagen (non-fatal)."
    fi
fi

log "HuggingFace CLI + vLLM installiert."

# ── 10. CUDA 13.2 toolchain for vLLM-Omni ────────────────────────────────────
step "CUDA ${VLLM_CUDA_VERSION} toolchain"
if ! lspci -nn 2>/dev/null | grep -qi 'NVIDIA'; then
    warn "No NVIDIA GPU — skipping CUDA ${VLLM_CUDA_VERSION} toolchain (VM or non-NVIDIA system)."
else

find_cuda_version_path() {
    local target_ver="$1"
    # Check /usr/local/cuda-X.Y symlink/dir
    for p in "/usr/local/cuda-${target_ver}" "/usr/local/cuda"; do
        if [[ -x "${p}/bin/nvcc" ]]; then
            local found_ver
            found_ver=$("${p}/bin/nvcc" --version | grep -oP 'release \K[\d.]+' | head -1)
            if [[ "$found_ver" == "$target_ver"* ]]; then
                echo "$p"
                return 0
            fi
        fi
    done
    return 1
}

CUDA_132_PATH=""
if CUDA_132_PATH=$(find_cuda_version_path "$VLLM_CUDA_VERSION"); then
    log "CUDA ${VLLM_CUDA_VERSION} found at: $CUDA_132_PATH"
else
    log "CUDA ${VLLM_CUDA_VERSION} not found. Attempting installation..."

    # Try dnf first (Fedora/Fedora may have it)
    CUDA_MAJOR=$(echo "$VLLM_CUDA_VERSION" | cut -d. -f1)
    CUDA_MINOR=$(echo "$VLLM_CUDA_VERSION" | cut -d. -f2)
    CUDA_PKG="cuda-toolkit-${CUDA_MAJOR}-${CUDA_MINOR}"

    if have_passwordless_sudo && sudo dnf install -y "$CUDA_PKG" 2>/dev/null; then
        log "Installed $CUDA_PKG via dnf."
    else
        if ! have_passwordless_sudo; then
            die "CUDA ${VLLM_CUDA_VERSION} is missing and passwordless sudo is not available in first-login context. Install CUDA ${VLLM_CUDA_VERSION} manually or via first-boot, then re-run."
        fi
        # Fall back to NVIDIA runfile installer (side-by-side, no system CUDA overwrite)
        log "dnf package not available. Downloading NVIDIA CUDA ${VLLM_CUDA_VERSION} runfile..."
        RUNFILE_URL="https://developer.download.nvidia.com/compute/cuda/${VLLM_CUDA_VERSION}/local_installers/cuda_${VLLM_CUDA_VERSION}_linux.run"
        RUNFILE="/tmp/cuda-${VLLM_CUDA_VERSION}-installer.run"

        curl -L --retry 5 --progress-bar -o "$RUNFILE" "$RUNFILE_URL" \
            || die "Failed to download CUDA ${VLLM_CUDA_VERSION} runfile from NVIDIA."

        chmod +x "$RUNFILE"
        sudo "$RUNFILE" \
            --silent \
            --toolkit \
            --toolkitpath="/usr/local/cuda-${VLLM_CUDA_VERSION}" \
            --no-opengl-libs \
            --override \
            || die "CUDA ${VLLM_CUDA_VERSION} runfile installation failed."

        rm -f "$RUNFILE"
        log "CUDA ${VLLM_CUDA_VERSION} installed to /usr/local/cuda-${VLLM_CUDA_VERSION}"
    fi

    CUDA_132_PATH=$(find_cuda_version_path "$VLLM_CUDA_VERSION") \
        || die "CUDA ${VLLM_CUDA_VERSION} still not found after installation."
fi

# Write venv activation hook to set CUDA 13.2 env for this venv
VENV_ACTIVATE_HOOK="${VENV_VLLM}/bin/activate.d"
mkdir -p "$VENV_ACTIVATE_HOOK"
cat > "${VENV_VLLM}/bin/activate.cuda" <<HOOKEOF
# Auto-sourced for vLLM-Omni venv — sets CUDA ${VLLM_CUDA_VERSION} paths
export CUDA_HOME="${CUDA_132_PATH}"
export PATH="\${CUDA_HOME}/bin\${PATH:+:\$PATH}"
export LD_LIBRARY_PATH="\${CUDA_HOME}/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
HOOKEOF

# Inject into venv's activate script
if ! grep -q 'activate.cuda' "${VENV_VLLM}/bin/activate"; then
    echo '' >> "${VENV_VLLM}/bin/activate"
    echo '# Fedora: CUDA toolchain for vLLM-Omni' >> "${VENV_VLLM}/bin/activate"
    echo "source \"${VENV_VLLM}/bin/activate.cuda\"" >> "${VENV_VLLM}/bin/activate"
fi
log "CUDA ${VLLM_CUDA_VERSION} environment configured for venv: $VENV_VLLM"
fi  # end: NVIDIA GPU check for CUDA toolchain

# ── 11. vLLM-Omni source build ────────────────────────────────────────────────
step "vLLM-Omni source build (CUDA ${VLLM_CUDA_VERSION}, sm${VLLM_ARCH_LIST//./})"
if ! lspci -nn 2>/dev/null | grep -qi 'NVIDIA'; then
    warn "No NVIDIA GPU — skipping vLLM build (VM or non-NVIDIA system)."
else

VLLM_OMNI_SRC="${HOME}/.local/src/vllm-omni"

if [[ -d "${VLLM_OMNI_SRC}/.git" ]]; then
    log "vLLM-Omni source already cloned. Pulling latest..."
    git -C "$VLLM_OMNI_SRC" pull --ff-only || warn "git pull failed; using existing source."
else
    log "Cloning vLLM-Omni..."
    mkdir -p "$(dirname "$VLLM_OMNI_SRC")"
    git clone --depth=1 https://github.com/vllm-project/vllm.git "$VLLM_OMNI_SRC" \
        || die "Failed to clone vLLM-Omni."
fi

# Apply use_existing_torch.py to prevent overwriting the system PyTorch
if [[ -f "${VLLM_OMNI_SRC}/use_existing_torch.py" ]]; then
    log "Running use_existing_torch.py (protects external PyTorch installations)..."
    (cd "$VLLM_OMNI_SRC" && "$VENV_VLLM/bin/python3" use_existing_torch.py) \
        || warn "use_existing_torch.py failed (non-fatal, continuing build)."
fi

log "Building vLLM-Omni against CUDA ${VLLM_CUDA_VERSION} + sm${VLLM_ARCH_LIST//./}..."
(
    cd "$VLLM_OMNI_SRC"
    # Activate venv environment for build
    source "${VENV_VLLM}/bin/activate"
    source "${VENV_VLLM}/bin/activate.cuda"

    export TORCH_CUDA_ARCH_LIST="${VLLM_ARCH_LIST}"
    export CUDA_HOME="${CUDA_132_PATH}"
    export MAX_JOBS="${MAX_JOBS:-$(nproc)}"

    pip install --quiet --no-build-isolation . \
        || die "vLLM-Omni build failed."
)
log "vLLM-Omni build completed."
fi  # end: NVIDIA GPU check for vLLM build
fi  # end: headless-vllm guard for steps 7-11
# ── 12. Download model ────────────────────────────────────────────────────────
step "Model download: ${VLLM_MODEL}"

if [[ "$INSTALL_PROFILE" == "headless-vllm" ]]; then
    log "Skipped (headless-vllm: model is downloaded inside the Podman container)."
elif ! lspci -nn 2>/dev/null | grep -qi 'NVIDIA'; then
    log "Skipped: kein NVIDIA GPU — großes Modell (${VLLM_MODEL}) nur auf echter Hardware laden."
    log "Testmodell bereits bereit: facebook/opt-125m"
else
    log "Checking HuggingFace login..."
    log "Downloading model: ${VLLM_MODEL} ..."
    "$VENV_VLLM/bin/python" -c "
from huggingface_hub import snapshot_download
snapshot_download('${VLLM_MODEL}', local_dir='${HOME}/.models/huggingface/hub/${VLLM_MODEL//\//__}')
" \
        || warn "Model download failed or deferred (check HF token / disk space)."
fi

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
