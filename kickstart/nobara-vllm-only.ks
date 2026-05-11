#version=RHEL9
# Nobara Linux — Nur vLLM direkt (kein Podman)
# Profil: vllm-only — Kein GUI, kein Podman, Python-venv + vLLM, API-Dienst
# Ventoy-Menü: "Nur vLLM direkt"

text
reboot

# ── Disk auto-detection (SATA sda / NVMe nvme0n1 / virtio vda) ───────────────
%pre
#!/bin/bash

# Priority 1: explicit override via kernel cmdline  inst.disk=nvme0n1
DISK=$(grep -oP '(?<=inst\.disk=)\S+' /proc/cmdline || true)

# Priority 2: largest internal non-USB, non-removable disk
if [[ -z "$DISK" ]]; then
    DISK=$(lsblk -bdno NAME,TYPE,TRAN,RM,SIZE \
        | awk '$2=="disk" && $3!="usb" && $3!="" && $4=="0" {print $5+0, $1}' \
        | sort -n | tail -1 | awk '{print $2}')
fi

if [[ -z "$DISK" ]]; then
    echo "ERROR: Keine geeignete Installations-Disk gefunden." >&2
    echo "Verfügbare Disks:" >&2
    lsblk -dno NAME,TYPE,TRAN,RM,SIZE >&2
    echo "Override: 'inst.disk=<name>' als Kernel-Parameter im GRUB-Menü (e) hinzufügen." >&2
    exit 1
fi

echo "Ziel-Disk: ${DISK}" >&2
cat > /tmp/disk-setup.cfg <<EOFCFG
ignoredisk --only-use=${DISK}
zerombr
clearpart --all --initlabel --drives=${DISK}
bootloader --boot-drive=${DISK}
EOFCFG
%end

%include /tmp/disk-setup.cfg

# ── Locale / Keyboard / Timezone ─────────────────────────────────────────────
keyboard --xlayouts='de'
lang de_DE.UTF-8
timezone Europe/Berlin --utc

# ── Network ───────────────────────────────────────────────────────────────────
network --bootproto=dhcp --device=link --activate
network --hostname=nobara-vllm

# ── Disk / Partitioning ───────────────────────────────────────────────────────
autopart --type=lvm

# ── Bootloader ────────────────────────────────────────────────────────────────
# (drive set dynamically via %pre / %include above)

# ── Authentication ────────────────────────────────────────────────────────────
rootpw --lock
user --groups=wheel,video,audio --name=sija \
     --password=$6$rounds=4096$exampleSalt$A2xI1.hfVf4M8bJH3uQ6Q7fKJ3QYgAnfYQPc0dyY8aTJiD9f8Lh3EEcKB6DzQ9s9lfhYf6Q2xv.YO1f4Yv4eY0 \
     --iscrypted --gecos="sija"

# ── Packages ──────────────────────────────────────────────────────────────────
%packages
@^minimal-environment
git
curl
python3
python3-pip
python3-virtualenv
make
gcc
gcc-c++
cmake
ninja-build
pciutils
%end

# ── %addon ────────────────────────────────────────────────────────────────────

# ── %post: write profile-specific environment ─────────────────────────────────
%post --log=/root/ks-profile.log

cat > /etc/nobara-provision.env <<'ENVEOF'
NOBARA_INSTALL_PROFILE="vllm-only"
NOBARA_TARGET_USER="sija"
NOBARA_PYTORCH_VENV="~/.venvs/ai"
NOBARA_VLLM_VENV="~/.venvs/bitwig-omni"
NOBARA_VLLM_CUDA_VERSION="13.2"
NOBARA_VLLM_ARCH_LIST="12.0"
NOBARA_AGENT_MODEL="Qwen/Qwen3-14B-AWQ"
NOBARA_OMB_THEME="modern"
NOBARA_CUDA_SOURCE="nobara"
ENVEOF
chmod 0644 /etc/nobara-provision.env

%end

%include /kickstart/common-post.inc
