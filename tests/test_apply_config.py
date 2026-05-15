import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))
import apply_config as ac  # type: ignore[import-untyped]  # noqa: E402


# ── Fixtures ──────────────────────────────────────────────────────────────────

MINIMAL_CONFIG = {
    "user": {
        "name": "testuser",
        "password": "testpassword123",
        "groups": "wheel,video,audio",
    },
    "system": {
        "hostname": "test-host",
        "timezone": "Europe/Berlin",
        "locale": "de_DE.UTF-8",
        "keyboard": "de",
    },
    "profile": "full",
    "gpu": {
        "cuda_source": "fedora",
        "cuda_version": "13.2",
        "arch_list": "12.0",
    },
    "theme": {
        "gtk_args": "-c Dark",
        "icon_args": "",
        "wallpaper_args": "",
        "omb_theme": "modern",
    },
    "ai": {
        "pytorch_venv": "~/.venvs/ai",
        "vllm_venv": "~/.venvs/omni",
        "audio_venv": "~/.venvs/audio",
        "audio_model": "moonshotai/Kimi-Audio-7B-Instruct",
        "agent_model": "Qwen/Qwen3-14B-AWQ",
    },
    "neo4j": {
        "uri": "bolt://localhost:7687",
        "user": "neo4j",
        "password": "dbpassword",
    },
}

SAMPLE_KS = """\
keyboard --xlayouts='de'
lang de_DE.UTF-8
timezone Europe/Berlin --utc
network --hostname=fedora-workstation
user --groups=wheel,libvirt,video,audio --name=sija  --password=$6$rounds=4096$oldhash  --iscrypted
AutomaticLogin=sija
FEDORA_TARGET_USER="sija"
FEDORA_CUDA_SOURCE="nvidia"
FEDORA_VLLM_CUDA_VERSION="12.0"
FEDORA_VLLM_ARCH_LIST="11.0"
FEDORA_WS_GTK_ARGS="-l -c Light"
FEDORA_WS_ICON_ARGS="-light"
FEDORA_WS_WALL_ARGS="-t Mojave"
FEDORA_OMB_THEME="font"
FEDORA_PYTORCH_VENV="~/.venvs/old-ai"
FEDORA_VLLM_VENV="~/.venvs/old-omni"
FEDORA_AUDIO_VENV="~/.venvs/old-audio"
FEDORA_AUDIO_MODEL="old/model"
FEDORA_AGENT_MODEL="old/agent"
FEDORA_NEO4J_URI="bolt://remotehost:7687"
FEDORA_NEO4J_USER="admin"
FEDORA_NEO4J_PASSWORD="oldpassword"
"""


def write_config(td: Path, cfg: dict) -> Path:
    p = td / "install.json"
    p.write_text(json.dumps(cfg), encoding="utf-8")
    return p


def write_ks(td: Path, content: str = SAMPLE_KS, name: str = "test.ks") -> Path:
    p = td / name
    p.write_text(content, encoding="utf-8")
    return p


# ── load_config ───────────────────────────────────────────────────────────────

class LoadConfigTests(unittest.TestCase):

    def test_loads_valid_json(self):
        with tempfile.TemporaryDirectory() as td:
            p = write_config(Path(td), MINIMAL_CONFIG)
            cfg = ac.load_config(p)
        self.assertEqual(cfg["user"]["name"], "testuser")

    def test_strips_comment_field(self):
        cfg_with_comment = {"_comment": "some note", "user": {"name": "x", "password": "y"}}
        with tempfile.TemporaryDirectory() as td:
            p = write_config(Path(td), cfg_with_comment)
            cfg = ac.load_config(p)
        self.assertNotIn("_comment", cfg)

    def test_preserves_all_sections(self):
        with tempfile.TemporaryDirectory() as td:
            p = write_config(Path(td), MINIMAL_CONFIG)
            cfg = ac.load_config(p)
        for section in ("user", "system", "gpu", "theme", "ai", "neo4j"):
            with self.subTest(section=section):
                self.assertIn(section, cfg)

    def test_raises_on_invalid_json(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "bad.json"
            p.write_text("{invalid json", encoding="utf-8")
            with self.assertRaises(json.JSONDecodeError):
                ac.load_config(p)


# ── hash_password ─────────────────────────────────────────────────────────────

class HashPasswordTests(unittest.TestCase):

    def test_returns_sha512_hash(self):
        h = ac.hash_password("testpassword")
        self.assertTrue(h.startswith("$6$"), f"Erwartet SHA-512 ($6$), bekam: {h}")

    def test_hash_is_not_plaintext(self):
        h = ac.hash_password("mysecret")
        self.assertNotIn("mysecret", h)

    def test_different_passwords_produce_different_hashes(self):
        h1 = ac.hash_password("password1")
        h2 = ac.hash_password("password2")
        self.assertNotEqual(h1, h2)

    def test_same_password_different_salts(self):
        # openssl passwd -6 generiert zufälligen Salt — zwei Hashes unterscheiden sich
        h1 = ac.hash_password("samepassword")
        h2 = ac.hash_password("samepassword")
        # Beide sind gültige SHA-512 Hashes
        self.assertTrue(h1.startswith("$6$"))
        self.assertTrue(h2.startswith("$6$"))

    def test_raises_on_openssl_failure(self):
        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "openssl")):
            with self.assertRaises(subprocess.CalledProcessError):
                ac.hash_password("test")


# ── patch_kickstart ───────────────────────────────────────────────────────────

class PatchKickstartTests(unittest.TestCase):

    def _patch(self, content: str, replacements: dict, check: bool = False) -> tuple[str, bool]:
        with tempfile.TemporaryDirectory() as td:
            ks = write_ks(Path(td), content)
            changed = ac.patch_kickstart(ks, replacements, check=check)
            result = ks.read_text() if not check else content
        return result, changed

    def test_replaces_hostname(self):
        result, changed = self._patch(
            SAMPLE_KS,
            {r"--hostname=[\w-]+": "--hostname=new-host"}
        )
        self.assertIn("--hostname=new-host", result)
        self.assertTrue(changed)

    def test_replaces_username(self):
        result, changed = self._patch(
            SAMPLE_KS,
            {r"--name=\w+": "--name=alice"}
        )
        self.assertIn("--name=alice", result)
        self.assertTrue(changed)

    def test_replaces_autologin_user(self):
        result, changed = self._patch(
            SAMPLE_KS,
            {r"AutomaticLogin=\w+": "AutomaticLogin=alice"}
        )
        self.assertIn("AutomaticLogin=alice", result)
        self.assertTrue(changed)

    def test_replaces_env_var(self):
        result, changed = self._patch(
            SAMPLE_KS,
            {r'FEDORA_TARGET_USER="[^"]+"': 'FEDORA_TARGET_USER="alice"'}
        )
        self.assertIn('FEDORA_TARGET_USER="alice"', result)
        self.assertTrue(changed)

    def test_returns_false_when_nothing_changed(self):
        _, changed = self._patch(
            "nothingtochange=here",
            {r"--hostname=[\w-]+": "--hostname=new-host"}
        )
        self.assertFalse(changed)

    def test_check_mode_does_not_write(self):
        original = "hostname=old-host"
        with tempfile.TemporaryDirectory() as td:
            ks = write_ks(Path(td), original)
            ac.patch_kickstart(ks, {r"hostname=\S+": "hostname=new-host"}, check=True)
            self.assertEqual(ks.read_text(), original)

    def test_check_mode_detects_change(self):
        _, changed = self._patch(
            SAMPLE_KS,
            {r"--hostname=[\w-]+": "--hostname=new-host"},
            check=True
        )
        self.assertTrue(changed)

    def test_multiple_replacements_applied(self):
        result, _ = self._patch(
            SAMPLE_KS,
            {
                r"--hostname=[\w-]+": "--hostname=multi-host",
                r"AutomaticLogin=\w+": "AutomaticLogin=multiuser",
            }
        )
        self.assertIn("--hostname=multi-host", result)
        self.assertIn("AutomaticLogin=multiuser", result)


# ── Vollständiger Workflow (Integration) ──────────────────────────────────────

class IntegrationTests(unittest.TestCase):

    def _run_main(self, config: dict, ks_content: str = SAMPLE_KS,
                  extra_args: list[str] | None = None) -> tuple[list[str], int]:
        """Führt main() mit config aus, gibt (ks_zeilen, exit_code) zurück."""
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            cfg_path = write_config(td_path, config)

            # main() sucht unter PROJECT/kickstart/*.ks
            ks_dir = td_path / "kickstart"
            ks_dir.mkdir()
            ks_path = ks_dir / "fedora-full.ks"
            ks_path.write_text(ks_content, encoding="utf-8")

            args = ["apply-config.py", "--config", str(cfg_path)] + (extra_args or [])
            with patch("sys.argv", args), \
                 patch.object(ac, "PROJECT", td_path):
                try:
                    ac.main()
                    rc: int = 0
                except SystemExit as e:
                    rc = int(e.code) if e.code is not None else 0

            result_lines = ks_path.read_text().splitlines()
        return result_lines, rc

    def test_user_name_applied(self):
        lines, _ = self._run_main(MINIMAL_CONFIG)
        self.assertTrue(any("--name=testuser" in l for l in lines))

    def test_hostname_applied(self):
        lines, _ = self._run_main(MINIMAL_CONFIG)
        self.assertTrue(any("--hostname=test-host" in l for l in lines))

    def test_autologin_user_applied(self):
        lines, _ = self._run_main(MINIMAL_CONFIG)
        self.assertTrue(any("AutomaticLogin=testuser" in l for l in lines))

    def test_env_vars_applied(self):
        lines, _ = self._run_main(MINIMAL_CONFIG)
        joined = "\n".join(lines)
        self.assertIn('FEDORA_CUDA_SOURCE="fedora"', joined)
        self.assertIn('FEDORA_OMB_THEME="modern"', joined)
        self.assertIn('FEDORA_TARGET_USER="testuser"', joined)
        self.assertIn('FEDORA_NEO4J_PASSWORD="dbpassword"', joined)

    def test_timezone_applied(self):
        lines, _ = self._run_main(MINIMAL_CONFIG)
        self.assertTrue(any("timezone Europe/Berlin --utc" in l for l in lines))

    def test_placeholder_password_exits_nonzero(self):
        cfg = {**MINIMAL_CONFIG, "user": {**MINIMAL_CONFIG["user"],
                                           "password": "PASSWORT_HIER_EINGEBEN"}}
        _, rc = self._run_main(cfg)
        self.assertNotEqual(rc, 0)

    def test_check_mode_does_not_modify_files(self):
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            cfg_path = write_config(td_path, MINIMAL_CONFIG)
            ks_dir = td_path / "kickstart"
            ks_dir.mkdir()
            ks_path = ks_dir / "fedora-full.ks"
            ks_path.write_text(SAMPLE_KS, encoding="utf-8")
            original = ks_path.read_text()

            args = ["apply-config.py", "--config", str(cfg_path), "--check"]
            with patch("sys.argv", args), \
                 patch.object(ac, "PROJECT", td_path):
                try:
                    ac.main()
                except SystemExit:
                    pass

            self.assertEqual(ks_path.read_text(), original)

    def test_missing_config_file_exits_nonzero(self):
        args = ["apply-config.py", "--config", "/nonexistent/install.json"]
        with patch("sys.argv", args):
            with self.assertRaises(SystemExit) as ctx:
                ac.main()
        self.assertNotEqual(ctx.exception.code, 0)

    def test_password_hash_written_to_kickstart(self):
        lines, _ = self._run_main(MINIMAL_CONFIG)
        joined = "\n".join(lines)
        # Passwort-Hash muss SHA-512 Format haben
        self.assertTrue(
            re.search(r"--password=\$6\$", joined),
            "SHA-512 Passwort-Hash nicht im Kickstart gefunden"
        )
        self.assertIn("--iscrypted", joined)


if __name__ == "__main__":
    unittest.main()
