#!/usr/bin/env bash
# tests/test_sync_usb.sh — Unittest für scripts/sync-usb.sh
#
# Testet ohne echten USB-Stick: Temp-Verzeichnisse simulieren Projekt + USB-Mount.
# Fake-Binaries (findmnt, lsblk, udisksctl, sync) werden über PATH gemockt.
#
# Usage:
#   bash tests/test_sync_usb.sh
#   bash tests/test_sync_usb.sh -v     # verbose

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SYNC_USB="${PROJECT_DIR}/scripts/sync-usb.sh"

VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

# ── Test-Framework ─────────────────────────────────────────────────────────────
PASS=0; FAIL=0; ERRORS=()

run_test() {
    local name="$1"; shift
    if "$@" &>/dev/null; then
        PASS=$(( PASS + 1 ))
        if [[ $VERBOSE -eq 1 ]]; then
            echo "  ok  $name"
        fi
    else
        FAIL=$(( FAIL + 1 ))
        ERRORS+=("$name")
        echo "  FAIL  $name"
    fi
}

run_test_output() {
    # run_test_output <name> <expected_pattern> <cmd...>
    local name="$1" pattern="$2"; shift 2
    local out
    out=$("$@" 2>&1) || true
    if echo "$out" | grep -q "$pattern"; then
        PASS=$(( PASS + 1 ))
        if [[ $VERBOSE -eq 1 ]]; then
            echo "  ok  $name"
        fi
    else
        FAIL=$(( FAIL + 1 ))
        ERRORS+=("$name")
        echo "  FAIL  $name"
        if [[ $VERBOSE -eq 1 ]]; then
            echo "       output: $out"
            echo "       pattern: $pattern"
        fi
    fi
}

# ── Test-Setup: Fake-Umgebung ──────────────────────────────────────────────────
setup() {
    # Temporäre Verzeichnisse für Projekt-Klon und USB-Mount
    TMP=$(mktemp -d -t sync-usb-test-XXXXXX)
    FAKE_PROJECT="${TMP}/project"
    FAKE_USB="${TMP}/usb"
    FAKE_BIN="${TMP}/bin"

    mkdir -p \
        "${FAKE_PROJECT}/kickstart" \
        "${FAKE_PROJECT}/scripts" \
        "${FAKE_PROJECT}/systemd" \
        "${FAKE_PROJECT}/boot" \
        "${FAKE_USB}/kickstart" \
        "${FAKE_USB}/scripts" \
        "${FAKE_USB}/systemd" \
        "${FAKE_USB}/boot" \
        "$FAKE_BIN"

    # Pflicht-Quelldateien anlegen (alle aus PLAN)
    touch \
        "${FAKE_PROJECT}/fedora-provision.sh" \
        "${FAKE_PROJECT}/kickstart/common-post.inc" \
        "${FAKE_PROJECT}/kickstart/fedora-vm.ks" \
        "${FAKE_PROJECT}/kickstart/fedora-full.ks" \
        "${FAKE_PROJECT}/kickstart/fedora-headless-vllm.ks" \
        "${FAKE_PROJECT}/kickstart/fedora-theme-bash.ks" \
        "${FAKE_PROJECT}/scripts/first-boot.sh" \
        "${FAKE_PROJECT}/scripts/first-login.sh" \
        "${FAKE_PROJECT}/scripts/vllm-router.py" \
        "${FAKE_PROJECT}/scripts/welcome-dialog.sh" \
        "${FAKE_PROJECT}/scripts/fedora-provision.desktop" \
        "${FAKE_PROJECT}/systemd/fedora-first-boot.service" \
        "${FAKE_PROJECT}/systemd/vllm@.container" \
        "${FAKE_PROJECT}/systemd/vllm-router.service" \
        "${FAKE_PROJECT}/boot/grub.cfg" \
        "${FAKE_USB}/boot/vmlinuz" \
        "${FAKE_USB}/boot/initrd.img"

    # Fake-Binaries: findmnt + mount melden USB als gemountet
    cat > "${FAKE_BIN}/findmnt" <<'EOF'
#!/bin/bash
exit 0
EOF
    cat > "${FAKE_BIN}/mount" <<'EOF'
#!/bin/bash
# Simuliert gemounteten USB für macOS-Pfad
echo "fake on /Volumes/FEDORA-USB type msdos"
exit 0
EOF
    # lsblk, udisksctl, diskutil, sync: no-ops
    for cmd in lsblk udisksctl diskutil sync; do
        printf '#!/bin/bash\nexit 0\n' > "${FAKE_BIN}/${cmd}"
    done
    chmod +x "${FAKE_BIN}"/*

    # sync-usb.sh via Wrapper mit überschriebenem PROJECT_DIR + USB_MNT starten
    WRAPPER="${TMP}/run-sync-usb.sh"
    cat > "$WRAPPER" <<WEOF
#!/usr/bin/env bash
export PATH="${FAKE_BIN}:\$PATH"

PATCHED="\$(mktemp)"
sed \
    -e 's|PROJECT_DIR=.*|PROJECT_DIR="${FAKE_PROJECT}"|' \
    -e 's|HOST_OS=.*|HOST_OS="Linux"|' \
    -e 's|USB_MNT="/run/media.*|USB_MNT="${FAKE_USB}"|' \
    -e 's|self_mounted=0|self_mounted=0 # test|' \
    "${SYNC_USB}" > "\$PATCHED"

export FAKE_PROJECT="${FAKE_PROJECT}"
export FAKE_USB="${FAKE_USB}"
export FEDORA_SYNC_SKIP_PREFLIGHT=1
export FEDORA_SYNC_DEPLOY_COMMAND="bash \"\$PATCHED\" --files-only"

bash "\$PATCHED" "\$@"
rc=\$?
rm -f "\$PATCHED"
exit \$rc
WEOF
    chmod +x "$WRAPPER"
    SYNC="$WRAPPER"
}

teardown() {
    rm -rf "$TMP"
}

# ── Tests ──────────────────────────────────────────────────────────────────────

echo ""
echo "══ test_sync_usb.sh ══"
echo ""

# ── 1. Ungültige Argumente ────────────────────────────────────────────────────
setup
run_test "ungültiges Argument gibt Exit 2" \
    bash -c "bash '${SYNC_USB}' --unknown 2>/dev/null; [[ \$? -eq 2 ]]"
teardown

# ── 2. check-Modus: aktuell → Exit 0 ─────────────────────────────────────────
setup
# Alle PLAN-Dateien auf USB spiegeln
for entry in \
    "fedora-provision.sh" \
    "kickstart/common-post.inc" \
    "kickstart/fedora-vm.ks" \
    "kickstart/fedora-full.ks" \
    "kickstart/fedora-headless-vllm.ks" \
    "kickstart/fedora-theme-bash.ks" \
    "scripts/first-boot.sh" \
    "scripts/first-login.sh" \
    "scripts/vllm-router.py" \
    "scripts/welcome-dialog.sh" \
    "scripts/fedora-provision.desktop" \
    "systemd/fedora-first-boot.service" \
    "systemd/vllm@.container" \
    "systemd/vllm-router.service" \
    "boot/grub.cfg"; do
    mkdir -p "${FAKE_USB}/$(dirname "$entry")"
    cp "${FAKE_PROJECT}/${entry}" "${FAKE_USB}/${entry}"
done
run_test_output "--check: aktuell meldet 'aktuell'" \
    "aktuell" \
    bash "$SYNC" --check
teardown

# ── 3. check-Modus: Drift → Exit 1 (read-only) ───────────────────────────────
setup
# Quelldatei geändert, USB noch alt
echo "neue version" > "${FAKE_PROJECT}/kickstart/fedora-full.ks"
run_test "--check: Drift gibt Exit 1" \
    bash -c "bash '${SYNC}' --check >/dev/null 2>&1; [[ \$? -eq 1 ]]"
teardown

# ── 4. check-modus: fehlende USB-Datei wird als Drift erkannt ────────────────
setup
run_test_output "--check: fehlende USB-Datei als Drift erkannt" \
    "fedora-full.ks" \
    bash -c "bash '${SYNC}' --check 2>&1 || true"
teardown

# ── 4b. check-deploy: Drift wird automatisch deployed ────────────────────────
setup
echo "neue version" > "${FAKE_PROJECT}/kickstart/fedora-full.ks"
run_test "--check-deploy: Drift deployt automatisch" \
    bash -c "bash '${SYNC}' --check-deploy && diff -q '${FAKE_PROJECT}/kickstart/fedora-full.ks' '${FAKE_USB}/kickstart/fedora-full.ks'"
teardown

# ── 5. files-only-Modus: kopiert Dateien ─────────────────────────────────────
setup
echo "v2" > "${FAKE_PROJECT}/kickstart/fedora-full.ks"
bash "$SYNC" --files-only &>/dev/null || true
run_test "--files-only: Datei wurde auf USB kopiert" \
    bash -c "[[ -f '${FAKE_USB}/kickstart/fedora-full.ks' ]] && diff -q '${FAKE_PROJECT}/kickstart/fedora-full.ks' '${FAKE_USB}/kickstart/fedora-full.ks'"
teardown

# ── 6. files-only-Modus: veraltete Dateien werden entfernt ───────────────────
setup
# Obsolete Datei auf USB anlegen
mkdir -p "${FAKE_USB}/ventoy"
touch "${FAKE_USB}/ventoy/ventoy_grub.cfg"
bash "$SYNC" --files-only &>/dev/null || true
run_test "--files-only: obsolete Datei entfernt" \
    bash -c "[[ ! -f '${FAKE_USB}/ventoy/ventoy_grub.cfg' ]]"
teardown

# ── 7. files-only-Modus: fehlende Quelldatei wird übersprungen ───────────────
setup
rm "${FAKE_PROJECT}/scripts/vllm-router.py"
run_test_output "--files-only: fehlende Quelle wird übersprungen (warn, kein Abbruch)" \
    "übersprungen\|Quelle fehlt" \
    bash -c "bash '${SYNC}' --files-only 2>&1"
teardown

# ── 8. check-Modus: alle Dateien gleich → Exit 0 ────────────────────────────
setup
# Alle USB-Dateien synchron mit Projekt
for entry in \
    "fedora-provision.sh" \
    "kickstart/common-post.inc" \
    "kickstart/fedora-vm.ks" \
    "kickstart/fedora-full.ks" \
    "kickstart/fedora-headless-vllm.ks" \
    "kickstart/fedora-theme-bash.ks" \
    "scripts/first-boot.sh" \
    "scripts/first-login.sh" \
    "scripts/vllm-router.py" \
    "scripts/welcome-dialog.sh" \
    "scripts/fedora-provision.desktop" \
    "systemd/fedora-first-boot.service" \
    "systemd/vllm@.container" \
    "systemd/vllm-router.service" \
    "boot/grub.cfg"; do
    mkdir -p "${FAKE_USB}/$(dirname "$entry")"
    cp "${FAKE_PROJECT}/${entry}" "${FAKE_USB}/${entry}"
done
run_test "--check: alles synchron → Exit 0" \
    bash "$SYNC" --check
teardown

# ── 9. files-only-Modus: kein Überschreiben identischer Dateien (Smoke) ──────
setup
echo "gleichinhalt" > "${FAKE_PROJECT}/boot/grub.cfg"
echo "gleichinhalt" > "${FAKE_USB}/boot/grub.cfg"
out=$(bash "$SYNC" --files-only 2>&1 || true)
run_test "--files-only: identische Datei wird nicht als 'Kopiert' gemeldet" \
    bash -c "! echo '$out' | grep -q 'Kopiert: boot/grub.cfg'"
teardown

# ── 10. Syntax-Check ─────────────────────────────────────────────────────────
run_test "sync-usb.sh Bash-Syntax korrekt" \
    bash -n "$SYNC_USB"

# ── Ergebnis ──────────────────────────────────────────────────────────────────
echo ""
echo "Ran $((PASS + FAIL)) tests: ${PASS} ok, ${FAIL} failed"
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "Fehlgeschlagen:"
    for e in "${ERRORS[@]}"; do echo "  - $e"; done
    echo ""
    exit 1
fi
echo ""
exit 0
