# fedora-install

Vollautomatisches Unattended-Install-Framework für **Fedora Linux** (Fedora-basiert) via Ventoy USB-Stick.

Ein einziger Befehl beschreibt den USB-Stick mit ISO, Kickstart-Profilen und GRUB-Menü. Beim Booten wählt man ein Profil — der Rest läuft ohne Eingriff durch.

---

## Voraussetzungen

| Was | Version / Bedingung |
|---|---|
| Fedora / Fedora / RHEL-basiertes Host-System | für `fedora-install.sh` |
| Python 3 | `python3`, `pip`, `venv` |
| `curl`, `lsblk`, `findmnt`, `sha256sum`, `git` | Standard-Tools |
| `7z` (p7zip-plugins) | für ISO CDLABEL-Extraktion |
| Ventoy USB-Stick | ≥ 32 GB empfohlen, Ventoy vorinstalliert |
| Root-Rechte | `sudo ./fedora-install.sh …` |

> **Ziel-Hardware:** UEFI-System mit NVIDIA GPU (Turing RTX 20xx oder neuer).  
> Legacy-BIOS wird nicht unterstützt.

---

## Projektstruktur

```
fedora-install/
├── fedora-install.sh          # Haupt-Orchestrator
│
├── config/
│   ├── example.xml            # Referenz-Konfiguration
│   └── schema.xsd             # XML-Schema (Validierung)
│
├── kickstart/
│   ├── fedora-full.ks         # Profil: Vollinstallation (GNOME + NVIDIA + AI)
│   ├── fedora-theme-bash.ks   # Profil: GNOME + WhiteSur, kein AI
│   ├── fedora-headless-vllm.ks# Profil: Kein GUI, Podman + vLLM als Dienst
│   ├── fedora-vm.ks           # Profil: VM (KVM/QEMU, vda)
│   └── common-post.inc        # Gemeinsamer %post-Block (alle Profile)
│
├── ventoy/
│   ├── ventoy_grub.cfg.tpl    # GRUB-Menü-Template (4 Profile, Hotkeys f/t/h/v)
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
│   ├── benchmark.sh           # GPU/CPU Benchmark
│   ├── podman-pipeline.sh     # CI-Pipeline im Container
│   └── podman-run.sh          # Podman vLLM-Dienst starten
│
├── systemd/
│   └── fedora-first-boot.service  # Systemd Unit für first-boot.sh
│
├── tests/
│   └── test_xml2ks.py         # Unit-Tests für xml2ks.py
│
└── iso/                       # Lokaler ISO-Cache (wird von fedora-install.sh befüllt)
```

---

## Schnellstart

### 1. Konfiguration anpassen

```bash
cp config/example.xml config/mein-system.xml
# Passwort-Hash generieren:
openssl passwd -6 meinPasswort
# Hash in config/mein-system.xml unter <password_hash> eintragen
```

Mindest-Anpassungen in der XML:

| Feld | Bedeutung |
|---|---|
| `<password_hash>` | SHA-512 Passwort-Hash des Ziel-Users |
| `<sha256>` | SHA256-Prüfsumme der ISO (optional, empfohlen) |
| `<hostname>` | Hostname des Zielsystems |

### 2. USB-Stick beschreiben

```bash
sudo ./fedora-install.sh --config config/mein-system.xml
```

Mit Vorschau (kein Schreiben):

```bash
sudo ./fedora-install.sh --config config/mein-system.xml --dry-run
```

### 3. Profil wählen — ISO-Install oder Provisioner

Zwei grundlegend verschiedene Mechanismen:

| Profil | Mechanismus | Wann |
|---|---|---|
| `full` | ISO-Boot → Anaconda → frisches System | Neues System / Festplatte leer |
| `theme-bash` | `fedora-provision.sh` auf laufendem System | Fedora bereits installiert |
| `headless-vllm` | `fedora-provision.sh` auf laufendem System | Fedora bereits installiert |

#### Profil `full` — Frische Installation per ISO

USB-Stick in Zielrechner → Im Ventoy-Menü Fedora-ISO auswählen → **F6** → **`f`** drücken.

Anaconda startet grafisch, die Installation läuft vollautomatisch durch. Nach dem Reboot startet die Provisionierung automatisch.

Disk-Override (falls nicht die größte interne Disk gewählt werden soll): Im GRUB-Menü **`e`** drücken und an die `linux`-Zeile anhängen:
```
inst.disk=nvme1n1
```


USB-Stick einstecken, im laufenden Fedora ausführen:

```bash
# Theme + WhiteSur + Oh-My-Bash
sudo bash /run/media/$USER/Ventoy/fedora-provision.sh --profile theme-bash

# NVIDIA + CUDA + Podman + vLLM als systemd-Dienst
sudo bash /run/media/$USER/Ventoy/fedora-provision.sh --profile headless-vllm

# NVIDIA + CUDA + vLLM direkt im Python venv
```

Für einen anderen Benutzer:
```bash
sudo bash /run/media/$USER/Ventoy/fedora-provision.sh --profile theme-bash --user max
```

Sofort starten statt beim nächsten Boot:
```bash
```

---

## Profile im Detail

### `full` — Vollinstallation (ISO-Boot)
Frische Neuinstallation. GNOME Desktop, NVIDIA Open Driver, CUDA, Podman, vLLM (Blackwell sm120), Kimi-Audio, Qwen3-14B-AWQ, Neo4j, WhiteSur-Theme, Oh-My-Bash.

### `theme-bash` — Theme + Bash (Provisioner)
Auf bestehendem Fedora: WhiteSur GTK/Icon/Wallpaper-Themes, Oh-My-Bash. NVIDIA Open Driver wird aktualisiert. Kein AI-Stack, kein CUDA.

### `headless-vllm` — Podman + vLLM (Provisioner)
Auf bestehendem Fedora: NVIDIA Open Driver, CUDA, Podman-Pipeline mit vLLM als systemd-Dienst. Kein Anaconda-GUI nötig.

Auf bestehendem Fedora: NVIDIA Open Driver, CUDA, vLLM direkt im Python venv als systemd-Dienst. Kein Podman.

### `vm` — VM (intern)
KVM/QEMU-Gast, virtio-Disk (`vda`). Wird vom Podman-Smoke-Gate genutzt.

---

## Konfiguration (XML)

```xml
<fedora-install>
  <iso>
    <url>https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Everything/x86_64/iso/Fedora-Everything-netinst-x86_64-43-1.6.iso</url>
    <sha256>abc123…</sha256>          <!-- optional, aber empfohlen -->
  </iso>

  <hostname>fedora-workstation</hostname>
  <timezone>Europe/Berlin</timezone>
  <locale>de_DE.UTF-8</locale>
  <keyboard>de</keyboard>

  <user>
    <name>sija</name>
    <password_hash>$6$…</password_hash>
    <groups>wheel,libvirt,video,audio</groups>
  </user>

  <first-boot>
    <fedora-sync enabled="true"/>
    <nvidia-open enabled="true"/>
    <cuda enabled="true" source="fedora"/>  <!-- oder source="nvidia" -->
  </first-boot>

  <first-login>
    <whitesur enabled="true">
      <gtk-args>-l -c Dark</gtk-args>
      <icon-args>-dark</icon-args>
    </whitesur>
    <ohmybash enabled="true" theme="modern"/>
    <pytorch-venv enabled="true" path="~/.venvs/ai"/>
    <vllm-omni enabled="true" venv="~/.venvs/bitwig-omni">
      <cuda-version>13.0</cuda-version>
      <arch-list>12.0</arch-list>   <!-- sm120 = Blackwell RTX 5070 Ti -->
      <agent-model>Qwen/Qwen3-14B-AWQ</agent-model>
    </vllm-omni>
  </first-login>
</fedora-install>
```

Validierung ohne Deployment:

```bash
python3 lib/xml2ks.py --validate-only config/mein-system.xml
```

---

## Boot-Ablauf

```
Ventoy USB
  └─ ISO (Fedora Live)
       └─ GRUB (ventoy_grub.cfg)
            └─ Kernel-Parameter:
               root=live:CDLABEL=<label>  rd.live.image  nomodeset
               inst.ks=hd:LABEL=Ventoy:/kickstart/<profil>.ks
                    │
                    ├─ %pre: Disk automatisch erkennen (sda / nvme0n1 / vda)
                    ├─ Anaconda (grafisch) installiert das System
                    ├─ %post: /etc/fedora-provision.env schreiben
                    └─ common-post.inc:
                         ├─ first-boot.sh → /usr/local/sbin/
                         ├─ fedora-first-boot.service → systemd enable
                         └─ first-login.desktop → ~/.config/autostart/
```

### Nach dem ersten Boot

`fedora-first-boot.service` läuft einmalig als root:
1. `fedora-sync` — Fedora-Pakete aktualisieren
2. NVIDIA Open Driver installieren + `akmods` bauen
3. CUDA installieren (Fedora-Repo oder NVIDIA-Repo)
4. CUDA-Umgebungsvariablen systemweit schreiben

### Nach dem ersten Login (GNOME)

`fedora-first-login.sh` läuft einmalig als User:
1. Flatpak Extension Manager
2. GNOME-Extensions aktivieren
3. WhiteSur GTK / Icon / Wallpaper installieren
4. Oh My Bash installieren und Theme setzen
5. Python venv `~/.venvs/ai` + PyTorch (CUDA-aware)
6. vLLM-Omni bauen (CUDA 13.x, sm120)
7. Modelle laden (Kimi-Audio-7B, Qwen3-14B-AWQ)

---

## Disk-Erkennung

Alle physischen Kickstart-Profile erkennen die Ziel-Disk automatisch per `%pre`-Skript:

```bash
DISK=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1; exit}')
```

Das funktioniert für SATA (`sda`), NVMe (`nvme0n1`) und virtio (`vda`) ohne Anpassung.

---

## Podman Smoke-Gate

Vor jedem echten Deployment prüft `fedora-install.sh`, ob die Kickstart-Skripte zuvor erfolgreich im Container getestet wurden:

```bash
# Test zuerst:
./scripts/podman-pipeline.sh

# Dann deployen:
sudo ./fedora-install.sh --config config/example.xml

# Gate überspringen (nicht empfohlen):
sudo ./fedora-install.sh --config config/example.xml --skip-smoke-gate
```

---

## Hinweise

- **NVIDIA-Treiber:** Der proprietary NVIDIA-Treiber wird **nicht** während der Installation geladen, sondern erst beim ersten Boot via `akmod-nvidia-open`. Das ist korrekt so.
- **UEFI erforderlich:** Legacy-BIOS/MBR wird nicht unterstützt. Der Bootloader wird ohne `--location=mbr` gesetzt, damit Anaconda UEFI automatisch erkennt und eine EFI-Partition anlegt.
- **Passwort-Hash:** Der Hash in `config/example.xml` ist ein Platzhalter — vor dem Deployment unbedingt ersetzen.
- **HuggingFace-Token:** Für Modelle hinter einem Login-Gate wird beim ersten Download interaktiv nach dem Token gefragt.

---

---

## Bug-Findings (Changelog)

Folgende Fehler wurden identifiziert und behoben. Ohne diese Fixes startet die Installation nicht.

---

### BUG-01 — `inst.text` erzwingt Text-Modus (leere Shell)

**Datei:** `ventoy/ventoy_grub.cfg.tpl`  
**Symptom:** Nach Profilauswahl im GRUB erscheint ein leeres schwarzes Fenster. Ctrl+Alt+F1–F6 reagiert nicht.  
**Ursache:** Der Kernel-Parameter `inst.text` weist Anaconda an, im TUI-Modus zu starten. Auf einem System mit NVIDIA-GPU und aktivem Display-Manager landet die Text-UI auf einem nicht sichtbaren VT.  
**Fix:** `inst.text` aus allen vier `linux`-Zeilen entfernt.

---

### BUG-02 — `modules_load=nvidia` im Installer-Kernel (Boot-Fehler)

**Datei:** `ventoy/ventoy_grub.cfg.tpl`  
**Symptom:** System hängt beim Booten oder startet in eine leere Shell, weil das Modul nicht geladen werden kann.  
**Ursache:** `modules_load=nvidia` versucht, den proprietary NVIDIA-Kernel-Modul während des ISO-Boots zu laden. Das Modul existiert **nicht** im Installer-Initrd der Live-ISO. Anaconda wird nie gestartet.  
**Fix:** Parameter vollständig entfernt. NVIDIA wird erst nach der Installation via `akmod-nvidia-open` gebaut (First-Boot).

---

### BUG-03 — `text` in Kickstart-Dateien (kein grafischer Installer)

**Dateien:** `kickstart/fedora-full.ks`, `kickstart/fedora-theme-bash.ks`  
**Symptom:** Anaconda startet im TUI-Modus statt im grafischen Installer.  
**Ursache:** Die Kickstart-Direktive `text` erzwingt Text-Modus, unabhängig vom Kernel-Parameter.  

---

### BUG-04 — `nomodeset` fehlt (schwarzer Bildschirm trotz grafischem Modus)

**Datei:** `ventoy/ventoy_grub.cfg.tpl`  
**Symptom:** Grafischer Anaconda-Installer startet, bleibt aber schwarz, weil `nouveau` oder `simpledrm` mit der NVIDIA-GPU kollidiert.  
**Ursache:** Ohne `nomodeset` versucht der Kernel, einen Modesetting-Treiber für die NVIDIA-GPU zu aktivieren. Da weder `nouveau` noch `nvidia` im Installer-Initrd vollständig funktionieren, bleibt der Framebuffer schwarz.  
**Fix:** `nomodeset` zu den GUI-Profil-Zeilen (`full`, `theme-bash`) hinzugefügt. Der Installer nutzt damit den VESA/Basic-Framebuffer — stabil und ausreichend für die Anaconda-Oberfläche.

---

### BUG-05 — Hardcodierte Disk `sda` (Installation schlägt fehl auf NVMe)

**Dateien:** alle `kickstart/fedora-*.ks` (außer `fedora-vm.ks`)  
**Symptom:** Anaconda bricht mit `Disk sda not found` ab. Installation startet nie.  
**Ursache:** `ignoredisk --only-use=sda` und `clearpart --drives=sda` setzen SATA-Disk voraus. Auf modernen Systemen mit NVMe heißt die Disk `nvme0n1`.  
**Fix:** `%pre`-Skript erkennt die erste verfügbare Disk automatisch per `lsblk` und schreibt die Direktiven in `/tmp/disk-setup.cfg`, das dann per `%include` eingebunden wird. Funktioniert für SATA, NVMe und virtio ohne Anpassung.

---

### BUG-06 — `bootloader --location=mbr` auf UEFI-System

**Dateien:** alle `kickstart/fedora-*.ks` (außer `fedora-vm.ks`)  
**Symptom:** Installation bricht ab oder System startet nach Installation nicht, weil kein UEFI-Bootloader angelegt wurde.  
**Ursache:** `--location=mbr` erzwingt Legacy-BIOS-Booting. Auf UEFI-Systemen muss Anaconda eine EFI-Systempartition (`/boot/efi`) anlegen und `grub2-efi` installieren. Der `mbr`-Parameter verhindert das.  
**Fix:** `--location=mbr` entfernt. Anaconda erkennt UEFI vs. BIOS automatisch und richtet den Bootloader korrekt ein.
