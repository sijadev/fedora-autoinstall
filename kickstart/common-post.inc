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

# ── RPM Fusion einbinden ──────────────────────────────────────────────────────
step "RPM Fusion Repos"
FEDORA_VER=$(rpm -E %fedora)
dnf install -y \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VER}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VER}.noarch.rpm" \
    || die "RPM Fusion konnte nicht eingebunden werden."
log "RPM Fusion free + nonfree aktiviert (Fedora ${FEDORA_VER})."

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
VLLM_ROUTER_PORT="${FEDORA_VLLM_ROUTER_PORT:-8000}"
VLLM_REGISTRY="${FEDORA_VLLM_REGISTRY:-${HOME}/.config/vllm-router/models.json}"
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

# ── 7-11. AI stack (skipped for headless-vllm — vLLM läuft via Podman-Router) ─
# Custom-Image fedora-vllm:latest + Quadlet-Template vllm@.container + vllm-router.service
# werden in scripts/first-boot.sh + scripts/first-login.sh aufgebaut. Hier nichts mehr zu tun.

# ── 12. Model download ────────────────────────────────────────────────────────
step "Model download"
log "Skipped: Modelle werden on-demand vom vllm-router geladen (HF-Cache: ~/.models/huggingface)."

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

# ── %post --nochroot: Anaconda-Logs auf USB-Stick sichern ─────────────────────
%post --nochroot --log=/root/ks-post-savelogs.log

TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
USB_DEV=$(blkid -L FEDORA-USB 2>/dev/null | head -1 || true)
LOG_DIR=""

if [[ -n "$USB_DEV" ]]; then
    MOUNT_TMP=$(mktemp -d)
    mount "$USB_DEV" "$MOUNT_TMP" 2>/dev/null && {
        LOG_DIR="${MOUNT_TMP}/logs"
        mkdir -p "$LOG_DIR"

        # Anaconda-Logs kopieren
        for logfile in \
            /tmp/anaconda.log \
            /tmp/syslog \
            /tmp/packaging.log \
            /tmp/storage.log \
            /tmp/program.log \
            /tmp/dnf.log \
            /root/ks-post.log \
            /root/ks-common-post.log \
            /root/ks-post-btrfs-rename.log \
            /root/ks-post-savelogs.log
        do
            [[ -f "$logfile" ]] && \
                cp "$logfile" "${LOG_DIR}/$(basename $logfile)-${TIMESTAMP}" 2>/dev/null || true
        done

        # Kernel-Meldungen
        dmesg > "${LOG_DIR}/dmesg-${TIMESTAMP}.log" 2>/dev/null || true

        # Kurzer Status
        echo "=== Anaconda Install Log ${TIMESTAMP} ===" > "${LOG_DIR}/install-summary-${TIMESTAMP}.txt"
        echo "Profile: ${FEDORA_INSTALL_PROFILE:-unknown}"   >> "${LOG_DIR}/install-summary-${TIMESTAMP}.txt"
        echo "Kernel: $(uname -r)"                            >> "${LOG_DIR}/install-summary-${TIMESTAMP}.txt"
        lspci | grep -iE 'nvidia|vga|display'                 >> "${LOG_DIR}/install-summary-${TIMESTAMP}.txt" 2>/dev/null || true

        sync
        umount "$MOUNT_TMP" 2>/dev/null || true
        echo "Logs gesichert nach: USB-Stick/logs/ (${TIMESTAMP})"
    }
    rmdir "$MOUNT_TMP" 2>/dev/null || true
else
    echo "FEDORA-USB nicht gefunden — Logs nicht gesichert."
fi

%end

# ── %post --nochroot: Provisioner + Scripts ins Zielsystem einbetten ──────────
# Damit nach dem Install der Welcome-Dialog und fedora-provision.sh OHNE USB-Stick
# verfügbar sind. Quelle: Custom-ISO (/run/install/repo) oder Ventoy USB.
%post --nochroot --log=/root/ks-post-embed-provisioner.log

set +e
SYSROOT="${ANA_INSTALL_PATH:-/mnt/sysroot}"
[[ ! -d "$SYSROOT" ]] && SYSROOT="/mnt/sysimage"
[[ ! -d "$SYSROOT" ]] && { echo "Kein sysroot gefunden — Abbruch."; exit 0; }

# Quell-Verzeichnis ermitteln: Custom-ISO oder FEDORA-USB oder externe Kickstart-Quelle
SRC=""
for candidate in /run/install/source /run/install/repo /run/install/sources/mount-* /mnt/install/repo; do
    if [[ -f "${candidate}/fedora-provision.sh" || -d "${candidate}/scripts" ]]; then
        SRC="$candidate"; break
    fi
done
if [[ -z "$SRC" ]]; then
    USB_DEV=$(blkid -L FEDORA-USB 2>/dev/null | head -1 || true)
    if [[ -n "$USB_DEV" ]]; then
        MNT=$(mktemp -d)
        mount "$USB_DEV" "$MNT" 2>/dev/null && SRC="$MNT"
    fi
fi
[[ -z "$SRC" ]] && { echo "Keine Quelle (ISO/USB) gefunden."; exit 0; }
echo "Quelle: $SRC"

mkdir -p "$SYSROOT/usr/local/sbin" \
         "$SYSROOT/usr/local/bin" \
         "$SYSROOT/usr/local/share/fedora-autoinstall" \
         "$SYSROOT/usr/share/applications"

[[ -f "${SRC}/fedora-provision.sh" ]] && \
    install -m 0750 "${SRC}/fedora-provision.sh" "$SYSROOT/usr/local/sbin/fedora-provision.sh"

[[ -f "${SRC}/scripts/welcome-dialog.sh" ]] && \
    install -m 0755 "${SRC}/scripts/welcome-dialog.sh" "$SYSROOT/usr/local/bin/fedora-welcome-dialog.sh"

[[ -f "${SRC}/scripts/fedora-provision.desktop" ]] && \
    install -m 0644 "${SRC}/scripts/fedora-provision.desktop" "$SYSROOT/usr/share/applications/fedora-provision.desktop"

# Vollständige Kopie für späteren manuellen Zugriff
[[ -d "${SRC}/scripts" ]] && cp -r "${SRC}/scripts"   "$SYSROOT/usr/local/share/fedora-autoinstall/"
[[ -d "${SRC}/kickstart" ]] && cp -r "${SRC}/kickstart" "$SYSROOT/usr/local/share/fedora-autoinstall/"

echo "Provisioner + Scripts unter /usr/local/{sbin,bin,share}/ eingebettet."

%end

# ── %post: Welcome-Dialog Autostart (nur full-Profil) ────────────────────────
%post --log=/root/ks-post-welcome-autostart.log

INSTALL_PROFILE="${FEDORA_INSTALL_PROFILE:-full}"
TARGET_USER="${FEDORA_TARGET_USER:-${INSTALL_USER:-sija}}"
USER_HOME="/home/${TARGET_USER}"

if [[ "$INSTALL_PROFILE" == "full" ]] && id "$TARGET_USER" &>/dev/null; then
    AUTOSTART_DIR="${USER_HOME}/.config/autostart"
    mkdir -p "$AUTOSTART_DIR"
    cat > "${AUTOSTART_DIR}/fedora-welcome.desktop" <<DESKTOPEOF
[Desktop Entry]
Type=Application
Name=Fedora Welcome
Exec=/usr/local/bin/fedora-welcome-dialog.sh
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=8
DESKTOPEOF
    chown -R "${TARGET_USER}:${TARGET_USER}" "$AUTOSTART_DIR"
    echo "Welcome-Dialog Autostart für ${TARGET_USER} aktiviert."
fi

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
