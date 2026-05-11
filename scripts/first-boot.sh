#!/usr/bin/env bash
# scripts/first-boot.sh — System-wide one-shot provisioning (runs as root via systemd)
#
# Executed by nobara-first-boot.service exactly once after the first boot.
# Marker: /var/lib/nobara-provision/first-boot.done
#
# Tasks:
#   1. nobara-sync
#   2. NVIDIA Open Driver update
#   3. CUDA installation (Nobara/Fedora or NVIDIA repo)
#   4. Set system-wide CUDA environment variables

set -euo pipefail

MARKER_DIR="/var/lib/nobara-provision"
MARKER_FILE="$MARKER_DIR/first-boot.done"
LOG_FILE="/var/log/nobara-first-boot.log"
ENV_FILE="/etc/nobara-provision.env"
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

INSTALL_PROFILE="${NOBARA_INSTALL_PROFILE:-full}"
log "Install profile: ${INSTALL_PROFILE}"

# ── 1. nobara-sync ────────────────────────────────────────────────────────────
step "nobara-sync"
if command -v nobara-sync &>/dev/null; then
    log "Running nobara-sync..."
    nobara-sync install-updates || die "nobara-sync failed."
    log "nobara-sync completed."
else
    warn "nobara-sync not found; skipping."
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
        die "No NVIDIA GPU detected. Cannot install NVIDIA Open Driver."
    fi
    # Turing and later are supported; check for pre-Turing (GTX 10xx / Pascal GP1xx)
    if echo "$gpu_info" | grep -qiE 'GP10[0-9]|GP1[0-9]{2}'; then
        die "NVIDIA Pascal GPU detected. Open Driver requires Turing or newer. Aborting."
    fi
    log "NVIDIA GPU detected (Open Driver compatible): $gpu_info"
}

check_nvidia_open_compat

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

# ── 3. CUDA installation ──────────────────────────────────────────────────────
step "CUDA installation"

if [[ "$INSTALL_PROFILE" == "theme-bash" ]]; then
    log "Profile '${INSTALL_PROFILE}' — CUDA not required. Skipping."
else

CUDA_SOURCE="${NOBARA_CUDA_SOURCE:-nobara}"

install_cuda_nobara() {
    log "Installing CUDA from Nobara/Fedora repos..."
    dnf install -y \
        cuda \
        cuda-toolkit \
        cuda-devel \
        || die "CUDA installation from Nobara/Fedora repos failed."
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
    nobara|fedora) install_cuda_nobara   ;;
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
# Nobara Auto-Install: CUDA environment — managed by nobara-first-boot.sh
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

fi  # end: [[ "$INSTALL_PROFILE" != "theme-bash" ]]

# ── Done ──────────────────────────────────────────────────────────────────────
step "First-boot provisioning complete"
marker_set() { mkdir -p "$(dirname "$1")"; touch "$1"; }
marker_set "$MARKER_FILE"
log "Marker written: $MARKER_FILE"
log "First-boot provisioning finished successfully."
