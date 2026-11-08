#!/usr/bin/env python3
"""Extract and verify App Intents metadata for the manually assembled app."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

INTENTS = {
    "NewTerminalIntent", "ShowQuickTerminalIntent", "ShowAgentOverviewIntent",
    "ListTerminalsIntent", "GetTerminalStatusIntent", "FocusTerminalIntent", "RequestCommandIntent",
}


def validate_metadata(path, preview=False):
    data = json.loads(Path(path).read_text())
    actions = data.get("actions", {})
    if not INTENTS.issubset(actions):
        raise ValueError("Siri metadata is missing AkiTTY actions")
    shortcuts = data.get("autoShortcuts", [])
    if {item.get("actionIdentifier") for item in shortcuts} != INTENTS:
        raise ValueError("Siri metadata is missing default App Shortcuts")
    for item in shortcuts:
        phrases = item.get("phraseTemplates", [])
        if not phrases or any("${applicationName}" not in phrase.get("key", "") for phrase in phrases):
            raise ValueError("Each Siri phrase must include the application name")
    if "TerminalEntity" not in data.get("entities", {}):
        raise ValueError("Siri metadata is missing terminal entities")
    if any(not actions[name].get("openAppWhenRun") for name in INTENTS):
        raise ValueError("Terminal actions must run in the foreground")
    if preview and any("com.apple.link.systemProtocol.ToolIntent" not in actions[name].get("systemProtocols", []) for name in INTENTS):
        raise ValueError("Siri preview metadata is missing tool registrations")
    return data


def tool_output(*args):
    return subprocess.check_output(args, text=True).strip()


def validate_training(data, path):
    training = Path(path).read_text()
    for shortcut in data["autoShortcuts"]:
        if "name: " + shortcut["actionIdentifier"] + "_" not in training:
            raise ValueError("Siri training is missing an action")
        for phrase in shortcut["phraseTemplates"]:
            if phrase["key"].replace("${applicationName}", "${+applicationName}") not in training:
                raise ValueError("Siri training is missing spoken phrases; check CFBundleDevelopmentRegion")


def module_constants(intermediates, module, anchor, architecture):
    # Whole-module optimization emits one *-primary file instead of a file for
    # each source. Both configurations must ship the same intent declarations.
    candidates = [p for name in [anchor, module + "-primary"]
                  for p in intermediates.rglob(name + ".swiftconstvalues")
                  if p.parent.name == architecture]
    if not candidates:
        raise ValueError("Missing Swift intent constants. Build with Xcode 27.2+ and the Swift build engine before packaging.")
    selected = max(candidates, key=lambda p: p.stat().st_mtime_ns)
    if selected.name == module + "-primary.swiftconstvalues":
        return [selected]
    return sorted(p for p in selected.parent.glob("*.swiftconstvalues") if not p.name.endswith("-primary.swiftconstvalues"))


def validate_preview_constants(files):
    tools = set()
    for path in files:
        for item in json.loads(path.read_text()):
            if "AppIntents.ToolIntent" in item.get("conformances", []):
                tools.add(item.get("typeName", "").removeprefix("AkittyKit."))
    if not INTENTS.issubset(tools):
        raise ValueError("Preview build is missing compiled Siri tool conformances; rebuild with AKITTY_SIRI_AI_PREVIEW=1")


def compile_skills(bundle, output):
    artifact = output / "Skills.skillsc"
    if artifact.exists():
        raise ValueError("Skills output already exists; use a fresh staging directory")
    checker = Path(__file__).with_name("check-siri-skills.py")
    subprocess.run([sys.executable, str(checker), "--bundle", str(bundle)], check=True)
    subprocess.run(["xcrun", "appintentsskillsprocessor", "--skillsbundle", str(bundle), "--output", str(output)], check=True)
    if not artifact.is_file() or artifact.stat().st_size == 0:
        raise ValueError("Apple's skills compiler did not produce Skills.skillsc")
    return artifact


def extract(build_dir, configuration, resources, binary, preview=False):
    root = Path(__file__).resolve().parents[1]
    # Swift's build engine emits constants as a supplemental compile output.
    # Restrict discovery to the selected configuration, never another build's
    # debug/release or index-only output. Missing metadata fails the bundle build.
    intermediates = build_dir / "out/Intermediates.noindex/Akitty.build" / configuration.capitalize()
    sdk = tool_output("xcrun", "--show-sdk-path")
    toolchain = str(Path(tool_output("xcrun", "--find", "swiftc")).parents[2])
    xcode_version = tool_output("xcodebuild", "-version").split("Build version ")[-1]
    architectures = tool_output("lipo", "-archs", str(binary)).split()
    if len(architectures) != 1:
        raise ValueError("Extract Siri metadata before assembling a universal app")
    deployment = "27.3" if preview else "14.0"
    with tempfile.TemporaryDirectory(prefix="akitty-intents-") as temporary:
        work = Path(temporary)
        outputs = []
        for module, anchor in [("AkittyKit", "SiriIntents"), ("Akitty", "AkittyShortcuts")]:
            module_values = module_constants(intermediates, module, anchor, architectures[0])
            if preview and module == "AkittyKit":
                validate_preview_constants(module_values)
            sources = work / (module + ".sources")
            constants = work / (module + ".constants")
            sources.write_text("".join(str(p) + "\n" for p in sorted((root / "macos/Sources" / module).glob("*.swift"))))
            constants.write_text("".join(str(p) + "\n" for p in module_values))
            output = work / module if module == "AkittyKit" else resources
            command = [
                "xcrun", "appintentsmetadataprocessor", "--module-name", module,
                "--output", str(output), "--toolchain-dir", toolchain,
                "--sdk-root", sdk, "--xcode-version", xcode_version,
                "--platform-family", "macOS", "--deployment-target", deployment,
                "--target-triple", architectures[0] + "-apple-macos" + deployment,
                "--source-file-list", str(sources), "--swift-const-vals-list", str(constants),
            ]
            if outputs:
                dependencies = work / "static-metadata"
                dependencies.write_text("".join(str(p) + "\n" for p in outputs))
                command += ["--static-metadata-file-list", str(dependencies)]
            subprocess.run(command, check=True)
            outputs.append(output / "Metadata.appintents/extract.actionsdata")
        data = validate_metadata(outputs[-1], preview=preview)
        # Train/validate Siri phrases against the real bundle identity, just as
        # Xcode does for an app target. Failure must stop packaging before signing.
        subprocess.run([
            "xcrun", "appintentsnltrainingprocessor", "--extracted-metadata-path", str(resources / "Metadata.appintents"),
            "--infoplist-path", str(resources.parent / "Info.plist"), "--bundle-id", "com.defai.akitty",
            "--product-path", str(resources), "--temp-dir-path", str(work / "training"),
        ], check=True)
        validate_training(data, resources / "Metadata.appintents/root.ssu.yaml")
        if preview:
            compile_skills(root / "macos/Siri/Skills.skillsbundle", resources / "Metadata.appintents")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--configuration", choices=["debug", "release"], required=True)
    parser.add_argument("--resources", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--preview", action="store_true")
    args = parser.parse_args()
    extract(args.build_dir, args.configuration, args.resources, args.binary, args.preview)
