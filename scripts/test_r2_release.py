import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "release", Path(__file__).with_name("r2-release.py")
)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

TAG = "v0.12.0"
VERSION = "0.12.0"
BUILD = "1200"
ARCHIVE = f"AkiTTY-{VERSION}-macOS-arm64.zip"
COMMIT = "a" * 40
SIGNATURE = base64.b64encode(bytes(64)).decode()


def appcast(url, *, length, version=VERSION, build=BUILD, signature=SIGNATURE, items=1):
    entries = "".join(
        "<item>"
        f"<sparkle:version>{build}</sparkle:version>"
        f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
        f'<enclosure url="{url}" length="{length}" type="application/octet-stream"'
        f' sparkle:edSignature="{signature}"/>'
        "</item>"
        for _ in range(items)
    )
    return (
        '<?xml version="1.0"?><rss '
        'xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">'
        f"<channel><title>Akitty</title>{entries}</channel></rss>"
    ).encode()


def manifest(version=VERSION, build=BUILD, commit=COMMIT, archive=b"signed archive"):
    name = f"AkiTTY-{version}-macOS-arm64.zip"
    return {
        "schema": 1,
        "version": version,
        "build": build,
        "commit": commit,
        "platform": "macos",
        "architecture": "arm64",
        "minimum_macos": "14.0",
        "name": name,
        "url": release.object_url(TAG, name),
        "size": len(archive),
        "sha256": hashlib.sha256(archive).hexdigest(),
    }


def prepared(archive=b"signed archive"):
    """Build a consistent asset set for the current release."""
    row = manifest(archive=archive)
    files = {
        row["name"]: archive,
        "release.json": json.dumps(row).encode(),
        "appcast.xml": appcast(row["url"], length=row["size"]),
    }
    files["SHA256SUMS"] = "".join(
        hashlib.sha256(data).hexdigest() + "  " + name + "\n"
        for name, data in files.items()
    ).encode()
    return files


class Store:
    """In-memory stand-in for the conditional R2 object API."""

    def __init__(self, values=None, lose_race=False):
        self.values = dict(values or {})
        self.lose_race = lose_race
        self.requests = []

    def storage(self, key, data=None, create_only=False):
        self.requests.append((key, data, create_only))
        if data is None:
            return self.values.get(key)
        if create_only and (self.lose_race or key in self.values):
            return None
        self.values[key] = data
        return data


class CloudStub:
    def __init__(self, store):
        self.store = store

    def storage(self, key, data=None, create_only=False):
        return self.store.storage(key, data, create_only)


class DistributionTests(unittest.TestCase):
    def test_github_digest_and_publication_are_required(self):
        data = b"signed archive"
        row = {
            "tag_name": "v0.6.0",
            "draft": False,
            "prerelease": False,
            "assets": [
                {
                    "name": "app.zip",
                    "size": len(data),
                    "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
                }
            ],
        }
        release.validate_assets(row, "v0.6.0", {"app.zip": data})
        with self.assertRaises(RuntimeError):
            release.validate_assets(row, "v0.6.0", {"app.zip": b"tampered"})
        row["draft"] = True
        with self.assertRaises(RuntimeError):
            release.validate_assets(row, "v0.6.0", {"app.zip": data})

    def test_immutable_bytes_cannot_be_overwritten(self):
        store = Store({"releases/download/v0.6.0/app.zip": b"old"})
        with self.assertRaises(RuntimeError):
            release.put_verified(
                CloudStub(store), "releases/download/v0.6.0/app.zip", b"new"
            )
        self.assertEqual(store.values["releases/download/v0.6.0/app.zip"], b"old")

    def test_public_readback_failure_is_not_success(self):
        store = Store()
        with patch.object(release, "public", return_value=b"wrong"):
            with self.assertRaises(RuntimeError):
                release.put_verified(
                    CloudStub(store), "appcast.xml", b"feed", mutable=True
                )

    def test_new_immutable_objects_use_a_conditional_put(self):
        cloud = object.__new__(release.Cloudflare)
        cloud.token, cloud.account = "token", "account"
        seen = {}

        def fake_fetch(
            url, *, method="GET", data=None, headers=None, missing=False, conflict=False
        ):
            seen.update(method=method, headers=headers, conflict=conflict, data=data)
            return data

        with patch.object(release, "fetch", side_effect=fake_fetch):
            cloud.storage(
                "releases/download/v0.12.0/app.zip", b"bytes", create_only=True
            )
        self.assertEqual(seen["method"], "PUT")
        self.assertEqual(seen["headers"]["If-None-Match"], "*")
        self.assertTrue(seen["conflict"])

        with patch.object(release, "fetch", side_effect=fake_fetch):
            cloud.storage("latest.json", b"{}")
        self.assertNotIn("If-None-Match", seen["headers"])
        self.assertFalse(seen["conflict"])

    def test_lost_creation_race_is_idempotent_only_for_identical_bytes(self):
        same = Store({ARCHIVE_KEY: b"bytes"}, lose_race=True)
        with patch.object(release, "public", return_value=b"bytes"):
            release.put_verified(CloudStub(same), ARCHIVE_KEY, b"bytes")
        self.assertEqual(same.values[ARCHIVE_KEY], b"bytes")

        other = Store({ARCHIVE_KEY: b"theirs"}, lose_race=True)
        with self.assertRaises(RuntimeError):
            release.put_verified(CloudStub(other), ARCHIVE_KEY, b"bytes")
        self.assertEqual(other.values[ARCHIVE_KEY], b"theirs")

    def test_manifest_must_match_tag_and_archive(self):
        files = prepared()
        row = release.validate_manifest(TAG, VERSION, files)
        self.assertEqual(row["commit"], COMMIT)
        for field, value in [
            ("version", "0.11.0"),
            ("commit", "ABC"),
            ("name", "AkiTTY-0.12.0-macOS-x86_64.zip"),
            ("url", release.object_url("v0.11.0", ARCHIVE)),
            ("sha256", "b" * 64),
            ("size", 1),
        ]:
            tampered = dict(row, **{field: value})
            with self.subTest(field=field):
                with self.assertRaises(RuntimeError):
                    release.validate_manifest(
                        TAG,
                        VERSION,
                        dict(files, **{"release.json": json.dumps(tampered).encode()}),
                    )

    def test_manifest_commit_must_equal_the_published_tag_commit(self):
        release.validate_tag_commit({"commit": COMMIT}, COMMIT)
        with self.assertRaises(RuntimeError):
            release.validate_tag_commit({"commit": COMMIT}, "b" * 40)
        with self.assertRaises(RuntimeError):
            release.validate_tag_commit({"commit": COMMIT}, None)

    def test_tag_commit_reads_the_github_commit(self):
        with patch.object(
            release.subprocess,
            "check_output",
            return_value=json.dumps({"sha": COMMIT}).encode(),
        ):
            self.assertEqual(release.tag_commit(TAG), COMMIT)

    def test_checksums_must_cover_exactly_the_assets(self):
        names = release.asset_names(VERSION)
        files = prepared()
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            for name, data in files.items():
                (source / name).write_bytes(data)
            (source / ".DS_Store").write_bytes(b"ignored")
            release.validate_checksums(source, files, names)

            (source / "stale.zip").write_bytes(b"old")
            with self.assertRaises(RuntimeError):
                release.validate_checksums(source, files, names)
            (source / "stale.zip").unlink()

        sum_line = hashlib.sha256(files[ARCHIVE]).hexdigest()
        cases = {
            "missing entry": "".join(
                line
                for line in files["SHA256SUMS"].decode().splitlines(keepends=True)
                if ARCHIVE not in line
            ).encode(),
            "extra entry": files["SHA256SUMS"] + (sum_line + "  other.zip\n").encode(),
            "duplicate entry": files["SHA256SUMS"]
            + (sum_line + "  " + ARCHIVE + "\n").encode(),
            "wrong digest": files["SHA256SUMS"].replace(
                sum_line.encode(), b"c" * 64, 1
            ),
            "malformed line": files["SHA256SUMS"] + b"\n",
        }
        for case, sums in cases.items():
            with self.subTest(case=case):
                with tempfile.TemporaryDirectory() as directory:
                    source = Path(directory)
                    for name, data in dict(files, SHA256SUMS=sums).items():
                        (source / name).write_bytes(data)
                    with self.assertRaises(RuntimeError):
                        release.validate_checksums(
                            source, dict(files, SHA256SUMS=sums), names
                        )

    def test_appcast_must_match_the_manifest(self):
        row = manifest()
        release.validate_appcast(appcast(row["url"], length=row["size"]), row)
        cases = {
            "url": appcast(release.object_url("v0.11.0", ARCHIVE), length=row["size"]),
            "length": appcast(row["url"], length=row["size"] + 1),
            "version": appcast(row["url"], length=row["size"], version="0.11.0"),
            "build": appcast(row["url"], length=row["size"], build="1199"),
            "unsigned": appcast(row["url"], length=row["size"], signature=""),
            "short signature": appcast(
                row["url"], length=row["size"], signature="AAAA"
            ),
            "two releases": appcast(row["url"], length=row["size"], items=2),
            "not xml": b"not xml",
        }
        for case, data in cases.items():
            with self.subTest(case=case):
                with self.assertRaises(RuntimeError):
                    release.validate_appcast(data, row)

    def test_retry_accepts_only_the_identical_published_manifest(self):
        row = manifest()
        published = json.dumps(row).encode()
        release.validate_latest(published, row)
        with self.assertRaises(RuntimeError):
            release.validate_latest(published, manifest(commit="b" * 40))

    def test_latest_must_not_move_backwards(self):
        release.validate_latest(None, manifest())
        published = json.dumps({"version": VERSION, "build": BUILD}).encode()
        release.validate_latest(published, manifest(build="1201"))
        for case, existing, current in [
            ("same build", published, manifest()),
            ("lower build", published, manifest(build="1199")),
            (
                "higher version, lower build",
                published,
                manifest(version="0.13.0", build="1"),
            ),
            ("older version", published, manifest(version="0.11.0", build="1300")),
            ("non-integer build", published, manifest(build="12a")),
            (
                "non-integer published build",
                json.dumps({"version": VERSION, "build": "x"}).encode(),
                manifest(build="1300"),
            ),
            (
                "missing published build",
                json.dumps({"version": VERSION}).encode(),
                manifest(build="1300"),
            ),
            ("invalid json", b"not json", manifest(build="1300")),
            (
                "invalid version",
                json.dumps({"version": "nightly", "build": BUILD}).encode(),
                manifest(build="1300"),
            ),
        ]:
            with self.subTest(case=case):
                with self.assertRaises(RuntimeError):
                    release.validate_latest(existing, current)


ARCHIVE_KEY = f"releases/download/{TAG}/{ARCHIVE}"


if __name__ == "__main__":
    unittest.main()
