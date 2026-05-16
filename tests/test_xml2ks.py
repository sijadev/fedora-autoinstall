import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from io import StringIO
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent.parent / "lib"))
import xml2ks  # type: ignore  # noqa: E402

# ── Fixture-Dateien ────────────────────────────────────────────────────────────
# tests/fixtures/minimal.xml — Pflichtfelder, keine Optionen
# tests/fixtures/full.xml    — vollständige Konfiguration (= config/example.xml)
FIXTURES = Path(__file__).parent / "fixtures"


def load_fixture(name: str) -> ET.Element:
    """Lädt eine XML-Fixture-Datei aus tests/fixtures/."""
    path = FIXTURES / name
    if not path.exists():
        raise FileNotFoundError(f"Fixture nicht gefunden: {path}")
    return ET.parse(str(path)).getroot()


def parse_xml(text: str) -> ET.Element:
    """Inline-XML parsen — nur für Tests mit spezifischen Sonderfällen."""
    return ET.fromstring(text)


def minimal_root(**overrides) -> ET.Element:
    """Lädt minimal.xml und wendet optionale Feldüberschreibungen an (xpath → text)."""
    root = load_fixture("minimal.xml")
    for xpath, value in overrides.items():
        el = root.find(xpath)
        if el is None:
            raise ValueError(f"xpath nicht gefunden in minimal.xml: {xpath}")
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

    # SATA / SCSI HDDs und SSDs
    def test_accepts_sda_disk(self):
        self.assertEqual(xml2ks.validate(minimal_root(), Path("x.xml")), [])

    def test_accepts_sdb_disk(self):
        root = minimal_root(**{"disk": "/dev/sdb"})
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])

    def test_accepts_sdc_disk(self):
        root = minimal_root(**{"disk": "/dev/sdc"})
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])

    def test_accepts_sdz_disk(self):
        root = minimal_root(**{"disk": "/dev/sdz"})
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])

    # NVMe SSDs
    def test_accepts_nvme0n1_disk(self):
        root = minimal_root(**{"disk": "/dev/nvme0n1"})
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])

    def test_accepts_nvme1n1_disk(self):
        root = minimal_root(**{"disk": "/dev/nvme1n1"})
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])

    def test_accepts_nvme0n2_disk(self):
        root = minimal_root(**{"disk": "/dev/nvme0n2"})
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])

    def test_accepts_nvme10n1_disk(self):
        root = minimal_root(**{"disk": "/dev/nvme10n1"})
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])

    # virtuelle Disks (KVM/QEMU, Xen)
    def test_accepts_vda_disk(self):
        root = minimal_root(**{"disk": "/dev/vda"})
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])

    def test_accepts_vdb_disk(self):
        root = minimal_root(**{"disk": "/dev/vdb"})
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])

    def test_accepts_xvda_disk(self):
        root = minimal_root(**{"disk": "/dev/xvda"})
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])

    # eMMC (Tablets, SBCs)
    def test_accepts_mmcblk_disk(self):
        root = minimal_root(**{"disk": "/dev/mmcblk0"})
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])

    def test_accepts_mmcblk1_disk(self):
        root = minimal_root(**{"disk": "/dev/mmcblk1"})
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])

    # Partitionen → abgelehnt
    def test_rejects_partition_not_whole_disk(self):
        root = minimal_root(**{"disk": "/dev/sda1"})
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(any("must be one of" in e for e in errors))

    def test_rejects_sda_multidigit_partition(self):
        root = minimal_root(**{"disk": "/dev/sda10"})
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(len(errors) > 0)

    def test_rejects_nvme_partition(self):
        root = minimal_root(**{"disk": "/dev/nvme0n1p1"})
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(len(errors) > 0)

    def test_rejects_nvme_partition_multidigit(self):
        root = minimal_root(**{"disk": "/dev/nvme0n1p12"})
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(len(errors) > 0)

    def test_rejects_mmcblk_partition(self):
        root = minimal_root(**{"disk": "/dev/mmcblk0p1"})
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(len(errors) > 0)

    # IDE (veraltet) → abgelehnt
    def test_rejects_hda_ide_disk(self):
        root = minimal_root(**{"disk": "/dev/hda"})
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(len(errors) > 0)

    # Loop / loop-device → abgelehnt
    def test_rejects_loop_device(self):
        root = minimal_root(**{"disk": "/dev/loop0"})
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(len(errors) > 0)

    # CD/DVD → abgelehnt
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

    # ── vLLM Router port validation ───────────────────────────────────────────

    def test_rejects_invalid_router_port_format(self):
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
                <vllm-router port="not-a-port"/>
              </first-login>
            </fedora-install>
        """)
        errors = xml2ks.validate(root, Path("x.xml"))
        self.assertTrue(any("port" in e.lower() for e in errors))

    def test_accepts_valid_router_port(self):
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
                <vllm-router port="8000"/>
              </first-login>
            </fedora-install>
        """)
        self.assertEqual(xml2ks.validate(root, Path("x.xml")), [])


# ── Kickstart generation tests ────────────────────────────────────────────────

class GenerateKickstartTests(unittest.TestCase):
    """Tests for generate_kickstart(). Uses minimal valid XML as baseline."""

    def _ks(self, xml_text=None, **script_kwargs) -> str:
        root = parse_xml(xml_text) if xml_text else load_fixture("minimal.xml")
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

    def test_auto_partition_generates_pre_block(self):
        # ignoredisk/bootloader/autopart stehen jetzt im %pre-generierten disk-setup.cfg
        ks = self._ks()
        self.assertIn("%pre", ks)
        self.assertIn("%include /tmp/disk-setup.cfg", ks)

    def test_auto_partition_generates_btrfs(self):
        # autopart steht im %pre Block (disk-setup.cfg), nicht direkt im KS
        ks = self._ks()
        self.assertIn("autopart --type=btrfs", ks)

    def test_auto_partition_ignoredisk_in_pre(self):
        # ignoredisk steht im %pre Block, nicht direkt im KS-Body
        ks = self._ks()
        self.assertIn("ignoredisk --only-use=$DISK", ks)
        self.assertIn("%pre", ks)

    def test_auto_partition_no_hardcoded_disk_outside_pre(self):
        # Kein hardcodierter Disk-Name außerhalb des %pre Blocks
        ks = self._ks()
        # %pre endet mit %end — alles danach darf kein ignoredisk mit festem Namen haben
        after_pre = ks.split("%end", 1)[-1] if "%end" in ks else ks
        self.assertNotIn("ignoredisk --only-use=sda", after_pre)

    def test_bootloader_no_location_mbr(self):
        # --location=mbr ist bei UEFI ungültig — darf nicht im Output stehen
        ks = self._ks()
        self.assertNotIn("--location=mbr", ks)

    def test_bootloader_uses_short_disk_name(self):
        # bootloader steht im %pre Block (disk-setup.cfg)
        ks = self._ks()
        self.assertIn("bootloader --boot-drive=$DISK", ks)
        self.assertNotIn("bootloader --location=mbr", ks)

    def test_nvme_disk_name_in_pre_block(self):
        # %pre Block erkennt Disk automatisch — kein hardcodierter nvme-Name
        root = minimal_root(**{"disk": "/dev/nvme0n1"})
        ks = xml2ks.generate_kickstart(root)
        self.assertIn("%pre", ks)
        self.assertIn("%include /tmp/disk-setup.cfg", ks)

    def test_nvme1n1_pre_block_present(self):
        root = minimal_root(**{"disk": "/dev/nvme1n1"})
        ks = xml2ks.generate_kickstart(root)
        self.assertIn("%pre", ks)
        self.assertIn("autopart --type=btrfs", ks)

    def test_sdb_pre_block_present(self):
        root = minimal_root(**{"disk": "/dev/sdb"})
        ks = xml2ks.generate_kickstart(root)
        self.assertIn("%pre", ks)
        self.assertIn("%include /tmp/disk-setup.cfg", ks)

    def test_mmcblk0_pre_block_present(self):
        root = minimal_root(**{"disk": "/dev/mmcblk0"})
        ks = xml2ks.generate_kickstart(root)
        self.assertIn("%pre", ks)
        self.assertIn("%include /tmp/disk-setup.cfg", ks)

    def test_pre_block_contains_disk_autodetection(self):
        # %pre Block muss NVMe, USB und zram ausschließen
        ks = self._ks()
        self.assertIn("$3!=\"usb\"", ks)
        self.assertIn("!~/^zram/", ks)
        self.assertIn("lsblk", ks)

    def test_pre_block_supports_inst_disk_override(self):
        # Kernel-Parameter inst.disk= muss Vorrang haben
        ks = self._ks()
        self.assertIn("inst\\.disk=", ks)

    def test_duplicate_packages_not_emitted(self):
        # Pakete die in base und extra-packages stehen dürfen nicht doppelt erscheinen
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
                <package>git</package>
                <package>curl</package>
                <package>git</package>
              </packages>
            </fedora-install>
        """)
        ks = xml2ks.generate_kickstart(root)
        # %packages Block isolieren — endet beim nächsten %end
        start = ks.index("%packages\n") + len("%packages\n")
        end   = ks.index("\n%end", start)
        pkg_lines = ks[start:end].splitlines()
        self.assertEqual(pkg_lines.count("git"), 1,
                         "git darf nur einmal im %packages Block stehen")

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
        for pkg in ("@^workstation-product-environment", "git", "curl", "python3", "flatpak"):
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

    def test_vllm_router_defaults_in_env_block(self):
        ks = self._ks()
        self.assertIn('FEDORA_VLLM_ROUTER_PORT="8000"', ks)
        self.assertIn('FEDORA_VLLM_REGISTRY="~/.config/vllm-router/models.json"', ks)
        self.assertIn('FEDORA_AGENT_MODEL="Qwen/Qwen3-14B-AWQ"', ks)
        self.assertIn('FEDORA_AUDIO_MODEL="moonshotai/Kimi-Audio-7B-Instruct"', ks)

    def test_venv_and_cuda_vars_in_env_block(self):
        ks = self._ks()
        self.assertIn('FEDORA_PYTORCH_VENV="~/.venvs/ai"', ks)
        self.assertIn('FEDORA_VLLM_VENV="~/.venvs/bitwig-omni"', ks)
        self.assertIn('FEDORA_AUDIO_VENV="~/.venvs/kimi-audio"', ks)
        self.assertIn("FEDORA_VLLM_CUDA_VERSION=", ks)
        self.assertIn("FEDORA_VLLM_ARCH_LIST=", ks)

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

    def test_vllm_router_config_from_xml(self):
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
                <vllm-router port="8080">
                  <registry>~/.config/vllm-router/custom.json</registry>
                  <agent-model>Qwen/Qwen3-8B</agent-model>
                  <audio-model>moonshotai/Kimi-Audio-7B-Instruct</audio-model>
                </vllm-router>
              </first-login>
            </fedora-install>
        """)
        ks = xml2ks.generate_kickstart(root)
        self.assertIn('FEDORA_VLLM_ROUTER_PORT="8080"', ks)
        self.assertIn('FEDORA_VLLM_REGISTRY="~/.config/vllm-router/custom.json"', ks)
        self.assertIn('FEDORA_AGENT_MODEL="Qwen/Qwen3-8B"', ks)

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
        self.assertIn('FEDORA_VLLM_ROUTER_PORT="8000"', ks)
        self.assertIn('FEDORA_VLLM_REGISTRY="~/.config/vllm-router/models.json"', ks)
        self.assertIn('FEDORA_AGENT_MODEL="Qwen/Qwen3-14B-AWQ"', ks)

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
                load_fixture("minimal.xml"),
                first_boot_script=fb,
                first_login_script=fl,
                systemd_unit=unit,
            )

        self.assertIn("echo first-boot", ks)
        self.assertIn("echo first-login", ks)
        self.assertIn("[Unit]", ks)
        self.assertIn("Description=Test", ks)

    def test_missing_script_file_warns_on_stderr(self):
        """Angegebener Pfad der nicht existiert → stderr-Warnung statt stillem leerem Heredoc."""
        import io
        buf = io.StringIO()
        with patch("sys.stderr", buf):
            xml2ks.generate_kickstart(
                load_fixture("minimal.xml"),
                first_boot_script=Path("/nonexistent/first-boot.sh"),
            )
        self.assertIn("WARNING", buf.getvalue())
        self.assertIn("nonexistent", buf.getvalue())

    def test_none_script_path_produces_no_warning(self):
        """None als Pfad = absichtlich weggelassen → keine Warnung."""
        import io
        buf = io.StringIO()
        with patch("sys.stderr", buf):
            xml2ks.generate_kickstart(
                load_fixture("minimal.xml"),
                first_boot_script=None,
            )
        self.assertNotIn("WARNING", buf.getvalue())

    def test_scripts_with_real_content_embedded(self):
        """Echte Script-Dateien müssen ihren Inhalt im Kickstart haben — kein leeres heredoc."""
        PROJECT = Path(__file__).parent.parent
        fb   = PROJECT / "scripts" / "first-boot.sh"
        fl   = PROJECT / "scripts" / "first-login.sh"
        unit = PROJECT / "systemd" / "fedora-first-boot.service"
        if not fb.exists() or not fl.exists() or not unit.exists():
            self.skipTest("Projekt-Scripts nicht gefunden")

        ks = xml2ks.generate_kickstart(
            load_fixture("minimal.xml"),
            first_boot_script=fb,
            first_login_script=fl,
            systemd_unit=unit,
        )
        # Kein leeres heredoc — Script-Inhalt muss vorhanden sein
        self.assertNotIn("<<'FBEOF'\n\nFBEOF", ks, "first-boot.sh heredoc ist leer")
        self.assertNotIn("<<'FLEOF'\n\nFLEOF", ks, "first-login.sh heredoc ist leer")
        self.assertNotIn("<<'UNITEOF'\n\nUNITEOF", ks, "systemd unit heredoc ist leer")
        # Mindestens ein erkennbares Element der echten Scripts
        self.assertTrue(
            "set -euo pipefail" in ks or "#!/usr/bin/env bash" in ks,
            "Kein Script-Inhalt in first-boot.sh gefunden"
        )

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

    def test_regression_ks_defaults_keep_ssh_access(self):
        """Regression guard: generated KS must keep SSH reachable by default."""
        ks = self._ks()
        self.assertIn("firewall --enabled --service=ssh", ks)
        self.assertIn("openssh-server", ks)
        self.assertIn("systemctl enable sshd.service", ks)

    def test_regression_embedded_first_boot_cuda_guards(self):
        """Regression guard for previously broken CUDA branch in embedded first-boot.sh."""
        project = Path(__file__).parent.parent
        fb = project / "scripts" / "first-boot.sh"
        fl = project / "scripts" / "first-login.sh"
        unit = project / "systemd" / "fedora-first-boot.service"
        if not fb.exists() or not fl.exists() or not unit.exists():
            self.skipTest("Projekt-Scripts nicht gefunden")

        ks = xml2ks.generate_kickstart(
            load_fixture("minimal.xml"),
            first_boot_script=fb,
            first_login_script=fl,
            systemd_unit=unit,
        )
        self.assertNotIn("fedora|fedora)", ks)
        self.assertNotIn('die "nvcc not found after CUDA installation."', ks)
        self.assertIn(
            'warn "nvcc not found after CUDA installation — skipping CUDA environment setup."',
            ks,
        )

    def test_regression_kernel_devel_branching_for_cachyos(self):
        """Regression guard: NVIDIA deps must branch by FEDORA_KERNEL_SOURCE."""
        project = Path(__file__).parent.parent
        fb = project / "scripts" / "first-boot.sh"
        fl = project / "scripts" / "first-login.sh"
        unit = project / "systemd" / "fedora-first-boot.service"
        if not fb.exists() or not fl.exists() or not unit.exists():
            self.skipTest("Projekt-Scripts nicht gefunden")

        ks = xml2ks.generate_kickstart(
            load_fixture("minimal.xml"),
            first_boot_script=fb,
            first_login_script=fl,
            systemd_unit=unit,
        )

        self.assertIn('if [[ "${FEDORA_KERNEL_SOURCE:-cachyos}" == "fedora" ]]; then', ks)
        self.assertIn("kernel-cachyos-devel", ks)
        self.assertIn("kernel-devel", ks)
        self.assertIn("kernel-headers", ks)
        self.assertNotIn("via DKMS/Nobara installiert", ks)

    def test_regression_btrfs_subvolume_syntax(self):
        """Regression guard: the synced Btrfs subvolume rename syntax must stay correct."""
        project = Path(__file__).parent.parent
        common_post = project / "kickstart" / "common-post.inc"
        if not common_post.exists():
            self.skipTest("kickstart/common-post.inc nicht gefunden")

        text = common_post.read_text(encoding="utf-8")

        expected_snippets = [
            "%post --nochroot --log=/root/ks-post-btrfs-rename.log",
            "mount -o subvolid=5",
            "btrfs subvolume snapshot \"${MOUNT_TMP}/root\" \"${MOUNT_TMP}/@\"",
            "btrfs subvolume snapshot \"${MOUNT_TMP}/home\" \"${MOUNT_TMP}/@home\"",
            "sed -i 's/subvol=root\\b/subvol=@/g'",
            "sed -i 's/subvol=home\\b/subvol=@home/g'",
        ]
        for snippet in expected_snippets:
            with self.subTest(snippet=snippet):
                self.assertIn(snippet, text)

        self.assertNotIn("subvol=@homehome", text)

    # ── Repo-Erreichbarkeit (generiert aus XML) ───────────────────────────────

    def _generate_ks_from_project(self) -> str:
        """Generiert KS aus config/example.xml + echten Projekt-Scripts."""
        project = Path(__file__).parent.parent
        fb   = project / "scripts" / "first-boot.sh"
        fl   = project / "scripts" / "first-login.sh"
        unit = project / "systemd" / "fedora-first-boot.service"
        cfg  = project / "config" / "example.xml"
        if not all(p.exists() for p in [fb, fl, unit, cfg]):
            self.skipTest("Projektdateien nicht gefunden")
        root = ET.parse(str(cfg)).getroot()
        return xml2ks.generate_kickstart(root, first_boot_script=fb,
                                         first_login_script=fl, systemd_unit=unit)

    def test_repo_urls_reachable(self):
        """
        Extracts all repo URLs embedded in the generated KS (from XML config)
        and checks that each returns HTTP 200/301/302 (HEAD request).
        Requires network access — skipped automatically if offline.
        """
        import re
        import urllib.request
        import urllib.error

        ks = self._generate_ks_from_project()

        # Extrahiere URLs aus typischen Repo-Zeilen im eingebetteten Script:
        #   dnf copr enable -y bieszczaders/kernel-cachyos
        #   --add-repo "https://..."   /  --from-repofile="https://..."
        url_patterns = [
            # explizite https:// URLs
            re.compile(r'https://[^\s\'"\\]+\.repo'),
            re.compile(r'https://[^\s\'"\\]+/repodata/repomd\.xml'),
        ]
        copr_patterns = [
            # COPR-Bezeichner → kanonische API-URL
            re.compile(r'dnf copr enable\s+-y\s+([\w/-]+)'),
        ]

        urls: dict[str, str] = {}  # url → herkunft

        for pat in url_patterns:
            for m in pat.finditer(ks):
                url = m.group(0)
                # Shell-Variablen wie ${distro} überspringen — nur konkrete URLs prüfen
                if "${" not in url:
                    urls[url] = "repo-url"

        for pat in copr_patterns:
            for m in pat.finditer(ks):
                copr_id = m.group(1).strip()
                owner, _, project_name = copr_id.partition("/")
                url = (f"https://copr.fedorainfracloud.org/coprs/{owner}/"
                       f"{project_name}/")
                urls[url] = f"copr:{copr_id}"

        if not urls:
            self.skipTest("Keine Repo-URLs im generierten KS gefunden")

        # Netzwerk-Check: erreichbar?
        try:
            urllib.request.urlopen(
                urllib.request.Request("https://copr.fedorainfracloud.org",
                                       method="HEAD"),
                timeout=5,
            )
        except (urllib.error.URLError, OSError):
            self.skipTest("Kein Netzwerk — Repo-Erreichbarkeitstest übersprungen")

        failures = []
        for url, origin in urls.items():
            try:
                req = urllib.request.Request(url, method="HEAD")
                req.add_header("User-Agent", "fedora-autoinstall-test/1.0")
                with urllib.request.urlopen(req, timeout=10) as resp:
                    code = resp.status
                if code not in (200, 301, 302, 303):
                    failures.append(f"{origin}: HTTP {code} — {url}")
            except urllib.error.HTTPError as e:
                if e.code not in (200, 301, 302, 303, 405):
                    failures.append(f"{origin}: HTTP {e.code} — {url}")
            except (urllib.error.URLError, OSError) as e:
                failures.append(f"{origin}: Nicht erreichbar — {url} ({e})")

        if failures:
            self.fail("Nicht erreichbare Repos:\n" + "\n".join(failures))

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
                <vllm-router port="8000">
                  <agent-model>Qwen/Qwen3-14B-AWQ</agent-model>
                </vllm-router>
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

        # Disk — bootloader + autopart stehen im %pre Block (disk-setup.cfg)
        self.assertIn("%pre", ks)
        self.assertIn("%include /tmp/disk-setup.cfg", ks)
        self.assertIn("autopart --type=btrfs", ks)
        self.assertNotIn("--location=mbr", ks)

        # Packages
        self.assertIn("podman", ks)
        self.assertIn("@development-tools", ks)

        # Env
        self.assertIn('FEDORA_VLLM_ROUTER_PORT="8000"', ks)
        self.assertIn('FEDORA_OMB_THEME="agnoster"', ks)
        self.assertIn('FEDORA_WS_GTK_ARGS="-l -c Dark"', ks)


# ── Fixture-basierte End-to-End Tests ────────────────────────────────────────

class FixtureTests(unittest.TestCase):
    """Tests die echte Fixture-Dateien aus tests/fixtures/ verwenden."""

    def test_minimal_xml_fixture_is_valid(self):
        root = load_fixture("minimal.xml")
        errors = xml2ks.validate(root, FIXTURES / "minimal.xml")
        self.assertEqual(errors, [], f"minimal.xml Validierungsfehler: {errors}")

    def test_full_xml_fixture_is_valid(self):
        root = load_fixture("full.xml")
        errors = xml2ks.validate(root, FIXTURES / "full.xml")
        self.assertEqual(errors, [], f"full.xml Validierungsfehler: {errors}")

    def test_full_xml_generates_kickstart(self):
        root = load_fixture("full.xml")
        ks = xml2ks.generate_kickstart(root)
        self.assertIn("#version=RHEL9", ks)
        self.assertIn("%packages", ks)
        self.assertIn("%post", ks)
        self.assertNotIn("--location=mbr", ks)

    def test_full_xml_has_pre_disk_detection(self):
        root = load_fixture("full.xml")
        ks = xml2ks.generate_kickstart(root)
        self.assertIn("%pre", ks)
        self.assertIn("%include /tmp/disk-setup.cfg", ks)
        self.assertIn("lsblk", ks)

    def test_full_xml_env_vars_present(self):
        root = load_fixture("full.xml")
        ks = xml2ks.generate_kickstart(root)
        self.assertIn("FEDORA_TARGET_USER=", ks)
        self.assertIn("FEDORA_OMB_THEME=", ks)
        self.assertIn("FEDORA_WS_GTK_ARGS=", ks)

    def test_minimal_xml_generates_kickstart(self):
        root = load_fixture("minimal.xml")
        ks = xml2ks.generate_kickstart(root)
        self.assertIn("#version=RHEL9", ks)
        self.assertIn("%pre", ks)
        self.assertNotIn("--location=mbr", ks)

    def test_fixtures_dir_exists(self):
        self.assertTrue(FIXTURES.is_dir(), f"fixtures/ Verzeichnis fehlt: {FIXTURES}")
        self.assertTrue((FIXTURES / "minimal.xml").exists())
        self.assertTrue((FIXTURES / "full.xml").exists())


# ── CLI / main() tests ────────────────────────────────────────────────────────

class MainCLITests(unittest.TestCase):

    def _write_minimal_xml(self, td: Path, disk="/dev/sda") -> Path:
        p = td / "config.xml"
        content = (FIXTURES / "minimal.xml").read_text(encoding="utf-8")
        p.write_text(content.replace("/dev/sda", disk), encoding="utf-8")
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
            content = (FIXTURES / "minimal.xml").read_text(encoding="utf-8")
            p.write_text(content.replace("/dev/sda", "/dev/sr0"), encoding="utf-8")
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

