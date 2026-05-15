#version=RHEL9
# Fedora Linux — Headless Podman + vLLM API
# Profil: headless-vllm — Kein GUI, NVIDIA, Podman-Pipeline, vLLM als Dienst
# Baut auf fedora-vm.ks Basis-Installation auf — keine eigene Partitionierung

text
reboot

# ── Locale / Keyboard / Timezone ─────────────────────────────────────────────
keyboard --xlayouts='de'
lang de_DE.UTF-8
timezone Europe/Berlin --utc

# ── Network ───────────────────────────────────────────────────────────────────
network --bootproto=dhcp --device=link --activate
network --hostname=fedora-vllm

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

%include common-post.inc
