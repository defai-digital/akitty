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
            }
        )
    )
    (root / "build").mkdir()
    (root / "build" / "Akitty-macOS.zip").write_bytes(b"notarized archive")


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
        if args[:2] == ("git", "rev-parse"):
            return HEAD
        if args[:2] == ("git", "status"):
            return self.status
        if str(args[0]).endswith("generate_appcast"):
            target = Path(args[-1])
            (target / "appcast.xml").write_bytes(b"<rss/>")
            return ""
        raise AssertionError("unexpected command: " + " ".join(args))


class BrokenRunner(Runner):
    def __call__(self, *args):
        if str(args[0]).endswith("generate_appcast"):
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
