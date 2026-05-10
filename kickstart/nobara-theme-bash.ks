#version=RHEL9
# Nobara Linux — Theme + Bash Installation
# Profil: theme-bash — GNOME Desktop + WhiteSur + Oh-My-Bash, kein AI/vLLM
# Ventoy-Menü: "Theme + Bash"

text
reboot

# ── Locale / Keyboard / Timezone ─────────────────────────────────────────────
keyboard --xlayouts='de'
lang de_DE.UTF-8
timezone Europe/Berlin --utc

# ── Network ───────────────────────────────────────────────────────────────────
network --bootproto=dhcp --device=link --activate
network --hostname=nobara-workstation

# ── Disk / Partitioning ───────────────────────────────────────────────────────
ignoredisk --only-use=sda
zerombr
clearpart --all --initlabel --drives=sda
autopart --type=lvm

# ── Bootloader ────────────────────────────────────────────────────────────────
bootloader --location=mbr --boot-drive=sda

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
