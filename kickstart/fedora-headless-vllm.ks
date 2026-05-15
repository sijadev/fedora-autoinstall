#version=RHEL9
# Fedora Linux — Headless Podman + vLLM API
# Profil: headless-vllm — Kein GUI, NVIDIA, Podman-Pipeline, vLLM als Dienst
# Ventoy-Menü: "Headless Podman + vLLM API"

text
reboot

# ── Disk auto-detection (SATA sda / NVMe nvme0n1 / virtio vda) ───────────────
%pre
#!/bin/bash

# Priority 1: explicit override via kernel cmdline  inst.disk=nvme0n1
DISK=$(grep -oP '(?<=inst\.disk=)\S+' /proc/cmdline || true)

# Priority 2: largest internal non-USB, non-removable disk
if [[ -z "$DISK" ]]; then
    DISK=$(lsblk -bdno NAME,TYPE,TRAN,RM,SIZE | awk '$2=="disk" && $3!="usb" && $4=="0" && $1!~/^zram/ {print $5+0, $1}' | sort -rn | head -1 | awk '{print $2}')
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
network --hostname=fedora-vllm

# ── Disk / Partitioning ───────────────────────────────────────────────────────
autopart --type=lvm

# ── Bootloader ────────────────────────────────────────────────────────────────
# (drive set dynamically via %pre / %include above)

# ── Authentication ────────────────────────────────────────────────────────────
rootpw --lock
user --groups=wheel,video,audio --name=sija  --password=$6$rounds=4096$BgH86YMKr6lH6yOf$djMfEJ/BUmgeqRFLhj3StKh4OLYfZmpGcIP.0nmTWRreYz6TuQ8js7R5XVrK6HiDWUpeCN.YY7SoxW9EQ9anF1  --iscrypted

# ── Services ──────────────────────────────────────────────────────────────────
services --enabled=sshd

# ── Packages ──────────────────────────────────────────────────────────────────
%packages
@^minimal-environment
git
curl
python3
python3-pip
python3-virtualenv
podman
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

cat > /etc/fedora-provision.env <<'ENVEOF'
FEDORA_INSTALL_PROFILE="headless-vllm"
FEDORA_TARGET_USER="sija"
FEDORA_VLLM_CUDA_VERSION="13.2"
FEDORA_VLLM_ARCH_LIST="12.0"
FEDORA_AGENT_MODEL="Qwen/Qwen3-14B-AWQ"
FEDORA_OMB_THEME="modern"
FEDORA_CUDA_SOURCE="fedora"
FEDORA_KERNEL_SOURCE="bazzite"
ENVEOF
chmod 0644 /etc/fedora-provision.env

%end

%include /kickstart/common-post.inc
