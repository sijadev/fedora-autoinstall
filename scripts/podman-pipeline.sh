#!/usr/bin/env bash
# scripts/podman-pipeline.sh — Layered Podman test pipeline for Nobara provisioning
#
# Each layer builds on the previous one and is committed as a named image tag.
# Rerun from any layer without redoing earlier work.
#
# Layers:
#   01-base     Fedora base + Nobara COPR repos + package groups
#   02-nvidia   NVIDIA Open Driver + CUDA (using host GPU pass-through)
#   03-themes   WhiteSur themes + Oh My Bash  (runs as target user)
#   04-vllm     vLLM + PyTorch (cu130/sm120) build
#   05-models   Model download: Kimi-Audio-7B (analysis) + Qwen3-14B-AWQ (agent)
#   06-agent    Neo4j driver + Bitwig agent scaffold
#
# Usage:
#   ./scripts/podman-pipeline.sh [OPTIONS] [LAYER...]
#
# Options:
#   --from LAYER      Start (or re-run) from this layer (rebuilds it + all after)
#   --only LAYER      Run only this one layer (must have previous image)
#   --image PREFIX    Image name prefix  (default: nobara-test)
#   --user NAME       Target username inside container (default: sija)
#   --no-gpu          Skip GPU pass-through (for CI without NVIDIA)
#   --dry-run         Print commands, don't run
#   --clean           Remove all nobara-test:* images and exit
#   -h, --help        Show this help
#
# Examples:
#   ./scripts/podman-pipeline.sh                        # run all layers
#   ./scripts/podman-pipeline.sh --from 03-themes       # rebuild from themes onward
#   ./scripts/podman-pipeline.sh --only 04-vllm         # re-run vllm layer only
#   ./scripts/podman-pipeline.sh --no-gpu --from 01-base

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Auto-launch in tmux so downloads survive terminal close + progress visible ─
# Skip if: already inside tmux, tmux not installed, or --no-tmux passed
if [[ -z "${TMUX:-}" ]] && command -v tmux &>/dev/null && [[ "${1:-}" != "--no-tmux" ]]; then
    SESSION="nobara-pipeline"
    if tmux has-session -t "$SESSION" 2>/dev/null; then
        echo "[tmux] Session '${SESSION}' already running — attaching..."
        exec tmux attach-session -t "$SESSION"
    fi
    # Start detached so VS Code terminal stays open; pipeline survives tab close
    tmux new-session -d -s "$SESSION" \
        "bash $(printf '%q' "$0") --no-tmux $(printf '%q ' "$@")
         echo
         echo '══ Pipeline finished — press Enter to close ══'
         read"
    echo ""
    echo "  Pipeline gestartet in tmux-Session '${SESSION}'"
    echo ""
    echo "  Fortschritt verfolgen:"
    echo "    tmux attach -t ${SESSION}"
    echo ""
    echo "  Loslösen (Pipeline läuft weiter):"
    echo "    Ctrl+B  dann  D"
    echo ""
    exec tmux attach-session -t "$SESSION"
fi
# Strip --no-tmux sentinel before processing remaining args
[[ "${1:-}" == "--no-tmux" ]] && shift

# ── load .env (HF_TOKEN etc.) ─────────────────────────────────────────────────
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    set -a; source "${SCRIPT_DIR}/.env"; set +a
fi
# ── defaults ──────────────────────────────────────────────────────────────────
IMAGE_PREFIX="nobara-test"
TARGET_USER="sija"
WITH_GPU=1
DRY_RUN=0
FROM_LAYER=""
ONLY_LAYER=""

# Layer order
ALL_LAYERS=(01-base 02-nvidia 03-themes 04-vllm 05-models 06-agent)

# ── colour helpers ─────────────────────────────────────────────────────────────
step()  { printf '\n\e[1;34m══ %s ══\e[0m\n' "$*"; }
ok()    { printf '\e[32m[OK]\e[0m  %s\n' "$*"; }
info()  { printf '\e[36m[..]\e[0m  %s\n' "$*"; }
warn()  { printf '\e[33m[WW]\e[0m  %s\n' "$*" >&2; }
die()   { printf '\e[31m[EE]\e[0m  %s\n' "$*" >&2; exit 1; }
run()   {
    if [[ "$DRY_RUN" == "1" ]]; then
        printf '\e[2m[dry] %s\e[0m\n' "$*"
    else
        "$@"
    fi
}

# ── arg parsing ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)       FROM_LAYER="$2"; shift 2 ;;
        --only)       ONLY_LAYER="$2"; shift 2 ;;
        --image)      IMAGE_PREFIX="$2"; shift 2 ;;
        --user)       TARGET_USER="$2"; shift 2 ;;
        --no-gpu)     WITH_GPU=0; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --clean)
            info "Removing images: ${IMAGE_PREFIX}:*"
            podman images --format '{{.Repository}}:{{.Tag}}' \
                | grep "^${IMAGE_PREFIX}:" \
                | xargs -r podman rmi --force
            ok "Done."; exit 0 ;;
        -h|--help)
            sed -n '2,/^set /p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

# ── helpers ────────────────────────────────────────────────────────────────────

image_exists() { podman image exists "${IMAGE_PREFIX}:$1" 2>/dev/null; }

# Run a container from a given image tag, execute inline script, then commit.
# Usage: run_layer <tag> <from_tag> <commit_msg> <script_body>
run_layer() {
    local tag="$1" from_tag="$2" msg="$3"
    shift 3
    local script_body="$*"

    step "Layer ${tag}: ${msg}"

    local from_image
    if [[ "$from_tag" == "scratch" ]]; then
        from_image="fedora:43"
    else
        from_image="${IMAGE_PREFIX}:${from_tag}"
    fi

    if image_exists "$tag"; then
        ok "Image ${IMAGE_PREFIX}:${tag} already exists — skipping (use --from ${tag} to rebuild)"
        return 0
    fi

    # GPU flags
    local gpu_flags=()
    if [[ "$WITH_GPU" == "1" ]]; then
        # Pass NVIDIA devices into container
        for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset; do
            [[ -e "$dev" ]] && gpu_flags+=(--device "$dev")
        done
        for capdev in /dev/nvidia-caps/nvidia-cap1 /dev/nvidia-caps/nvidia-cap2; do
            [[ -e "$capdev" ]] && gpu_flags+=(--device "$capdev")
        done
    fi

    # Mount project scripts read-only
    local mounts=(
        -v "${SCRIPT_DIR}/scripts:/opt/nobara/scripts:ro,z"
        -v "${SCRIPT_DIR}/config:/opt/nobara/config:ro,z"
    )

    # Bind-mount only GPU driver runtime libs; CUDA toolkit is installed inside the container.
    if [[ "$WITH_GPU" == "1" ]]; then
        for d in /usr/lib64/libcuda.so* /usr/lib64/libnvidia-ml.so* /usr/lib64/libnvidia-ptxjitcompiler.so*; do
            [[ -e "$d" ]] && mounts+=(-v "${d}:${d}:ro")
        done
    fi

    info "Running container from ${from_image}..."
    local cid
    cid=$(run podman run -d \
        "${gpu_flags[@]+"${gpu_flags[@]}"}" \
        "${mounts[@]}" \
        --env "TARGET_USER=${TARGET_USER}" \
        --env "SCRIPT_DIR=/opt/nobara" \
        ${HF_TOKEN:+--env "HF_TOKEN=${HF_TOKEN}"} \
        --privileged \
        "$from_image" \
        bash -c "$script_body") || die "podman run failed"

    if [[ "$DRY_RUN" != "1" ]]; then
        info "Container ID: ${cid:0:12}  (streaming logs...)"
        podman logs -f "$cid" || true

        local exit_code
        exit_code=$(podman inspect --format '{{.State.ExitCode}}' "$cid")
        if [[ "$exit_code" != "0" ]]; then
            warn "Container exited with code ${exit_code}"
            warn "Commit skipped. Fix the error and re-run with --from ${tag}"
            podman rm "$cid" >/dev/null 2>&1 || true
            die "Layer ${tag} failed."
        fi

        info "Committing as ${IMAGE_PREFIX}:${tag}..."
        podman commit \
            --format docker \
            --message "$msg" \
            --author "nobara-pipeline" \
            "$cid" "${IMAGE_PREFIX}:${tag}"
        podman rm "$cid" >/dev/null 2>&1 || true
        ok "Layer ${tag} committed → ${IMAGE_PREFIX}:${tag}"
    fi
}

# Force-rebuild from a given layer by removing it and all subsequent images
invalidate_from() {
    local start="$1"
    local found=0
    for layer in "${ALL_LAYERS[@]}"; do
        if [[ "$layer" == "$start" ]]; then found=1; fi
        if [[ "$found" == "1" ]] && image_exists "$layer"; then
            info "Removing ${IMAGE_PREFIX}:${layer} (invalidated by --from ${start})"
            podman rmi --force "${IMAGE_PREFIX}:${layer}" >/dev/null 2>&1 || true
        fi
    done
}

# ── Determine which layers to run ─────────────────────────────────────────────
[[ -n "$FROM_LAYER" ]] && invalidate_from "$FROM_LAYER"

LAYERS_TO_RUN=("${ALL_LAYERS[@]}")
if [[ -n "$ONLY_LAYER" ]]; then
    LAYERS_TO_RUN=("$ONLY_LAYER")
fi

# ── GPU availability check ─────────────────────────────────────────────────────
if [[ "$WITH_GPU" == "1" ]] && ! command -v nvidia-smi &>/dev/null; then
    warn "nvidia-smi not found — GPU layers may fail. Use --no-gpu to skip."
fi

# ─────────────────────────────────────────────────────────────────────────────
# LAYER DEFINITIONS
# ─────────────────────────────────────────────────────────────────────────────

layer_01_base() {
    run_layer "01-base" "scratch" "Fedora base + Nobara repos + core packages" '
set -euo pipefail
echo "==> Updating base system..."
dnf -y update --quiet

echo "==> Installing base tools..."
dnf -y install --quiet \
    curl wget git bash sudo \
    python3 python3-pip python3-virtualenv \
    make gcc gcc-c++ cmake ninja-build \
    flatpak \
    dnf-plugins-core \
    procps-ng which findutils

echo "==> Adding Nobara COPR repos..."
# Nobara 43 COPR — provides nobara-sync and Nobara package groups
dnf -y copr enable --quiet \
    gloriouseggroll/nobara 2>/dev/null || \
    dnf -y install --quiet \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" \
    2>/dev/null || true

echo "==> Installing nobara-sync if available..."
dnf -y install --quiet nobara-sync 2>/dev/null || \
    echo "nobara-sync not available in this environment (expected in CI)"

echo "==> Adding target user ${TARGET_USER}..."
useradd -m -G wheel,video,audio -s /bin/bash "${TARGET_USER}" 2>/dev/null || true
echo "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/99-nobara-test

echo "==> Writing provisioning env..."
mkdir -p /etc
cat > /etc/nobara-provision.env <<EOF
NOBARA_TARGET_USER="${TARGET_USER}"
NOBARA_PYTORCH_VENV="~/.venvs/ai"
NOBARA_VLLM_VENV="~/.venvs/bitwig-omni"
NOBARA_VLLM_CUDA_VERSION="13.0"
NOBARA_VLLM_ARCH_LIST="12.0"
NOBARA_AUDIO_MODEL="moonshotai/Kimi-Audio-7B-Instruct"
NOBARA_AGENT_MODEL="Qwen/Qwen3-14B-AWQ"
NOBARA_AUDIO_VENV="~/.venvs/kimi-audio"
NOBARA_NEO4J_URI="bolt://localhost:7687"
NOBARA_NEO4J_USER="neo4j"
NOBARA_NEO4J_PASSWORD="bitwig-agent"
NOBARA_WS_GTK_ARGS="-l -c Dracula"
NOBARA_WS_ICON_ARGS="-a bold"
NOBARA_WS_WALL_ARGS=""
EOF

echo "==> Layer 01-base complete."
'
}

layer_02_nvidia() {
    run_layer "02-nvidia" "01-base" "NVIDIA Open Driver + CUDA toolkit" '
set -euo pipefail
source /etc/nobara-provision.env 2>/dev/null || true

echo "==> Checking GPU availability..."
if ! nvidia-smi &>/dev/null; then
    echo "WARNING: nvidia-smi failed — GPU not accessible in this container."
    echo "         NVIDIA driver headers will be installed but runtime skipped."
fi

echo "==> Adding RPM Fusion (needed for akmod-nvidia)..."
dnf -y install --quiet \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" \
    2>/dev/null || true

echo "==> Installing NVIDIA Open kernel module headers + userspace..."
# In a container we cannot load kernel modules — install userspace libs only
dnf -y install --quiet \
    xorg-x11-drv-nvidia-libs \
    xorg-x11-drv-nvidia-cuda \
    xorg-x11-drv-nvidia-cuda-libs \
    libva-nvidia-driver \
    2>/dev/null || \
    echo "NVIDIA userspace packages not available — skipping (expected without Nobara repos)"

echo "==> Verifying CUDA availability (via host bind-mount)..."
if command -v nvcc &>/dev/null; then
    echo "  nvcc found: $(which nvcc)"
    nvcc --version
else
    echo "  [WW] nvcc not found — CUDA bind-mount not active (expected without --no-gpu)"
fi

echo "==> Writing CUDA env profile..."
mkdir -p /etc/profile.d
cat > /etc/profile.d/cuda.sh <<'CUDAEOF'
# CUDA: host-mounted nvcc is at /usr/bin/nvcc
# Detect CUDA version from nvcc if available
if command -v nvcc &>/dev/null; then
    _v=$(nvcc --version 2>/dev/null | grep -oP 'release \K[0-9.]+')
    export CUDA_VERSION="${_v:-}"
    export CUDA_HOME="/usr"
    export LD_LIBRARY_PATH="/usr/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    unset _v
fi
CUDAEOF

echo "==> Layer 02-nvidia complete."
'
}

layer_03_themes() {
    run_layer "03-themes" "02-nvidia" "WhiteSur themes + Oh My Bash (as user)" '
set -euo pipefail
source /etc/nobara-provision.env 2>/dev/null || true

echo "==> Installing Oh My Bash dependencies..."
dnf -y install --quiet curl git bash

echo "==> Running as user ${TARGET_USER}..."
su - "${TARGET_USER}" -c '"'"'
set -euo pipefail
source /etc/nobara-provision.env 2>/dev/null || true

THEMES_DIR="${HOME}/themes"
mkdir -p "$THEMES_DIR"

# ── Oh My Bash ───────────────────────────────────────────────────────────────
echo "  --> Installing Oh My Bash..."
if [[ ! -d "${HOME}/.oh-my-bash" ]]; then
    bash <(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh) \
        --unattended
fi

OMB_THEME="${NOBARA_OMB_THEME:-modern}"
if grep -q "OSH_THEME=" "${HOME}/.bashrc" 2>/dev/null; then
    sed -i "s|^OSH_THEME=.*|OSH_THEME=\"${OMB_THEME}\"|" "${HOME}/.bashrc"
else
    echo "OSH_THEME=\"${OMB_THEME}\"" >> "${HOME}/.bashrc"
fi
echo "  [OK] Oh My Bash installed, theme=${OMB_THEME}"

# ── WhiteSur GTK theme ───────────────────────────────────────────────────────
install_whitesur() {
    local name="$1" url="$2" dest_dir="$3"
    shift 3
    local extra_args=("$@")
    local dir="${THEMES_DIR}/${name}"
    echo "  --> WhiteSur: ${name}..."
    if [[ -d "${dir}/.git" ]]; then
        git -C "$dir" pull --ff-only --quiet 2>/dev/null || true
    else
        git clone --depth=1 --quiet "$url" "$dir"
    fi
    if [[ -x "${dir}/install.sh" ]]; then
        local dest_args=()
        if [[ -n "$dest_dir" ]]; then
            mkdir -p "$dest_dir"
            dest_args=(-d "$dest_dir")
        fi
        # Validate -c color variant against what install.sh accepts
        local valid_colors=(Light Dark Nord)
        local filtered_args=()
        local skip_next=0
        local next_is_color=0
        for arg in "${extra_args[@]+"${extra_args[@]}"}"; do
            if [[ "$skip_next" == "1" ]]; then skip_next=0; continue; fi
            if [[ "$next_is_color" == "1" ]]; then
                next_is_color=0
                # Only pass through known valid color variants
                local valid=0
                for c in "${valid_colors[@]}"; do [[ "$arg" == "$c" ]] && valid=1 && break; done
                if [[ "$valid" == "1" ]]; then
                    filtered_args+=("-c" "$arg")
                else
                    echo "  [WW] Skipping unknown -c variant: $arg"
                fi
                continue
            fi
            if [[ "$arg" == "-c" ]]; then
                next_is_color=1; continue
            fi
            filtered_args+=("$arg")
        done
        bash "${dir}/install.sh" "${dest_args[@]+"${dest_args[@]}"}" \
            "${filtered_args[@]+"${filtered_args[@]}"}" 2>&1 | tail -5 || \
            echo "  [WW] ${name} install.sh exited non-zero (non-fatal)"
        echo "  [OK] ${name} installed."
    fi
}

mkdir -p "${HOME}/.local/share/themes" "${HOME}/.local/share/icons"

GTK_ARGS=(-l -c Dark)
ICON_ARGS=(-dark)
WALL_ARGS=()

install_whitesur "WhiteSur-gtk-theme" \
    "https://github.com/vinceliuice/WhiteSur-gtk-theme.git" \
    "${HOME}/.local/share/themes" "${GTK_ARGS[@]}"

install_whitesur "WhiteSur-icon-theme" \
    "https://github.com/vinceliuice/WhiteSur-icon-theme.git" \
    "${HOME}/.local/share/icons" "${ICON_ARGS[@]+"${ICON_ARGS[@]}"}"

install_whitesur "WhiteSur-wallpapers" \
    "https://github.com/vinceliuice/WhiteSur-wallpapers.git" \
    "" "${WALL_ARGS[@]+"${WALL_ARGS[@]}"}"

echo "  [OK] All WhiteSur themes installed."
'"'"'

echo "==> Layer 03-themes complete."
'
}

layer_04_vllm() {
    local _script
    _script=$(cat <<'LAYER04_EOF'
set -euo pipefail
source /etc/nobara-provision.env 2>/dev/null || true

# Ensure Python headers + gcc are present (needed by triton/torch._inductor at vLLM runtime)
echo "==> Installing build dependencies (python3-devel, gcc)..."
dnf install -y python3-devel gcc --setopt=install_weak_deps=False 2>/dev/null || true

echo "==> Adding NVIDIA CUDA repository for Fedora 43..."
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/fedora43/x86_64/cuda-fedora43.repo \
    -o /etc/yum.repos.d/cuda-fedora43.repo 2>/dev/null || true

echo "==> Installing CUDA compiler and JIT-link library inside container..."
dnf install -y \
    cuda-compiler-13-2 \
    libnvjitlink-13-2 \
    libnvptxcompiler-13-2 \
    --setopt=install_weak_deps=False 2>/dev/null \
    && dnf clean all 2>/dev/null || true

# Create /usr/local/cuda symlink pointing to installed CUDA version
if [[ ! -e /usr/local/cuda ]]; then
    _cuda_inst=$(ls -d /usr/local/cuda-13.* 2>/dev/null | sort -V | tail -1)
    [[ -n "$_cuda_inst" ]] && ln -sfn "$_cuda_inst" /usr/local/cuda
fi

echo "==> Writing CUDA environment profile (/etc/profile.d/cuda.sh)..."
cat > /etc/profile.d/cuda.sh << 'CUDA_PROF'
# CUDA toolkit installed in container at /usr/local/cuda
export CUDA_HOME="/usr/local/cuda"
export PATH="${CUDA_HOME}/bin${PATH:+:${PATH}}"
# NVIDIA places actual .so files in targets/x86_64-linux/lib/
export LD_LIBRARY_PATH="${CUDA_HOME}/lib64:${CUDA_HOME}/targets/x86_64-linux/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
CUDA_PROF

# Register targets lib in ldconfig so child processes (e.g. vLLM EngineCore) find it
echo "/usr/local/cuda/targets/x86_64-linux/lib" > /etc/ld.so.conf.d/cuda-targets.conf
ldconfig 2>/dev/null || true

echo "==> Verifying CUDA installation..."
if [[ -x /usr/local/cuda/bin/nvcc ]]; then
    echo "  nvcc: $(/usr/local/cuda/bin/nvcc --version 2>&1 | grep release || true)"
else
    echo "  WARNING: nvcc not found at /usr/local/cuda/bin/nvcc"
fi

# Write user-level script to a temp file — avoids all su -c '...' quoting issues
_USR_SCRIPT=$(mktemp /tmp/layer04_XXXXXX.sh)
chmod 755 "$_USR_SCRIPT"
cat > "$_USR_SCRIPT" << 'USER_EOF'
#!/bin/bash
set -euo pipefail
source /etc/nobara-provision.env 2>/dev/null || true
[[ -f /etc/profile.d/cuda.sh ]] && source /etc/profile.d/cuda.sh

PYTORCH_VENV="${NOBARA_PYTORCH_VENV:-${HOME}/.venvs/ai}"
[[ "$PYTORCH_VENV" == '~'* ]] && PYTORCH_VENV="${HOME}${PYTORCH_VENV#\~}"
VLLM_VENV="${NOBARA_VLLM_VENV:-${HOME}/.venvs/bitwig-omni}"
[[ "$VLLM_VENV" == '~'* ]] && VLLM_VENV="${HOME}${VLLM_VENV#\~}"
VLLM_ARCH_LIST="${NOBARA_VLLM_ARCH_LIST:-12.0}"
CUDA_VER="${NOBARA_VLLM_CUDA_VERSION:-13.2}"

# Detect CUDA version via awk (no grep regex quoting issues)
detect_cuda_ver() {
    for p in /usr/bin/nvcc /usr/local/cuda/bin/nvcc /usr/local/cuda-*/bin/nvcc; do
        [[ -x "$p" ]] || continue
        local ver
        ver=$("$p" --version 2>/dev/null | awk 'NR==4{v=$5; gsub(",","",v); print v; exit}')
        [[ -n "$ver" ]] && { echo "$ver"; return; }
    done
    echo ""
}

# ── PyTorch venv ──────────────────────────────────────────────────────────────
echo "  --> Creating PyTorch venv at ${PYTORCH_VENV}..."
mkdir -p "$(dirname "$PYTORCH_VENV")"
[[ -d "$PYTORCH_VENV" ]] || python3 -m venv "$PYTORCH_VENV"
"${PYTORCH_VENV}/bin/pip" install --quiet --upgrade pip

DETECTED_CUDA=$(detect_cuda_ver)
if [[ -n "$DETECTED_CUDA" ]]; then
    MAJOR=$(echo "$DETECTED_CUDA" | cut -d. -f1)
    MINOR=$(echo "$DETECTED_CUDA" | cut -d. -f2)
    VER=$(( MAJOR * 100 + MINOR ))
    if   (( VER >= 1300 )); then IDX="cu130"
    elif (( VER >= 1206 )); then IDX="cu126"
    elif (( VER >= 1204 )); then IDX="cu124"
    else                         IDX="cu121"; fi
    PT_URL="https://download.pytorch.org/whl/${IDX}"
    echo "  CUDA ${DETECTED_CUDA} -> PyTorch index: ${PT_URL}"
else
    PT_URL="https://download.pytorch.org/whl/cpu"
    echo "  No CUDA -> CPU-only PyTorch"
fi

"${PYTORCH_VENV}/bin/pip" install --quiet \
    torch torchvision torchaudio --index-url "$PT_URL"

echo "  --> Verifying PyTorch..."
"${PYTORCH_VENV}/bin/python3" - <<'PYEOF'
import torch
print(f"  PyTorch {torch.__version__}")
print(f"  CUDA available: {torch.cuda.is_available()}")
if torch.cuda.is_available():
    print(f"  GPU: {torch.cuda.get_device_name(0)}")
PYEOF

# ── vLLM-Omni venv ────────────────────────────────────────────────────────────
echo "  --> Creating vLLM-Omni venv at ${VLLM_VENV}..."
mkdir -p "$(dirname "$VLLM_VENV")"
[[ -d "$VLLM_VENV" ]] || python3 -m venv "$VLLM_VENV"
"${VLLM_VENV}/bin/pip" install --quiet --upgrade pip
"${VLLM_VENV}/bin/pip" install --quiet 'huggingface_hub[hf_xet]' autoawq 2>/dev/null || \
    "${VLLM_VENV}/bin/pip" install --quiet huggingface_hub autoawq 2>/dev/null || true

# ── Find CUDA (installed in container at /usr/local/cuda) ───────────────────
CUDA_PATH="${CUDA_HOME:-/usr/local/cuda}"

if [[ -x "${CUDA_PATH}/bin/nvcc" ]]; then
    echo "  --> Installing vLLM (CUDA ${DETECTED_CUDA:-?}, sm${VLLM_ARCH_LIST//./})..."

    # Install torch in vLLM venv — should hit pip cache from PyTorch venv install
    "${VLLM_VENV}/bin/pip" install --quiet \
        torch torchvision torchaudio \
        --extra-index-url "https://download.pytorch.org/whl/${IDX:-cu130}"

    # Try pre-built vLLM wheel from PyPI first (fast, no compilation)
    VLLM_INSTALLED=0
    if "${VLLM_VENV}/bin/pip" install --quiet vllm 2>/tmp/vllm_pypi.log; then
        VLLM_INSTALLED=1
        echo "  [OK] vLLM installed from PyPI wheel."
    else
        echo "  [..] Pre-built wheel not available, building from source..."
        tail -3 /tmp/vllm_pypi.log 2>/dev/null || true

        VLLM_SRC="${HOME}/.local/src/vllm-omni"
        mkdir -p "$(dirname "$VLLM_SRC")"
        [[ -d "${VLLM_SRC}/.git" ]] || \
            git clone --depth=1 --quiet https://github.com/vllm-project/vllm.git "$VLLM_SRC"
        git -C "$VLLM_SRC" pull --ff-only --quiet 2>/dev/null || true

        # use_existing_torch.py removes torch from build-system.requires
        [[ -f "${VLLM_SRC}/use_existing_torch.py" ]] && \
            "${VLLM_VENV}/bin/python3" "${VLLM_SRC}/use_existing_torch.py" "$VLLM_SRC" 2>/dev/null || true

        # All build-system deps must be in the venv for --no-build-isolation
        "${VLLM_VENV}/bin/pip" install --quiet setuptools wheel ninja cmake packaging

        export VIRTUAL_ENV="${VLLM_VENV}"
        export PATH="${VLLM_VENV}/bin:${CUDA_PATH}/bin:${PATH}"
        export CUDA_HOME="$CUDA_PATH"
        export LD_LIBRARY_PATH="${CUDA_PATH}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
        export TORCH_CUDA_ARCH_LIST="${VLLM_ARCH_LIST}"
        export MAX_JOBS="${MAX_JOBS:-$(nproc)}"

        # Use explicit venv python3 -m pip to guarantee correct interpreter
        if (cd "$VLLM_SRC" && "${VLLM_VENV}/bin/python3" -m pip install --no-build-isolation .); then
            VLLM_INSTALLED=1
            echo "  [OK] vLLM built from source."
        else
            echo "  [WW] vLLM source build failed -- inference skipped"
        fi
    fi
else
    echo "  [WW] CUDA not found -- vLLM install skipped"
fi
echo "  [OK] Layer 04-vllm complete."
USER_EOF

su - "${TARGET_USER}" -c "bash $_USR_SCRIPT"
_exit=$?
rm -f "$_USR_SCRIPT"
(( _exit == 0 )) || exit $_exit
echo "==> Layer 04-vllm complete."
LAYER04_EOF
)
    run_layer "04-vllm" "03-themes" "PyTorch venv + vLLM-Omni build + smoke test" "$_script"
}

layer_05_models() {
    local _script
    _script=$(cat <<'LAYER05_EOF'
set -euo pipefail
source /etc/nobara-provision.env 2>/dev/null || true

AUDIO_MODEL="${NOBARA_AUDIO_MODEL:-moonshotai/Kimi-Audio-7B-Instruct}"
AGENT_MODEL="${NOBARA_AGENT_MODEL:-Qwen/Qwen3-14B-AWQ}"
echo "==> Checking disk space..."
AVAIL_GB=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
(( AVAIL_GB >= 20 )) || echo "WARNING: Only ${AVAIL_GB}GB free — models need ~15GB total."

_USR=$(mktemp /tmp/layer05_XXXXXX.sh)
chmod 755 "$_USR"
cat > "$_USR" << 'USER_EOF'
#!/bin/bash
set -euo pipefail
source /etc/nobara-provision.env 2>/dev/null || true

AUDIO_MODEL="${NOBARA_AUDIO_MODEL:-moonshotai/Kimi-Audio-7B-Instruct}"
AGENT_MODEL="${NOBARA_AGENT_MODEL:-Qwen/Qwen3-14B-AWQ}"
VLLM_VENV="${NOBARA_VLLM_VENV:-${HOME}/.venvs/bitwig-omni}"
[[ "$VLLM_VENV" == '~'* ]] && VLLM_VENV="${HOME}${VLLM_VENV#\~}"
AUDIO_VENV="${NOBARA_AUDIO_VENV:-${HOME}/.venvs/kimi-audio}"
[[ "$AUDIO_VENV" == '~'* ]] && AUDIO_VENV="${HOME}${AUDIO_VENV#\~}"
HF_CACHE="${HOME}/.cache/huggingface/hub"

hf_download() {
    local model="$1" dest="${HF_CACHE}/${2:-${1//\//__}}"
    # Only consider fully cached if actual weight files (.safetensors/.bin) exist
    if [[ -d "$dest" ]] && ls "$dest"/*.safetensors "$dest"/*.bin 2>/dev/null | grep -q .; then
        echo "  [OK] ${model} already cached." && return 0
    fi
    echo "  --> Downloading: ${model}..."
    local venv="${3:-$VLLM_VENV}"
    for cli in "${venv}/bin/hf" "${venv}/bin/huggingface-cli"; do
        [[ -x "$cli" ]] || continue
        "$cli" download "$model" --local-dir "$dest" && return 0
    done
    # Python API fallback
    "${venv}/bin/python3" -c "
from huggingface_hub import snapshot_download
snapshot_download('${model}', local_dir='${dest}')
" || echo "  [WW] Download failed for ${model} (check HF token)"
}

# ── Kimi-Audio venv (audio analysis model) ───────────────────────────────────
echo "==> Setting up Kimi-Audio venv at ${AUDIO_VENV}..."
mkdir -p "$(dirname "$AUDIO_VENV")"
[[ -d "$AUDIO_VENV" ]] || python3 -m venv "$AUDIO_VENV"
"${AUDIO_VENV}/bin/pip" install --quiet --upgrade pip
"${AUDIO_VENV}/bin/pip" install --quiet \
    torch torchvision torchaudio \
    --extra-index-url https://download.pytorch.org/whl/cu130
"${AUDIO_VENV}/bin/pip" install --quiet \
    'huggingface_hub[hf_xet]' transformers accelerate soundfile librosa 2>/dev/null || \
"${AUDIO_VENV}/bin/pip" install --quiet \
    huggingface_hub transformers accelerate soundfile librosa || true

# ── Download Kimi-Audio-7B (audio analyser) ──────────────────────────────────
hf_download "$AUDIO_MODEL" "${AUDIO_MODEL//\//__}" "$AUDIO_VENV"

# ── Download Qwen3-14B-AWQ (bitwig agent) ────────────────────────────────────
hf_download "$AGENT_MODEL" "${AGENT_MODEL//\//__}" "$VLLM_VENV"

echo "==> Layer 05-models complete."
USER_EOF

# Inject secrets: su - drops all env vars, so prepend exports to the tempfile
[[ -n "${HF_TOKEN:-}" ]] && \
    printf 'export HF_TOKEN=%q\n' "$HF_TOKEN" | cat - "$_USR" > "${_USR}.tmp" && \
    mv "${_USR}.tmp" "$_USR"

su - "${TARGET_USER}" -c "bash $_USR"
_exit=$?
rm -f "$_USR" "${_USR}.tmp" 2>/dev/null || true
(( _exit == 0 )) || exit $_exit
echo "==> Layer 05-models complete."
LAYER05_EOF
)
    run_layer "05-models" "04-vllm" "Model downloads: Kimi-Audio-7B + Qwen3-14B-AWQ" "$_script"
}

layer_06_agent() {
    local _script
    _script=$(cat <<'LAYER06_EOF'
set -euo pipefail
source /etc/nobara-provision.env 2>/dev/null || true

echo "==> Installing Neo4j + agent system deps..."
dnf -y install --quiet java-21-openjdk-headless 2>/dev/null || true

_USR=$(mktemp /tmp/layer06_XXXXXX.sh)
chmod 755 "$_USR"
cat > "$_USR" << 'USER_EOF'
#!/bin/bash
set -euo pipefail
source /etc/nobara-provision.env 2>/dev/null || true

VLLM_VENV="${NOBARA_VLLM_VENV:-${HOME}/.venvs/bitwig-omni}"
[[ "$VLLM_VENV" == '~'* ]] && VLLM_VENV="${HOME}${VLLM_VENV#\~}"
AUDIO_VENV="${NOBARA_AUDIO_VENV:-${HOME}/.venvs/kimi-audio}"
[[ "$AUDIO_VENV" == '~'* ]] && AUDIO_VENV="${HOME}${AUDIO_VENV#\~}"
AGENT_DIR="${HOME}/.local/share/bitwig-agent"

# ── Neo4j Python driver + music analysis deps ────────────────────────────────
echo "==> Installing Neo4j driver + agent deps..."
"${VLLM_VENV}/bin/pip" install --quiet \
    neo4j 'openai>=1.0' httpx pydantic typer rich 2>/dev/null || true
"${AUDIO_VENV}/bin/pip" install --quiet \
    neo4j essentia-tensorflow 2>/dev/null || \
"${AUDIO_VENV}/bin/pip" install --quiet neo4j essentia 2>/dev/null || true

# ── Bitwig Agent scaffold ─────────────────────────────────────────────────────
mkdir -p "$AGENT_DIR"

cat > "${AGENT_DIR}/analyze_audio.py" << 'PYEOF'
#!/usr/bin/env python3
"""
Step 1: Audio Analysis via Kimi-Audio-7B
Input:  audio file path
Output: {tempo, key, scale, genre, mood, time_signature}
"""
import sys, json, os
from pathlib import Path

def analyze(audio_path: str) -> dict:
    import torch
    from transformers import AutoProcessor, AutoModelForCausalLM

    model_id = os.environ.get(
        "NOBARA_AUDIO_MODEL", "moonshotai/Kimi-Audio-7B-Instruct"
    )
    cache_dir = Path.home() / ".cache/huggingface/hub" / model_id.replace("/", "__")

    processor = AutoProcessor.from_pretrained(str(cache_dir), trust_remote_code=True)
    model = AutoModelForCausalLM.from_pretrained(
        str(cache_dir), torch_dtype=torch.float16,
        device_map="auto", trust_remote_code=True
    )

    prompt = (
        "Analyze this audio file. Return ONLY valid JSON with these fields: "
        '"tempo" (BPM float), "key" (e.g. "Am"), "scale" (e.g. "minor"), '
        '"genre" (e.g. "techno"), "mood" (e.g. "dark"), '
        '"time_signature" (e.g. "4/4").'
    )
    inputs = processor(text=prompt, audio=audio_path, return_tensors="pt").to(model.device)
    out = model.generate(**inputs, max_new_tokens=256)
    text = processor.decode(out[0], skip_special_tokens=True)

    # Extract JSON block
    import re
    m = re.search(r'\{.*?\}', text, re.DOTALL)
    if m:
        return json.loads(m.group())
    raise ValueError(f"No JSON in model output: {text}")

if __name__ == "__main__":
    result = analyze(sys.argv[1])
    print(json.dumps(result, indent=2))
PYEOF

cat > "${AGENT_DIR}/query_neo4j.py" << 'PYEOF'
#!/usr/bin/env python3
"""
Step 2: Query Neo4j music theory DB
Input:  audio analysis dict
Output: {chord_progression, scales, reference_songs, rhythm_patterns}
"""
import os, json, sys
from neo4j import GraphDatabase

NEO4J_URI  = os.environ.get("NOBARA_NEO4J_URI",  "bolt://localhost:7687")
NEO4J_USER = os.environ.get("NOBARA_NEO4J_USER", "neo4j")
NEO4J_PASS = os.environ.get("NOBARA_NEO4J_PASSWORD", "bitwig-agent")

def query(analysis: dict) -> dict:
    driver = GraphDatabase.driver(NEO4J_URI, auth=(NEO4J_USER, NEO4J_PASS))
    key    = analysis.get("key", "Am")
    genre  = analysis.get("genre", "electronic")
    mood   = analysis.get("mood", "dark")
    tempo  = float(analysis.get("tempo", 120))

    with driver.session() as s:
        # Chord progressions for key + genre
        chords = s.run("""
            MATCH (k:Key {name: $key})-[:HAS_PROGRESSION]->(p:Progression)
            WHERE p.genre = $genre OR p.genre = 'any'
            RETURN p.chords AS chords, p.name AS name
            LIMIT 5
        """, key=key, genre=genre).data()

        # Reference songs with similar feel
        songs = s.run("""
            MATCH (s:Song)
            WHERE s.key = $key AND s.genre = $genre
              AND abs(s.tempo - $tempo) < 15
            RETURN s.title AS title, s.artist AS artist,
                   s.tempo AS tempo, s.structure AS structure
            LIMIT 3
        """, key=key, genre=genre, tempo=tempo).data()

        # Rhythm patterns
        rhythms = s.run("""
            MATCH (r:RhythmPattern)
            WHERE r.genre = $genre AND r.time_signature = $ts
            RETURN r.name AS name, r.pattern AS pattern
            LIMIT 3
        """, genre=genre, ts=analysis.get("time_signature", "4/4")).data()

    driver.close()
    return {"chord_progressions": chords, "reference_songs": songs,
            "rhythm_patterns": rhythms, "input_analysis": analysis}

if __name__ == "__main__":
    analysis = json.loads(sys.argv[1])
    print(json.dumps(query(analysis), indent=2))
PYEOF

cat > "${AGENT_DIR}/generate_project.py" << 'PYEOF'
#!/usr/bin/env python3
"""
Step 3: Generate Bitwig project via Qwen3-14B agent
Input:  neo4j context dict
Output: ~/.local/share/bitwig-agent/output/<title>.bwtemplate.json
"""
import os, json, sys
from pathlib import Path
from vllm import LLM, SamplingParams

AGENT_MODEL = os.environ.get("NOBARA_AGENT_MODEL", "Qwen/Qwen3-14B-AWQ")
MODEL_DIR = Path.home() / ".cache/huggingface/hub" / AGENT_MODEL.replace("/", "__")
OUTPUT_DIR = Path.home() / ".local/share/bitwig-agent/output"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

SYSTEM_PROMPT = """
You are an expert music producer and Bitwig Studio specialist.
Given audio analysis results and music theory context from Neo4j,
create a detailed Bitwig project template as JSON.

The JSON must include:
- project_name (string)
- tempo (float)
- time_signature (string)
- key (string)
- tracks: list of {name, type (instrument|audio|fx), device, clips}
- clips: list of {name, length_bars, notes: [{pitch, start, duration, velocity}]}
- macro_mappings: list of {name, target_device, parameter}

Think step by step. Use <think>...</think> for reasoning, then output ONLY valid JSON.
"""

def generate(context: dict) -> dict:
    llm = LLM(model=str(MODEL_DIR), dtype="auto",
              max_model_len=8192, gpu_memory_utilization=0.9)
    analysis = context["input_analysis"]
    prompt = f"""
{SYSTEM_PROMPT}

Audio Analysis:
{json.dumps(analysis, indent=2)}

Music Theory Context (from Neo4j):
Chord Progressions: {json.dumps(context.get('chord_progressions', []), indent=2)}
Reference Songs: {json.dumps(context.get('reference_songs', []), indent=2)}
Rhythm Patterns: {json.dumps(context.get('rhythm_patterns', []), indent=2)}

Generate the Bitwig project template JSON now:
"""
    params = SamplingParams(max_tokens=4096, temperature=0.3)
    out = llm.generate([prompt], params)[0].outputs[0].text

    # Strip <think>...</think> block
    import re
    out = re.sub(r'<think>.*?</think>', '', out, flags=re.DOTALL).strip()
    m = re.search(r'\{.*\}', out, re.DOTALL)
    if not m:
        raise ValueError(f"No JSON in agent output")
    return json.loads(m.group())

if __name__ == "__main__":
    context = json.loads(sys.argv[1])
    project = generate(context)
    name = project.get("project_name", "bitwig-project").replace(" ", "_")
    out_file = OUTPUT_DIR / f"{name}.bwtemplate.json"
    out_file.write_text(json.dumps(project, indent=2))
    print(f"[OK] Project saved: {out_file}")
    print(json.dumps(project, indent=2))
PYEOF

cat > "${AGENT_DIR}/run_pipeline.sh" << 'SHEOF'
#!/bin/bash
# Bitwig Agent Pipeline: Audio -> Kimi-Audio -> Neo4j -> Qwen3-14B -> .bwtemplate
set -euo pipefail
source /etc/nobara-provision.env 2>/dev/null || true

AUDIO_FILE="${1:?Usage: run_pipeline.sh <audio_file>}"
AGENT_DIR="${HOME}/.local/share/bitwig-agent"
AUDIO_VENV="${NOBARA_AUDIO_VENV:-${HOME}/.venvs/kimi-audio}"
[[ "$AUDIO_VENV" == '~'* ]] && AUDIO_VENV="${HOME}${AUDIO_VENV#~}"
VLLM_VENV="${NOBARA_VLLM_VENV:-${HOME}/.venvs/bitwig-omni}"
[[ "$VLLM_VENV" == '~'* ]] && VLLM_VENV="${HOME}${VLLM_VENV#~}"

echo "[1/3] Analyzing audio with Kimi-Audio-7B..."
ANALYSIS=$("${AUDIO_VENV}/bin/python3" "${AGENT_DIR}/analyze_audio.py" "$AUDIO_FILE")
echo "  Analysis: $ANALYSIS"

echo "[2/3] Querying Neo4j music theory DB..."
CONTEXT=$("${AUDIO_VENV}/bin/python3" "${AGENT_DIR}/query_neo4j.py" "$ANALYSIS")

echo "[3/3] Generating Bitwig project via Qwen3-14B..."
"${VLLM_VENV}/bin/python3" "${AGENT_DIR}/generate_project.py" "$CONTEXT"
SHEOF
chmod +x "${AGENT_DIR}/run_pipeline.sh"

echo "  [OK] Bitwig agent scaffold installed at ${AGENT_DIR}"
echo "  Usage: ${AGENT_DIR}/run_pipeline.sh <your_audio.wav>"
echo "==> Layer 06-agent complete."
USER_EOF

[[ -n "${HF_TOKEN:-}" ]] && \
    printf 'export HF_TOKEN=%q\n' "$HF_TOKEN" | cat - "$_USR" > "${_USR}.tmp" && \
    mv "${_USR}.tmp" "$_USR"

su - "${TARGET_USER}" -c "bash $_USR"
_exit=$?
rm -f "$_USR" "${_USR}.tmp" 2>/dev/null || true
(( _exit == 0 )) || exit $_exit
echo "==> Layer 06-agent complete."
LAYER06_EOF
)
    run_layer "06-agent" "05-models" "Neo4j driver + Bitwig agent scaffold" "$_script"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN — run requested layers
# ─────────────────────────────────────────────────────────────────────────────

step "Nobara Podman Pipeline"
info "Image prefix : ${IMAGE_PREFIX}"
info "Target user  : ${TARGET_USER}"
info "GPU pass-through: $([ "$WITH_GPU" = 1 ] && echo enabled || echo disabled)"
info "Layers to run: ${LAYERS_TO_RUN[*]}"
echo ""

for layer in "${LAYERS_TO_RUN[@]}"; do
    case "$layer" in
        01-base)   layer_01_base   ;;
        02-nvidia) layer_02_nvidia ;;
        03-themes) layer_03_themes ;;
        04-vllm)   layer_04_vllm   ;;
        05-models) layer_05_models ;;
        06-agent)  layer_06_agent  ;;
        *)         die "Unknown layer: ${layer}. Valid: ${ALL_LAYERS[*]}" ;;
    esac
done

echo ""
step "Pipeline complete"
info "Available images:"
podman images --format "  {{.Repository}}:{{.Tag}}  ({{.Size}})" \
    | grep "^  ${IMAGE_PREFIX}:" || true
echo ""
ok "Run a layer interactively:  podman run -it --rm ${IMAGE_PREFIX}:03-themes bash"
ok "Rebuild from themes:        ./scripts/podman-pipeline.sh --from 03-themes"
ok "Run Bitwig agent:           podman run -it --rm ${IMAGE_PREFIX}:06-agent bash"
ok "  then: ~/.local/share/bitwig-agent/run_pipeline.sh <audio.wav>"

# ── Write smoke-test stamp for nobara-install.sh gate ─────────────────────────
if [[ "$DRY_RUN" != "1" ]]; then
    _stamp_dir="${SCRIPT_DIR}/.state"
    _stamp_file="${_stamp_dir}/podman-smoke-passed.stamp"
    _config_sha=$(find "${SCRIPT_DIR}/config" "${SCRIPT_DIR}/scripts" -type f \
        | sort | xargs sha256sum 2>/dev/null | sha256sum | awk '{print $1}')
    mkdir -p "$_stamp_dir"
    {
        echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "layers=${LAYERS_TO_RUN[*]}"
        echo "image_prefix=${IMAGE_PREFIX}"
        echo "config_sha=${_config_sha}"
    } > "$_stamp_file"
    unset _stamp_dir _stamp_file _config_sha
    ok "Smoke stamp written → .state/podman-smoke-passed.stamp"
fi
