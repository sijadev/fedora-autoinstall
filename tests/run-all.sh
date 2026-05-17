#!/usr/bin/env bash
# tests/run-all.sh - Standard-Testlauf fur das Repository.
#
# Usage:
#   bash tests/run-all.sh
#   bash tests/run-all.sh -v
#   bash tests/run-all.sh --full

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

VERBOSE=0
FULL=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		-v|--verbose)
			VERBOSE=1
			shift
			;;
		--full)
			FULL=1
			shift
			;;
		-h|--help)
			echo "Usage: bash tests/run-all.sh [-v|--verbose] [--full]"
			exit 0
			;;
		*)
			echo "Unbekanntes Argument: $1" >&2
			exit 2
			;;
	esac
done

vflag=()
[[ $VERBOSE -eq 1 ]] && vflag=(-v)

cd "$PROJECT_DIR"

echo ""
echo "== Standard-Testlauf =="
echo ""

echo "[1/5] Shell: install.sh"
bash tests/test_install_sh.sh "${vflag[@]+"${vflag[@]}"}"

echo "[2/5] Shell: sync-usb.sh"
bash tests/test_sync_usb.sh "${vflag[@]+"${vflag[@]}"}"

echo "[3/5] Shell: systemd units"
bash tests/test_systemd_units.sh "${vflag[@]+"${vflag[@]}"}"

if [[ $FULL -eq 1 ]]; then
	echo "[4/5] Python: apply_config + xml2ks"
	python3 -m unittest -v tests.test_apply_config tests.test_xml2ks

	echo "[5/5] Python: kickstart validator"
	python3 -m unittest -v tests.test_kickstart_validator
else
	echo "[4/5] Python: ubersprungen (nutze --full)"
	echo "[5/5] Validator: ubersprungen (nutze --full)"
fi

echo ""
echo "Alle Testgruppen erfolgreich."
echo ""
