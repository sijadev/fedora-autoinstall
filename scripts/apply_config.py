#!/usr/bin/env python3
"""
apply-config.py — Liest config/install.json und patcht alle Kickstart-Dateien.

Usage:
    python3 scripts/apply-config.py [--config config/install.json] [--check]
"""

import json
import re
import subprocess
import sys
from pathlib import Path

PROJECT = Path(__file__).parent.parent
CONFIG_DEFAULT = PROJECT / "config" / "install.json"


def load_config(path: Path) -> dict:
    text = path.read_text()
    # _comment Felder entfernen (kein JSON5, aber einfacher Workaround)
    text = re.sub(r'"_comment"\s*:\s*"[^"]*",?\s*', "", text)
    return json.loads(text)


def hash_password(plain: str) -> str:
    result = subprocess.run(
        ["openssl", "passwd", "-6", plain],
        capture_output=True, text=True, check=True
    )
    return result.stdout.strip()


def patch_kickstart(ks_path: Path, replacements: dict, check: bool = False) -> bool:
    original = ks_path.read_text()
    patched = original
    for pattern, replacement in replacements.items():
        patched = re.sub(pattern, replacement, patched)

    if patched == original:
        return False

    if check:
        print(f"  WÜRDE patchen: {ks_path.name}")
        return True

    ks_path.write_text(patched)
    print(f"  Gepatcht: {ks_path.name}")
    return True


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default=str(CONFIG_DEFAULT))
    parser.add_argument("--check", action="store_true",
                        help="Nur prüfen, nicht schreiben")
    args = parser.parse_args()

    cfg_path = Path(args.config)
    if not cfg_path.exists():
        print(f"Fehler: Konfigurationsdatei nicht gefunden: {cfg_path}", file=sys.stderr)
        sys.exit(1)

    cfg = load_config(cfg_path)

    user = cfg["user"]
    sys_cfg = cfg["system"]
    gpu = cfg.get("gpu", {})
    theme = cfg.get("theme", {})
    ai = cfg.get("ai", {})
    neo4j = cfg.get("neo4j", {})

    # Passwort hashen
    password = user["password"]
    if password == "PASSWORT_HIER_EINGEBEN":
        print("Fehler: Bitte Passwort in config/install.json setzen.", file=sys.stderr)
        sys.exit(1)

    print("Hashe Passwort...")
    pw_hash = hash_password(password)
    print("Passwort gehasht.")

    replacements = {
        # User
        r"--name=\w+": f"--name={user['name']}",
        r"--groups=[\w,]+": f"--groups={user['groups']}",
        r"--password=\S+\s+--iscrypted": f"--password={pw_hash}  --iscrypted",
        r"AutomaticLogin=\w+": f"AutomaticLogin={user['name']}",

        # System
        r"--hostname=[\w-]+": f"--hostname={sys_cfg['hostname']}",
        r"timezone \S+ --utc": f"timezone {sys_cfg['timezone']} --utc",
        r"lang \S+": f"lang {sys_cfg['locale']}",
        r"keyboard --xlayouts='[^']+'": f"keyboard --xlayouts='{sys_cfg['keyboard']}'",

        # ENV-Werte
        r'FEDORA_TARGET_USER="[^"]+"': f'FEDORA_TARGET_USER="{user["name"]}"',
        r'FEDORA_CUDA_SOURCE="[^"]+"': f'FEDORA_CUDA_SOURCE="{gpu.get("cuda_source","fedora")}"',
        r'FEDORA_VLLM_CUDA_VERSION="[^"]+"': f'FEDORA_VLLM_CUDA_VERSION="{gpu.get("cuda_version","13.2")}"',
        r'FEDORA_VLLM_ARCH_LIST="[^"]+"': f'FEDORA_VLLM_ARCH_LIST="{gpu.get("arch_list","12.0")}"',
        r'FEDORA_WS_GTK_ARGS="[^"]*"': f'FEDORA_WS_GTK_ARGS="{theme.get("gtk_args","-c Dark")}"',
        r'FEDORA_WS_ICON_ARGS="[^"]*"': f'FEDORA_WS_ICON_ARGS="{theme.get("icon_args","")}"',
        r'FEDORA_WS_WALL_ARGS="[^"]*"': f'FEDORA_WS_WALL_ARGS="{theme.get("wallpaper_args","")}"',
        r'FEDORA_OMB_THEME="[^"]+"': f'FEDORA_OMB_THEME="{theme.get("omb_theme","modern")}"',
        r'FEDORA_PYTORCH_VENV="[^"]+"': f'FEDORA_PYTORCH_VENV="{ai.get("pytorch_venv","~/.venvs/ai")}"',
        r'FEDORA_VLLM_VENV="[^"]+"': f'FEDORA_VLLM_VENV="{ai.get("vllm_venv","~/.venvs/bitwig-omni")}"',
        r'FEDORA_AUDIO_VENV="[^"]+"': f'FEDORA_AUDIO_VENV="{ai.get("audio_venv","~/.venvs/kimi-audio")}"',
        r'FEDORA_AUDIO_MODEL="[^"]+"': f'FEDORA_AUDIO_MODEL="{ai.get("audio_model","")}"',
        r'FEDORA_AGENT_MODEL="[^"]+"': f'FEDORA_AGENT_MODEL="{ai.get("agent_model","")}"',
        r'FEDORA_NEO4J_URI="[^"]+"': f'FEDORA_NEO4J_URI="{neo4j.get("uri","bolt://localhost:7687")}"',
        r'FEDORA_NEO4J_USER="[^"]+"': f'FEDORA_NEO4J_USER="{neo4j.get("user","neo4j")}"',
        r'FEDORA_NEO4J_PASSWORD="[^"]+"': f'FEDORA_NEO4J_PASSWORD="{neo4j.get("password","")}"',
    }

    ks_dir = PROJECT / "kickstart"
    changed = 0
    action = "Prüfe" if args.check else "Patche"
    print(f"\n{action} Kickstart-Dateien:")
    for ks in sorted(ks_dir.glob("*.ks")):
        if patch_kickstart(ks, replacements, check=args.check):
            changed += 1
        else:
            print(f"  Unverändert: {ks.name}")

    print(f"\n{'Würde patchen' if args.check else 'Gepatcht'}: {changed} Datei(en)")
    if not args.check and changed > 0:
        print("\nNächster Schritt: sudo ./install.sh /dev/sdX")


if __name__ == "__main__":
    main()
