#!/usr/bin/env python3
"""Freeze and verify a notarized package, then sign its Sparkle update feed."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import tomllib
import xml.etree.ElementTree as ElementTree

ROOT = Path(__file__).resolve().parents[1]
STAMP_PATH = Path("Contents/Resources/akitty-build.json")
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"

# The packaged identity must agree with the checked-in plist.
IDENTITY_KEYS = [
    "CFBundleIdentifier",
    "CFBundleVersion",
    "CFBundleShortVersionString",
    "SUPublicEDKey",
    "SUFeedURL",
    "SURequireSignedFeed",
]


class ReleaseError(Exception):
    """A release that must not be prepared."""


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def read_build_stamp(app):
    path = app / STAMP_PATH
    if not path.is_file():
        raise ReleaseError("Packaged app has no build stamp; rebuild and notarize it")
    try:
        stamp = json.loads(path.read_text())
    except json.JSONDecodeError:
        raise ReleaseError("Packaged app build stamp is not valid JSON") from None
    if not isinstance(stamp, dict) or stamp.get("schema") != 1:
        raise ReleaseError("Packaged app build stamp is unsupported")
    return stamp


def validate_build_stamp(stamp, *, commit, version, build):
    if stamp.get("schema") != 1:
        raise ReleaseError("Packaged app build stamp is unsupported")
    if stamp.get("commit") != commit:
        raise ReleaseError("Packaged app was built from a different commit than HEAD")
    if stamp.get("dirty") is not False:
        raise ReleaseError("Packaged app was built from a dirty tree")
    if stamp.get("configuration") != "release":
        raise ReleaseError("Packaged app is not a release build")
    if stamp.get("version") != version or str(stamp.get("build")) != str(build):
        raise ReleaseError("Packaged app version differs from its build stamp")


def verify_package(archive, expected, version, private, run=run):
    """Extract, verify and identify a notarized archive; return plist and stamp."""
    private.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="verify-release-", dir=private) as temp:
        run("ditto", "-x", "-k", str(archive), temp)
        app = Path(temp) / "Akitty.app"
        actual = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        stamp = read_build_stamp(app)
        for key in IDENTITY_KEYS:
            if actual.get(key) != expected.get(key):
                raise ReleaseError("Packaged identity differs from source: " + key)
        if actual["CFBundleShortVersionString"] != version:
            raise ReleaseError("Package and workspace versions differ")
        run("codesign", "--verify", "--deep", "--strict", str(app))
        run("spctl", "--assess", "--type", "execute", str(app))
        run("xcrun", "stapler", "validate", str(app))
        if run("lipo", "-archs", str(app / "Contents/MacOS/Akitty")) != "arm64":
            raise ReleaseError("This release lane expects an Apple Silicon package")
        return actual, stamp


def validate_account_key(tools, key_account, expected, run=run):
    """The signing account must be the identity Info.plist publishes."""
    try:
        actual = run(str(tools / "generate_keys"), "--account", key_account, "-p")
    except (OSError, subprocess.CalledProcessError):
        raise ReleaseError("Cannot read the Sparkle signing account") from None
    if not actual or actual.strip() != expected.get("SUPublicEDKey"):
        raise ReleaseError("Sparkle account key differs from Info.plist SUPublicEDKey")


def appcast_signature(path):
    """Extract the single enclosure signature generate_appcast produced."""
    path = Path(path)
    if not path.is_file():
        raise ReleaseError("generate_appcast produced no appcast.xml")
    try:
        root = ElementTree.fromstring(path.read_bytes())
    except ElementTree.ParseError:
        raise ReleaseError("Generated appcast.xml is not valid XML") from None
    items = root.findall("./channel/item")
    if len(items) != 1:
        raise ReleaseError("Generated appcast.xml must describe exactly one release")
    enclosures = items[0].findall("enclosure")
    if len(enclosures) != 1:
        raise ReleaseError("Generated appcast.xml must publish exactly one enclosure")
    signature = enclosures[0].get(SPARKLE + "edSignature") or ""
    if not signature:
        raise ReleaseError("Generated appcast.xml is not signed")
    return signature


def validate_appcast(path, manifest):
    """The generated feed must describe the release.json manifest being published."""
    path = Path(path)
    if not path.is_file():
        raise ReleaseError("generate_appcast produced no appcast.xml")
    try:
        root = ElementTree.fromstring(path.read_bytes())
    except ElementTree.ParseError:
        raise ReleaseError("Generated appcast.xml is not valid XML") from None
    items = root.findall("./channel/item")
    if len(items) != 1:
        raise ReleaseError("Generated appcast.xml must describe exactly one release")
    item = items[0]
    enclosures = item.findall("enclosure")
    if len(enclosures) != 1:
        raise ReleaseError("Generated appcast.xml must publish exactly one enclosure")
    enclosure = enclosures[0]
    if (item.findtext(SPARKLE + "shortVersionString") or "") != manifest["version"]:
        raise ReleaseError(
            "Generated appcast.xml shortVersionString differs from release.json"
        )
    if (item.findtext(SPARKLE + "version") or "") != str(manifest["build"]):
        raise ReleaseError("Generated appcast.xml version differs from release.json")
    if (enclosure.get("url") or "") != manifest["url"]:
        raise ReleaseError(
            "Generated appcast.xml enclosure URL differs from release.json"
        )
    if (enclosure.get("length") or "") != str(manifest["size"]):
        raise ReleaseError(
            "Generated appcast.xml enclosure length differs from release.json"
        )
    minimum = manifest.get("minimum_macos")
    if not minimum:
        raise ReleaseError("release.json has no minimum_macos")
    if (item.findtext(SPARKLE + "minimumSystemVersion") or "") != minimum:
        raise ReleaseError(
            "Generated appcast.xml minimumSystemVersion differs from release.json"
        )


def verify_appcast_signature(tools, key_account, archive, signature, run=run):
    """Sparkle must verify the feed signature with the release account key."""
    try:
        run(
            str(tools / "sign_update"),
            "--account",
            key_account,
            "--verify",
            str(archive),
            signature,
        )
    except (OSError, subprocess.CalledProcessError):
        raise ReleaseError(
            "Appcast signature does not verify with the signing account"
        ) from None


def prepare(
    key_account,
    *,
    root=ROOT,
    head=None,
    run=run,
    verify=verify_package,
    output_root=None,
):
    """Build release assets in a sibling temporary directory, then publish them."""
    version = tomllib.loads((root / "Cargo.toml").read_text())["workspace"]["package"][
        "version"
    ]
    source = root / "build" / "Akitty-macOS.zip"
    notes = root / "docs" / "releases" / f"{version}.md"
    tools = root / "macos" / ".build" / "artifacts" / "sparkle" / "Sparkle" / "bin"
    if not source.is_file():
        raise ReleaseError("Build and notarize the release app before preparing assets")
    if not notes.is_file():
        raise ReleaseError(f"Missing release notes: docs/releases/{version}.md")
    if not (tools / "generate_appcast").is_file():
        raise ReleaseError("Sparkle tools are missing; build the Swift package first")
    if head is None:
        try:
            head = run("git", "rev-parse", "HEAD")
        except subprocess.CalledProcessError:
            raise ReleaseError("Cannot resolve the release commit") from None
    if run("git", "status", "--porcelain"):
        raise ReleaseError(
            "Commit and verify the complete release source before preparing assets"
        )
    parent = (
        Path(output_root) if output_root is not None else root / "build" / "release"
    )
    parent.mkdir(parents=True, exist_ok=True)
    destination = parent / ("v" + version)
    if destination.exists():
        raise ReleaseError(
            "Release assets already exist at "
            + str(destination)
            + "; remove them to prepare again"
        )
    # Same parent as the destination keeps the final rename on one filesystem, and
    # a failure discards only this temporary directory so a retry can start over.
    work = Path(tempfile.mkdtemp(prefix="." + destination.name + ".tmp.", dir=parent))
    try:
        name = f"AkiTTY-{version}-macOS-arm64.zip"
        archive = work / name
        shutil.copyfile(source, archive)
        expected = plistlib.loads((root / "macos" / "Info.plist").read_bytes())
        actual, stamp = verify(archive, expected, version, root / ".internal", run=run)
        validate_build_stamp(
            stamp,
            commit=head,
            version=version,
            build=actual.get("CFBundleVersion"),
        )
        validate_account_key(tools, key_account, expected, run=run)
        prefix = f"https://download.automatosx.com/akitty/releases/download/v{version}/"
        shutil.copyfile(notes, archive.with_suffix(".md"))
        run(
            str(tools / "generate_appcast"),
            "--account",
            key_account,
            "--maximum-deltas",
            "0",
            "--embed-release-notes",
            "--download-url-prefix",
            prefix,
            "--link",
            "https://github.com/defai-digital/akitty",
            str(work),
        )
        verify_appcast_signature(
            tools,
            key_account,
            archive,
            appcast_signature(work / "appcast.xml"),
            run=run,
        )
        archive.with_suffix(".md").unlink()
        content = archive.read_bytes()
        manifest = {
            "schema": 1,
            "version": version,
            "build": actual["CFBundleVersion"],
            "commit": head,
            "platform": "macos",
            "architecture": "arm64",
            "minimum_macos": "14.0",
            "name": name,
            "url": prefix + name,
            "size": len(content),
            "sha256": hashlib.sha256(content).hexdigest(),
        }
        validate_appcast(work / "appcast.xml", manifest)
        (work / "release.json").write_text(json.dumps(manifest, indent=2) + "\n")
        checksums = []
        for file in [archive, work / "release.json", work / "appcast.xml"]:
            checksums.append(
                hashlib.sha256(file.read_bytes()).hexdigest() + "  " + file.name
            )
        (work / "SHA256SUMS").write_text("\n".join(checksums) + "\n")
        if destination.exists():
            raise ReleaseError(
                "Release assets appeared at "
                + str(destination)
                + "; remove them to prepare again"
            )
        work.rename(destination)
    except BaseException:
        shutil.rmtree(work, ignore_errors=True)
        raise
    try:
        shown = destination.relative_to(root)
    except ValueError:
        shown = destination
    print("Prepared verified release:", shown)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key-account", default="akitty")
    args = parser.parse_args()
    try:
        prepare(args.key_account)
    except ReleaseError as error:
        raise SystemExit(str(error))


if __name__ == "__main__":
    main()
