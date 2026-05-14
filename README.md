# fedora-autoinstall - beta

Vollautomatisches Unattended-Install-Framework für **Fedora Linux** — eigener GRUB2-Bootloader + Bazzite-Kernel auf USB-Stick, kein Ventoy.

Beim Booten erscheint direkt das GRUB2-Menü mit Hotkeys — der Rest läuft ohne Eingriff durch.

---

## Voraussetzungen

| Was | Version / Bedingung |
|---|---|
| Fedora-basiertes Host-System | für `build-usb.sh` |
| Python 3 | `python3`, `pip`, `venv` |
| `sgdisk`, `mkfs.fat`, `grub2-install` | `dnf install gdisk dosfstools grub2-efi-x64` |
| `xorriso`, `cpio`, `zstd`, `rpm2cpio` | `dnf install xorriso cpio zstd rpm-build` |
| USB-Stick | ≥ 8 GB, wird komplett neu formatiert |
| Root-Rechte | `sudo scripts/build-usb.sh …` |

> **Ziel-Hardware:** UEFI-System mit NVIDIA GPU (Turing RTX 20xx oder neuer), AMD Ryzen CPU empfohlen.  
> Legacy-BIOS wird nicht unterstützt.

---

## Projektstruktur

```
fedora-autoinstall/
├── fedora-provision.sh        # Provisioner für laufende Systeme
├── fedora-iso-build.sh        # Custom-ISO bauen (für dd-Flash ohne USB-Boot)
├── Containerfile.vllm         # Custom vLLM Image (Blackwell sm_120 optimiert)
│
├── boot/
│   └── grub.cfg               # GRUB2-Menü (5 Profile: f/d/m/t/h)
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
│   └── common-post.inc        # Gemeinsamer %post-Block
│
├── lib/
│   ├── common.sh              # Logging, dry-run, Safety-Checks
│   └── xml2ks.py              # XML → Kickstart Konverter + Validator
│
├── scripts/
│   ├── build-usb.sh           # USB-Stick einmalig aufbauen (GRUB2 + Bazzite-Kernel)
│   ├── sync-usb.sh            # Repo → USB synchronisieren
│   ├── first-boot.sh          # Systemweite Provisionierung (root, einmalig)
│   ├── first-login.sh         # User-Provisionierung (einmalig)
│   ├── vm-test.sh             # VM-Test via KVM/QEMU + SSH
│   ├── vm-test-blackwell.sh   # Headless KVM-Test: Blackwell-Boot-Simulation
│   ├── podman-pipeline.sh     # Layered Container-Build + --build-vllm
│   └── podman-run.sh          # Interaktiver Container-Start
│
├── systemd/
│   └── fedora-first-boot.service
│
└── iso/
    ├── kernel-cache/          # Bazzite-Kernel-RPM-Cache (kein Re-Download)
    └── Fedora-Everything-netinst-*.iso  # Source-ISO (manuell ablegen)
```

---

## Schnellstart

### 1. USB-Stick einmalig aufbauen

```bash
# Source-ISO nach iso/ legen (einmalig):
# https://fedoraproject.org/everything/download  →  iso/

# USB-Stick aufbauen (formatiert, installiert GRUB2 + Bazzite-Kernel):
sudo scripts/build-usb.sh /dev/sdX
```

Was `build-usb.sh` macht:
- GPT: Part 1 = EFI (256 MB FAT32), Part 2 = FEDORA-USB (Rest FAT32)
- GRUB2 EFI (`BOOTX64.EFI`) + `boot/grub.cfg` installieren
- Bazzite-Kernel von COPR laden (RPM-Cache in `iso/kernel-cache/`)
- Anaconda-initrd mit Bazzite-Modulen neu packen
- Kickstart, Scripts, Systemd-Units auf USB kopieren

Bazzite-Kernel-RPMs werden in `iso/kernel-cache/` gecacht — kein Re-Download beim nächsten Mal.

### 2. USB-Stick aktuell halten

```bash
# Prüfen ob Stick aktuell ist:
scripts/sync-usb.sh --check

# Synchronisieren (interaktiv mit Diff):
scripts/sync-usb.sh

# Ohne Rückfrage:
scripts/sync-usb.sh --force
```

> **Kernel-Update:** `build-usb.sh` erneut ausführen — `sync-usb.sh` aktualisiert nur Scripts/Kickstart/Config, nicht den Kernel.

### 3. Profil wählen und installieren

USB einstecken → UEFI Boot → GRUB2-Menü → Hotkey drücken:

| Taste | Profil | Was passiert |
|-------|--------|-------------|
| `f` | Vollinstallation | Anaconda → `fedora-full.ks` (GNOME + NVIDIA + AI) |
| `d` | Debug-Install | Text-Modus + Serial-Log + Logs auf USB |
| `m` | VM-Test | Anaconda → `fedora-vm.ks` (KVM/QEMU) |
| `t` | Theme + Bash | Provisioner auf bestehendem System |
| `h` | Headless vLLM | Provisioner: Podman + Kimi-Audio + Qwen3 |

Stage2 (Anaconda-Installer) wird live vom Fedora Mirror geladen — keine ISO auf dem USB-Stick nötig.

### 4. Provisioner auf laufendem System

```bash
# Theme + WhiteSur + Oh-My-Bash
sudo bash /run/media/$USER/FEDORA-USB/fedora-provision.sh --profile theme-bash

# Podman + Kimi-Audio-7B + Qwen3 (AI Agent)
sudo bash /run/media/$USER/FEDORA-USB/fedora-provision.sh --profile headless-vllm
```

---

## Alternative: Custom-ISO (ohne USB-Boot)

Für `dd`-Flash direkt auf USB oder SD-Karte — kein GRUB2-Setup nötig:

```bash
sudo dnf install lorax xorriso cpio zstd

# Standard-ISO mit Kickstart (full-Profil)
sudo ./fedora-iso-build.sh --profile full

# Mit Bazzite-Kernel-Swap für Blackwell (RTX 50/9070)
sudo ./fedora-iso-build.sh --profile full --swap-kernel

# Direkt auf USB-Stick schreiben
sudo ./fedora-iso-build.sh --profile full --swap-kernel --write /dev/sdX
```

Ergebnis: `iso/Fedora-Auto-full.iso` — booten startet Anaconda automatisch mit eingebettetem Kickstart.

---

## NVIDIA Blackwell (RTX 50 / 9070)

Der **Bazzite-Kernel** im USB-Boot bringt nativen sm_120-Support — der iGPU-Workaround aus alten Ventoy-Anleitungen ist **nicht mehr nötig**.

Einfach [f] drücken und abwarten.

### Diagnose: Schwarzer Bildschirm

Falls Anaconda nach dem Boot schweigt: **mindestens 90 Sekunden warten** — stage2 wird live vom Netzwerk geladen.

Falls weiterhin schwarz, **TTY-Switch** versuchen:

| Tastenkombi | Inhalt |
|---|---|
| `Ctrl+Alt+F1` | Anaconda-UI (Hauptkonsole) |
| `Ctrl+Alt+F2` | Root-Shell — `dmesg`, `journalctl -xb` |
| `Ctrl+Alt+F3` | `anaconda.log` |
| `Ctrl+Alt+F4` | Storage-Log |
| `Ctrl+Alt+F5` | Programm-Log |

Für tiefere Diagnose: **[d] Debug-Install** — Serial-Log landet auf dem USB-Stick unter `logs/`.

---

## Profile im Detail

### `full` — Vollinstallation (USB-Boot)
Frische Neuinstallation auf leerem System. Btrfs, GNOME Desktop, NVIDIA Open Driver, CUDA, WhiteSur-Theme, Oh-My-Bash, Podman, AI-Stack.

### `theme-bash` — Theme + Bash (Provisioner)
WhiteSur GTK/Icon/Wallpaper/Cursor-Themes, Dash-to-Dock, Blur-my-Shell, Oh-My-Bash. Kein AI-Stack.

### `headless-vllm` — Podman + KI-Agent (Provisioner)
NVIDIA Open Driver, CUDA, Podman mit zwei vLLM-Services:
- **Kimi-Audio-7B** auf Port 8000 — Musik-Analyse
- **Qwen3-14B** auf Port 8001 — Reasoning + LangGraph

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
Qwen3-14B + Thinking — Port 8001 (~5 GB VRAM)
  <think>...</think> → LangGraph Slaves
       │
       ▼
~/bitwig-output/  (.bwtemplate.json)
```

**VRAM gesamt: ~9 GB** — beide Modelle gleichzeitig in 16 GB VRAM.

### Pipeline starten

```bash
# Router starten (lädt Backends on-demand)
systemctl --user start vllm-router.service

# Einzelne Datei
~/.local/share/bitwig-agent/run_pipeline.sh ~/bitwig-input/track.mp3

# Alle Dateien in ~/bitwig-input/
~/.local/share/bitwig-agent/run_pipeline.sh
```

### LangGraph / OpenAI-Clients via vLLM-Router

Eine OpenAI-kompatible API auf `:8000` mit Multi-Model Hotswap. Jedes LangGraph-Projekt
setzt `OPENAI_BASE_URL=http://localhost:8000/v1` und wählt das Modell per Request-Body —
der Router startet/stoppt vLLM-Backend-Container (Quadlet `vllm@<name>.service`) on-demand.

```bash
# Verfügbare Modelle anzeigen
curl http://localhost:8000/v1/models

# Chat — Backend wird beim ersten Request automatisch gestartet (30-180s Cold-Start)
curl http://localhost:8000/v1/chat/completions -d '{
  "model": "agent",
  "messages": [{"role":"user","content":"hi"}]
}'

# Preload ohne Anfrage
curl -X POST 'http://localhost:8000/admin/preload?model=agent'

# Status aller Modelle (laufend / idle / VRAM-Anteil)
curl http://localhost:8000/admin/status
```

**Neues Modell hinzufügen** — `~/.config/vllm-router/models.json`:

```json
{
  "qwen3-14b": {
    "hf_repo": "Qwen/Qwen3-14B-AWQ",
    "port": 8102,
    "vram_share": 0.55,
    "max_len": 8192,
    "extra": "--enable-reasoning --reasoning-parser deepseek_r1"
  }
}
```

```python
# LangGraph-Beispiel
from langchain_openai import ChatOpenAI
llm = ChatOpenAI(base_url="http://localhost:8000/v1", model="agent", api_key="sk-anything")
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
# Blackwell-Boot-Simulation (headless KVM, Serial-Log-Monitoring)
scripts/vm-test-blackwell.sh
scripts/vm-test-blackwell.sh --keep   # VM nach Test behalten

# Vollständiger Provisioner-Test
scripts/vm-test.sh install    # Frische Installation (Anaconda)
scripts/vm-test.sh snapshot   # Snapshot anlegen
scripts/vm-test.sh test theme-bash  # Provisioner testen
```

---

## Boot-Ablauf

```
FEDORA-USB (GRUB2 + Bazzite-Kernel)
  └─ GRUB2-Menü (boot/grub.cfg)
       └─ Anaconda — stage2 vom Fedora Mirror (Netzwerk)
            ├─ %pre: Disk automatisch erkennen
            ├─ Btrfs partitionieren (@ + @home Subvolumes)
            ├─ %post: provision.env + first-boot.sh + first-login.desktop
            └─ %post --nochroot: fstab + Logs auf USB sichern
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
- **Kernel-Cache:** `iso/kernel-cache/` — Bazzite-RPMs werden gecacht, kein Re-Download bei `build-usb.sh`.
- **common-post.inc:** Muss mit `scripts/first-boot.sh` und `scripts/first-login.sh` synchron gehalten werden.
