"""Require release signatures on every nested Mach-O, including plain CLI helpers."""

from pathlib import Path
import subprocess
import sys

TEAM = "N5ZUZDUJS6"
MACHO = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"
)}


def signature(path):
    return subprocess.check_output(
        ["codesign", "--display", "--verbose=4", str(path)],
        stderr=subprocess.STDOUT, text=True,
    )


def verify(app, inspect=signature):
    app = Path(app)
    helper = app / "Contents/MacOS/akitty-agent"
    if not helper.is_file() or not helper.stat().st_mode & 0o111:
        raise ValueError("Release bundle is missing its executable akitty-agent helper")
    found = set()
    for path in app.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as handle:
            if handle.read(4) not in MACHO:
                continue
        details = inspect(path)
        if ("Signature=adhoc" in details or "Authority=Developer ID Application:" not in details
                or f"TeamIdentifier={TEAM}\n" not in details
                or "runtime" not in details or "Timestamp=" not in details):
            raise ValueError("Nested code lacks a timestamped Developer ID runtime signature: " + str(path.relative_to(app)))
        found.add(path.relative_to(app).as_posix())
    if not {"Contents/MacOS/Akitty", "Contents/MacOS/akitty-agent"}.issubset(found):
        raise ValueError("Release app and CLI helper must be Mach-O executables")
    return len(found)


if __name__ == "__main__":
    print("Verified release signatures:", verify(sys.argv[1]), "Mach-O files")
