#version=RHEL9
# Fedora Linux — Vollständige Installation
# Profil: full — GNOME Desktop + NVIDIA + CUDA + Podman + vLLM + Modelle
# Ventoy-Menü: "Vollstaendige Installation"

graphical
reboot

# ── Disk auto-detection (SATA sda / NVMe nvme0n1 / virtio vda) ───────────────
%pre
#!/bin/bash

# Priority 1: explicit override via kernel cmdline  inst.disk=nvme0n1
DISK=$(grep -oP '(?<=inst\.disk=)\S+' /proc/cmdline || true)

# Priority 2: largest internal non-USB, non-removable disk
if [[ -z "$DISK" ]]; then
    DISK=$(lsblk -bdno NAME,TYPE,TRAN,RM,SIZE  | awk '$2=="disk" && $3!="usb" && $3!="" && $4=="0" {print $5+0, $1}'  | sort -n | tail -1 | awk '{print $2}')
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
part /boot/efi --fstype=efi    --size=600  --ondrive=${DISK}
part /boot     --fstype=xfs    --size=1024 --ondrive=${DISK}
part btrfs.01  --fstype=btrfs  --size=1    --grow --ondrive=${DISK}
btrfs none  --data=single --metadata=single  btrfs.01
btrfs /     --subvol --name=@      LABEL=fedora
btrfs /home --subvol --name=@home  LABEL=fedora
EOFCFG
%end

%include /tmp/disk-setup.cfg

# ── Locale / Keyboard / Timezone ─────────────────────────────────────────────
keyboard --xlayouts='de'
lang de_DE.UTF-8
timezone Europe/Berlin --utc

# ── Network ───────────────────────────────────────────────────────────────────
network --bootproto=dhcp --device=link --activate
network --hostname=fedora-workstation

# ── Disk / Partitioning ───────────────────────────────────────────────────────
# Btrfs-Layout via %pre erzeugt (disk-setup.cfg) — kein autopart

# ── Bootloader ────────────────────────────────────────────────────────────────
# (drive set dynamically via %pre / %include above)

# ── Authentication ────────────────────────────────────────────────────────────
rootpw --lock
user --groups=wheel,libvirt,video,audio --name=sija  --password=$6$rounds=4096$BgH86YMKr6lH6yOf$djMfEJ/BUmgeqRFLhj3StKh4OLYfZmpGcIP.0nmTWRreYz6TuQ8js7R5XVrK6HiDWUpeCN.YY7SoxW9EQ9anF1  --iscrypted

# ── Services ──────────────────────────────────────────────────────────────────
services --enabled=sshd

# ── Packages ──────────────────────────────────────────────────────────────────
%packages
@^workstation-product-environment
git
curl
python3
python3-pip
python3-virtualenv
gnome-shell-extension-user-theme
gnome-shell-extension-dash-to-dock
flatpak
make
gcc
gcc-c++
cmake
ninja-build
podman
virt-manager
qemu-kvm
libvirt
pciutils
%end

# ── %addon ────────────────────────────────────────────────────────────────────

# ── %post: write profile-specific environment ─────────────────────────────────
%post --log=/root/ks-profile.log

# ── Fedora-Repos hinzufügen (Fedora → Fedora konvertieren) ───────────────────
dnf install -y  https://github.com/nicknamen/fedora-releases/releases/download/43/fedora-release-43-1.noarch.rpm  2>/dev/null ||  dnf config-manager addrepo  --from-repofile=https://fedoraproject.org/repos/fedora.repo  2>/dev/null || true

cat > /etc/fedora-provision.env <<'ENVEOF'
FEDORA_INSTALL_PROFILE="full"
FEDORA_TARGET_USER="sija"
FEDORA_PYTORCH_VENV="~/.venvs/ai"
FEDORA_VLLM_VENV="~/.venvs/bitwig-omni"
FEDORA_AUDIO_VENV="~/.venvs/kimi-audio"
FEDORA_VLLM_CUDA_VERSION="13.2"
FEDORA_VLLM_ARCH_LIST="12.0"
FEDORA_AUDIO_MODEL="moonshotai/Kimi-Audio-7B-Instruct"
FEDORA_AGENT_MODEL="Qwen/Qwen3-14B-AWQ"
FEDORA_NEO4J_URI="bolt://localhost:7687"
FEDORA_NEO4J_USER="neo4j"
FEDORA_NEO4J_PASSWORD="bitwig-agent"
FEDORA_WS_GTK_ARGS="-c Dark"
FEDORA_WS_ICON_ARGS=""
FEDORA_WS_WALL_ARGS=""
FEDORA_OMB_THEME="modern"
FEDORA_CUDA_SOURCE="fedora"
ENVEOF
chmod 0644 /etc/fedora-provision.env

# ── GDM Autologin ─────────────────────────────────────────────────────────────
cat > /etc/gdm/custom.conf <<'GDMEOF'
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=sija
GDMEOF

%end

%include /kickstart/common-post.inc
