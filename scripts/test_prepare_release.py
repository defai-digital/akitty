import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "prepare", Path(__file__).with_name("prepare-release.py")
)
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)

HEAD = "a" * 40
VERSION = "9.9.9"
BUILD = "9999"
ARCHIVE = f"AkiTTY-{VERSION}-macOS-arm64.zip"
PUBLISHED = {ARCHIVE, "release.json", "appcast.xml", "SHA256SUMS"}
PUBLIC_KEY = "3HMi+FbZd4fKYjgadkLHPvU9z+3wD8Qq44gykDQ31lo="
SIGNATURE = base64.b64encode(bytes(64)).decode()
ARCHIVE_BYTES = b"notarized archive"
ARCHIVE_URL = (
    f"https://download.automatosx.com/akitty/releases/download/v{VERSION}/{ARCHIVE}"
)


def appcast(
    build=BUILD,
    version=VERSION,
    signature=SIGNATURE,
    url=ARCHIVE_URL,
    length=len(ARCHIVE_BYTES),
    minimum="14.0",
):
    minimum_element = (
        ""
        if minimum is None
        else f"<sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>"
    )
    return (
        '<?xml version="1.0"?><rss '
        'xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">'
        f"<channel><title>Akitty</title><item>"
        f"<sparkle:version>{build}</sparkle:version>"
        f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
        f"{minimum_element}"
        f'<enclosure url="{url}" length="{length}" type="application/octet-stream"'
        f' sparkle:edSignature="{signature}"/>'
        "</item></channel></rss>"
    ).encode()


def workspace(root):
    (root / "Cargo.toml").write_text(
        f'[workspace]\nmembers = []\n\n[workspace.package]\nversion = "{VERSION}"\n'
    )
    (root / "docs" / "releases").mkdir(parents=True)
    (root / "docs" / "releases" / f"{VERSION}.md").write_text("# notes\n")
    (root / "macos" / ".build" / "artifacts" / "sparkle" / "Sparkle" / "bin").mkdir(
        parents=True
    )
    (root / "macos/.build/artifacts/sparkle/Sparkle/bin/generate_appcast").write_text(
        ""
    )
    (root / "macos" / "Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleIdentifier": "com.defai.akitty",
                "CFBundleShortVersionString": VERSION,
                "CFBundleVersion": BUILD,
                "SUPublicEDKey": PUBLIC_KEY,
            }
        )
    )
    (root / "build").mkdir()
    (root / "build" / "Akitty-macOS.zip").write_bytes(ARCHIVE_BYTES)


def stamp(**overrides):
    row = {
        "schema": 1,
        "commit": HEAD,
        "dirty": False,
        "configuration": "release",
        "version": VERSION,
        "build": BUILD,
    }
    row.update(overrides)
    return row


class Runner:
    """Offline stand-in for git and Sparkle's generate_appcast."""

    def __init__(self, status=""):
        self.calls = []
        self.status = status

    def __call__(self, *args):
        self.calls.append(args)
        tool = Path(str(args[0])).name
        if args[:2] == ("git", "rev-parse"):
            return HEAD
        if args[:2] == ("git", "status"):
            return self.status
        if tool == "generate_keys":
            return PUBLIC_KEY
        if tool == "generate_appcast":
            (Path(args[-1]) / "appcast.xml").write_bytes(appcast())
            return ""
        if tool == "sign_update":
            return ""
        raise AssertionError("unexpected command: " + " ".join(args))


class BrokenRunner(Runner):
    def __call__(self, *args):
        if str(args[0]).endswith("generate_appcast"):
            self.calls.append(args)
            raise subprocess.CalledProcessError(1, args[0])
        return super().__call__(*args)


class AppcastRunner(Runner):
    """Emit a signed feed with one field deliberately mismatched to the manifest."""

    def __init__(self, **overrides):
        super().__init__()
        self.overrides = overrides

    def __call__(self, *args):
        if Path(str(args[0])).name == "generate_appcast":
            self.calls.append(args)
            (Path(args[-1]) / "appcast.xml").write_bytes(appcast(**self.overrides))
            return ""
        return super().__call__(*args)


class WrongKeyRunner(Runner):
    def __call__(self, *args):
        if Path(str(args[0])).name == "generate_keys":
            self.calls.append(args)
            return "b" * 44
        return super().__call__(*args)


class RejectingSignatureRunner(Runner):
    def __call__(self, *args):
        if Path(str(args[0])).name == "sign_update":
            self.calls.append(args)
            raise subprocess.CalledProcessError(1, args[0])
        return super().__call__(*args)


def verifier(plist=None, build_stamp=None):
    row = {
        "CFBundleIdentifier": "com.defai.akitty",
        "CFBundleShortVersionString": VERSION,
        "CFBundleVersion": BUILD,
    }
    if plist:
        row.update(plist)
    value = build_stamp if build_stamp is not None else stamp()

    def verify(archive, expected, version, private, run=None):
        assert archive.is_file(), "the archive must be staged before verification"
        return dict(row), dict(value)

    return verify


class PrepareReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        workspace(self.root)
        self.output = self.root / "out"

    def prepare(self, **kwargs):
        kwargs.setdefault("run", Runner())
        kwargs.setdefault("verify", verifier())
        return prepare.prepare(
            "akitty", root=self.root, head=HEAD, output_root=self.output, **kwargs
        )

    def test_assets_are_published_atomically_and_consistently(self):
        self.prepare()
        destination = self.output / ("v" + VERSION)
        self.assertEqual({path.name for path in destination.iterdir()}, PUBLISHED)
        self.assertEqual(
            [path.name for path in self.output.iterdir()], [destination.name]
        )
        manifest = json.loads((destination / "release.json").read_text())
        self.assertEqual(manifest["commit"], HEAD)
        self.assertEqual(manifest["version"], VERSION)
        self.assertEqual(manifest["build"], BUILD)
        archive = (destination / ARCHIVE).read_bytes()
        self.assertEqual(manifest["sha256"], hashlib.sha256(archive).hexdigest())
        self.assertEqual(manifest["size"], len(archive))
        self.assertEqual(
            manifest["url"],
            f"https://download.automatosx.com/akitty/releases/download/v{VERSION}/{ARCHIVE}",
        )
        sums = {}
        for line in (destination / "SHA256SUMS").read_text().splitlines():
            digest, name = line.split("  ")
            sums[name] = digest
        self.assertEqual(set(sums), PUBLISHED - {"SHA256SUMS"})
        for name, digest in sums.items():
            self.assertEqual(
                digest, hashlib.sha256((destination / name).read_bytes()).hexdigest()
            )

    def test_failed_signing_leaves_no_release_and_allows_a_retry(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.prepare(run=BrokenRunner())
        self.assertEqual([path.name for path in self.output.iterdir()], [])
        self.assertFalse((self.output / ("v" + VERSION)).exists())

        self.prepare()
        self.assertEqual(
            {path.name for path in (self.output / ("v" + VERSION)).iterdir()}, PUBLISHED
        )

    def test_account_key_must_match_the_published_identity(self):
        with self.assertRaises(prepare.ReleaseError):
            self.prepare(run=WrongKeyRunner())
        self.assertEqual([path.name for path in self.output.iterdir()], [])

    def test_appcast_signature_must_verify_with_the_account(self):
        with self.assertRaises(prepare.ReleaseError):
            self.prepare(run=RejectingSignatureRunner())
        self.assertEqual([path.name for path in self.output.iterdir()], [])
        self.assertFalse((self.output / ("v" + VERSION)).exists())

    def test_account_key_and_signature_are_checked_in_order(self):
        runner = Runner()
        self.prepare(run=runner)
        tools = [Path(str(args[0])).name for args in runner.calls]
        self.assertLess(tools.index("generate_keys"), tools.index("generate_appcast"))
        self.assertLess(tools.index("generate_appcast"), tools.index("sign_update"))
        sign = runner.calls[tools.index("sign_update")]
        self.assertEqual(sign[1:4], ("--account", "akitty", "--verify"))
        self.assertTrue(str(sign[4]).endswith(ARCHIVE))
        self.assertEqual(sign[5], SIGNATURE)

    def test_generated_appcast_must_match_the_manifest(self):
        cases = {
            "short version": {"version": "0.0.1"},
            "sparkle version": {"build": "1"},
            "minimum system version": {"minimum": "15.0"},
            "missing minimum system version": {"minimum": None},
            "enclosure url": {"url": "https://download.automatosx.com/other.zip"},
            "enclosure length": {"length": "1"},
        }
        for case, overrides in cases.items():
            with self.subTest(case=case):
                with self.assertRaises(prepare.ReleaseError):
                    self.prepare(run=AppcastRunner(**overrides))
                self.assertEqual([path.name for path in self.output.iterdir()], [])
                self.assertFalse((self.output / ("v" + VERSION)).exists())

    def test_appcast_requires_the_manifest_minimum_macos(self):
        feed = self.root / "feed.xml"
        feed.write_bytes(appcast())
        row = {
            "version": VERSION,
            "build": BUILD,
            "url": ARCHIVE_URL,
            "size": len(ARCHIVE_BYTES),
        }
        with self.assertRaises(prepare.ReleaseError):
            prepare.validate_appcast(feed, row)

    def test_stale_or_dirty_stamps_are_rejected(self):
        cases = {
            "other commit": stamp(commit="b" * 40),
            "dirty tree": stamp(dirty=True),
            "debug build": stamp(configuration="debug"),
            "other version": stamp(version="0.0.1"),
            "other build": stamp(build="1"),
            "unsupported schema": stamp(schema=2),
        }
        for case, value in cases.items():
            with self.subTest(case=case):
                with self.assertRaises(prepare.ReleaseError):
                    self.prepare(verify=verifier(build_stamp=value))
                self.assertEqual([path.name for path in self.output.iterdir()], [])

    def test_packaged_identity_must_match_the_stamp_build(self):
        with self.assertRaises(prepare.ReleaseError):
            self.prepare(verify=verifier(plist={"CFBundleVersion": "1"}))

    def test_dirty_source_is_rejected_before_anything_is_written(self):
        with self.assertRaises(prepare.ReleaseError):
            self.prepare(run=Runner(status=" M Cargo.toml\n"))
        self.assertFalse(self.output.exists())

    def test_existing_release_is_not_overwritten(self):
        destination = self.output / ("v" + VERSION)
        destination.mkdir(parents=True)
        marker = destination / "release.json"
        marker.write_text("complete previous release")
        with self.assertRaises(prepare.ReleaseError):
            self.prepare()
        self.assertEqual(marker.read_text(), "complete previous release")
        self.assertEqual(
            [path.name for path in self.output.iterdir()], [destination.name]
        )

    def test_missing_inputs_fail_before_a_temporary_directory_exists(self):
        missing = [
            self.root / "build" / "Akitty-macOS.zip",
            self.root / "macos/.build/artifacts/sparkle/Sparkle/bin/generate_appcast",
            self.root / "docs" / "releases" / f"{VERSION}.md",
        ]
        for path in missing:
            with self.subTest(path=path.name):
                path.unlink()
                with self.assertRaises(prepare.ReleaseError):
                    self.prepare()
                self.assertFalse(self.output.exists())
                path.touch()

    def test_build_stamp_reader_rejects_missing_or_malformed_stamps(self):
        app = self.root / "Akitty.app"
        (app / "Contents" / "Resources").mkdir(parents=True)
        with self.assertRaises(prepare.ReleaseError):
            prepare.read_build_stamp(app)
        (app / prepare.STAMP_PATH).write_text("{")
        with self.assertRaises(prepare.ReleaseError):
            prepare.read_build_stamp(app)
        (app / prepare.STAMP_PATH).write_text(json.dumps({"schema": 2}))
        with self.assertRaises(prepare.ReleaseError):
            prepare.read_build_stamp(app)
        (app / prepare.STAMP_PATH).write_text(json.dumps(stamp()))
        self.assertEqual(prepare.read_build_stamp(app)["commit"], HEAD)


if __name__ == "__main__":
    unittest.main()
