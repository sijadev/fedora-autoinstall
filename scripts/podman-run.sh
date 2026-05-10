#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# podman-run.sh — interaktiven nobara-test Container starten
#
# Usage:
#   ./scripts/podman-run.sh [OPTIONS] [-- COMMAND...]
#
# Options:
#   --layer TAG      Image-Tag (default: 06-agent)
#   --user USER      Benutzer im Container (default: sija)
#   --image PREFIX   Image-Prefix (default: nobara-test)
#   --no-gpu         GPU-Geräte und Treiber-Mounts weglassen
#   --root           Als root einloggen statt als USER
#   -- CMD...        Beliebiger Befehl statt interaktiver Shell
#
# Beispiele:
#   ./scripts/podman-run.sh
#   ./scripts/podman-run.sh --layer 04-vllm
#   ./scripts/podman-run.sh -- bash -c 'nvidia-smi'
#   ./scripts/podman-run.sh -- bash /opt/nobara/scripts/run_pipeline.sh /tmp/audio.wav
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMAGE_PREFIX="nobara-test"
TARGET_USER="sija"
LAYER="06-agent"
WITH_GPU=1
AS_ROOT=0
EXTRA_CMD=()

# ── .env laden ────────────────────────────────────────────────────────────────
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    set -a; source "${SCRIPT_DIR}/.env"; set +a
fi

# ── Argumente parsen ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --layer)  LAYER="$2";        shift 2 ;;
        --user)   TARGET_USER="$2";  shift 2 ;;
        --image)  IMAGE_PREFIX="$2"; shift 2 ;;
        --no-gpu) WITH_GPU=0;        shift   ;;
        --root)   AS_ROOT=1;         shift   ;;
        --)       shift; EXTRA_CMD=("$@"); break ;;
        *)        echo "Unbekannte Option: $1" >&2; exit 1 ;;
    esac
done

IMAGE="${IMAGE_PREFIX}:${LAYER}"

# ── Image prüfen ──────────────────────────────────────────────────────────────
if ! podman image exists "$IMAGE" 2>/dev/null; then
    echo "FEHLER: Image '${IMAGE}' nicht gefunden." >&2
    echo "Verfügbare nobara-test Images:" >&2
    podman images --filter "reference=${IMAGE_PREFIX}:*" --format "  {{.Repository}}:{{.Tag}}" 2>/dev/null || true
    exit 1
fi

# ── GPU-Flags zusammenstellen ─────────────────────────────────────────────────
gpu_flags=()
mounts=()

if [[ "$WITH_GPU" == "1" ]]; then
    for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset; do
        [[ -e "$dev" ]] && gpu_flags+=(--device "$dev")
    done
    for lib in \
        /usr/lib64/libcuda.so* \
        /usr/lib64/libnvidia-ml.so* \
        /usr/lib64/libnvidia-ptxjitcompiler.so*
    do
        [[ -e "$lib" ]] && mounts+=(-v "${lib}:${lib}:ro")
    done
fi

# ── Startbefehl ───────────────────────────────────────────────────────────────
if [[ ${#EXTRA_CMD[@]} -gt 0 ]]; then
    # Expliziter Befehl übergeben
    run_cmd=("${EXTRA_CMD[@]}")
elif [[ "$AS_ROOT" == "1" ]]; then
    run_cmd=(bash)
else
    run_cmd=(bash -c "su - ${TARGET_USER}")
fi

# ── Info ──────────────────────────────────────────────────────────────────────
echo "==> Starte Container"
echo "    Image  : ${IMAGE}"
echo "    User   : $([ "$AS_ROOT" = 1 ] && echo root || echo "${TARGET_USER}")"
echo "    GPU    : $([ "$WITH_GPU" = 1 ] && echo aktiviert || echo deaktiviert)"
[[ ${#EXTRA_CMD[@]} -gt 0 ]] && echo "    Befehl : ${EXTRA_CMD[*]}"
echo ""

# ── Ausführen ─────────────────────────────────────────────────────────────────
exec podman run --rm -it \
    --privileged \
    "${gpu_flags[@]+"${gpu_flags[@]}"}" \
    "${mounts[@]+"${mounts[@]}"}" \
    ${HF_TOKEN:+--env "HF_TOKEN=${HF_TOKEN}"} \
    --env "TARGET_USER=${TARGET_USER}" \
    "$IMAGE" \
    "${run_cmd[@]}"
