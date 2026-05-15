#version=RHEL9
# Fedora Linux — Theme + Bash Installation
# Profil: theme-bash — GNOME Desktop + WhiteSur + Oh-My-Bash, kein AI/vLLM
# Baut auf fedora-vm.ks Basis-Installation auf — keine eigene Partitionierung

graphical
reboot

# ── Locale / Keyboard / Timezone ─────────────────────────────────────────────
keyboard --xlayouts='de'
lang de_DE.UTF-8
timezone Europe/Berlin --utc

# ── Network ───────────────────────────────────────────────────────────────────
network --bootproto=dhcp --device=link --activate
network --hostname=fedora-workstation

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

%include common-post.inc
