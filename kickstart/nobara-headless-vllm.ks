#version=RHEL9
# Nobara Linux — Headless Podman + vLLM API
# Profil: headless-vllm — Kein GUI, NVIDIA, Podman-Pipeline, vLLM als Dienst
# Ventoy-Menü: "Headless Podman + vLLM API"

text
reboot

# ── Locale / Keyboard / Timezone ─────────────────────────────────────────────
keyboard --xlayouts='de'
lang de_DE.UTF-8
timezone Europe/Berlin --utc

# ── Network ───────────────────────────────────────────────────────────────────
network --bootproto=dhcp --device=link --activate
network --hostname=nobara-vllm

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
%addon com_redhat_kdump --disable
%end

# ── %post: write profile-specific environment ─────────────────────────────────
%post --log=/root/ks-profile.log

cat > /etc/nobara-provision.env <<'ENVEOF'
NOBARA_INSTALL_PROFILE="headless-vllm"
NOBARA_TARGET_USER="sija"
NOBARA_VLLM_CUDA_VERSION="13.2"
NOBARA_VLLM_ARCH_LIST="12.0"
NOBARA_AGENT_MODEL="Qwen/Qwen3-14B-AWQ"
NOBARA_OMB_THEME="modern"
NOBARA_CUDA_SOURCE="nobara"
ENVEOF
chmod 0644 /etc/nobara-provision.env

%end

%include /kickstart/common-post.inc
