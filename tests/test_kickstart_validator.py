import shutil
import subprocess
import unittest
from pathlib import Path
from typing import cast


PROJECT = Path(__file__).parent.parent
KICKSTART_DIR = PROJECT / "kickstart"
KSVALIDATOR = shutil.which("ksvalidator")


@unittest.skipUnless(KSVALIDATOR, "ksvalidator nicht gefunden (dnf install pykickstart)")
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
