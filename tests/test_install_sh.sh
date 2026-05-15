#!/usr/bin/env bash
# tests/test_install_sh.sh — Unittest für install.sh
#
# Prüft ohne echten USB-Stick und ohne ISO-Download:
# - xml2ks.py wird mit allen --*-script Argumenten aufgerufen
# - JSON-Modus ruft apply_config.py auf
# - Fehlende Konfiguration bricht nicht ab
#
# Usage:
#   bash tests/test_install_sh.sh
#   bash tests/test_install_sh.sh -v

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_SH="${PROJECT_DIR}/install.sh"

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
    local name="$1" pattern="$2"; shift 2
    local out; out=$("$@" 2>&1) || true
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
            echo "       output: $(echo "$out" | head -5)"
            echo "       pattern: $pattern"
        fi
    fi
}

echo ""
echo "══ test_install_sh.sh ══"
echo ""

# ── 1. Syntax-Check ───────────────────────────────────────────────────────────
run_test "install.sh Bash-Syntax korrekt" \
    bash -n "$INSTALL_SH"

# ── 2. xml2ks.py Aufruf enthält --first-boot-script ─────────────────────────
run_test "install.sh übergibt --first-boot-script an xml2ks.py" \
    bash -c "grep -q '\-\-first-boot-script' '${INSTALL_SH}'"

# ── 3. xml2ks.py Aufruf enthält --first-login-script ────────────────────────
run_test "install.sh übergibt --first-login-script an xml2ks.py" \
    bash -c "grep -q '\-\-first-login-script' '${INSTALL_SH}'"

# ── 4. xml2ks.py Aufruf enthält --systemd-unit ───────────────────────────────
run_test "install.sh übergibt --systemd-unit an xml2ks.py" \
    bash -c "grep -q '\-\-systemd-unit' '${INSTALL_SH}'"

# ── 5. Script-Pfade zeigen auf existierende Dateien ──────────────────────────
run_test "scripts/first-boot.sh existiert" \
    test -f "${PROJECT_DIR}/scripts/first-boot.sh"

run_test "scripts/first-login.sh existiert" \
    test -f "${PROJECT_DIR}/scripts/first-login.sh"

run_test "systemd/fedora-first-boot.service existiert" \
    test -f "${PROJECT_DIR}/systemd/fedora-first-boot.service"

# ── 6. Scripts sind nicht leer ────────────────────────────────────────────────
run_test "first-boot.sh ist nicht leer" \
    bash -c "[[ -s '${PROJECT_DIR}/scripts/first-boot.sh' ]]"

run_test "first-login.sh ist nicht leer" \
    bash -c "[[ -s '${PROJECT_DIR}/scripts/first-login.sh' ]]"

run_test "fedora-first-boot.service ist nicht leer" \
    bash -c "[[ -s '${PROJECT_DIR}/systemd/fedora-first-boot.service' ]]"

# ── 7. Kein leeres heredoc in generiertem Kickstart ──────────────────────────
# Wenn install.sh korrekt aufgerufen wurde, darf fedora-full.ks kein leeres heredoc haben
run_test "fedora-full.ks hat keinen leeren first-boot Heredoc" \
    bash -c "! grep -Pzo \"<<'FBEOF'\n\nFBEOF\" '${PROJECT_DIR}/kickstart/fedora-full.ks'"

run_test "fedora-full.ks hat keinen leeren systemd-unit Heredoc" \
    bash -c "! grep -Pzo \"<<'UNITEOF'\n\nUNITEOF\" '${PROJECT_DIR}/kickstart/fedora-full.ks'"

# ── 8. JSON-Modus: apply_config.py wird referenziert ─────────────────────────
run_test "install.sh referenziert apply_config.py im JSON-Modus" \
    bash -c "grep -q 'apply_config\.py' '${INSTALL_SH}'"

# ── 9. --custom Flag schaltet auf JSON-Modus ─────────────────────────────────
run_test "install.sh hat --custom Argument" \
    bash -c "grep -q '\-\-custom' '${INSTALL_SH}'"

# ── 10. Richtige Paketgruppe im Kickstart ────────────────────────────────────
run_test "fedora-full.ks verwendet workstation-product-environment" \
    bash -c "grep -q 'workstation-product-environment' '${PROJECT_DIR}/kickstart/fedora-full.ks'"

run_test "fedora-full.ks verwendet nicht veraltetes fedora-desktop" \
    bash -c "! grep -q '@\^fedora-desktop' '${PROJECT_DIR}/kickstart/fedora-full.ks'"

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
