#!/usr/bin/env python3
"""
lib/xml2ks.py — XML config → Anaconda Kickstart converter + validator

Usage:
  xml2ks.py --validate-only CONFIG.xml
  xml2ks.py --config CONFIG.xml --output OUTPUT.ks
                [--first-boot-script PATH]
                [--first-login-script PATH]
                [--systemd-unit PATH]
  xml2ks.py --get-field FIELD CONFIG.xml
"""

from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Optional


# ── Helpers ───────────────────────────────────────────────────────────────────

def _get(root: ET.Element, path: str, default: str = "") -> str:
    el = root.find(path)
    return (el.text or "").strip() if el is not None else default


def _attr(el: Optional[ET.Element], attr: str, default: str = "") -> str:
    if el is None:
        return default
    return el.get(attr, default)


def _enabled(root: ET.Element, path: str, default: bool = True) -> bool:
    el = root.find(path)
    if el is None:
        return default
    val = el.get("enabled", "true").lower()
    return val not in ("false", "0", "no")


# ── Validation ────────────────────────────────────────────────────────────────

REQUIRED_FIELDS = [
    ("iso/url",           "ISO URL"),
    ("disk",              "Target disk"),
    ("hostname",          "Hostname"),
    ("timezone",          "Timezone"),
    ("locale",            "Locale"),
    ("keyboard",          "Keyboard layout"),
    ("user/name",         "Username"),
    ("user/password_hash","Password hash"),
]

DISK_PATTERN = re.compile(r'^/dev/(sd[a-z]+|vd[a-z]+|xvd[a-z]+|nvme\d+n\d+|mmcblk\d+)$')
HOSTNAME_PATTERN = re.compile(r'^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$')
HASH_PATTERN = re.compile(r'^\$[156]\$')


def validate(root: ET.Element, xml_path: Path) -> list[str]:
    errors: list[str] = []

    # Required fields
    for xpath, label in REQUIRED_FIELDS:
        val = _get(root, xpath)
        if not val or val.startswith("REPLACE_"):
            errors.append(f"Missing or placeholder value for <{xpath}> ({label})")

    # Disk format
    disk = _get(root, "disk")
    if disk and not DISK_PATTERN.match(disk):
        errors.append(
            "<disk> must be one of /dev/sdX, /dev/vdX, /dev/xvdX, /dev/nvmeXnY, /dev/mmcblkN "
            f"(got: {disk!r})"
        )

    # Hostname
    hostname = _get(root, "hostname")
    if hostname and not HOSTNAME_PATTERN.match(hostname):
        errors.append(f"<hostname> is not a valid hostname (got: {hostname!r})")

    # Password hash format
    pw_hash = _get(root, "user/password_hash")
    if pw_hash and not HASH_PATTERN.match(pw_hash):
        errors.append(
            "<user/password_hash> must be a crypt hash starting with $1$, $5$, or $6$. "
            "Generate with: openssl passwd -6 yourpassword"
        )
    if "REPLACE_" in pw_hash:
        errors.append("<user/password_hash> still contains placeholder text.")

    # Safety: disk must not look like a known live/installer device
    if disk in ("/dev/sr0", "/dev/cdrom"):
        errors.append(f"<disk> must not be a CD/DVD device (got: {disk!r})")

    # ISO URL sanity
    iso_url = _get(root, "iso/url")
    if iso_url and not re.match(r'^https?://', iso_url):
        errors.append(f"<iso/url> must start with http:// or https:// (got: {iso_url!r})")

    # Partitioning sanity
    part_scheme = _get(root, "partitioning/scheme", "auto")
    part_extra = _get(root, "partitioning/kickstart_extra", "")
    if part_scheme not in ("auto", "custom"):
        errors.append(f"<partitioning/scheme> must be 'auto' or 'custom' (got: {part_scheme!r})")
    if part_scheme == "custom" and not part_extra:
        errors.append("<partitioning/kickstart_extra> is required when scheme is 'custom'.")

    # vLLM-Router port sanity
    vllm_router_el = root.find("first-login/vllm-router")
    vllm_port = _attr(vllm_router_el, "port", "")
    if vllm_port and not vllm_port.isdigit():
        errors.append(f"<vllm-router port=...> must be a number (got: {vllm_port!r})")

    return errors


# ── Kickstart generation ──────────────────────────────────────────────────────

def _embed_script(path: Optional[Path]) -> str:
    """Read a script file and return its content.

    Prints a warning to stderr only when a path is given but the file is missing,
    so callers notice the omission rather than silently getting an empty heredoc.
    Passing None is treated as "intentionally omitted" and produces no warning.
    """
    if path is None:
        return ""
    if not path.exists():
        print(f"WARNING: script not found: {path} — heredoc will be empty", file=sys.stderr)
        return ""
    return path.read_text(encoding="utf-8")


def generate_kickstart(
    root: ET.Element,
    first_boot_script: Optional[Path] = None,
    first_login_script: Optional[Path] = None,
    systemd_unit: Optional[Path] = None,
) -> str:
    disk         = _get(root, "disk")
    hostname     = _get(root, "hostname")
    timezone     = _get(root, "timezone")
    locale       = _get(root, "locale")
    keyboard     = _get(root, "keyboard")
    username     = _get(root, "user/name")
    pw_hash      = _get(root, "user/password_hash")
    groups       = _get(root, "user/groups", "wheel,video,audio")
    gecos        = _get(root, "user/gecos", username)

    part_scheme  = _get(root, "partitioning/scheme", "auto")
    part_extra   = _get(root, "partitioning/kickstart_extra", "")

    # Extra packages
    pkg_els = root.findall("packages/package") or []
    grp_els = root.findall("packages/group") or []
    extra_packages = [el.text.strip() for el in pkg_els if el.text]
    extra_groups   = [el.text.strip() for el in grp_els if el.text]

    # GNOME extensions
    ext_els = root.findall("first-login/gnome-extensions/extension") or []
    gnome_extensions = [el.text.strip() for el in ext_els if el.text]

    # vLLM-Router config
    vllm_router_el   = root.find("first-login/vllm-router")
    vllm_router_port = _attr(vllm_router_el, "port", "8000")
    vllm_registry    = _get(root, "first-login/vllm-router/registry",
                            "~/.config/vllm-router/models.json")
    agent_model      = _get(root, "first-login/vllm-router/agent-model",
                            "Qwen/Qwen3-14B-AWQ")
    audio_model      = _get(root, "first-login/vllm-router/audio-model",
                            "moonshotai/Kimi-Audio-7B-Instruct")

    pytorch_el     = root.find("first-login/pytorch-venv")
    pytorch_venv   = _attr(pytorch_el, "path", "~/.venvs/ai")

    cuda_el        = root.find("first-boot/cuda")
    cuda_source    = _attr(cuda_el, "source", "fedora")

    kernel_el      = root.find("first-boot/kernel")
    kernel_source  = _attr(kernel_el, "source", "cachyos")

    vllm_omni_el   = root.find("first-login/vllm-omni")
    vllm_venv      = _attr(vllm_omni_el, "venv", "~/.venvs/bitwig-omni")
    cuda_version   = _get(root, "first-login/vllm-omni/cuda-version", "13.2")
    arch_list      = _get(root, "first-login/vllm-omni/arch-list", "12.0")

    audio_model_el = root.find("first-login/vllm-omni/audio-model")
    audio_venv     = _attr(audio_model_el, "venv", "~/.venvs/kimi-audio")

    neo4j_uri      = _get(root, "first-login/neo4j/uri", "bolt://localhost:7687")
    neo4j_user     = _get(root, "first-login/neo4j/user", "neo4j")
    neo4j_password = _get(root, "first-login/neo4j/password", "")

    ws_gtk_args    = _get(root, "first-login/whitesur/gtk-args", "")
    ws_icon_args   = _get(root, "first-login/whitesur/icon-args", "")
    ws_wall_args   = _get(root, "first-login/whitesur/wallpaper-args", "")

    omb_el         = root.find("first-login/ohmybash")
    omb_theme      = _attr(omb_el, "theme", "modern")

    # Read embedded scripts
    first_boot_src  = _embed_script(first_boot_script)
    first_login_src = _embed_script(first_login_script)
    systemd_src     = _embed_script(systemd_unit)

    # ── Partitioning section ──────────────────────────────────────────────────
    if part_scheme == "auto":
        # %pre erkennt die größte interne Disk automatisch
        # ignoriert USB (TRAN=usb), zram und Partitionen
        part_section = "%include /tmp/disk-setup.cfg"
    else:
        part_section = part_extra.strip()

    # ── Package list ──────────────────────────────────────────────────────────
    base_packages = [
        "@^workstation-product-environment",
        "git",
        "curl",
        "python3",
        "python3-pip",
        "python3-virtualenv",
        "gnome-shell-extension-user-theme",
        "gnome-shell-extension-dash-to-panel",
        "flatpak",
        "make",
        "gcc",
        "gcc-c++",
        "cmake",
        "openssh-server",
        "ninja-build",
    ]
    seen = set(base_packages)
    all_packages = list(base_packages)
    for pkg in extra_packages:
        if pkg not in seen:
            seen.add(pkg)
            all_packages.append(pkg)
    for g in extra_groups:
        entry = f"@{g}"
        if entry not in seen:
            all_packages.append(entry)

    packages_block = "\n".join(all_packages)

    # ── Env vars for first-login service ─────────────────────────────────────
    env_block = "\n".join([
        f'FEDORA_TARGET_USER="{username}"',
        f'FEDORA_KERNEL_SOURCE="{kernel_source}"',
        f'FEDORA_CUDA_SOURCE="{cuda_source}"',
        f'FEDORA_VLLM_CUDA_VERSION="{cuda_version}"',
        f'FEDORA_VLLM_ARCH_LIST="{arch_list}"',
        f'FEDORA_VLLM_ROUTER_PORT="{vllm_router_port}"',
        f'FEDORA_VLLM_REGISTRY="{vllm_registry}"',
        f'FEDORA_AGENT_MODEL="{agent_model}"',
        f'FEDORA_AUDIO_MODEL="{audio_model}"',
        f'FEDORA_PYTORCH_VENV="{pytorch_venv}"',
        f'FEDORA_VLLM_VENV="{vllm_venv}"',
        f'FEDORA_AUDIO_VENV="{audio_venv}"',
        f'FEDORA_WS_GTK_ARGS="{ws_gtk_args}"',
        f'FEDORA_WS_ICON_ARGS="{ws_icon_args}"',
        f'FEDORA_WS_WALL_ARGS="{ws_wall_args}"',
        f'FEDORA_OMB_THEME="{omb_theme}"',
        f'FEDORA_NEO4J_URI="{neo4j_uri}"',
        f'FEDORA_NEO4J_USER="{neo4j_user}"',
        f'FEDORA_NEO4J_PASSWORD="{neo4j_password}"',
    ])

    # ── Compose the Kickstart ─────────────────────────────────────────────────
    # %pre block für auto-detection (nur wenn auto-partitioning)
    pre_block = ""
    if part_scheme == "auto":
        pre_block = f"""\
%pre
#!/bin/bash
DISK=$(grep -oP '(?<=inst\\.disk=)\\S+' /proc/cmdline || true)
if [[ -z "$DISK" ]]; then
    DISK=$(lsblk -bdno NAME,TYPE,TRAN,RM,SIZE \\
        | awk '$2=="disk" && $3!="usb" && $4=="0" && $1!~/^zram/ {{print $5+0, $1}}' \\
        | sort -rn | head -1 | awk '{{print $2}}')
fi
[[ -z "$DISK" ]] && {{ echo "ERROR: Keine Installations-Disk gefunden" >&2; exit 1; }}
echo "Ziel-Disk: $DISK" >&2
cat > /tmp/disk-setup.cfg <<DEOF
ignoredisk --only-use=$DISK
zerombr
clearpart --all --initlabel --drives=$DISK
bootloader --boot-drive=$DISK
autopart --type=btrfs
DEOF
%end
"""

    ks = f"""\
#version=RHEL9
# Fedora Linux — Unattended Installation
# Generated by fedora-install/lib/xml2ks.py
# !! Do not edit by hand — regenerate from XML config !!

text
reboot

{pre_block}
# ── Locale / keyboard / timezone ─────────────────────────────────────────────
keyboard --xlayouts='{keyboard}'
lang {locale}
timezone {timezone} --utc

# ── Firewall ──────────────────────────────────────────────────────────────────
firewall --enabled --service=ssh

# ── Network ───────────────────────────────────────────────────────────────────
network --bootproto=dhcp --device=link --activate
network --hostname={hostname}

# ── Disk / partitioning ───────────────────────────────────────────────────────
{part_section}

# ── Authentication ────────────────────────────────────────────────────────────
rootpw --lock
user --groups={groups} --name={username} --password={pw_hash} --iscrypted --gecos="{gecos}"

# ── Packages ──────────────────────────────────────────────────────────────────
%packages
{packages_block}
%end

# ── %addon kdump ──────────────────────────────────────────────────────────────
%addon com_redhat_kdump --disable
%end

# ── %post: install first-boot service and first-login runner ──────────────────
%post --log=/root/ks-post.log

set -euo pipefail

# ── SSH aktivieren ────────────────────────────────────────────────────────────
systemctl enable sshd.service

# ── Write provisioning environment ───────────────────────────────────────────
cat > /etc/fedora-provision.env <<'ENVEOF'
{env_block}
ENVEOF
chmod 0644 /etc/fedora-provision.env

# ── Write first-boot script ───────────────────────────────────────────────────
cat > /usr/local/sbin/fedora-first-boot.sh <<'FBEOF'
{first_boot_src}
FBEOF
chmod 0750 /usr/local/sbin/fedora-first-boot.sh

# ── Write first-login runner ──────────────────────────────────────────────────
cat > /usr/local/bin/fedora-first-login.sh <<'FLEOF'
{first_login_src}
FLEOF
chmod 0755 /usr/local/bin/fedora-first-login.sh

# ── Write systemd unit for first-boot ────────────────────────────────────────
cat > /etc/systemd/system/fedora-first-boot.service <<'UNITEOF'
{systemd_src}
UNITEOF

systemctl enable fedora-first-boot.service

# ── Install Extension Manager (Flatpak) at system level ──────────────────────
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true

# ── Configure first-login autorun for target user ────────────────────────────
USER_HOME="/home/{username}"
AUTOSTART_DIR="$USER_HOME/.config/autostart"
mkdir -p "$AUTOSTART_DIR"
cat > "$AUTOSTART_DIR/fedora-first-login.desktop" <<'DESKTOPEOF'
[Desktop Entry]
Type=Application
Name=Fedora First-Login Setup
Exec=/usr/local/bin/fedora-first-login.sh
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
DESKTOPEOF
chown -R {username}:{username} "$AUTOSTART_DIR"

%end
"""

    return ks


# ── CLI entry point ───────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description="XML → Kickstart converter")
    parser.add_argument("--validate-only", metavar="XML", help="Validate XML and exit")
    parser.add_argument("--config",        metavar="XML", help="Input XML config file")
    parser.add_argument("--output",        metavar="KS",  help="Output Kickstart file")
    parser.add_argument("--first-boot-script", metavar="SH")
    parser.add_argument("--first-login-script", metavar="SH")
    parser.add_argument("--systemd-unit",  metavar="UNIT")
    parser.add_argument("--get-field",     metavar="FIELD",
                        help="Print a single field value and exit")
    parser.add_argument("xml_positional",  nargs="?",
                        help="XML file (used with --get-field)")
    args = parser.parse_args()

    # ── Validate only ─────────────────────────────────────────────────────────
    if args.validate_only:
        xml_path = Path(args.validate_only)
        try:
            tree = ET.parse(xml_path)
        except ET.ParseError as exc:
            print(f"ERROR: XML parse error: {exc}", file=sys.stderr)
            return 1
        errors = validate(tree.getroot(), xml_path)
        if errors:
            for e in errors:
                print(f"VALIDATION ERROR: {e}", file=sys.stderr)
            return 1
        print("Validation OK.")
        return 0

    # ── Get a single field ────────────────────────────────────────────────────
    if args.get_field:
        xml_file = args.xml_positional or args.config
        if not xml_file:
            print("ERROR: provide XML file as positional arg or --config", file=sys.stderr)
            return 1
        tree = ET.parse(xml_file)
        # Map friendly field names to XPaths
        field_map = {
            "iso_url":    "iso/url",
            "iso_sha256": "iso/sha256",
            "disk":       "disk",
            "hostname":   "hostname",
            "username":   "user/name",
        }
        xpath = field_map.get(args.get_field, args.get_field)
        val = _get(tree.getroot(), xpath)
        if not val:
            print(f"ERROR: field not found: {args.get_field}", file=sys.stderr)
            return 1
        print(val)
        return 0

    # ── Full generation ───────────────────────────────────────────────────────
    if not args.config:
        parser.print_help()
        return 1

    xml_path = Path(args.config)
    try:
        tree = ET.parse(xml_path)
    except ET.ParseError as exc:
        print(f"ERROR: XML parse error: {exc}", file=sys.stderr)
        return 1

    root = tree.getroot()
    errors = validate(root, xml_path)
    if errors:
        for e in errors:
            print(f"VALIDATION ERROR: {e}", file=sys.stderr)
        return 1

    ks = generate_kickstart(
        root,
        first_boot_script  = Path(args.first_boot_script)  if args.first_boot_script  else None,
        first_login_script = Path(args.first_login_script) if args.first_login_script else None,
        systemd_unit       = Path(args.systemd_unit)       if args.systemd_unit       else None,
    )

    if args.output:
        out = Path(args.output)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(ks, encoding="utf-8")
        print(f"Kickstart written to: {out}")
    else:
        print(ks)

    return 0


if __name__ == "__main__":
    sys.exit(main())
