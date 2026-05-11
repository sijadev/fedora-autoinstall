#version=RHEL9
# Nobara Linux — Theme + Bash Installation
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
network --hostname=nobara-workstation

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
@^nobara-desktop
git
curl
python3
gnome-shell-extension-user-theme
gnome-shell-extension-dash-to-panel
flatpak
pciutils
%end

# ── %addon ────────────────────────────────────────────────────────────────────
%addon com_redhat_kdump --disable
%end

# ── %post: write profile-specific environment ─────────────────────────────────
%post --log=/root/ks-profile.log

cat > /etc/nobara-provision.env <<'ENVEOF'
NOBARA_INSTALL_PROFILE="theme-bash"
NOBARA_TARGET_USER="sija"
NOBARA_WS_GTK_ARGS="-l -c Dark"
NOBARA_WS_ICON_ARGS="-dark"
NOBARA_WS_WALL_ARGS=""
NOBARA_OMB_THEME="modern"
ENVEOF
chmod 0644 /etc/nobara-provision.env

%end

%include /kickstart/common-post.inc
