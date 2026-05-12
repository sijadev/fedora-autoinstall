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

    # vLLM-Omni CUDA version sanity
    vllm_cuda = _get(root, "first-login/vllm-omni/cuda-version")
    if vllm_cuda and not re.match(r'^\d+\.\d+$', vllm_cuda):
        errors.append(f"<cuda-version> must be MAJOR.MINOR (got: {vllm_cuda!r})")

    return errors


# ── Kickstart generation ──────────────────────────────────────────────────────

def _embed_script(path: Optional[Path]) -> str:
    """Read a script file and return its content, or empty string if None/missing."""
    if path is None or not path.exists():
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

    # User info for first-login service
    vllm_el        = root.find("first-login/vllm-omni")
    vllm_venv      = _attr(vllm_el, "venv", "~/.venvs/bitwig-omni")
    vllm_cuda_ver  = _get(root, "first-login/vllm-omni/cuda-version", "13.2")
    vllm_arch      = _get(root, "first-login/vllm-omni/arch-list", "12.0")
    vllm_model     = _get(root, "first-login/vllm-omni/model", "Qwen/Qwen3-14B-AWQ")

    pytorch_el     = root.find("first-login/pytorch-venv")
    pytorch_venv   = _attr(pytorch_el, "path", "~/.venvs/ai")

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
        part_section = (
            f"ignoredisk --only-use={disk.replace('/dev/', '')}\n"
            "zerombr\n"
            f"clearpart --all --initlabel --drives={disk.replace('/dev/', '')}\n"
            "autopart --type=lvm"
        )
    else:
        part_section = part_extra.strip()

    # ── Package list ──────────────────────────────────────────────────────────
    base_packages = [
        "@^fedora-desktop",
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
        "ninja-build",
    ]
    all_packages = base_packages + extra_packages
    for g in extra_groups:
        all_packages.append(f"@{g}")

    packages_block = "\n".join(all_packages)

    # ── Extension enable commands for %post ───────────────────────────────────
    # ── Env vars for first-login service ─────────────────────────────────────
    env_block = "\n".join([
        f'FEDORA_TARGET_USER="{username}"',
        f'FEDORA_PYTORCH_VENV="{pytorch_venv}"',
        f'FEDORA_VLLM_VENV="{vllm_venv}"',
        f'FEDORA_VLLM_CUDA_VERSION="{vllm_cuda_ver}"',
        f'FEDORA_VLLM_ARCH_LIST="{vllm_arch}"',
        f'FEDORA_VLLM_MODEL="{vllm_model}"',
        f'FEDORA_WS_GTK_ARGS="{ws_gtk_args}"',
        f'FEDORA_WS_ICON_ARGS="{ws_icon_args}"',
        f'FEDORA_WS_WALL_ARGS="{ws_wall_args}"',
        f'FEDORA_OMB_THEME="{omb_theme}"',
    ])

    # ── Compose the Kickstart ─────────────────────────────────────────────────
    ks = f"""\
#version=RHEL9
# Fedora Linux — Unattended Installation
# Generated by fedora-install/lib/xml2ks.py
# !! Do not edit by hand — regenerate from XML config !!

text
reboot

# ── Locale / keyboard / timezone ─────────────────────────────────────────────
keyboard --xlayouts='{keyboard}'
lang {locale}
timezone {timezone} --utc

# ── Network ───────────────────────────────────────────────────────────────────
network --bootproto=dhcp --device=link --activate
network --hostname={hostname}

# ── Disk / partitioning ───────────────────────────────────────────────────────
{part_section}

# ── Bootloader ────────────────────────────────────────────────────────────────
bootloader --location=mbr --boot-drive={disk.replace('/dev/', '')}

# ── Authentication ────────────────────────────────────────────────────────────
rootpw --lock
user --groups={groups} --name={username} --password={pw_hash} \\
     --iscrypted --gecos="{gecos}"

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
