import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from io import StringIO
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
import xml2ks  # noqa: E402  # type: ignore


# ── Fixtures ──────────────────────────────────────────────────────────────────

def parse_xml(text: str) -> ET.Element:
    return ET.fromstring(text)


MINIMAL_VALID_XML = """
<fedora-install>
  <iso><url>https://example.com/fedora.iso</url></iso>
  <disk>/dev/sda</disk>
  <hostname>fedora-test</hostname>
  <timezone>Europe/Berlin</timezone>
  <locale>de_DE.UTF-8</locale>
  <keyboard>de</keyboard>
  <user>
    <name>sija</name>
    <password_hash>$6$salt$hashvalue</password_hash>
  </user>
</fedora-install>
"""


def minimal_root(**overrides) -> ET.Element:
    """Return a minimal valid root with optional field overrides (xpath → text)."""
    root = parse_xml(MINIMAL_VALID_XML)
    for xpath, value in overrides.items():
        el = root.find(xpath)
        if el is None:
            raise ValueError(f"xpath not found: {xpath}")
        el.text = value
    return root


# ── Helper function tests ─────────────────────────────────────────────────────

class GetHelperTests(unittest.TestCase):
    def setUp(self):
        self.root = parse_xml("""
            <root>
              <a>hello</a>
              <b>  spaced  </b>
              <c></c>
            </root>
        """)

    def test_get_existing(self):
        self.assertEqual(xml2ks._get(self.root, "a"), "hello")

    def test_get_strips_whitespace(self):
        self.assertEqual(xml2ks._get(self.root, "b"), "spaced")

    def test_get_empty_element_returns_empty_string(self):
        # _get() returns "" for an element with no text, regardless of default;
        # the default is only used when the element is absent entirely.
        self.assertEqual(xml2ks._get(self.root, "c", "fallback"), "")

    def test_get_missing_element_returns_default(self):
        self.assertEqual(xml2ks._get(self.root, "missing", "default"), "default")

    def test_get_missing_element_returns_empty_string_by_default(self):
        self.assertEqual(xml2ks._get(self.root, "missing"), "")


class AttrHelperTests(unittest.TestCase):
    def test_attr_existing(self):
        el = ET.fromstring('<tag foo="bar"/>')
        self.assertEqual(xml2ks._attr(el, "foo"), "bar")

    def test_attr_missing_returns_default(self):
        el = ET.fromstring('<tag/>')
        self.assertEqual(xml2ks._attr(el, "missing", "default"), "default")

    def test_attr_none_element_returns_default(self):
        self.assertEqual(xml2ks._attr(None, "foo", "fallback"), "fallback")


class EnabledHelperTests(unittest.TestCase):
    def setUp(self):
        self.root = parse_xml("""
            <root>
              <a enabled="true"/>
              <b enabled="false"/>
              <c enabled="0"/>
              <d enabled="no"/>
              <e/>
            </root>
        """)

    def test_true_enabled(self):
        self.assertTrue(xml2ks._enabled(self.root, "a"))

    def test_false_enabled(self):
        self.assertFalse(xml2ks._enabled(self.root, "b"))

    def test_zero_disabled(self):
        self.assertFalse(xml2ks._enabled(self.root, "c"))

    def test_no_disabled(self):
        self.assertFalse(xml2ks._enabled(self.root, "d"))

    def test_missing_attr_defaults_to_true(self):
        self.assertTrue(xml2ks._enabled(self.root, "e"))

    def test_missing_element_uses_default(self):
        self.assertFalse(xml2ks._enabled(self.root, "missing", default=False))


# ── Validation tests ──────────────────────────────────────────────────────────

class ValidateTests(unittest.TestCase):

    # ── Disk ──────────────────────────────────────────────────────────────────

    def test_accepts_sda_disk(self):
        self.assertEqual(xml2ks.validate(minimal_root(), Path("x.xml")), [])

    def test_accepts_nvme_disk(self):
        root = minimal_root(**{"disk": "/dev/nvme0n1"})
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])

    def test_accepts_vda_disk(self):
        root = minimal_root(**{"disk": "/dev/vda"})
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])

    def test_accepts_xvda_disk(self):
        root = minimal_root(**{"disk": "/dev/xvda"})
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])

    def test_accepts_mmcblk_disk(self):
        root = minimal_root(**{"disk": "/dev/mmcblk0"})
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])

    def test_rejects_partition_not_whole_disk(self):
        root = minimal_root(**{"disk": "/dev/sda1"})
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(any("must be one of" in e for e in errors))

    def test_rejects_cdrom_device(self):
        root = minimal_root(**{"disk": "/dev/sr0"})
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(any("CD/DVD" in e or "sr0" in e for e in errors))

    def test_rejects_cdrom_device_alias(self):
        root = minimal_root(**{"disk": "/dev/cdrom"})
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(any("CD/DVD" in e or "cdrom" in e for e in errors))

    # ── Hostname ──────────────────────────────────────────────────────────────

    def test_accepts_valid_hostname(self):
        root = minimal_root(**{"hostname": "my-host-01"})
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])

    def test_rejects_hostname_with_underscore(self):
        root = minimal_root(**{"hostname": "bad_host"})
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(any("hostname" in e.lower() for e in errors))

    def test_rejects_hostname_starting_with_dash(self):
        root = minimal_root(**{"hostname": "-badhost"})
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(any("hostname" in e.lower() for e in errors))

    # ── ISO URL ───────────────────────────────────────────────────────────────

    def test_accepts_https_iso_url(self):
        self.assertEqual(xml2ks.validate(minimal_root(), Path("x.xml")), [])

    def test_accepts_http_iso_url(self):
        root = minimal_root(**{"iso/url": "http://mirror.example.com/fedora.iso"})
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])

    def test_rejects_ftp_iso_url(self):
        root = minimal_root(**{"iso/url": "ftp://example.com/fedora.iso"})
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(any("iso/url" in e.lower() for e in errors))

    def test_rejects_relative_iso_url(self):
        root = minimal_root(**{"iso/url": "fedora.iso"})
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(any("iso/url" in e.lower() for e in errors))

    # ── Password hash ─────────────────────────────────────────────────────────

    def test_accepts_sha512_hash(self):
        self.assertEqual(xml2ks.validate(minimal_root(), Path("x.xml")), [])

    def test_accepts_sha256_hash(self):
        root = minimal_root(**{"user/password_hash": "$5$salt$hashvalue"})
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])

    def test_accepts_md5_hash(self):
        root = minimal_root(**{"user/password_hash": "$1$salt$hashvalue"})
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])

    def test_rejects_plaintext_password(self):
        root = minimal_root(**{"user/password_hash": "mysecretpassword"})
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(any("crypt hash" in e or "$1$" in e or "$6$" in e for e in errors))

    def test_rejects_placeholder_password_hash(self):
        root = minimal_root(**{"user/password_hash": "$6$REPLACE_ME"})
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(any("placeholder" in e.lower() for e in errors))

    # ── Required fields ───────────────────────────────────────────────────────

    def test_rejects_missing_hostname(self):
        root = minimal_root(**{"hostname": ""})
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(any("hostname" in e.lower() for e in errors))

    def test_rejects_missing_timezone(self):
        root = minimal_root(**{"timezone": ""})
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(any("timezone" in e.lower() for e in errors))

    def test_rejects_missing_locale(self):
        root = minimal_root(**{"locale": ""})
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(any("locale" in e.lower() for e in errors))

    def test_rejects_replace_placeholder_in_any_field(self):
        root = minimal_root(**{"hostname": "REPLACE_HOSTNAME"})
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(len(errors) > 0)

    # ── Partitioning ──────────────────────────────────────────────────────────

    def test_custom_partition_requires_kickstart_extra(self):
        root = parse_xml("""
            <fedora-install>
              <iso><url>https://example.com/fedora.iso</url></iso>
              <disk>/dev/sda</disk>
              <partitioning><scheme>custom</scheme></partitioning>
              <hostname>fedora-test</hostname>
              <timezone>Europe/Berlin</timezone>
              <locale>de_DE.UTF-8</locale>
              <keyboard>de</keyboard>
              <user>
                <name>sija</name>
                <password_hash>$6$salt$hashvalue</password_hash>
              </user>
            </fedora-install>
        """)
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(any("kickstart_extra" in e for e in errors))

    def test_accepts_custom_partition_with_kickstart_extra(self):
        root = parse_xml("""
            <fedora-install>
              <iso><url>https://example.com/fedora.iso</url></iso>
              <disk>/dev/vda</disk>
              <partitioning>
                <scheme>custom</scheme>
                <kickstart_extra>ignoredisk --only-use=vda</kickstart_extra>
              </partitioning>
              <hostname>fedora-test</hostname>
              <timezone>Europe/Berlin</timezone>
              <locale>de_DE.UTF-8</locale>
              <keyboard>de</keyboard>
              <user>
                <name>sija</name>
                <password_hash>$6$salt$hashvalue</password_hash>
              </user>
            </fedora-install>
        """)
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])

    def test_rejects_invalid_partition_scheme(self):
        root = parse_xml("""
            <fedora-install>
              <iso><url>https://example.com/fedora.iso</url></iso>
              <disk>/dev/sda</disk>
              <partitioning><scheme>btrfs</scheme></partitioning>
              <hostname>fedora-test</hostname>
              <timezone>Europe/Berlin</timezone>
              <locale>de_DE.UTF-8</locale>
              <keyboard>de</keyboard>
              <user>
                <name>sija</name>
                <password_hash>$6$salt$hashvalue</password_hash>
              </user>
            </fedora-install>
        """)
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(any("scheme" in e for e in errors))

    # ── vLLM CUDA version ─────────────────────────────────────────────────────

    def test_rejects_invalid_cuda_version_format(self):
        root = parse_xml("""
            <fedora-install>
              <iso><url>https://example.com/fedora.iso</url></iso>
              <disk>/dev/sda</disk>
              <hostname>fedora-test</hostname>
              <timezone>Europe/Berlin</timezone>
              <locale>de_DE.UTF-8</locale>
              <keyboard>de</keyboard>
              <user>
                <name>sija</name>
                <password_hash>$6$salt$hashvalue</password_hash>
              </user>
              <first-login>
                <vllm-omni><cuda-version>13</cuda-version></vllm-omni>
              </first-login>
            </fedora-install>
        """)
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(any("cuda-version" in e.lower() for e in errors))

    def test_accepts_valid_cuda_version(self):
        root = parse_xml("""
            <fedora-install>
              <iso><url>https://example.com/fedora.iso</url></iso>
              <disk>/dev/sda</disk>
              <hostname>fedora-test</hostname>
              <timezone>Europe/Berlin</timezone>
              <locale>de_DE.UTF-8</locale>
              <keyboard>de</keyboard>
              <user>
                <name>sija</name>
                <password_hash>$6$salt$hashvalue</password_hash>
              </user>
              <first-login>
                <vllm-omni><cuda-version>13.2</cuda-version></vllm-omni>
              </first-login>
            </fedora-install>
        """)
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])


# ── Kickstart generation tests ────────────────────────────────────────────────

class GenerateKickstartTests(unittest.TestCase):
    """Tests for generate_kickstart(). Uses minimal valid XML as baseline."""

    def _ks(self, xml_text=None, **script_kwargs) -> str:
        root = parse_xml(xml_text) if xml_text else parse_xml(MINIMAL_VALID_XML)
        return xml2ks.generate_kickstart(root, **script_kwargs)

    # ── Structure ─────────────────────────────────────────────────────────────

    def test_contains_version_header(self):
        self.assertIn("#version=RHEL9", self._ks())

    def test_contains_text_and_reboot(self):
        ks = self._ks()
        self.assertIn("text\n", ks)
        self.assertIn("reboot\n", ks)

    def test_contains_packages_block(self):
        ks = self._ks()
        self.assertIn("%packages\n", ks)
        self.assertIn("%end\n", ks)

    def test_contains_post_block(self):
        self.assertIn("%post", self._ks())

    def test_contains_kdump_addon(self):
        self.assertIn("com_redhat_kdump --disable", self._ks())

    # ── Locale / Keyboard / Timezone ─────────────────────────────────────────

    def test_locale_in_output(self):
        self.assertIn("lang de_DE.UTF-8", self._ks())

    def test_keyboard_in_output(self):
        self.assertIn("keyboard --xlayouts='de'", self._ks())

    def test_timezone_in_output(self):
        self.assertIn("timezone Europe/Berlin --utc", self._ks())

    def test_hostname_in_network_directive(self):
        self.assertIn("network --hostname=fedora-test", self._ks())

    # ── User / Auth ───────────────────────────────────────────────────────────

    def test_rootpw_locked(self):
        self.assertIn("rootpw --lock", self._ks())

    def test_user_name_in_output(self):
        self.assertIn("--name=sija", self._ks())

    def test_user_password_hash_in_output(self):
        self.assertIn("--password=$6$salt$hashvalue", self._ks())

    def test_user_iscrypted(self):
        self.assertIn("--iscrypted", self._ks())

    def test_custom_user_groups(self):
        root = parse_xml("""
            <fedora-install>
              <iso><url>https://example.com/fedora.iso</url></iso>
              <disk>/dev/sda</disk>
              <hostname>h</hostname>
              <timezone>UTC</timezone>
              <locale>en_US.UTF-8</locale>
              <keyboard>us</keyboard>
              <user>
                <name>alice</name>
                <password_hash>$6$x$y</password_hash>
                <groups>wheel,docker,video</groups>
              </user>
            </fedora-install>
        """)
        ks = xml2ks.generate_kickstart(root)
        self.assertIn("--groups=wheel,docker,video", ks)

    def test_user_gecos_defaults_to_username(self):
        self.assertIn('--gecos="sija"', self._ks())

    def test_custom_gecos(self):
        root = parse_xml("""
            <fedora-install>
              <iso><url>https://example.com/fedora.iso</url></iso>
              <disk>/dev/sda</disk>
              <hostname>h</hostname>
              <timezone>UTC</timezone>
              <locale>en_US.UTF-8</locale>
              <keyboard>us</keyboard>
              <user>
                <name>sija</name>
                <password_hash>$6$x$y</password_hash>
                <gecos>Sija Full Name</gecos>
              </user>
            </fedora-install>
        """)
        ks = xml2ks.generate_kickstart(root)
        self.assertIn('--gecos="Sija Full Name"', ks)

    # ── Disk / Partitioning ───────────────────────────────────────────────────

    def test_auto_partition_generates_lvm(self):
        ks = self._ks()
        self.assertIn("autopart --type=lvm", ks)

    def test_auto_partition_ignoredisk_uses_short_name(self):
        ks = self._ks()
        self.assertIn("ignoredisk --only-use=sda", ks)

    def test_bootloader_uses_short_disk_name(self):
        ks = self._ks()
        self.assertIn("bootloader --location=mbr --boot-drive=sda", ks)

    def test_nvme_disk_short_name_in_bootloader(self):
        root = minimal_root(**{"disk": "/dev/nvme0n1"})
        ks = xml2ks.generate_kickstart(root)
        self.assertIn("--boot-drive=nvme0n1", ks)

    def test_custom_partition_is_emitted_verbatim(self):
        root = parse_xml("""
            <fedora-install>
              <iso><url>https://example.com/fedora.iso</url></iso>
              <disk>/dev/sda</disk>
              <partitioning>
                <scheme>custom</scheme>
                <kickstart_extra>
                    ignoredisk --only-use=sda
                    clearpart --all --initlabel --drives=sda
                    part /boot --fstype=ext4 --size=1024
                    part pv.1  --fstype=lvmpv --grow
                </kickstart_extra>
              </partitioning>
              <hostname>fedora-test</hostname>
              <timezone>Europe/Berlin</timezone>
              <locale>de_DE.UTF-8</locale>
              <keyboard>de</keyboard>
              <user>
                <name>sija</name>
                <password_hash>$6$salt$hashvalue</password_hash>
              </user>
            </fedora-install>
        """)
        ks = xml2ks.generate_kickstart(root)
        self.assertIn("ignoredisk --only-use=sda", ks)
        self.assertIn("clearpart --all --initlabel --drives=sda", ks)
        self.assertIn("part /boot", ks)
        # auto-LVM directive must NOT appear — custom block replaces auto partitioning
        self.assertNotIn("autopart --type=lvm", ks)

    # ── Packages ──────────────────────────────────────────────────────────────

    def test_base_packages_present(self):
        ks = self._ks()
        for pkg in ("@^fedora-desktop", "git", "curl", "python3", "flatpak"):
            with self.subTest(pkg=pkg):
                self.assertIn(pkg, ks)

    def test_extra_packages_included(self):
        root = parse_xml("""
            <fedora-install>
              <iso><url>https://example.com/fedora.iso</url></iso>
              <disk>/dev/sda</disk>
              <hostname>h</hostname>
              <timezone>UTC</timezone>
              <locale>en_US.UTF-8</locale>
              <keyboard>us</keyboard>
              <user>
                <name>sija</name>
                <password_hash>$6$x$y</password_hash>
              </user>
              <packages>
                <package>podman</package>
                <package>virt-manager</package>
              </packages>
            </fedora-install>
        """)
        ks = xml2ks.generate_kickstart(root)
        self.assertIn("podman", ks)
        self.assertIn("virt-manager", ks)

    def test_extra_groups_included(self):
        root = parse_xml("""
            <fedora-install>
              <iso><url>https://example.com/fedora.iso</url></iso>
              <disk>/dev/sda</disk>
              <hostname>h</hostname>
              <timezone>UTC</timezone>
              <locale>en_US.UTF-8</locale>
              <keyboard>us</keyboard>
              <user>
                <name>sija</name>
                <password_hash>$6$x$y</password_hash>
              </user>
              <packages>
                <group>development-tools</group>
              </packages>
            </fedora-install>
        """)
        ks = xml2ks.generate_kickstart(root)
        self.assertIn("@development-tools", ks)

    # ── Provisioning env vars ─────────────────────────────────────────────────

    def test_target_user_in_env_block(self):
        self.assertIn('FEDORA_TARGET_USER="sija"', self._ks())

    def test_vllm_defaults_in_env_block(self):
        ks = self._ks()
        self.assertIn('FEDORA_VLLM_CUDA_VERSION="13.2"', ks)
        self.assertIn('FEDORA_VLLM_ARCH_LIST="12.0"', ks)
        self.assertIn('FEDORA_VLLM_MODEL="Qwen/Qwen3-14B-AWQ"', ks)

    def test_pytorch_venv_default(self):
        self.assertIn('FEDORA_PYTORCH_VENV="~/.venvs/ai"', self._ks())

    def test_omb_theme_default(self):
        self.assertIn('FEDORA_OMB_THEME="modern"', self._ks())

    def test_whitesur_args_from_xml(self):
        root = parse_xml("""
            <fedora-install>
              <iso><url>https://example.com/fedora.iso</url></iso>
              <disk>/dev/sda</disk>
              <hostname>h</hostname>
              <timezone>UTC</timezone>
              <locale>en_US.UTF-8</locale>
              <keyboard>us</keyboard>
              <user>
                <name>sija</name>
                <password_hash>$6$x$y</password_hash>
              </user>
              <first-login>
                <whitesur>
                  <gtk-args>-l -c Dark</gtk-args>
                  <icon-args>-dark</icon-args>
                  <wallpaper-args>-t Mojave</wallpaper-args>
                </whitesur>
              </first-login>
            </fedora-install>
        """)
        ks = xml2ks.generate_kickstart(root)
        self.assertIn('FEDORA_WS_GTK_ARGS="-l -c Dark"', ks)
        self.assertIn('FEDORA_WS_ICON_ARGS="-dark"', ks)
        self.assertIn('FEDORA_WS_WALL_ARGS="-t Mojave"', ks)

    def test_vllm_config_from_xml(self):
        root = parse_xml("""
            <fedora-install>
              <iso><url>https://example.com/fedora.iso</url></iso>
              <disk>/dev/sda</disk>
              <hostname>h</hostname>
              <timezone>UTC</timezone>
              <locale>en_US.UTF-8</locale>
              <keyboard>us</keyboard>
              <user>
                <name>sija</name>
                <password_hash>$6$x$y</password_hash>
              </user>
              <first-login>
                <vllm-omni venv="~/.venvs/bitwig-omni">
                  <cuda-version>13.0</cuda-version>
                  <arch-list>12.0</arch-list>
                  <model>Qwen/Qwen3-14B-AWQ</model>
                </vllm-omni>
                <ohmybash theme="modern"/>
              </first-login>
            </fedora-install>
        """)
        ks = xml2ks.generate_kickstart(root)
        self.assertIn('FEDORA_VLLM_CUDA_VERSION="13.0"', ks)
        self.assertIn('FEDORA_VLLM_ARCH_LIST="12.0"', ks)

    def test_defaults_for_optional_first_login_fields(self):
        root = parse_xml("""
            <fedora-install>
              <iso><url>https://example.com/fedora.iso</url></iso>
              <disk>/dev/vda</disk>
              <hostname>fedora-test</hostname>
              <timezone>Europe/Berlin</timezone>
              <locale>de_DE.UTF-8</locale>
              <keyboard>de</keyboard>
              <user>
                <name>sija</name>
                <password_hash>$6$salt$hashvalue</password_hash>
              </user>
              <first-login />
            </fedora-install>
        """)
        ks = xml2ks.generate_kickstart(root)
        # Defaults from generate_kickstart (not 13.0)
        self.assertIn('FEDORA_VLLM_CUDA_VERSION="13.2"', ks)
        self.assertIn('FEDORA_VLLM_ARCH_LIST="12.0"', ks)
        self.assertIn('FEDORA_VLLM_MODEL="Qwen/Qwen3-14B-AWQ"', ks)

    # ── Embedded scripts ──────────────────────────────────────────────────────

    def test_embedded_scripts_included(self):
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            fb   = td_path / "first-boot.sh"
            fl   = td_path / "first-login.sh"
            unit = td_path / "first-boot.service"
            fb.write_text("echo first-boot", encoding="utf-8")
            fl.write_text("echo first-login", encoding="utf-8")
            unit.write_text("[Unit]\nDescription=Test", encoding="utf-8")

            ks = xml2ks.generate_kickstart(
                parse_xml(MINIMAL_VALID_XML),
                first_boot_script=fb,
                first_login_script=fl,
                systemd_unit=unit,
            )

        self.assertIn("echo first-boot", ks)
        self.assertIn("echo first-login", ks)
        self.assertIn("[Unit]", ks)
        self.assertIn("Description=Test", ks)

    def test_missing_script_files_produce_empty_heredoc(self):
        ks = xml2ks.generate_kickstart(
            parse_xml(MINIMAL_VALID_XML),
            first_boot_script=Path("/nonexistent/first-boot.sh"),
            first_login_script=None,
        )
        # heredoc delimiters must still be present (empty but valid KS)
        self.assertIn("cat > /usr/local/sbin/fedora-first-boot.sh <<'FBEOF'", ks)
        self.assertIn("FBEOF", ks)
        self.assertIn("cat > /usr/local/bin/fedora-first-login.sh <<'FLEOF'", ks)

    def test_autostart_desktop_entry_for_target_user(self):
        ks = self._ks()
        self.assertIn("fedora-first-login.desktop", ks)
        self.assertIn("/home/sija", ks)
        self.assertIn("chown -R sija:sija", ks)

    def test_flatpak_flathub_remote_added(self):
        self.assertIn("flathub", self._ks())
        self.assertIn("flatpak remote-add", self._ks())

    def test_systemd_enable_first_boot(self):
        self.assertIn("systemctl enable fedora-first-boot.service", self._ks())

    # ── Full generation integration ───────────────────────────────────────────

    def test_full_xml_generates_valid_ks_structure(self):
        root = parse_xml("""
            <fedora-install>
              <iso><url>https://example.com/fedora.iso</url></iso>
              <disk>/dev/vda</disk>
              <hostname>fedora-test</hostname>
              <timezone>Europe/Berlin</timezone>
              <locale>de_DE.UTF-8</locale>
              <keyboard>de</keyboard>
              <user>
                <name>sija</name>
                <password_hash>$6$salt$hashvalue</password_hash>
                <groups>wheel,video</groups>
              </user>
              <packages>
                <package>podman</package>
                <group>development-tools</group>
              </packages>
              <first-login>
                <vllm-omni venv="~/.venvs/bitwig-omni">
                  <cuda-version>13.2</cuda-version>
                  <arch-list>12.0</arch-list>
                  <model>Qwen/Qwen3-14B-AWQ</model>
                </vllm-omni>
                <ohmybash theme="agnoster"/>
                <whitesur>
                  <gtk-args>-l -c Dark</gtk-args>
                </whitesur>
              </first-login>
            </fedora-install>
        """)
        ks = xml2ks.generate_kickstart(root)

        # Required sections
        for section in ("%packages", "%end", "%post", "%addon"):
            with self.subTest(section=section):
                self.assertIn(section, ks)

        # Disk
        self.assertIn("--boot-drive=vda", ks)
        self.assertIn("autopart --type=lvm", ks)

        # Packages
        self.assertIn("podman", ks)
        self.assertIn("@development-tools", ks)

        # Env
        self.assertIn('FEDORA_VLLM_CUDA_VERSION="13.2"', ks)
        self.assertIn('FEDORA_OMB_THEME="agnoster"', ks)
        self.assertIn('FEDORA_WS_GTK_ARGS="-l -c Dark"', ks)


# ── CLI / main() tests ────────────────────────────────────────────────────────

class MainCLITests(unittest.TestCase):

    def _write_minimal_xml(self, td: Path, disk="/dev/sda") -> Path:
        p = td / "config.xml"
        p.write_text(MINIMAL_VALID_XML.replace("/dev/sda", disk), encoding="utf-8")
        return p

    def test_validate_only_ok(self):
        with tempfile.TemporaryDirectory() as td:
            xml_path = self._write_minimal_xml(Path(td))
            with patch("sys.argv", ["xml2ks.py", "--validate-only", str(xml_path)]):
                with patch("sys.stdout", StringIO()):
                    rc = xml2ks.main()
        self.assertEqual(rc, 0)

    def test_validate_only_fails_on_invalid_xml(self):
        with tempfile.TemporaryDirectory() as td:
            bad = Path(td) / "bad.xml"
            bad.write_text("<unclosed", encoding="utf-8")
            with patch("sys.argv", ["xml2ks.py", "--validate-only", str(bad)]):
                with patch("sys.stderr", StringIO()):
                    rc = xml2ks.main()
        self.assertEqual(rc, 1)

    def test_validate_only_fails_on_invalid_config(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "bad.xml"
            p.write_text(MINIMAL_VALID_XML.replace("/dev/sda", "/dev/sr0"), encoding="utf-8")
            with patch("sys.argv", ["xml2ks.py", "--validate-only", str(p)]):
                with patch("sys.stderr", StringIO()):
                    rc = xml2ks.main()
        self.assertEqual(rc, 1)

    def test_get_field_hostname(self):
        with tempfile.TemporaryDirectory() as td:
            xml_path = self._write_minimal_xml(Path(td))
            buf = StringIO()
            with patch("sys.argv", ["xml2ks.py", "--get-field", "hostname", str(xml_path)]):
                with patch("sys.stdout", buf):
                    rc = xml2ks.main()
        self.assertEqual(rc, 0)
        self.assertEqual(buf.getvalue().strip(), "fedora-test")

    def test_get_field_disk(self):
        with tempfile.TemporaryDirectory() as td:
            xml_path = self._write_minimal_xml(Path(td))
            buf = StringIO()
            with patch("sys.argv", ["xml2ks.py", "--get-field", "disk", str(xml_path)]):
                with patch("sys.stdout", buf):
                    rc = xml2ks.main()
        self.assertEqual(rc, 0)
        self.assertEqual(buf.getvalue().strip(), "/dev/sda")

    def test_get_field_iso_url(self):
        with tempfile.TemporaryDirectory() as td:
            xml_path = self._write_minimal_xml(Path(td))
            buf = StringIO()
            with patch("sys.argv", ["xml2ks.py", "--get-field", "iso_url", str(xml_path)]):
                with patch("sys.stdout", buf):
                    rc = xml2ks.main()
        self.assertEqual(rc, 0)
        self.assertIn("example.com", buf.getvalue())

    def test_get_field_missing_returns_1(self):
        with tempfile.TemporaryDirectory() as td:
            xml_path = self._write_minimal_xml(Path(td))
            with patch("sys.argv", ["xml2ks.py", "--get-field", "nonexistent_field", str(xml_path)]):
                with patch("sys.stderr", StringIO()):
                    rc = xml2ks.main()
        self.assertEqual(rc, 1)

    def test_full_generation_writes_output_file(self):
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            xml_path = self._write_minimal_xml(td_path)
            out_path = td_path / "out.ks"
            with patch("sys.argv", [
                "xml2ks.py", "--config", str(xml_path), "--output", str(out_path)
            ]):
                with patch("sys.stdout", StringIO()):
                    rc = xml2ks.main()
            # assertions inside with-block so temp dir still exists
            self.assertEqual(rc, 0)
            self.assertTrue(out_path.exists())
            content = out_path.read_text(encoding="utf-8")
            self.assertIn("#version=RHEL9", content)

    def test_no_args_returns_nonzero(self):
        with patch("sys.argv", ["xml2ks.py"]):
            with patch("sys.stdout", StringIO()):
                with patch("sys.stderr", StringIO()):
                    rc = xml2ks.main()
        self.assertNotEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()

