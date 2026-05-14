# ── common-post.inc ───────────────────────────────────────────────────────────
# Shared %post block — included by all Fedora Kickstart profiles.
# Each profile KS writes /etc/fedora-provision.env BEFORE this %include.
#
# SYNC NOTE: The scripts embedded here must match scripts/first-boot.sh and
#            scripts/first-login.sh (with profile-aware logic). Update both
#            when making changes.
# ─────────────────────────────────────────────────────────────────────────────

%post --log=/root/ks-common-post.log

set -euo pipefail

# ── Read profile (written by profile-specific %post before this %include) ─────
source /etc/fedora-provision.env 2>/dev/null || true
INSTALL_PROFILE="${FEDORA_INSTALL_PROFILE:-full}"
TARGET_USER="${FEDORA_TARGET_USER:-sija}"
USER_HOME="/home/${TARGET_USER}"

echo "[common-post] FEDORA_INSTALL_PROFILE=${INSTALL_PROFILE}"

# ── Btrfs mount options: compress=zstd:1 + noatime ───────────────────────────
if grep -q 'btrfs' /etc/fstab 2>/dev/null; then
    sed -i '/\sbtrfs\s/ s/defaults/defaults,compress=zstd:1,noatime/' /etc/fstab
fi

# ── Write first-boot script ───────────────────────────────────────────────────
cat > /usr/local/sbin/fedora-first-boot.sh <<'FBEOF'
#!/usr/bin/env bash
# fedora-first-boot.sh — System-wide one-shot provisioning (runs as root via systemd)
set -euo pipefail

MARKER_DIR="/var/lib/fedora-provision"
MARKER_FILE="$MARKER_DIR/first-boot.done"
LOG_FILE="/var/log/fedora-first-boot.log"
ENV_FILE="/etc/fedora-provision.env"
CUDA_ENV_FILE="/etc/profile.d/cuda.sh"

exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; }
die()  { err "$*"; exit 1; }
step() { echo; echo "══ $* ══"; }

if [[ -f "$MARKER_FILE" ]]; then
    log "First-boot already completed. Skipping."
    exit 0
fi
mkdir -p "$MARKER_DIR"

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
INSTALL_PROFILE="${FEDORA_INSTALL_PROFILE:-full}"
log "Install profile: ${INSTALL_PROFILE}"

# ── 1. System-Update ──────────────────────────────────────────────────────────
step "System-Update"
dnf upgrade -y || die "dnf upgrade failed."

# ── 2. NVIDIA Open Driver ─────────────────────────────────────────────────────
step "NVIDIA Open Driver update"

check_nvidia_open_compat() {
    if ! command -v lspci &>/dev/null; then warn "lspci not available."; return 0; fi
    local gpu_info
    gpu_info=$(lspci -nn | grep -i 'NVIDIA' || true)
    if [[ -z "$gpu_info" ]]; then
        warn "No NVIDIA GPU detected (VM or non-NVIDIA system) — skipping NVIDIA driver."
        return 1
    fi
    if echo "$gpu_info" | grep -qiE 'GP10[0-9]|GP1[0-9]{2}'; then
        die "NVIDIA Pascal GPU: Open Driver requires Turing or newer."
    fi
    log "NVIDIA GPU (Open Driver compatible): $gpu_info"
}

if check_nvidia_open_compat; then
    dnf install -y kernel-devel kernel-headers akmod-nvidia-open xorg-x11-drv-nvidia-cuda \
        || die "NVIDIA Open Driver installation failed."
    if command -v akmods &>/dev/null; then
        akmods --force || die "akmods failed."
    fi
    log "NVIDIA Open Driver installed."
fi  # end: check_nvidia_open_compat

# ── 3. CUDA installation ──────────────────────────────────────────────────────
step "CUDA installation"

if [[ "$INSTALL_PROFILE" == "theme-bash" ]]; then
    log "Profile '${INSTALL_PROFILE}' — CUDA not required. Skipping."
else

CUDA_SOURCE="${FEDORA_CUDA_SOURCE:-fedora}"

install_cuda_fedora() {
    dnf install -y cuda cuda-toolkit cuda-devel \
        || die "CUDA from Fedora/Fedora repos failed."
}

install_cuda_nvidia_repo() {
    local arch; arch=$(uname -m)
    local repo_url="https://developer.download.nvidia.com/compute/cuda/repos/rhel9/${arch}/cuda-rhel9.repo"
    if ! dnf config-manager --add-repo "$repo_url" 2>/dev/null; then
        dnf config-manager addrepo --from-repofile="$repo_url" \
            || die "Failed to add NVIDIA CUDA repo."
    fi
    dnf install -y cuda-toolkit cuda-devel || die "CUDA from NVIDIA repo failed."
}

case "$CUDA_SOURCE" in
    fedora|fedora) install_cuda_fedora   ;;
    nvidia)        install_cuda_nvidia_repo ;;
    *)             die "Unknown CUDA source: $CUDA_SOURCE" ;;
esac

CUDA_HOME_DETECTED=""
for candidate in /usr/local/cuda /usr/local/cuda-*; do
    [[ -x "${candidate}/bin/nvcc" ]] && { CUDA_HOME_DETECTED="$candidate"; break; }
done
[[ -n "$CUDA_HOME_DETECTED" ]] || die "nvcc not found after CUDA install."
log "CUDA at: $CUDA_HOME_DETECTED"

# ── 4. CUDA environment variables ────────────────────────────────────────────
step "CUDA environment variables"
cat > "$CUDA_ENV_FILE" <<ENVEOF
# Fedora: CUDA environment
export CUDA_HOME="${CUDA_HOME_DETECTED}"
export PATH="\${CUDA_HOME}/bin\${PATH:+:\$PATH}"
export LD_LIBRARY_PATH="\${CUDA_HOME}/lib64:\${CUDA_HOME}/targets/x86_64-linux/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
ENVEOF
chmod 0644 "$CUDA_ENV_FILE"

# ldconfig for CUDA targets path
echo "/usr/local/cuda/targets/x86_64-linux/lib" > /etc/ld.so.conf.d/cuda-targets.conf
ldconfig

mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/cuda-env.conf <<SYSENVEOF
[Manager]
DefaultEnvironment=CUDA_HOME=${CUDA_HOME_DETECTED}
SYSENVEOF
systemctl daemon-reload

fi  # end: [[ "$INSTALL_PROFILE" != "theme-bash" ]]

# ── Done ──────────────────────────────────────────────────────────────────────
step "First-boot provisioning complete"
mkdir -p "$(dirname "$MARKER_FILE")"
touch "$MARKER_FILE"
log "First-boot done. Log: $LOG_FILE"
FBEOF
chmod 0750 /usr/local/sbin/fedora-first-boot.sh

# ── Write first-login script ──────────────────────────────────────────────────
cat > /usr/local/bin/fedora-first-login.sh <<'FLEOF'
#!/usr/bin/env bash
# fedora-first-login.sh — User-level one-shot provisioning
set -euo pipefail

MARKER_DIR="${HOME}/.local/share/fedora-provision"
MARKER_FILE="${MARKER_DIR}/first-login.done"
LOG_FILE="${MARKER_DIR}/first-login.log"
ENV_FILE="/etc/fedora-provision.env"

mkdir -p "$MARKER_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; }
die()  { err "$*"; exit 1; }
step() { echo; echo "══ $* ══"; }

have_passwordless_sudo() { sudo -n true 2>/dev/null; }

if [[ -f "$MARKER_FILE" ]]; then
    log "First-login already completed. Cleaning up."
    rm -f "${HOME}/.config/autostart/fedora-first-login.desktop"
    exit 0
fi

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

INSTALL_PROFILE="${FEDORA_INSTALL_PROFILE:-full}"
log "Install profile: ${INSTALL_PROFILE}"

TARGET_USER="${FEDORA_TARGET_USER:-${USER}}"
PYTORCH_VENV="${FEDORA_PYTORCH_VENV:-${HOME}/.venvs/ai}"
VLLM_VENV="${FEDORA_VLLM_VENV:-${HOME}/.venvs/bitwig-omni}"
VLLM_CUDA_VERSION="${FEDORA_VLLM_CUDA_VERSION:-13.2}"
VLLM_ARCH_LIST="${FEDORA_VLLM_ARCH_LIST:-12.0}"
VLLM_MODEL="${FEDORA_AGENT_MODEL:-Qwen/Qwen3-14B-AWQ}"
WS_GTK_ARGS="${FEDORA_WS_GTK_ARGS:-}"
WS_ICON_ARGS="${FEDORA_WS_ICON_ARGS:-}"
WS_WALL_ARGS="${FEDORA_WS_WALL_ARGS:-}"
OMB_THEME="${FEDORA_OMB_THEME:-modern}"
THEMES_DIR="${HOME}/.cache/fedora-themes-build"

# ── 1. Flatpak Extension Manager ──────────────────────────────────────────────
step "Flatpak Extension Manager"
if [[ "$INSTALL_PROFILE" =~ ^(headless-vllm|vllm-only)$ ]]; then
    log "Skipped (headless profile)."
elif ! flatpak list --user 2>/dev/null | grep -q 'com.mattjakeman.ExtensionManager'; then
    flatpak install --user --noninteractive flathub com.mattjakeman.ExtensionManager \
        || warn "Extension Manager install failed (non-fatal)."
else
    log "Extension Manager already installed."
fi

# ── 2. GNOME extensions ───────────────────────────────────────────────────────
step "GNOME extensions"
if [[ "$INSTALL_PROFILE" =~ ^(headless-vllm|vllm-only)$ ]]; then
    log "Skipped (headless profile)."
elif command -v gnome-extensions &>/dev/null; then
    for ext in \
        "user-theme@gnome-shell-extensions.gcampax.github.com" \
        "dash-to-panel@jderose9.github.com"; do
        gnome-extensions enable "$ext" 2>/dev/null \
            && log "Enabled: $ext" \
            || warn "Could not enable: $ext"
    done
else
    warn "gnome-extensions CLI not found; skipping."
fi

# ── 3-5. WhiteSur themes ──────────────────────────────────────────────────────
step "WhiteSur themes"
if [[ "$INSTALL_PROFILE" =~ ^(headless-vllm|vllm-only)$ ]]; then
    log "Skipped (headless profile)."
else

WHITESUR_ERRORS=()

ws_install_theme() {
    local repo_name="$1" repo_url="$2" install_dest_flag="$3" extra_args="$4"
    local install_dir="${THEMES_DIR}/${repo_name}"
    log "WhiteSur: $repo_name"
    if [[ -d "$install_dir/.git" ]]; then
        git -C "$install_dir" pull --ff-only 2>&1 | while read -r l; do log "  git: $l"; done \
            || warn "  git pull failed for $repo_name."
    else
        mkdir -p "$THEMES_DIR"
        git clone --depth=1 "$repo_url" "$install_dir" 2>&1 | \
            while read -r l; do log "  git: $l"; done \
            || { WHITESUR_ERRORS+=("$repo_name: clone failed"); return; }
    fi
    local install_sh="${install_dir}/install.sh"
    [[ -x "$install_sh" ]] || { WHITESUR_ERRORS+=("$repo_name: install.sh missing"); return; }
    # TERM=xterm: setterm inside install.sh fails with TERM=dumb/unset (no TTY in %post), exiting non-zero
    # shellcheck disable=SC2086
    local _tmpout
    _tmpout=$(mktemp)
    if TERM=xterm bash "$install_sh" $install_dest_flag $extra_args >"$_tmpout" 2>&1; then
        while IFS= read -r l; do log "  install: $l"; done < "$_tmpout"
        rm -f "$_tmpout"
        log "  $repo_name installed successfully."
    else
        while IFS= read -r l; do log "  install: $l"; done < "$_tmpout"
        rm -f "$_tmpout"
        WHITESUR_ERRORS+=("$repo_name: install.sh failed")
    fi
}

GTK_DEST="-d ${HOME}/.local/share/themes"
ICON_DEST="-d ${HOME}/.local/share/icons"

ws_install_theme "WhiteSur-gtk-theme"   "https://github.com/vinceliuice/WhiteSur-gtk-theme.git"   ""  "-l -c Dark"
ws_install_theme "WhiteSur-icon-theme" "https://github.com/vinceliuice/WhiteSur-icon-theme.git"  "$ICON_DEST" ""
ws_install_theme "WhiteSur-wallpapers"  "https://github.com/vinceliuice/WhiteSur-wallpapers.git"  ""           "$WS_WALL_ARGS"
ws_install_theme "WhiteSur-cursors"     "https://github.com/vinceliuice/WhiteSur-cursors.git"     "$ICON_DEST" ""

# GNOME theme + icons + cursor anwenden
if command -v gsettings &>/dev/null; then
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'      2>/dev/null || true
    gsettings set org.gnome.desktop.interface icon-theme   'WhiteSur-dark'    2>/dev/null || true
    gsettings set org.gnome.desktop.interface cursor-theme 'WhiteSur-cursors' 2>/dev/null || true
    log "GNOME theme applied: WhiteSur libadwaita (~/.config/gtk-4.0) + WhiteSur-dark icons + WhiteSur-cursors"
fi

# Repos nach Installation entfernen
log "Theme-Repos gecacht: $THEMES_DIR"

fi  # end: WhiteSur headless guard

# ── 6. Oh My Bash ─────────────────────────────────────────────────────────────
step "Oh My Bash"
OMB_DIR="${HOME}/.oh-my-bash"
if [[ -d "$OMB_DIR" ]]; then
    log "Oh My Bash already installed."
else
    bash <(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh) \
        --unattended || warn "Oh My Bash install failed (non-fatal)."
fi
if [[ -f "${HOME}/.bashrc" ]]; then
    if grep -q 'OSH_THEME=' "${HOME}/.bashrc"; then
        sed -i "s|^OSH_THEME=.*|OSH_THEME=\"${OMB_THEME}\"|" "${HOME}/.bashrc"
    else
        echo "OSH_THEME=\"${OMB_THEME}\"" >> "${HOME}/.bashrc"
    fi
fi

# ── Profile: theme-bash stops here ───────────────────────────────────────────
if [[ "$INSTALL_PROFILE" == "theme-bash" ]]; then
    step "theme-bash profile — skipping AI provisioning"
    touch "$MARKER_FILE"
    rm -f "${HOME}/.config/autostart/fedora-first-login.desktop"
    log "First-login done (theme-bash). Log: $LOG_FILE"
    exit 0
fi

# ── 7-11. AI stack (skipped for headless-vllm — handled by Podman) ───────────
step "Python AI venv"
if [[ "$INSTALL_PROFILE" == "headless-vllm" ]]; then
    log "Skipped (headless-vllm uses Podman for AI stack)."
else

VENV_AI="${PYTORCH_VENV/#\~/$HOME}"
[[ -d "$VENV_AI" ]] || { mkdir -p "$(dirname "$VENV_AI")"; python3 -m venv "$VENV_AI"; }
"$VENV_AI/bin/pip" install --quiet --upgrade pip

step "PyTorch installation"
detect_cuda_version() {
    for p in /usr/local/cuda/bin/nvcc /usr/bin/nvcc; do
        [[ -x "$p" ]] && { "$p" --version | grep -oP 'release \K[\d.]+' | head -1; return; }
    done; echo ""
}
resolve_pytorch_index() {
    local v="$1"; local maj min vi
    maj=$(echo "$v" | cut -d. -f1); min=$(echo "$v" | cut -d. -f2); vi=$(( maj*100+min ))
    if   (( vi >= 1302 )); then echo "https://download.pytorch.org/whl/cu128"
    elif (( vi >= 1206 )); then echo "https://download.pytorch.org/whl/cu126"
    elif (( vi >= 1204 )); then echo "https://download.pytorch.org/whl/cu124"
    elif (( vi >= 1201 )); then echo "https://download.pytorch.org/whl/cu121"
    else echo "https://download.pytorch.org/whl/cpu"; fi
}
CUDA_VER=$(detect_cuda_version)
PYTORCH_INDEX=$( [[ -n "$CUDA_VER" ]] && resolve_pytorch_index "$CUDA_VER" || echo "https://download.pytorch.org/whl/cpu" )
log "PyTorch index: $PYTORCH_INDEX"
"$VENV_AI/bin/pip" install --quiet torch torchvision torchaudio --index-url "$PYTORCH_INDEX"
"$VENV_AI/bin/python3" -c "import torch; print('PyTorch', torch.__version__, 'CUDA:', torch.cuda.is_available())" \
    || warn "PyTorch verification failed (non-fatal)."

step "vLLM-Omni venv"
VENV_VLLM="${VLLM_VENV/#\~/$HOME}"
[[ -d "$VENV_VLLM" ]] || { mkdir -p "$(dirname "$VENV_VLLM")"; python3 -m venv "$VENV_VLLM"; }
"$VENV_VLLM/bin/pip" install --quiet --upgrade pip
"$VENV_VLLM/bin/pip" install --quiet "huggingface_hub[cli]" autoawq \
    || warn "HuggingFace CLI / autoawq install failed (non-fatal)."

step "CUDA ${VLLM_CUDA_VERSION} toolchain"
find_cuda_version_path() {
    local tv="$1"
    for p in "/usr/local/cuda-${tv}" "/usr/local/cuda"; do
        [[ -x "${p}/bin/nvcc" ]] || continue
        local fv; fv=$("${p}/bin/nvcc" --version | grep -oP 'release \K[\d.]+' | head -1)
        [[ "$fv" == "$tv"* ]] && { echo "$p"; return 0; }
    done; return 1
}
CUDA_132_PATH=""
if CUDA_132_PATH=$(find_cuda_version_path "$VLLM_CUDA_VERSION"); then
    log "CUDA ${VLLM_CUDA_VERSION} at: $CUDA_132_PATH"
else
    log "CUDA ${VLLM_CUDA_VERSION} not found. Installing..."
    CUDA_MAJOR=$(echo "$VLLM_CUDA_VERSION" | cut -d. -f1)
    CUDA_MINOR=$(echo "$VLLM_CUDA_VERSION" | cut -d. -f2)
    have_passwordless_sudo && sudo dnf install -y "cuda-toolkit-${CUDA_MAJOR}-${CUDA_MINOR}" 2>/dev/null \
        || die "Cannot install CUDA ${VLLM_CUDA_VERSION} — no sudo or dnf package."
    CUDA_132_PATH=$(find_cuda_version_path "$VLLM_CUDA_VERSION") \
        || die "CUDA ${VLLM_CUDA_VERSION} not found after install."
fi
cat > "${VENV_VLLM}/bin/activate.cuda" <<HOOKEOF
export CUDA_HOME="${CUDA_132_PATH}"
export PATH="\${CUDA_HOME}/bin\${PATH:+:\$PATH}"
export LD_LIBRARY_PATH="\${CUDA_HOME}/lib64:\${CUDA_HOME}/targets/x86_64-linux/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
HOOKEOF
grep -q 'activate.cuda' "${VENV_VLLM}/bin/activate" \
    || echo "source \"${VENV_VLLM}/bin/activate.cuda\"" >> "${VENV_VLLM}/bin/activate"

step "vLLM-Omni source build"
VLLM_OMNI_SRC="${HOME}/.local/src/vllm-omni"
if [[ -d "${VLLM_OMNI_SRC}/.git" ]]; then
    git -C "$VLLM_OMNI_SRC" pull --ff-only || warn "git pull failed."
else
    mkdir -p "$(dirname "$VLLM_OMNI_SRC")"
    git clone --depth=1 https://github.com/vllm-project/vllm.git "$VLLM_OMNI_SRC" \
        || die "Failed to clone vLLM."
fi
[[ -f "${VLLM_OMNI_SRC}/use_existing_torch.py" ]] \
    && (cd "$VLLM_OMNI_SRC" && "$VENV_VLLM/bin/python3" use_existing_torch.py) \
    || true
(
    cd "$VLLM_OMNI_SRC"
    source "${VENV_VLLM}/bin/activate"
    source "${VENV_VLLM}/bin/activate.cuda"
    export TORCH_CUDA_ARCH_LIST="${VLLM_ARCH_LIST}"
    export CUDA_HOME="${CUDA_132_PATH}"
    export MAX_JOBS="${MAX_JOBS:-$(nproc)}"
    pip install --quiet --no-build-isolation . || die "vLLM build failed."
)
log "vLLM build done."

fi  # end: headless-vllm AI stack guard

# ── 12. Model download ────────────────────────────────────────────────────────
step "Model download: ${VLLM_MODEL}"
if [[ "$INSTALL_PROFILE" == "headless-vllm" ]]; then
    log "Skipped (model is downloaded inside the Podman container)."
else
    VENV_VLLM_PATH="${VLLM_VENV/#\~/$HOME}"
    "${VENV_VLLM_PATH}/bin/huggingface-cli" download "${VLLM_MODEL}" \
        --local-dir "${HOME}/.cache/huggingface/hub/${VLLM_MODEL//\//__}" \
        || warn "Model download failed or deferred (check HF token / disk space)."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
step "First-login provisioning complete"
[[ -v WHITESUR_ERRORS ]] && [[ "${#WHITESUR_ERRORS[@]}" -gt 0 ]] \
    && for e in "${WHITESUR_ERRORS[@]}"; do warn "WhiteSur: $e"; done

touch "$MARKER_FILE"
rm -f "${HOME}/.config/autostart/fedora-first-login.desktop"
log "First-login done. Log: $LOG_FILE"
FLEOF
chmod 0755 /usr/local/bin/fedora-first-login.sh

# ── Write systemd first-boot unit ────────────────────────────────────────────
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

systemctl enable fedora-first-boot.service

# ── Configure first-login run (GUI vs. headless) ──────────────────────────────
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true

AUTOSTART_DIR="${USER_HOME}/.config/autostart"

if [[ "$INSTALL_PROFILE" =~ ^(full|theme-bash)$ ]]; then
    # GUI profiles: GNOME autostart
    mkdir -p "$AUTOSTART_DIR"
    cat > "${AUTOSTART_DIR}/fedora-first-login.desktop" <<'DESKTOPEOF'
[Desktop Entry]
Type=Application
Name=Fedora First-Login Setup
Exec=/usr/local/bin/fedora-first-login.sh
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
DESKTOPEOF
    chown "${TARGET_USER}:${TARGET_USER}" "${USER_HOME}/.config"
    chown -R "${TARGET_USER}:${TARGET_USER}" "$AUTOSTART_DIR"
    echo "[common-post] GNOME autostart configured for ${TARGET_USER}"
else
    # Headless profiles: systemd user service
    cat > /etc/systemd/system/fedora-provision-user.service <<USRUNITEOF
[Unit]
Description=Fedora User Provisioning (${INSTALL_PROFILE})
After=fedora-first-boot.service network-online.target
Requires=fedora-first-boot.service
Wants=network-online.target
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
    echo "[common-post] Headless systemd service enabled for ${TARGET_USER}"
fi

echo "[common-post] Done. Profile: ${INSTALL_PROFILE}"

%end

# ── %post --nochroot: Btrfs Subvolumes → @/@home umbenennen (Timeshift-kompatibel) ──
%post --nochroot --log=/root/ks-post-btrfs-rename.log

set -euo pipefail

SYSIMAGE="/mnt/sysimage"
BTRFS_DEV=$(findmnt -n -o SOURCE "${SYSIMAGE}" 2>/dev/null | sed 's/\[.*\]//' || true)

if [[ -z "$BTRFS_DEV" ]]; then
    echo "WARN: Kein btrfs Device erkannt — Subvolume-Rename übersprungen."
    exit 0
fi

MOUNT_TMP=$(mktemp -d)
mount -o subvolid=5 "$BTRFS_DEV" "$MOUNT_TMP"

if [[ -d "${MOUNT_TMP}/root" ]] && [[ ! -d "${MOUNT_TMP}/@" ]]; then
    btrfs subvolume snapshot "${MOUNT_TMP}/root" "${MOUNT_TMP}/@"
    echo "Subvolume Snapshot: root → @"
fi

if [[ -d "${MOUNT_TMP}/home" ]] && [[ ! -d "${MOUNT_TMP}/@home" ]]; then
    btrfs subvolume snapshot "${MOUNT_TMP}/home" "${MOUNT_TMP}/@home"
    echo "Subvolume Snapshot: home → @home"
fi

umount "$MOUNT_TMP"
rmdir "$MOUNT_TMP"

sed -i 's/subvol=root\b/subvol=@/g'      "${SYSIMAGE}/etc/fstab"
sed -i 's/subvol=home\b/subvol=@home/g'  "${SYSIMAGE}/etc/fstab"
echo "fstab aktualisiert: subvol=root → @, subvol=home → @home"

%end
