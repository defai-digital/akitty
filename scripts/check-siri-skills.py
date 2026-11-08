#!/usr/bin/env python3
"""Check Siri app skill sources; this does not compile or register them with Siri."""
import argparse
import json
from pathlib import Path
import re

DEFAULT_BUNDLE = Path(__file__).resolve().parents[1] / "macos/Siri/Skills.skillsbundle"
NAME = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")


def scalar(value):
    if value.startswith('"'):
        value = json.loads(value)
    elif not value or not value[0].isalnum() or ": " in value or " #" in value:
        raise ValueError("Use plain text or a JSON-quoted string for skill metadata")
    if not isinstance(value, str) or not value.strip() or any(ord(c) < 32 for c in value):
        raise ValueError("Skill metadata must be nonempty single-line text")
    return value


def validate_skill(path):
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        raise ValueError("Skill must begin with YAML frontmatter")
    try:
        end = lines.index("---", 1)
    except ValueError:
        raise ValueError("Skill frontmatter is not closed") from None
    metadata = {}
    for line in lines[1:end]:
        key, separator, value = line.partition(":")
        if not separator or key not in {"name", "description"} or key in metadata:
            raise ValueError("Only unique name and description metadata fields are supported")
        metadata[key] = scalar(value.strip())
    if set(metadata) != {"name", "description"}:
        raise ValueError("Skill needs name and description metadata")
    name = metadata["name"]
    if len(name) > 64 or not NAME.fullmatch(name) or name != path.parent.name:
        raise ValueError("Skill name must match its directory and use 1-64 lowercase letters, digits, and single hyphens")
    if len(metadata["description"]) > 1024:
        raise ValueError("Skill description exceeds 1024 characters")
    body = "\n".join(lines[end + 1:])
    if not body.strip() or len(body) > 10000:
        raise ValueError("Skill body must contain 1-10000 characters")
    return metadata


def validate_bundle(bundle):
    if bundle.is_symlink() or not bundle.is_dir() or {p.name for p in bundle.iterdir()} != {"Skills"}:
        raise ValueError("Skills bundle must contain only the Skills directory")
    skills = bundle / "Skills"
    if skills.is_symlink() or not skills.is_dir():
        raise ValueError("Skills must be a directory")
    result = []
    for folder in sorted(skills.iterdir()):
        if folder.is_symlink() or not folder.is_dir() or {p.name for p in folder.iterdir()} != {"SKILL.md"}:
            raise ValueError("Each skill directory must contain only SKILL.md")
        source = folder / "SKILL.md"
        if source.is_symlink() or not source.is_file():
            raise ValueError("Skill source must be a regular file")
        result.append(validate_skill(source))
    if not result:
        raise ValueError("Skills bundle must contain at least one skill")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=DEFAULT_BUNDLE)
    args = parser.parse_args()
    print(f"Validated {len(validate_bundle(args.bundle))} Siri app skill sources; Apple compilation is a separate step.")
