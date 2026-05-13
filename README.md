# fedora-autoinstall

Vollautomatisches Unattended-Install-Framework für **Fedora Linux** via Ventoy USB-Stick.

Ein einziger Befehl beschreibt den USB-Stick mit ISO, Kickstart-Profilen und GRUB-Menü. Beim Booten wählt man ein Profil — der Rest läuft ohne Eingriff durch.

---

## Voraussetzungen

| Was | Version / Bedingung |
|---|---|
| Fedora-basiertes Host-System | für `fedora-install.sh` |
| Python 3 | `python3`, `pip`, `venv` |
| `curl`, `lsblk`, `findmnt`, `sha256sum`, `git` | Standard-Tools |
| `7z` (p7zip-plugins) | für ISO CDLABEL-Extraktion |
| Ventoy USB-Stick | ≥ 32 GB empfohlen, Ventoy vorinstalliert |
| Root-Rechte | `sudo ./fedora-install.sh …` |

> **Ziel-Hardware:** UEFI-System mit NVIDIA GPU (Turing RTX 20xx oder neuer), AMD Ryzen CPU empfohlen.  
> Legacy-BIOS wird nicht unterstützt.

---

## Projektstruktur

```
fedora-autoinstall/
├── fedora-install.sh          # Haupt-Orchestrator
├── fedora-provision.sh        # Provisioner für laufende Systeme
├── Containerfile.vllm         # Custom vLLM Image (Blackwell sm_120 optimiert)
│
├── config/
│   ├── example.xml            # Referenz-Konfiguration
│   └── schema.xsd             # XML-Schema (Validierung)
│
├── kickstart/
│   ├── fedora-full.ks         # Vollinstallation (GNOME + NVIDIA + AI)
│   ├── fedora-theme-bash.ks   # GNOME + WhiteSur, kein AI
│   ├── fedora-headless-vllm.ks# Kein GUI, Podman + Kimi-Audio + Qwen3
│   ├── fedora-vm.ks           # VM (KVM/QEMU, vda)
│   └── common-post.inc        # Gemeinsamer %post-Block (sync mit scripts/!)
│
├── ventoy/
│   ├── ventoy_grub.cfg.tpl    # GRUB-Menü (5 Profile: m/f/t/h/v)
│   └── ventoy.json.tpl        # Ventoy auto_install-Template
│
├── lib/
│   ├── common.sh              # Logging, dry-run, Safety-Checks
│   ├── usb.sh                 # Ventoy USB-Erkennung und Mount
│   └── xml2ks.py              # XML → Kickstart Konverter + Validator
│
├── scripts/
│   ├── first-boot.sh          # Systemweite Provisionierung (root, einmalig)
│   ├── first-login.sh         # User-Provisionierung (sija, einmalig)
│   ├── vm-test.sh             # VM-Test via KVM/QEMU + SSH
│   ├── podman-pipeline.sh     # Layered Container-Build + --build-vllm
│   └── podman-run.sh          # Interaktiver Container-Start
│
├── systemd/
│   └── fedora-first-boot.service
│
└── iso/                       # Lokaler ISO-Cache
```

---

## Schnellstart

### 1. USB-Stick beschreiben

```bash
sudo ./fedora-install.sh --config config/mein-system.xml
```

### 2. Profil wählen

USB einstecken → Im Ventoy-Hauptmenü **F6** drücken → Hotkey wählen:

| Taste | Profil | Was passiert |
|-------|--------|-------------|
| `m` | VM-Test | Anaconda → `fedora-vm.ks` (KVM/QEMU) |
| `f` | Vollinstallation | Anaconda → `fedora-full.ks` |
| `t` | Theme + Bash | Provisioner auf bestehendem System |
| `h` | Headless vLLM | Provisioner: Podman + Kimi-Audio + Qwen3 |
| `v` | vLLM only | Provisioner: vLLM only |

### 3. Provisioner auf laufendem System

```bash
# Theme + WhiteSur + Oh-My-Bash
sudo bash /run/media/$USER/Ventoy/fedora-provision.sh --profile theme-bash

# Podman + Kimi-Audio-7B + Qwen3-8B (AI Agent)
sudo bash /run/media/$USER/Ventoy/fedora-provision.sh --profile headless-vllm
```

---

## Profile im Detail

### `full` — Vollinstallation (ISO-Boot)
Frische Neuinstallation auf leerem System. Btrfs-Dateisystem, GNOME Desktop, NVIDIA Open Driver, CUDA, WhiteSur-Theme, Oh-My-Bash, Podman, AI-Stack.

### `theme-bash` — Theme + Bash (Provisioner)
WhiteSur GTK/Icon/Wallpaper/Cursor-Themes, Dash-to-Dock, Blur-my-Shell, Oh-My-Bash. Kein AI-Stack.

### `headless-vllm` — Podman + KI-Agent (Provisioner)
NVIDIA Open Driver, CUDA, Podman mit zwei vLLM-Services:
- **Kimi-Audio-7B** auf Port 8000 — Musik-Analyse
- **Qwen3-8B** auf Port 8001 — Reasoning + LangGraph

### `vm` — VM (intern)
KVM/QEMU-Gast, virtio-Disk (`vda`). Für automatisierte VM-Tests.

---

## Dateisystem: Btrfs

Alle Profile nutzen **Btrfs** mit Ubuntu-kompatiblem Subvolume-Layout:

| Subvolume | Mountpoint | Zweck |
|-----------|-----------|-------|
| `@` | `/` | Root — Timeshift-Snapshots |
| `@home` | `/home` | Home-Verzeichnis |

Mount-Optionen: `compress=zstd:1,noatime`  
Kein Swap-Partition — **zram-generator** übernimmt (50% RAM, zstd-Kompression).

### Timeshift + GRUB-Snapshots

Beim ersten Boot werden automatisch eingerichtet:
- **Timeshift** (btrfs-Modus) — monatliche Snapshots + Boot-Snapshot
- **grub-btrfs** — Snapshots erscheinen im GRUB-Auswahlmenü

---

## System-Optimierungen

### Performance (first-boot.sh)

| Bereich | Was |
|---------|-----|
| **DNF** | `max_parallel_downloads=10`, `fastestmirror`, `deltarpm` |
| **Kernel/Sysctl** | `vm.swappiness=10`, `vfs_cache_pressure=50`, `net.core.somaxconn=1024` |
| **Hugepages** | `madvise` via tmpfiles.d — PyTorch/vLLM nutzen es gezielt |
| **CPU** | `tuned throughput-performance` + `schedutil` Governor |
| **scx_bpfland** | Cache-aware Scheduler für AMD Ryzen CCDs (COPR bieszczaders) |
| **NVIDIA** | Persistence Mode als systemd-Service |
| **zram** | 50% RAM, zstd — ersetzt Swap-Partition |
| **irqbalance** | IRQ-Verteilung auf alle CPU-Kerne |
| **ananicy-cpp** | Prozess-Priorisierung (COPR eriknguyen) |
| **AMD Ryzen** | P-State EPP=performance, `amd_pstate=active`, `amd_iommu=on` im GRUB |
| **fstrim** | Wöchentlicher SSD TRIM |

### GNOME (first-login.sh)

| Bereich | Was |
|---------|-----|
| **Theme** | WhiteSur GTK/Icons/Wallpaper/Cursor (macOS-Stil) |
| **Dock** | Dash-to-Dock: unten, autohide, Apps-Button links |
| **Extensions** | blur-my-shell, caffeine, AppIndicator, user-theme |
| **Schrift** | `font-antialiasing=rgba`, `font-hinting=slight` |
| **Night Light** | 20:00–07:00, 3500K |
| **GRUB Theme** | WhiteSur (passend zum Desktop) |

---

## AI Agent: Bitwig Musik-Pipeline

### Architektur

```
~/bitwig-input/  (MP3/WAV/FLAC)
       │
       ▼
Kimi-Audio-7B — Port 8000 (~4 GB VRAM)
  Musik-Analyse: Tempo, Key, Genre, Mood, Chords
       │
       ▼
Neo4j — Musik-Theorie DB
  Chord Progressions, Reference Songs, Rhythm Patterns
       │
       ▼
Qwen3-8B + Thinking — Port 8001 (~5 GB VRAM)
  <think>...</think> → LangGraph Slaves
       │
       ▼
~/bitwig-output/  (.bwtemplate.json)
```

**VRAM gesamt: ~9 GB** — beide Modelle gleichzeitig in 16 GB VRAM.

### Verzeichnisse

| Verzeichnis | Inhalt |
|-------------|--------|
| `~/bitwig-input/` | MP3/WAV/FLAC Eingabedateien |
| `~/bitwig-output/` | Generierte `.bwtemplate.json` Ergebnisse |
| `~/.models/huggingface/` | Modell-Gewichte (getrennt von `~/.cache/`) |

### Pipeline starten

```bash
# Services starten
systemctl --user start vllm-audio.service vllm-agent.service

# Einzelne Datei
~/.local/share/bitwig-agent/run_pipeline.sh ~/bitwig-input/track.mp3

# Alle Dateien in ~/bitwig-input/
~/.local/share/bitwig-agent/run_pipeline.sh
```

### Custom vLLM Image (Blackwell-optimiert)

```bash
# Einmaliger Build ~30-60 Min (CUDA sm_120 für RTX 9070)
./scripts/podman-pipeline.sh --build-vllm
# → fedora-vllm:latest  (~10-15% mehr tokens/sec)
```

---

## VM-Test

```bash
# Vollständiger Test-Zyklus
./scripts/vm-test.sh install    # Frische Installation (Anaconda)
./scripts/vm-test.sh base       # Snapshot anlegen
./scripts/vm-test.sh test theme-bash  # Provisioner testen
```

**VM-Anforderungen:** 100 GB Disk, 8 GB RAM, 4 vCPUs, Ventoy USB-Passthrough.

---

## Boot-Ablauf

```
Ventoy USB
  └─ ISO (Fedora Netinstall)
       └─ GRUB (ventoy_grub.cfg) — WhiteSur Theme
            └─ Anaconda (graphical, nomodeset)
                 ├─ %pre: Disk automatisch erkennen
                 ├─ Btrfs partitionieren (@ + @home Subvolumes)
                 ├─ %post: provision.env + first-boot.sh + first-login.desktop
                 └─ %post --nochroot: fstab + GRUB auf subvol=@ umstellen
```

### Erster Boot (root, einmalig)

`fedora-first-boot.service` führt aus:
1. System-Update
2. NVIDIA Open Driver + akmods
3. CUDA (Fedora-Repo oder NVIDIA-Repo)
4. Kernel-Tuning: sysctl, hugepages, tuned, scx_bpfland
5. NVIDIA Persistence Mode
6. WhiteSur GRUB Theme
7. Timeshift + grub-btrfs
8. zram, irqbalance, ananicy-cpp
9. AMD Ryzen P-State + GRUB-Parameter

### Erster Login (User, einmalig)

`fedora-first-login.sh` führt aus:
1. Flathub + Flatpak Extension Manager
2. GNOME Extensions (dash-to-dock, blur-my-shell, caffeine, appindicator)
3. WhiteSur Themes + Dash-to-Dock Konfiguration
4. GNOME Tweaks + Night Light
5. Oh My Bash
6. AI-Stack (nur `full`/`headless-vllm`): PyTorch, vLLM, Modelle

---

## Disk-Erkennung

Alle physischen Profile erkennen die Ziel-Disk automatisch:

```bash
DISK=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1; exit}')
```

Funktioniert für SATA (`sda`), NVMe (`nvme0n1`) und virtio (`vda`).

Override: Im GRUB `e` drücken, an die `linux`-Zeile anhängen:
```
inst.disk=nvme1n1
```

---

## Hinweise

- **NVIDIA-Treiber:** Wird erst beim ersten Boot via `akmod-nvidia-open` gebaut — nicht während der Installation.
- **UEFI erforderlich:** Legacy-BIOS/MBR nicht unterstützt.
- **Passwort-Hash:** `openssl passwd -6 meinPasswort` — in `config/example.xml` ersetzen.
- **HuggingFace-Token:** In `/etc/fedora-provision.env` als `FEDORA_HF_TOKEN` eintragen.
- **Modell-Cache:** `~/.models/huggingface/` — bewusst von `~/.cache/` getrennt, überlebt Cache-Bereinigungen.
- **common-post.inc:** Muss mit `scripts/first-boot.sh` und `scripts/first-login.sh` synchron gehalten werden.
