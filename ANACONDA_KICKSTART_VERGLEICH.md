# Vergleich: Anaconda/Kickstart Findings vs. Projektstand

Stand: 2026-05-15

## Verwendete Referenzen (Web-Recherche)

- Anaconda Boot-Optionen:  
  https://anaconda-installer.readthedocs.io/en/latest/user-guide/boot-options.html
- Anaconda Kickstart-Guide:  
  https://anaconda-installer.readthedocs.io/en/latest/user-guide/kickstart.html
- Pykickstart Syntax-Referenz:  
  https://pykickstart.readthedocs.io/en/latest/kickstart-docs.html
- Pykickstart Beispiele:  
  https://pykickstart.readthedocs.io/en/latest/kickstart-examples.html
- GitHub-Beispiele:  
  https://github.com/Linuxfabrik/kickstart  
  https://github.com/sinner-/kickstart-fedora-workstation  
  https://github.com/foundata/kickstart-templates

## Kurzfazit

Das Projekt setzt die zentralen Anaconda-Kickstart-Mechaniken bereits korrekt um: `inst.ks`-Aufrufe sind valide, die Dateipfade für ISO/USB sind stimmig und `%include`-Strukturen funktionieren konsistent. Größte Lücke ist nicht Funktionalität, sondern Dokumentation/Robustheit (z. B. kein OEMDRV-Fallback, keine `ksvalidator`-Prüfung im Workflow).

## Detailvergleich

| Thema | Offizielle Findings | Projektstand | Bewertung |
|---|---|---|---|
| Kickstart per Boot-Arg | `inst.ks=<quelle>` unterstützt `http/https/ftp/nfs/hd/cdrom` | `boot/grub.cfg` nutzt `inst.ks=hd:LABEL=FEDORA-USB:/kickstart/...`; ISO nutzt `inst.ks=cdrom:/ks.cfg`; VM-Test nutzt auch HTTP/File-Variante | ✅ |
| Standardpfad | Wenn Pfad fehlt, default ist `/ks.cfg` | `fedora-iso-build.sh` bettet Kickstart explizit als `/ks.cfg` ein und bootet mit `inst.ks=cdrom:/ks.cfg` | ✅ |
| OEMDRV Autoload | Auto-Load möglich via Label `OEMDRV` + `/ks.cfg` | Keine Nutzung/kein Fallback auf OEMDRV in GRUB/Skripten | ⚠️ Optionaler Gap |
| Mehrere KS-Quellen | `inst.ks.all` probiert mehrere HTTP(S)/FTP-Quellen | Nicht verwendet | ⚠️ Optionaler Gap |
| Install-Quelle | `inst.repo`/`inst.stage2` müssen erreichbar sein | `boot/grub.cfg` setzt `inst.stage2=https://dl.fedoraproject.org/...` | ✅ |
| Runtime-Dateipfade | Bei ISO-Zusatzinhalten typischer Zugriff über `/run/install/source/...` | `scripts/vm-test-blackwell.sh --usb` nutzt `inst.ks=file:///run/install/source/fedora-vm.ks` | ✅ |
| Include-Mechanik | `%include`/`%ksappend` sind gültige KS-Features | KS-Profile nutzen `%include /kickstart/common-post.inc`; Builder kopiert `kickstart/` konsistent auf ISO/USB | ✅ |
| Beispiel-KS nach Installation | Anaconda schreibt typischerweise `/root/anaconda-ks.cfg` | Nicht explizit dokumentiert im Projekt | ℹ️ |
| Syntax-Validierung | Empfohlen: `ksvalidator` (pykickstart) | Kein Treffer für `ksvalidator`/`ksverdiff` in Repo-Skripten/Tests | ⚠️ |

## Relevante Stellen im Projekt

- `boot/grub.cfg`  
  `inst.ks=hd:LABEL=FEDORA-USB:/kickstart/fedora-full.ks`  
  `inst.ks=hd:LABEL=FEDORA-USB:/kickstart/fedora-vm.ks`
- `fedora-iso-build.sh`  
  Kopiert Profil nach `.../ks.cfg` und nutzt `inst.ks=cdrom:/ks.cfg`
- `scripts/build-usb.sh`  
  Kopiert `kickstart/*.ks` + `common-post.inc` auf USB (`/kickstart`)
- `scripts/vm-test-blackwell.sh`  
  testet `inst.ks` über `http://...`, `file:///run/install/source/...` und `cdrom:/ks.cfg`
- `kickstart/*.ks`  
  nutzen `%include /kickstart/common-post.inc`

## Empfehlungen (priorisiert)

1. **`ksvalidator` in den Test/Build-Workflow aufnehmen**  
   Beispiel: `ksvalidator kickstart/*.ks` für frühzeitige Syntaxfehler.
2. **OEMDRV als dokumentierten Fallback ergänzen**  
   Für „USB mit Label OEMDRV + /ks.cfg“-Szenario bei problematischen Boot-Umgebungen.
3. **Optionale Mirror-Resilienz dokumentieren**  
   Für netzwerkabhängige Setups: Alternativen mit mehreren `inst.ks=` + `inst.ks.all`.
4. **Hinweis auf `/root/anaconda-ks.cfg` in README ergänzen**  
   Nützlich für Debugging und Reproduktion installierter Systeme.

