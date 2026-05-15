#!/usr/bin/env bash
# tests/test_systemd_units.sh - Validiert systemd/ Unit-Dateien im Repository.
#
# Usage:
#   bash tests/test_systemd_units.sh
#   bash tests/test_systemd_units.sh -v

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SYSTEMD_DIR="${PROJECT_DIR}/systemd"

VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

PASS=0
FAIL=0
SKIP=0
ERRORS=()

run_test() {
    local name="$1"
    shift
    if "$@" &>/dev/null; then
        PASS=$((PASS + 1))
        if [[ $VERBOSE -eq 1 ]]; then
            echo "  ok    $name"
        fi
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("$name")
        echo "  FAIL  $name"
    fi
}

skip_test() {
    local name="$1"
    SKIP=$((SKIP + 1))
    if [[ $VERBOSE -eq 1 ]]; then
        echo "  skip  $name"
    fi
}

echo ""
echo "== test_systemd_units.sh =="
echo ""

FIRST_BOOT="${SYSTEMD_DIR}/fedora-first-boot.service"
ROUTER="${SYSTEMD_DIR}/vllm-router.service"
QUADLET="${SYSTEMD_DIR}/vllm@.container"

run_test "fedora-first-boot.service existiert" test -f "$FIRST_BOOT"
run_test "vllm-router.service existiert" test -f "$ROUTER"
run_test "vllm@.container existiert" test -f "$QUADLET"

run_test "fedora-first-boot.service nicht leer" bash -c "[[ -s '$FIRST_BOOT' ]]"
run_test "vllm-router.service nicht leer" bash -c "[[ -s '$ROUTER' ]]"
run_test "vllm@.container nicht leer" bash -c "[[ -s '$QUADLET' ]]"

run_test "fedora-first-boot.service hat [Unit]" grep -q '^\[Unit\]' "$FIRST_BOOT"
run_test "fedora-first-boot.service hat [Service]" grep -q '^\[Service\]' "$FIRST_BOOT"
run_test "fedora-first-boot.service hat [Install]" grep -q '^\[Install\]' "$FIRST_BOOT"
run_test "fedora-first-boot.service aktiviert multi-user.target" grep -q '^WantedBy=multi-user.target$' "$FIRST_BOOT"
run_test "fedora-first-boot.service hat ExecStart" grep -q '^ExecStart=/usr/local/sbin/fedora-first-boot.sh$' "$FIRST_BOOT"
run_test "fedora-first-boot.service hat Marker-Guard" grep -q '^ConditionPathExists=!/var/lib/fedora-provision/first-boot.done$' "$FIRST_BOOT"

run_test "vllm-router.service hat [Unit]" grep -q '^\[Unit\]' "$ROUTER"
run_test "vllm-router.service hat [Service]" grep -q '^\[Service\]' "$ROUTER"
run_test "vllm-router.service hat [Install]" grep -q '^\[Install\]' "$ROUTER"
run_test "vllm-router.service aktiviert default.target" grep -q '^WantedBy=default.target$' "$ROUTER"
run_test "vllm-router.service hat ExecStart" grep -q '^ExecStart=%h/.local/bin/vllm-router$' "$ROUTER"
run_test "vllm-router.service hat Restart" grep -q '^Restart=on-failure$' "$ROUTER"

run_test "vllm@.container hat [Unit]" grep -q '^\[Unit\]' "$QUADLET"
run_test "vllm@.container hat [Container]" grep -q '^\[Container\]' "$QUADLET"
run_test "vllm@.container hat [Service]" grep -q '^\[Service\]' "$QUADLET"
run_test "vllm@.container hat [Install]" grep -q '^\[Install\]' "$QUADLET"
run_test "vllm@.container hat Image" grep -q '^Image=localhost/fedora-vllm:latest$' "$QUADLET"
run_test "vllm@.container hat EnvironmentFile" grep -q '^EnvironmentFile=%h/.config/vllm-router/instances/%i.env$' "$QUADLET"
run_test "vllm@.container aktiviert default.target" grep -q '^WantedBy=default.target$' "$QUADLET"

if command -v systemd-analyze >/dev/null 2>&1; then
    if [[ -x /usr/local/sbin/fedora-first-boot.sh ]]; then
        run_test "systemd-analyze verify: fedora-first-boot.service" \
            systemd-analyze verify "$FIRST_BOOT"
    else
        skip_test "systemd-analyze verify: fedora-first-boot.service (ExecStart fehlt lokal)"
    fi

    if [[ -x "${HOME}/.local/bin/vllm-router" ]]; then
        run_test "systemd-analyze verify: vllm-router.service" \
            systemd-analyze verify "$ROUTER"
    else
        skip_test "systemd-analyze verify: vllm-router.service (ExecStart fehlt lokal)"
    fi
else
    skip_test "systemd-analyze verify: fedora-first-boot.service"
    skip_test "systemd-analyze verify: vllm-router.service"
fi

echo ""
echo "Ran $((PASS + FAIL + SKIP)) tests: ${PASS} ok, ${FAIL} failed, ${SKIP} skipped"
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "Fehlgeschlagen:"
    for e in "${ERRORS[@]}"; do
        echo "  - $e"
    done
    echo ""
    exit 1
fi

echo ""
exit 0
