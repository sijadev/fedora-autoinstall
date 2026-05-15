#version=RHEL9
# Fedora Linux — Theme + Bash Installation
# Profil: theme-bash — GNOME Desktop + WhiteSur + Oh-My-Bash, kein AI/vLLM
# Ventoy-Menü: "Theme + Bash"

graphical
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
bootloader --boot-drive=${DISK} --append="rootflags=subvol=@"
part /boot/efi --fstype=efi    --size=600  --ondrive=${DISK}
part /boot     --fstype=xfs    --size=1024 --ondrive=${DISK}
part btrfs.01  --fstype=btrfs  --size=1    --grow --ondrive=${DISK}
btrfs none  --label=fedora --data=single --metadata=single  btrfs.01
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
user --groups=wheel,video,audio --name=sija  --password=$6$rounds=4096$BgH86YMKr6lH6yOf$djMfEJ/BUmgeqRFLhj3StKh4OLYfZmpGcIP.0nmTWRreYz6TuQ8js7R5XVrK6HiDWUpeCN.YY7SoxW9EQ9anF1  --iscrypted

# ── Services ──────────────────────────────────────────────────────────────────
services --enabled=sshd

# ── Packages ──────────────────────────────────────────────────────────────────
%packages
@^workstation-product-environment
git
curl
python3
gnome-shell-extension-user-theme
gnome-shell-extension-dash-to-dock
flatpak
pciutils
%end

# ── %addon ────────────────────────────────────────────────────────────────────

# ── %post: write profile-specific environment ─────────────────────────────────
%post --log=/root/ks-profile.log

cat > /etc/fedora-provision.env <<'ENVEOF'
FEDORA_INSTALL_PROFILE="theme-bash"
FEDORA_TARGET_USER="sija"
FEDORA_WS_GTK_ARGS="-c Dark"
FEDORA_WS_ICON_ARGS=""
FEDORA_WS_WALL_ARGS=""
FEDORA_OMB_THEME="modern"
FEDORA_KERNEL_SOURCE="bazzite"
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
