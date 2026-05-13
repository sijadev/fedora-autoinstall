#!/usr/bin/env bash
# scripts/first-boot.sh — System-wide one-shot provisioning (runs as root via systemd)
#
# Executed by fedora-first-boot.service exactly once after the first boot.
# Marker: /var/lib/fedora-provision/first-boot.done
#
# Tasks:
#   1. fedora-sync
#   2. NVIDIA Open Driver update
#   3. CUDA installation (Fedora/Fedora or NVIDIA repo)
#   4. Set system-wide CUDA environment variables

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

# ── Idempotency guard ─────────────────────────────────────────────────────────
if [[ -f "$MARKER_FILE" ]]; then
    log "First-boot already completed (marker exists: $MARKER_FILE). Skipping."
    exit 0
fi

mkdir -p "$MARKER_DIR"

# ── Load provisioning env ─────────────────────────────────────────────────────
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

INSTALL_PROFILE="${FEDORA_INSTALL_PROFILE:-full}"
log "Install profile: ${INSTALL_PROFILE}"

# ── 0. Theme-Abhängigkeiten vorinstallieren (verhindert sudo-Prompts in first-login) ──
step "Theme dependencies"
if [[ "$INSTALL_PROFILE" =~ ^(full|theme-bash)$ ]]; then
    dnf install -y sassc glib2-devel gnome-shell-extension-user-theme gnome-shell-extension-dash-to-dock 2>/dev/null \
        && log "Theme deps + GNOME extensions installed." \
        || warn "Theme deps/extensions install failed (non-fatal)."
fi

# ── 1. System-Update ──────────────────────────────────────────────────────────
step "System-Update"
if command -v fedora-sync &>/dev/null; then
    log "Running fedora-sync..."
    fedora-sync install-updates || die "fedora-sync failed."
    log "fedora-sync completed."
else
    log "Running dnf upgrade..."
    dnf upgrade -y || die "dnf upgrade failed."
    log "dnf upgrade completed."
fi

# ── 2. NVIDIA Open Driver ─────────────────────────────────────────────────────
step "NVIDIA Open Driver update"

check_nvidia_open_compat() {
    # Check GPU PCI IDs against architectures that support the Open Module:
    # Turing (TU1xx), Ampere (GA1xx), Ada Lovelace (AD1xx), Blackwell (GB1xx)
    if ! command -v lspci &>/dev/null; then
        warn "lspci not available; skipping GPU compatibility check."
        return 0
    fi
    local gpu_info
    gpu_info=$(lspci -nn | grep -i 'NVIDIA' || true)
    if [[ -z "$gpu_info" ]]; then
        warn "No NVIDIA GPU detected (VM or non-NVIDIA system) — skipping NVIDIA driver."
        return 1
    fi
    if echo "$gpu_info" | grep -qiE 'GP10[0-9]|GP1[0-9]{2}'; then
        die "NVIDIA Pascal GPU detected. Open Driver requires Turing or newer. Aborting."
    fi
    log "NVIDIA GPU detected (Open Driver compatible): $gpu_info"
}

if check_nvidia_open_compat; then
    log "Installing/updating NVIDIA Open Kernel Module driver..."
    dnf install -y \
        kernel-devel \
        kernel-headers \
        akmod-nvidia-open \
        xorg-x11-drv-nvidia-cuda \
        || die "NVIDIA Open Driver installation failed. No proprietary fallback."

    # Wait for the kmod to be built (akmods)
    if command -v akmods &>/dev/null; then
        log "Building kernel modules (akmods)..."
        akmods --force || die "akmods failed for NVIDIA Open Driver."
    fi
    log "NVIDIA Open Driver installed/updated."
fi  # end: check_nvidia_open_compat

# ── 3. CUDA installation ──────────────────────────────────────────────────────
step "CUDA installation"

if [[ "$INSTALL_PROFILE" == "theme-bash" ]]; then
    log "Profile '${INSTALL_PROFILE}' — CUDA not required. Skipping."
elif ! lspci -nn 2>/dev/null | grep -qi 'NVIDIA'; then
    warn "No NVIDIA GPU detected — skipping CUDA installation (VM or non-NVIDIA system)."
else

CUDA_SOURCE="${FEDORA_CUDA_SOURCE:-fedora}"

install_cuda_fedora() {
    log "Installing CUDA from Fedora/Fedora repos..."
    # Fedora packages: 'cuda' (toolkit), 'cuda-cudart-devel' (dev headers)
    # Note: 'cuda-toolkit' does not exist in Fedora repos (use 'cuda' instead)
    dnf install -y \
        cuda \
        cuda-cudart-devel \
        || die "CUDA installation from Fedora/Fedora repos failed."
}

install_cuda_nvidia_repo() {
    log "Installing CUDA from official NVIDIA repo..."
    local arch; arch=$(uname -m)
    local distro="rhel9"
    local repo_url="https://developer.download.nvidia.com/compute/cuda/repos/${distro}/${arch}/cuda-${distro}.repo"

    if ! dnf config-manager --add-repo "$repo_url" 2>/dev/null; then
        # Try with dnf5 syntax
        dnf config-manager addrepo --from-repofile="$repo_url" \
            || die "Failed to add NVIDIA CUDA repo."
    fi

    dnf install -y \
        cuda-toolkit \
        cuda-devel \
        || die "CUDA installation from NVIDIA repo failed."
}

case "$CUDA_SOURCE" in
    fedora|fedora) install_cuda_fedora   ;;
    nvidia)        install_cuda_nvidia_repo ;;
    *)             die "Unknown cuda source: $CUDA_SOURCE" ;;
esac

# Discover installed CUDA path
CUDA_HOME_DETECTED=""
for candidate in /usr/local/cuda /usr/local/cuda-*; do
    if [[ -x "${candidate}/bin/nvcc" ]]; then
        CUDA_HOME_DETECTED="$candidate"
        break
    fi
done
[[ -n "$CUDA_HOME_DETECTED" ]] || die "nvcc not found after CUDA installation."
log "CUDA installed at: $CUDA_HOME_DETECTED"

CUDA_VERSION_INSTALLED=$("${CUDA_HOME_DETECTED}/bin/nvcc" --version \
    | grep -oP 'release \K[\d.]+' | head -1)
log "CUDA version: $CUDA_VERSION_INSTALLED"

# ── 4. System-wide CUDA environment variables ─────────────────────────────────
step "CUDA environment variables"

cat > "$CUDA_ENV_FILE" <<ENVEOF
# Fedora Auto-Install: CUDA environment — managed by fedora-first-boot.sh
export CUDA_HOME="${CUDA_HOME_DETECTED}"
export PATH="\${CUDA_HOME}/bin\${PATH:+:\$PATH}"
export LD_LIBRARY_PATH="\${CUDA_HOME}/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
ENVEOF
chmod 0644 "$CUDA_ENV_FILE"
log "CUDA env written to $CUDA_ENV_FILE"

# Also write a systemd-compatible EnvironmentFile entry
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/cuda-env.conf <<SYSENVEOF
# CUDA environment for systemd services
[Manager]
DefaultEnvironment=CUDA_HOME=${CUDA_HOME_DETECTED}
SYSENVEOF
systemctl daemon-reload

fi  # end: CUDA (GPU present + profile requires CUDA)

# ── 5. Kernel/Sysctl performance tuning ──────────────────────────────────────
step "Kernel/Sysctl tuning"

cat > /etc/sysctl.d/99-fedora-performance.conf <<'SYSCTLEOF'
# Fedora Auto-Install: performance tuning
vm.swappiness = 10
vm.vfs_cache_pressure = 50
kernel.sched_migration_cost_ns = 500000
net.core.somaxconn = 1024
SYSCTLEOF
chmod 0644 /etc/sysctl.d/99-fedora-performance.conf
sysctl --system 2>&1 | grep -E 'Applying|error' | while read -r l; do log "  sysctl: $l"; done || true
log "Sysctl tuning applied."

# Transparent Hugepages: madvise (opt-in per Prozess — PyTorch/vLLM nutzen es gezielt)
cat > /etc/tmpfiles.d/transparent-hugepages.conf <<'THPEOF'
w /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise
w /sys/kernel/mm/transparent_hugepage/defrag  - - - - defer+madvise
THPEOF
chmod 0644 /etc/tmpfiles.d/transparent-hugepages.conf
echo madvise        > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo defer+madvise  > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true
log "Transparent hugepages: madvise (per tmpfiles.d persistent)."

# ── 6. CPU Performance Governor (tuned) ───────────────────────────────────────
step "CPU performance profile"

if ! command -v tuned-adm &>/dev/null; then
    dnf install -y tuned && log "tuned installed." || warn "tuned install failed (non-fatal)."
fi

if command -v tuned-adm &>/dev/null; then
    cat > /etc/systemd/system/cpu-performance.service <<'CPUEOF'
[Unit]
Description=CPU Performance Governor via tuned
After=tuned.service
Requires=tuned.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/tuned-adm profile throughput-performance
ExecStop=/usr/sbin/tuned-adm profile balanced

[Install]
WantedBy=multi-user.target
CPUEOF
    systemctl daemon-reload
    systemctl enable tuned.service          2>/dev/null || true
    systemctl enable cpu-performance.service 2>/dev/null || true
    systemctl start  tuned.service          2>/dev/null || true
    tuned-adm profile throughput-performance 2>/dev/null \
        && log "tuned: throughput-performance aktiv." \
        || warn "tuned-adm fehlgeschlagen (non-fatal, wirkt ab nächstem Boot)."
fi

# ── 7. NVIDIA Persistence Mode ────────────────────────────────────────────────
if lspci -nn 2>/dev/null | grep -qi 'NVIDIA'; then
    step "NVIDIA persistence mode"
    cat > /etc/systemd/system/nvidia-performance.service <<'NVEOF'
[Unit]
Description=NVIDIA Persistence Mode
After=multi-user.target
ConditionPathExists=/usr/bin/nvidia-smi

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/nvidia-smi -pm 1
ExecStop=/usr/bin/nvidia-smi  -pm 0

[Install]
WantedBy=multi-user.target
NVEOF
    systemctl daemon-reload
    systemctl enable nvidia-performance.service 2>/dev/null \
        && log "nvidia-performance.service aktiviert." \
        || warn "nvidia-performance.service enable fehlgeschlagen (non-fatal)."
fi

# ── 8. Timeshift + grub-btrfs (nur bei Btrfs-Root) ───────────────────────────
if findmnt -n -o FSTYPE / 2>/dev/null | grep -qx 'btrfs'; then
    step "Timeshift + grub-btrfs"
    dnf install -y timeshift grub2-btrfs inotify-tools 2>/dev/null \
        && log "timeshift + grub2-btrfs + inotify-tools installiert." \
        || warn "timeshift/grub2-btrfs install fehlgeschlagen (non-fatal)."

    BTRFS_DEV=$(findmnt -n -o SOURCE /)
    BTRFS_UUID=$(blkid -s UUID -o value "$BTRFS_DEV" 2>/dev/null || true)

    # btrfs qgroups für Timeshift aktivieren
    btrfs quota enable / 2>/dev/null || true

    if [[ -n "$BTRFS_UUID" ]] && command -v timeshift &>/dev/null; then
        mkdir -p /etc/timeshift
        cat > /etc/timeshift/timeshift.json <<TIMESHIFTEOF
{
  "backup_device_uuid" : "${BTRFS_UUID}",
  "parent_device_size" : "0",
  "do_first_run" : "false",
  "btrfs_mode" : "true",
  "include_btrfs_home_for_backup" : "false",
  "stop_cron_emails" : "true",
  "btrfs_use_qgroup" : "true",
  "schedule_monthly" : "true",
  "schedule_weekly" : "false",
  "schedule_daily" : "false",
  "schedule_hourly" : "false",
  "schedule_boot" : "true",
  "count_monthly" : "3",
  "count_weekly" : "3",
  "count_daily" : "5",
  "count_hourly" : "6",
  "count_boot" : "5"
}
TIMESHIFTEOF
        chmod 0644 /etc/timeshift/timeshift.json
        log "Timeshift konfiguriert: BTRFS-Modus, UUID=${BTRFS_UUID}."
    fi

    # grub-btrfs: Snapshots automatisch im GRUB-Menü registrieren
    if systemctl list-unit-files grub-btrfs.path &>/dev/null; then
        systemctl enable --now grub-btrfs.path 2>/dev/null \
            && log "grub-btrfs.path aktiviert." \
            || warn "grub-btrfs.path enable fehlgeschlagen (non-fatal)."
    fi
    grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null \
        && log "GRUB-Konfiguration aktualisiert." \
        || warn "grub2-mkconfig fehlgeschlagen (non-fatal)."
else
    log "Root ist kein btrfs — Timeshift/grub-btrfs übersprungen."
fi

# ── 9. zram-generator (Swap im RAM — Pflicht ohne Swap-Partition) ────────────
step "zram-generator"
if ! rpm -q zram-generator &>/dev/null; then
    dnf install -y zram-generator \
        && log "zram-generator installiert." \
        || warn "zram-generator install fehlgeschlagen (non-fatal)."
fi
# Konfiguration: 50% RAM, max 8 GB, zstd-Kompression
cat > /etc/systemd/zram-generator.conf <<'ZRAMEOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
ZRAMEOF
chmod 0644 /etc/systemd/zram-generator.conf
log "zram-generator: 50% RAM (max 8 GB), zstd."

# ── 10. irqbalance (IRQ-Verteilung auf alle CPU-Kerne) ────────────────────────
step "irqbalance"
if ! rpm -q irqbalance &>/dev/null; then
    dnf install -y irqbalance \
        && log "irqbalance installiert." \
        || warn "irqbalance install fehlgeschlagen (non-fatal)."
fi
systemctl enable --now irqbalance 2>/dev/null \
    && log "irqbalance aktiviert." \
    || warn "irqbalance enable fehlgeschlagen (non-fatal)."

# ── 11. ananicy-cpp (Prozess-Priorisierung) ───────────────────────────────────
step "ananicy-cpp"
if ! rpm -q ananicy-cpp &>/dev/null; then
    # COPR aktivieren und installieren
    if dnf copr enable -y eriknguyen/ananicy-cpp &>/dev/null; then
        dnf install -y ananicy-cpp \
            && log "ananicy-cpp installiert." \
            || warn "ananicy-cpp install fehlgeschlagen (non-fatal)."
    else
        warn "ananicy-cpp COPR nicht verfügbar — übersprungen (non-fatal)."
    fi
fi
if command -v ananicy-cpp &>/dev/null; then
    systemctl enable --now ananicy-cpp 2>/dev/null \
        && log "ananicy-cpp aktiviert." \
        || warn "ananicy-cpp enable fehlgeschlagen (non-fatal)."
fi

# ── 12. AMD Ryzen Optimierungen ───────────────────────────────────────────────
if grep -qi 'amd\|ryzen\|epyc' /proc/cpuinfo 2>/dev/null; then
    step "AMD Ryzen optimizations"

    # amd-pstate EPP auf 'performance' setzen (persistent via systemd-Service)
    cat > /etc/systemd/system/amd-pstate-epp.service <<'AMDEOF'
[Unit]
Description=AMD P-State Energy Performance Preference (performance)
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do echo performance > "$f" 2>/dev/null || true; done'

[Install]
WantedBy=multi-user.target
AMDEOF
    systemctl daemon-reload
    systemctl enable amd-pstate-epp.service 2>/dev/null \
        && log "amd-pstate-epp.service aktiviert." \
        || warn "amd-pstate-epp enable fehlgeschlagen (non-fatal)."
    # Sofort anwenden
    for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        echo performance > "$f" 2>/dev/null || true
    done
    log "AMD P-State EPP auf 'performance' gesetzt."

    # GRUB Kernel-Parameter für Ryzen
    GRUB_FILE="/etc/default/grub"
    if [[ -f "$GRUB_FILE" ]] && ! grep -q 'amd_pstate' "$GRUB_FILE"; then
        sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 amd_pstate=active amd_iommu=on cpufreq.default_governor=performance"/' \
            "$GRUB_FILE"
        grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null \
            && log "GRUB: AMD Kernel-Parameter eingetragen." \
            || warn "grub2-mkconfig fehlgeschlagen (non-fatal)."
    else
        log "GRUB AMD-Parameter bereits vorhanden oder grub-config nicht gefunden."
    fi
else
    log "Kein AMD CPU erkannt — AMD Ryzen Optimierungen übersprungen."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
step "First-boot provisioning complete"
marker_set() { mkdir -p "$(dirname "$1")"; touch "$1"; }
marker_set "$MARKER_FILE"
log "Marker written: $MARKER_FILE"
log "First-boot provisioning finished successfully."
