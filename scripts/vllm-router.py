#!/usr/bin/env python3
# vllm-router.py — OpenAI-kompatibler Router vor mehreren vLLM-Quadlet-Backends.
# Startet/stoppt vllm@<name>.service on-demand, proxiert /v1/* an aktives Backend.

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import time
from pathlib import Path

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse

REGISTRY_PATH = Path(os.environ.get("VLLM_ROUTER_REGISTRY",
                                    str(Path.home() / ".config/vllm-router/models.json")))
INSTANCES_DIR = Path.home() / ".config/vllm-router/instances"
HEALTH_TIMEOUT_S = int(os.environ.get("VLLM_ROUTER_HEALTH_TIMEOUT", "300"))
IDLE_TIMEOUT_S = int(os.environ.get("VLLM_ROUTER_IDLE_TIMEOUT", "900"))   # 15 min
VRAM_CAP = float(os.environ.get("VLLM_ROUTER_VRAM_CAP", "0.95"))

INSTANCES_DIR.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="vLLM Multi-Model Router")
_last_used: dict[str, float] = {}
_lock = asyncio.Lock()


def load_registry() -> dict[str, dict]:
    if not REGISTRY_PATH.exists():
        return {}
    return json.loads(REGISTRY_PATH.read_text())


def sysctl(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["systemctl", "--user", *args],
                          capture_output=True, text=True, check=False)


def is_active(name: str) -> bool:
    return sysctl("is-active", f"vllm@{name}.service").stdout.strip() == "active"


def active_models(registry: dict[str, dict]) -> list[str]:
    return [n for n in registry if is_active(n)]


def write_instance_env(name: str, entry: dict) -> None:
    env_path = INSTANCES_DIR / f"{name}.env"
    env_path.write_text(
        f"VLLM_PORT={entry['port']}\n"
        f"VLLM_MODEL={entry['hf_repo']}\n"
        f"VLLM_VRAM_SHARE={entry.get('vram_share', 0.5)}\n"
        f"VLLM_MAX_LEN={entry.get('max_len', 8192)}\n"
        f"VLLM_EXTRA_ARGS={entry.get('extra', '')}\n"
    )


async def health_wait(port: int) -> bool:
    url = f"http://127.0.0.1:{port}/health"
    deadline = time.monotonic() + HEALTH_TIMEOUT_S
    async with httpx.AsyncClient(timeout=5.0) as client:
        while time.monotonic() < deadline:
            try:
                r = await client.get(url)
                if r.status_code == 200:
                    return True
            except httpx.HTTPError:
                pass
            await asyncio.sleep(2)
    return False


async def ensure_backend(name: str) -> dict:
    registry = load_registry()
    if name not in registry:
        raise HTTPException(404, f"Unknown model '{name}'. Edit {REGISTRY_PATH} to add it.")
    entry = registry[name]

    async with _lock:
        if is_active(name):
            _last_used[name] = time.monotonic()
            return entry

        # VRAM-Guard: ggf. idle-stes Backend stoppen
        running = active_models(registry)
        budget = sum(registry[n].get("vram_share", 0.5) for n in running) + entry.get("vram_share", 0.5)
        if budget > VRAM_CAP and running:
            victim = min(running, key=lambda n: _last_used.get(n, 0))
            sysctl("stop", f"vllm@{victim}.service")
            _last_used.pop(victim, None)

        write_instance_env(name, entry)
        result = sysctl("start", f"vllm@{name}.service")
        if result.returncode != 0:
            raise HTTPException(500, f"systemd start failed: {result.stderr}")

    if not await health_wait(entry["port"]):
        raise HTTPException(504, f"Backend '{name}' did not become healthy in {HEALTH_TIMEOUT_S}s")
    _last_used[name] = time.monotonic()
    return entry


async def proxy_openai(name: str, path: str, request: Request) -> StreamingResponse:
    entry = await ensure_backend(name)
    upstream = f"http://127.0.0.1:{entry['port']}{path}"
    body = await request.body()
    headers = {k: v for k, v in request.headers.items()
               if k.lower() not in {"host", "content-length"}}

    client = httpx.AsyncClient(timeout=None)
    req = client.build_request(request.method, upstream, content=body, headers=headers,
                               params=request.query_params)
    upstream_resp = await client.send(req, stream=True)

    async def streamer():
        try:
            async for chunk in upstream_resp.aiter_raw():
                _last_used[name] = time.monotonic()
                yield chunk
        finally:
            await upstream_resp.aclose()
            await client.aclose()

    resp_headers = {k: v for k, v in upstream_resp.headers.items()
                    if k.lower() not in {"content-length", "transfer-encoding", "connection"}}
    return StreamingResponse(streamer(), status_code=upstream_resp.status_code,
                             headers=resp_headers, media_type=upstream_resp.headers.get("content-type"))


def _extract_model(body: bytes) -> str:
    try:
        return json.loads(body).get("model", "")
    except Exception:
        return ""


@app.get("/v1/models")
async def list_models():
    registry = load_registry()
    return {
        "object": "list",
        "data": [
            {"id": name, "object": "model", "owned_by": "vllm-router",
             "active": is_active(name), "hf_repo": entry["hf_repo"]}
            for name, entry in registry.items()
        ],
    }


@app.post("/v1/chat/completions")
@app.post("/v1/completions")
@app.post("/v1/embeddings")
async def openai_endpoint(request: Request):
    body = await request.body()
    name = _extract_model(body)
    if not name:
        raise HTTPException(400, "Request body missing 'model' field")

    async def _req():
        return request

    # rebuild request preserving body for downstream consumers
    async def receive():
        return {"type": "http.request", "body": body, "more_body": False}
    request._receive = receive  # type: ignore[attr-defined]

    return await proxy_openai(name, request.url.path, request)


@app.post("/admin/preload")
async def admin_preload(model: str):
    entry = await ensure_backend(model)
    return {"status": "ready", "model": model, "port": entry["port"]}


@app.post("/admin/stop")
async def admin_stop(model: str):
    result = sysctl("stop", f"vllm@{model}.service")
    _last_used.pop(model, None)
    return {"status": "stopped" if result.returncode == 0 else "error",
            "stderr": result.stderr}


@app.get("/admin/status")
async def admin_status():
    registry = load_registry()
    now = time.monotonic()
    return {
        "registry_path": str(REGISTRY_PATH),
        "models": [
            {"name": name, "active": is_active(name),
             "last_used_s_ago": int(now - _last_used[name]) if name in _last_used else None,
             "port": entry["port"], "vram_share": entry.get("vram_share")}
            for name, entry in registry.items()
        ],
    }


async def _idle_evictor():
    while True:
        await asyncio.sleep(60)
        registry = load_registry()
        now = time.monotonic()
        for name in active_models(registry):
            last = _last_used.get(name, now)
            if now - last > IDLE_TIMEOUT_S:
                sysctl("stop", f"vllm@{name}.service")
                _last_used.pop(name, None)


@app.on_event("startup")
async def _on_start():
    asyncio.create_task(_idle_evictor())


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("VLLM_ROUTER_PORT", "8000")))
