import shutil
import subprocess
import unittest
from pathlib import Path
from typing import cast


PROJECT = Path(__file__).parent.parent
KICKSTART_DIR = PROJECT / "kickstart"


def _find_ksvalidator() -> str | None:
    """Find ksvalidator from PATH or common pipx locations."""
    found = shutil.which("ksvalidator")
    if found:
        return found

    # pipx often installs CLI tools to ~/.local/bin, which may not be in PATH
    # for non-login shells (e.g. some test runners in editors/CI).
    fallback = Path.home() / ".local" / "bin" / "ksvalidator"
    if fallback.is_file():
        return str(fallback)

    return None


KSVALIDATOR = _find_ksvalidator()


@unittest.skipUnless(KSVALIDATOR, "ksvalidator nicht gefunden (installiere pykickstart, z.B. per pipx)")
class KickstartValidatorTests(unittest.TestCase):
    """Validiert statische Kickstart-Profile mit dem externen ksvalidator-Tool."""

    def _validate(self, filename: str) -> None:
        proc = subprocess.run(
            [cast(str, KSVALIDATOR), filename],
            cwd=KICKSTART_DIR,
            text=True,
            capture_output=True,
            check=False,
        )
        msg = (
            f"ksvalidator fehlgeschlagen für {filename}\n"
            f"exit={proc.returncode}\n"
            f"stdout:\n{proc.stdout}\n"
            f"stderr:\n{proc.stderr}"
        )
        self.assertEqual(proc.returncode, 0, msg)

    def test_profiles_validate_cleanly(self):
        for ks in ("fedora-full.ks", "fedora-vm.ks", "fedora-theme-bash.ks", "fedora-headless-vllm.ks"):
            with self.subTest(kickstart=ks):
                self._validate(ks)


if __name__ == "__main__":
    unittest.main()
