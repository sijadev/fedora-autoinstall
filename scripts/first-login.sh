#!/usr/bin/env bash
# scripts/first-login.sh — User-level one-shot provisioning for the target user
#
# Runs via ~/.config/autostart/nobara-first-login.desktop on first GNOME login.
# Marker: ~/.local/share/nobara-provision/first-login.done
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

MARKER_DIR="${HOME}/.local/share/nobara-provision"
MARKER_FILE="${MARKER_DIR}/first-login.done"
LOG_FILE="${MARKER_DIR}/first-login.log"
ENV_FILE="/etc/nobara-provision.env"

mkdir -p "$MARKER_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

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
    rm -f "${HOME}/.config/autostart/nobara-first-login.desktop"
    exit 0
fi

# ── Load provisioning env ─────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

INSTALL_PROFILE="${NOBARA_INSTALL_PROFILE:-full}"
log "Install profile: ${INSTALL_PROFILE}"

TARGET_USER="${NOBARA_TARGET_USER:-${USER}}"
PYTORCH_VENV="${NOBARA_PYTORCH_VENV:-${HOME}/.venvs/ai}"
VLLM_VENV="${NOBARA_VLLM_VENV:-${HOME}/.venvs/bitwig-omni}"
VLLM_CUDA_VERSION="${NOBARA_VLLM_CUDA_VERSION:-13.2}"
VLLM_ARCH_LIST="${NOBARA_VLLM_ARCH_LIST:-12.0}"
VLLM_MODEL="${NOBARA_VLLM_MODEL:-Qwen/Qwen3-14B-AWQ}"
WS_GTK_ARGS="${NOBARA_WS_GTK_ARGS:-}"
WS_ICON_ARGS="${NOBARA_WS_ICON_ARGS:-}"
WS_WALL_ARGS="${NOBARA_WS_WALL_ARGS:-}"
OMB_THEME="${NOBARA_OMB_THEME:-modern}"

THEMES_DIR="${HOME}/.cache/nobara-themes-build"

# ── Profile: headless profiles skip all GUI steps ────────────────────────────
if [[ "$INSTALL_PROFILE" =~ ^(headless-vllm|vllm-only)$ ]]; then
    step "Headless profile (${INSTALL_PROFILE}) — skipping GUI provisioning"
    log "GNOME steps 1-5 skipped. Oh-My-Bash + AI steps will run via systemd service."
fi

# ── 1. Flatpak Extension Manager ──────────────────────────────────────────────
step "Flatpak Extension Manager"
if [[ "$INSTALL_PROFILE" =~ ^(headless-vllm|vllm-only)$ ]]; then
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
if [[ "$INSTALL_PROFILE" =~ ^(headless-vllm|vllm-only)$ ]]; then
    log "Skipped (headless profile)."
else
    EXTENSIONS=(
        "user-theme@gnome-shell-extensions.gcampax.github.com"
        "dash-to-dock@micxgx.gmail.com"
    )

    # Methode 1: gnome-extensions enable (nur wenn Extension in laufender Session geladen)
    # Methode 1a: gnome-extensions enable (nur wenn Extension in laufender Session geladen)
    if command -v gnome-extensions &>/dev/null; then
        for ext in "${EXTENSIONS[@]}"; do
            gnome-extensions enable "$ext" 2>/dev/null \
                && log "Enabled via gnome-extensions: $ext" \
                || true
        done
    fi

    # Methode 1b: DBUS — GNOME Shell direkt mitteilen Extensions zu laden
    dbus_addr=$(cat /proc/$(pgrep -u "$USER" gnome-shell 2>/dev/null | head -1)/environ 2>/dev/null \
        | tr '\0' '\n' | grep DBUS_SESSION_BUS_ADDRESS | cut -d= -f2- || true)
    if [[ -n "$dbus_addr" ]]; then
        for ext in "${EXTENSIONS[@]}"; do
            DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
                gdbus call --session \
                --dest org.gnome.Shell \
                --object-path /org/gnome/Shell \
                --method org.gnome.Shell.Extensions.EnableExtension \
                "$ext" 2>/dev/null \
                && log "Enabled via DBUS: $ext" \
                || true
        done
    fi

    # Methode 2: gsettings — fügt Extensions zur enabled-Liste hinzu (wirkt nach GNOME-Restart)
    if command -v gsettings &>/dev/null; then
        # GVariant @as [] bereinigen → nur echte Extension-IDs behalten
        current=$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo "[]")
        current=$(echo "$current" | grep -oP "'[^']+'" | tr -d "'" | grep -v '^$' || true)
        new_list=""
        for ext in "${EXTENSIONS[@]}"; do
            new_list+="'${ext}', "
            echo "$current" | grep -qF "$ext" || log "Füge zur enabled-Liste hinzu: $ext"
        done
        # Bestehende Extensions übernehmen (ohne Duplikate)
        while IFS= read -r e; do
            [[ -z "$e" ]] && continue
            found=0
            for ext in "${EXTENSIONS[@]}"; do [[ "$e" == "$ext" ]] && found=1; done
            [[ $found -eq 0 ]] && new_list+="'${e}', "
        done <<< "$current"
        new_list="[${new_list%, }]"
        gsettings set org.gnome.shell enabled-extensions "$new_list" 2>/dev/null \
            && log "Extensions in gsettings gesetzt: $new_list" \
            || warn "gsettings enabled-extensions fehlgeschlagen."
    fi
fi

# ── 3-5. WhiteSur themes ──────────────────────────────────────────────────
step "WhiteSur themes"
if [[ "$INSTALL_PROFILE" =~ ^(headless-vllm|vllm-only)$ ]]; then
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

    # Determine install arguments
    local args_var="$extra_args"
    if [[ -z "$args_var" ]]; then
        read -r -p "  Enter install.sh args for ${repo_name} (Enter to skip): " args_var || true
    fi

    # Run installer — cd into repo dir so relative paths (e.g. 'dist/') work
    local install_sh="${install_dir}/install.sh"
    if [[ ! -x "$install_sh" ]]; then
        WHITESUR_ERRORS+=("$repo_name: install.sh not found or not executable")
        return
    fi

    # shellcheck disable=SC2086
    if (cd "$install_dir" && bash "./install.sh" $install_dest_flag $args_var) 2>&1 | \
           while read -r l; do log "  install: $l"; done; then
        log "  $repo_name installed successfully."
    else
        WHITESUR_ERRORS+=("$repo_name: install.sh exited with error")
    fi
}

GTK_DEST="-d ${HOME}/.local/share/themes"
ICON_DEST="-d ${HOME}/.local/share/icons"

# GTK Theme — auf GNOME 49+ (libadwaita) nur -l -c Dark
# install.sh ohne -l erzeugt auf GNOME 49 keine Dateien (nur libadwaita wird unterstützt)
ws_install_theme \
    "WhiteSur-gtk-theme" \
    "https://github.com/vinceliuice/WhiteSur-gtk-theme.git" \
    "" \
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
git clone --depth=1 "https://github.com/vinceliuice/WhiteSur-wallpapers.git" "$walls_dir" 2>&1 | \
    while read -r l; do log "  git: $l"; done || { WHITESUR_ERRORS+=("WhiteSur-wallpapers: clone failed"); }
if [[ -x "${walls_dir}/install-gnome-backgrounds.sh" ]]; then
    mkdir -p "${HOME}/.local/share/gnome-background-properties"
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
if command -v gsettings &>/dev/null; then
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'      2>/dev/null || true
    gsettings set org.gnome.desktop.interface icon-theme   'WhiteSur-dark'    2>/dev/null || true
    gsettings set org.gnome.desktop.interface cursor-theme 'WhiteSur-cursors' 2>/dev/null || true
    # Wallpaper setzen (erste verfügbare WhiteSur-Datei)
    wallpaper=$(find "${HOME}/.local/share/backgrounds/WhiteSur" -name "*.jpg" -o -name "*.png" 2>/dev/null | head -1)
    [[ -n "$wallpaper" ]] && {
        gsettings set org.gnome.desktop.background picture-uri       "file://${wallpaper}" 2>/dev/null || true
        gsettings set org.gnome.desktop.background picture-uri-dark  "file://${wallpaper}" 2>/dev/null || true
        log "Wallpaper gesetzt: $wallpaper"
    }
    log "GNOME theme applied: WhiteSur libadwaita + WhiteSur-dark icons + WhiteSur-cursors"
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
    rm -f "${HOME}/.config/autostart/nobara-first-login.desktop"
    log "First-login provisioning complete (theme-bash). Log: $LOG_FILE"
    exit 0
fi

# ── Profile: headless-vllm skips direct vLLM (handled via Podman) ────────────
# vllm-only installs vLLM directly; headless-vllm relies on Podman pipeline.
if [[ "$INSTALL_PROFILE" == "headless-vllm" ]]; then
    step "headless-vllm profile — skipping direct vLLM (Podman pipeline handles it)"
    log "vLLM steps 7-11 skipped. Model download still runs to cache locally."
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

log "Installing HuggingFace CLI + autoawq in vLLM-Omni venv..."
"$VENV_VLLM/bin/pip" install --quiet \
    "huggingface_hub[cli]" \
    autoawq \
    || warn "HuggingFace CLI / autoawq install failed (non-fatal)."

log "HuggingFace CLI installed. Token will be prompted lazily on first download."

# ── 10. CUDA 13.2 toolchain for vLLM-Omni ────────────────────────────────────
step "CUDA ${VLLM_CUDA_VERSION} toolchain"

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

    # Try dnf first (Nobara/Fedora may have it)
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
    echo '# Nobara: CUDA toolchain for vLLM-Omni' >> "${VENV_VLLM}/bin/activate"
    echo "source \"${VENV_VLLM}/bin/activate.cuda\"" >> "${VENV_VLLM}/bin/activate"
fi
log "CUDA ${VLLM_CUDA_VERSION} environment configured for venv: $VENV_VLLM"

# ── 11. vLLM-Omni source build ────────────────────────────────────────────────
step "vLLM-Omni source build (CUDA ${VLLM_CUDA_VERSION}, sm${VLLM_ARCH_LIST//./})"

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
fi  # end: headless-vllm guard for steps 7-11
# ── 12. Download model ────────────────────────────────────────────────────────
step "Model download: ${VLLM_MODEL}"

if [[ "$INSTALL_PROFILE" == "headless-vllm" ]]; then
    log "Skipped (headless-vllm: model is downloaded inside the Podman container)."
else
log "Checking HuggingFace login..."
log "Downloading model: ${VLLM_MODEL} ..."
# Lazy token behavior: download will prompt for login only when required.
"$VENV_VLLM/bin/huggingface-cli" download "${VLLM_MODEL}" \
    --local-dir "${HOME}/.cache/huggingface/hub/${VLLM_MODEL//\//__}" \
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
rm -f "${HOME}/.config/autostart/nobara-first-login.desktop"
log "Autostart entry removed."
log "First-login provisioning finished. Log: $LOG_FILE"
