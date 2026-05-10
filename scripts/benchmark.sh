#!/usr/bin/env bash
# scripts/benchmark.sh — GPU + vLLM + Audio pipeline benchmark
#
# Runs inside nobara-test:06-agent (or any later image).
# Tests:
#   1. CUDA device info + VRAM
#   2. PyTorch FLOPS  (FP32 / FP16 / BF16 matmul throughput)
#   3. vLLM inference throughput  (Qwen3-14B-AWQ, tokens/s)
#   4. Kimi-Audio load time       (model cold-start)
#   5. Neo4j connectivity         (bolt ping)
#
# Usage:
#   ./scripts/benchmark.sh [OPTIONS]
#
# Options:
#   --image TAG       Image to benchmark (default: nobara-test:06-agent)
#   --user NAME       User inside container  (default: sija)
#   --no-gpu          Run CPU-only (skip CUDA/vLLM tests)
#   --quick           Skip vLLM inference test (fast sanity-check only)
#   --neo4j URI       Neo4j bolt URI to test  (default: bolt://localhost:7687)
#   --out FILE        Write JSON report to FILE (default: logs/benchmark-<ts>.json)
#   -h, --help        Show this help

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── load .env ─────────────────────────────────────────────────────────────────
[[ -f "${SCRIPT_DIR}/.env" ]] && { set -a; source "${SCRIPT_DIR}/.env"; set +a; }

# ── defaults ──────────────────────────────────────────────────────────────────
IMAGE="nobara-test:06-agent"
TARGET_USER="sija"
WITH_GPU=1
QUICK=0
NEO4J_URI="bolt://localhost:7687"
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
OUT_FILE="${SCRIPT_DIR}/logs/benchmark-${TIMESTAMP}.json"

# ── colour helpers ─────────────────────────────────────────────────────────────
step()  { printf '\n\e[1;34m══ %s ══\e[0m\n' "$*"; }
ok()    { printf '\e[32m[OK]\e[0m  %s\n' "$*"; }
info()  { printf '\e[36m[..]\e[0m  %s\n' "$*"; }
warn()  { printf '\e[33m[WW]\e[0m  %s\n' "$*" >&2; }
die()   { printf '\e[31m[EE]\e[0m  %s\n' "$*" >&2; exit 1; }

# ── arg parsing ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)   IMAGE="$2";       shift 2 ;;
        --user)    TARGET_USER="$2"; shift 2 ;;
        --no-gpu)  WITH_GPU=0;       shift   ;;
        --quick)   QUICK=1;          shift   ;;
        --neo4j)   NEO4J_URI="$2";   shift 2 ;;
        --out)     OUT_FILE="$2";    shift 2 ;;
        -h|--help)
            sed -n '2,/^set /p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

mkdir -p "$(dirname "$OUT_FILE")"

# ── check image exists ────────────────────────────────────────────────────────
podman image exists "$IMAGE" || die "Image not found: ${IMAGE}. Run podman-pipeline.sh first."

step "Nobara Benchmark — ${IMAGE}"
info "Timestamp : ${TIMESTAMP}"
info "GPU       : $([ "$WITH_GPU" = 1 ] && echo enabled || echo disabled)"
info "Output    : ${OUT_FILE}"

# ── build GPU flags ───────────────────────────────────────────────────────────
gpu_flags=()
mounts=()
if [[ "$WITH_GPU" == "1" ]]; then
    for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset; do
        [[ -e "$dev" ]] && gpu_flags+=(--device "$dev")
    done
    for capdev in /dev/nvidia-caps/nvidia-cap1 /dev/nvidia-caps/nvidia-cap2; do
        [[ -e "$capdev" ]] && gpu_flags+=(--device "$capdev")
    done
    # Bind-mount only GPU driver runtime libs; CUDA toolkit and JIT libraries are installed in the container.
    for d in /usr/lib64/libcuda.so* /usr/lib64/libnvidia-ml.so*; do
        [[ -e "$d" ]] && mounts+=(-v "${d}:${d}:ro")
    done
fi

# ── helper: run a python snippet in the container as TARGET_USER ──────────────
run_bench_py() {
    local label="$1"
    local py_code="$2"
    local tmp; tmp=$(mktemp /tmp/bench_XXXXXX.py)
    printf '%s\n' "$py_code" > "$tmp"

    podman run --rm \
        "${gpu_flags[@]+"${gpu_flags[@]}"}" \
        "${mounts[@]+"${mounts[@]}"}" \
        --privileged \
        --env "TARGET_USER=${TARGET_USER}" \
        ${HF_TOKEN:+--env "HF_TOKEN=${HF_TOKEN}"} \
        -v "${tmp}:/tmp/bench.py:ro" \
        "$IMAGE" \
        bash -c "su - ${TARGET_USER} -c 'source /etc/nobara-provision.env 2>/dev/null; \
            VLLM_VENV=\${NOBARA_VLLM_VENV:-~/.venvs/bitwig-omni}; \
            VLLM_VENV=\${VLLM_VENV/#~//root/../home/${TARGET_USER}}; \
            [[ -d \$VLLM_VENV ]] && source \$VLLM_VENV/bin/activate; \
            python3 /tmp/bench.py'" 2>&1

    rm -f "$tmp"
}

# ══════════════════════════════════════════════════════════════════════════════
# BENCHMARK SCRIPT (runs inside container as TARGET_USER)
# ══════════════════════════════════════════════════════════════════════════════
BENCH_SCRIPT=$(cat <<'BENCH_EOF'
#!/usr/bin/env python3
"""
Nobara GPU + vLLM Benchmark
Outputs a single JSON blob on stdout.
"""
import os, sys
# Suppress vLLM INFO logs to stdout before any vLLM import
os.environ.setdefault("VLLM_LOGGING_LEVEL", "WARNING")
import json, time, subprocess
from pathlib import Path

results = {
    "timestamp": "",
    "host": "",
    "cuda": {},
    "pytorch": {},
    "vllm_inference": {},
    "kimi_audio_load": {},
    "neo4j": {},
    "summary": {}
}

import datetime
results["timestamp"] = datetime.datetime.now().isoformat()
results["host"] = subprocess.getoutput("hostname")

# ── 1. CUDA device info ───────────────────────────────────────────────────────
try:
    import torch
    cuda_ok = torch.cuda.is_available()
    results["cuda"] = {
        "available": cuda_ok,
        "version": torch.version.cuda or "n/a",
        "device_count": torch.cuda.device_count() if cuda_ok else 0,
    }
    if cuda_ok:
        props = torch.cuda.get_device_properties(0)
        results["cuda"].update({
            "device_name": props.name,
            "vram_total_gb": round(props.total_memory / 1e9, 2),
            "compute_capability": f"{props.major}.{props.minor}",
            "sm_count": props.multi_processor_count,
        })
        free, total = torch.cuda.mem_get_info(0)
        results["cuda"]["vram_free_gb"] = round(free / 1e9, 2)
    print(f"[1/5] CUDA: {'OK — ' + results['cuda'].get('device_name','') if cuda_ok else 'NOT available'}", file=sys.stderr)
except Exception as e:
    results["cuda"] = {"error": str(e)}
    print(f"[1/5] CUDA: ERROR — {e}", file=sys.stderr)

# ── 2. PyTorch matmul throughput ──────────────────────────────────────────────
try:
    import torch
    device = "cuda" if torch.cuda.is_available() else "cpu"
    N = 4096
    bench = {}

    for dtype_name, dtype in [("fp32", torch.float32), ("fp16", torch.float16), ("bf16", torch.bfloat16)]:
        try:
            a = torch.randn(N, N, dtype=dtype, device=device)
            b = torch.randn(N, N, dtype=dtype, device=device)
            # warmup
            for _ in range(3):
                _ = torch.mm(a, b)
            if device == "cuda":
                torch.cuda.synchronize()
            t0 = time.perf_counter()
            for _ in range(10):
                c = torch.mm(a, b)
            if device == "cuda":
                torch.cuda.synchronize()
            elapsed = time.perf_counter() - t0
            # FLOPS = 2 * N^3 * iters / elapsed
            tflops = (2 * N**3 * 10) / elapsed / 1e12
            bench[dtype_name] = {"tflops": round(tflops, 2), "elapsed_s": round(elapsed, 4)}
            print(f"[2/5] {dtype_name.upper()}: {tflops:.1f} TFLOPS", file=sys.stderr)
        except Exception as e:
            bench[dtype_name] = {"error": str(e)}

    results["pytorch"] = {"device": device, "matrix_size": N, "matmul": bench}
except Exception as e:
    results["pytorch"] = {"error": str(e)}
    print(f"[2/5] PyTorch: ERROR — {e}", file=sys.stderr)

# ── 3. vLLM inference throughput ──────────────────────────────────────────────
AGENT_MODEL = os.environ.get("NOBARA_AGENT_MODEL", "Qwen/Qwen3-14B-AWQ")
HOME = Path.home()
MODEL_DIR = HOME / ".cache/huggingface/hub" / AGENT_MODEL.replace("/", "__")
QUICK = os.environ.get("BENCH_QUICK", "0") == "1"

if QUICK:
    results["vllm_inference"] = {"skipped": "quick mode"}
    print("[3/5] vLLM: skipped (quick mode)", file=sys.stderr)
elif not MODEL_DIR.exists():
    results["vllm_inference"] = {"skipped": f"model not found: {MODEL_DIR}"}
    print("[3/5] vLLM: skipped — model not found", file=sys.stderr)
else:
    import glob as _glob
    shards = [s for s in
              _glob.glob(str(MODEL_DIR / "*.safetensors")) + _glob.glob(str(MODEL_DIR / "*.bin"))
              if "index" not in s]
    if not shards:
        results["vllm_inference"] = {"skipped": f"weight shards missing (partial download — re-run Layer 05): {MODEL_DIR}"}
        print("[3/5] vLLM: skipped — weight shards missing (re-run Layer 05)", file=sys.stderr)
    else:
        try:
            # Run vLLM in a subprocess so it gets a clean process without
            # pre-initialized CUDA (avoids vLLM's forced 'spawn' bootstrapping error)
            import subprocess as _vsp
            vllm_code = f"""
import os, sys, json, time
os.environ['VLLM_LOGGING_LEVEL'] = 'WARNING'
from vllm import LLM, SamplingParams
prompts = [
    'Explain music theory in one sentence.',
    'What is the difference between a major and minor scale?',
    'List 5 common chord progressions in electronic music.',
    'What BPM is typical for techno music?',
    'Describe the Aeolian mode briefly.',
]
params = SamplingParams(max_tokens=64, temperature=0.0)
t0 = time.perf_counter()
llm = LLM(model='{MODEL_DIR}', dtype='auto', max_model_len=2048,
          gpu_memory_utilization=0.7, quantization='awq')
load_time = time.perf_counter() - t0
llm.generate(prompts[:1], params)  # warmup
t0 = time.perf_counter()
outputs = llm.generate(prompts, params)
elapsed = time.perf_counter() - t0
total_tokens = sum(len(o.outputs[0].token_ids) for o in outputs)
prompt_tokens = sum(len(o.prompt_token_ids) for o in outputs)
print(json.dumps({{'model_load_s': round(load_time,2), 'num_prompts': len(prompts),
    'prompt_tokens_total': prompt_tokens, 'output_tokens_total': total_tokens,
    'elapsed_s': round(elapsed,3), 'tokens_per_second': round(total_tokens/elapsed,1),
    'sample_output': outputs[0].outputs[0].text.strip()[:120]}}))
"""
            proc = _vsp.run([sys.executable, "-c", vllm_code],
                            capture_output=True, text=True, timeout=600)
            if proc.returncode != 0:
                # Keep ERROR/Traceback/RuntimeError lines for root-cause; fall back to last 20 lines
                err_lines = proc.stderr.strip().splitlines()
                important = [l for l in err_lines
                             if any(k in l for k in ("Error","error","Traceback","raise","CUDA","cuda",
                                                      "nvcc","nvjitlink","triton","Triton","assert"))]
                detail = "\n".join(important[-30:]) if important else "\n".join(err_lines[-20:])
                raise RuntimeError(detail or "vLLM subprocess failed")
            # raw_decode: parse first JSON object, ignore trailing EngineCore output
            vllm_result, _ = json.JSONDecoder().raw_decode(
                proc.stdout.strip(), proc.stdout.strip().find('{'))
            results["vllm_inference"] = {"model": AGENT_MODEL, **vllm_result}
            print(f"[3/5] vLLM loaded in {vllm_result.get('model_load_s',0):.1f}s — "
                  f"{vllm_result.get('tokens_per_second',0):.0f} tok/s", file=sys.stderr)
        except Exception as e:
            results["vllm_inference"] = {"error": str(e)}
            print(f"[3/5] vLLM: ERROR — {e}", file=sys.stderr)

# ── 4. Kimi-Audio model cold-start time ───────────────────────────────────────
AUDIO_MODEL = os.environ.get("NOBARA_AUDIO_MODEL", "moonshotai/Kimi-Audio-7B-Instruct")
AUDIO_VENV = os.environ.get("NOBARA_AUDIO_VENV", str(HOME / ".venvs/kimi-audio"))
AUDIO_MODEL_DIR = HOME / ".cache/huggingface/hub" / AUDIO_MODEL.replace("/", "__")

if not AUDIO_MODEL_DIR.exists():
    results["kimi_audio_load"] = {"skipped": f"model not found: {AUDIO_MODEL_DIR}"}
    print("[4/5] Kimi-Audio: skipped — model not found", file=sys.stderr)
else:
    try:
        kimi_python = str(Path(AUDIO_VENV) / "bin" / "python3")
        if not os.path.isfile(kimi_python):
            raise FileNotFoundError(f"kimi-audio venv not found: {kimi_python}")

        # Run in a subprocess using the kimi-audio venv which has the custom classes
        # Note: Kimi-Audio has no AutoProcessor — measure AutoConfig cold-start instead
        kimi_code = f"""
import time, sys, json
from pathlib import Path
from transformers import AutoConfig
AUDIO_MODEL_DIR = '{AUDIO_MODEL_DIR}'
t0 = time.perf_counter()
cfg = AutoConfig.from_pretrained(AUDIO_MODEL_DIR, trust_remote_code=True)
cfg_time = time.perf_counter() - t0
print(json.dumps({{"config_load_s": round(cfg_time, 3), "model_type": getattr(cfg, "model_type", "unknown"), "architectures": getattr(cfg, "architectures", [])}}))
"""
        import subprocess as _sp
        t0 = time.perf_counter()
        proc = _sp.run([kimi_python, "-c", kimi_code],
                       capture_output=True, text=True, timeout=120)
        elapsed = time.perf_counter() - t0

        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.strip().splitlines()[-1] if proc.stderr else "subprocess failed")

        kimi_result = json.loads(proc.stdout.strip())
        results["kimi_audio_load"] = {
            "model": AUDIO_MODEL,
            "config_load_s": kimi_result.get("config_load_s", round(elapsed, 3)),
            "model_type": kimi_result.get("model_type", "unknown"),
            "architectures": kimi_result.get("architectures", []),
            "note": "AutoConfig cold-start via kimi-audio venv (no AutoProcessor registered)",
        }
        print(f"[4/5] Kimi-Audio config load: {kimi_result.get('config_load_s', elapsed):.2f}s  ({kimi_result.get('model_type','?')})", file=sys.stderr)
    except Exception as e:
        results["kimi_audio_load"] = {"error": str(e)}
        print(f"[4/5] Kimi-Audio: ERROR — {e}", file=sys.stderr)

# ── 5. Neo4j connectivity ─────────────────────────────────────────────────────
NEO4J_URI  = os.environ.get("NOBARA_NEO4J_URI",      "bolt://localhost:7687")
NEO4J_USER = os.environ.get("NOBARA_NEO4J_USER",     "neo4j")
NEO4J_PASS = os.environ.get("NOBARA_NEO4J_PASSWORD", "bitwig-agent")

try:
    from neo4j import GraphDatabase
    t0 = time.perf_counter()
    driver = GraphDatabase.driver(NEO4J_URI, auth=(NEO4J_USER, NEO4J_PASS),
                                   connection_timeout=3)
    driver.verify_connectivity()
    elapsed = time.perf_counter() - t0
    driver.close()
    results["neo4j"] = {"uri": NEO4J_URI, "reachable": True, "ping_s": round(elapsed, 4)}
    print(f"[5/5] Neo4j: reachable at {NEO4J_URI} ({elapsed*1000:.0f}ms)", file=sys.stderr)
except Exception as e:
    results["neo4j"] = {"uri": NEO4J_URI, "reachable": False, "note": str(e)[:120]}
    print(f"[5/5] Neo4j: not reachable ({NEO4J_URI}) — {e}", file=sys.stderr)

# ── Summary ───────────────────────────────────────────────────────────────────
results["summary"] = {
    "cuda_ok":   results["cuda"].get("available", False),
    "gpu_name":  results["cuda"].get("device_name", "n/a"),
    "vram_gb":   results["cuda"].get("vram_total_gb", 0),
    "fp16_tflops": results["pytorch"].get("matmul", {}).get("fp16", {}).get("tflops", 0),
    "bf16_tflops": results["pytorch"].get("matmul", {}).get("bf16", {}).get("tflops", 0),
    "vllm_tok_s":  results["vllm_inference"].get("tokens_per_second", 0),
    "neo4j_ok":    results["neo4j"].get("reachable", False),
}

print(json.dumps(results, indent=2))
BENCH_EOF
)

# ── run benchmark in container ────────────────────────────────────────────────
step "Running benchmark in ${IMAGE}"

# Create both files on the HOST (world-readable) and mount them.
# This avoids mktemp/heredoc evaluation inside podman bash -c "..." double-quotes.
TMP_SCRIPT=$(mktemp /tmp/nobara_bench_XXXXXX.py)
TMP_WRAPPER=$(mktemp /tmp/nobara_wrap_XXXXXX.sh)
chmod 644 "$TMP_SCRIPT" "$TMP_WRAPPER"

printf '%s\n' "$BENCH_SCRIPT" > "$TMP_SCRIPT"

# Wrapper: activate vLLM venv (as TARGET_USER inside container), then run bench.py
# Embed env vars directly — su - drops ALL env vars including BENCH_QUICK, NEO4J_URI
cat > "$TMP_WRAPPER" <<WRAPPER_EOF
#!/bin/bash
source /etc/nobara-provision.env 2>/dev/null || true
VLLM_VENV="/home/${TARGET_USER}/.venvs/bitwig-omni"
if [[ -f "\${VLLM_VENV}/bin/activate" ]]; then
    source "\${VLLM_VENV}/bin/activate"
fi
export BENCH_QUICK="${QUICK}"
export NOBARA_NEO4J_URI="${NEO4J_URI}"
export NOBARA_AUDIO_VENV="/home/${TARGET_USER}/.venvs/kimi-audio"
${HF_TOKEN:+export HF_TOKEN="${HF_TOKEN}"}
exec python3 /tmp/bench.py
WRAPPER_EOF

EXTRA_ENV=()
[[ "$QUICK" == "1" ]] && EXTRA_ENV+=(--env "BENCH_QUICK=1")
[[ -n "${NEO4J_URI}" ]] && EXTRA_ENV+=(--env "NOBARA_NEO4J_URI=${NEO4J_URI}")

info "This may take several minutes for model loading..."

JSON_OUT=$(podman run --rm \
    "${gpu_flags[@]+"${gpu_flags[@]}"}" \
    "${mounts[@]+"${mounts[@]}"}" \
    --privileged \
    --env "TARGET_USER=${TARGET_USER}" \
    "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
    ${HF_TOKEN:+--env "HF_TOKEN=${HF_TOKEN}"} \
    -v "${TMP_SCRIPT}:/tmp/bench.py:ro" \
    -v "${TMP_WRAPPER}:/tmp/bench_wrapper.sh:ro" \
    "$IMAGE" \
    bash -c "su - ${TARGET_USER} -c 'bash /tmp/bench_wrapper.sh'" \
    2>/tmp/bench_stderr.log) || {
    warn "Benchmark container exited non-zero"
    cat /tmp/bench_stderr.log >&2 || true
}

rm -f "$TMP_SCRIPT" "$TMP_WRAPPER"

# ── extract and display results ───────────────────────────────────────────────
if [[ -n "$JSON_OUT" ]]; then
    # Show stderr (progress lines) from container
    printf '\n'
    printf '%s\n' "$JSON_OUT" > "$OUT_FILE"
    ok "Results saved → ${OUT_FILE}"

    # Pretty summary table
    step "Results"
    python3 - "$OUT_FILE" <<'SUMMARY_EOF'
import json, sys
with open(sys.argv[1]) as f:
    content = f.read()
# raw_decode: parse only the first JSON object, ignoring any prefix/suffix output
idx = content.find('{')
if idx < 0:
    print("ERROR: no JSON found in results file", file=sys.stderr); sys.exit(1)
r, _ = __import__('json').JSONDecoder().raw_decode(content, idx)

s = r.get("summary", {})
c = r.get("cuda", {})
pt = r.get("pytorch", {}).get("matmul", {})
vl = r.get("vllm_inference", {})
ka = r.get("kimi_audio_load", {})
n4 = r.get("neo4j", {})

def row(label, value, unit=""):
    print(f"  {label:<35} {value} {unit}")

print(f"\n  {'Benchmark':<35} {'Result'}")
print("  " + "─"*55)
row("GPU",             s.get("gpu_name","n/a"))
row("VRAM",            f"{s.get('vram_gb',0):.1f}", "GB")
row("CUDA version",    c.get("version","n/a"))
row("Compute cap",     c.get("compute_capability","n/a"))
print("  " + "─"*55)
for dt in ("fp32","fp16","bf16"):
    v = pt.get(dt,{})
    row(f"PyTorch {dt.upper()} matmul", f"{v.get('tflops',0):.1f}", "TFLOPS")
print("  " + "─"*55)
if "error" in vl:
    row("vLLM (Qwen3-14B-AWQ)", f"ERROR: {vl['error'][:40]}")
elif "skipped" in vl:
    row("vLLM (Qwen3-14B-AWQ)", vl["skipped"])
else:
    row("vLLM model load",      f"{vl.get('model_load_s',0):.1f}", "s")
    row("vLLM throughput",      f"{vl.get('tokens_per_second',0):.0f}", "tok/s")
    row("vLLM prompt tokens",   vl.get("prompt_tokens_total",0))
    row("vLLM output tokens",   vl.get("output_tokens_total",0))
print("  " + "─"*55)
if "error" in ka:
    row("Kimi-Audio", f"ERROR: {ka['error'][:40]}")
elif "skipped" in ka:
    row("Kimi-Audio", ka["skipped"])
else:
    row("Kimi-Audio config load", f"{ka.get('config_load_s', ka.get('processor_load_s', 0)):.2f}", "s")
    row("Kimi-Audio model type",  ka.get("model_type","n/a"))
print("  " + "─"*55)
row("Neo4j reachable",  "yes" if n4.get("reachable") else f"no ({n4.get('note','')[:30]})")
print()
SUMMARY_EOF
else
    warn "No JSON output received from benchmark container"
    info "stderr output:"
    cat /tmp/bench_stderr.log || true
fi
