import copy
import importlib.util
from pathlib import Path
import tempfile
import json
import os
import unittest

spec = importlib.util.spec_from_file_location("siri_metadata", Path(__file__).with_name("build-siri-metadata.py"))
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


class SiriMetadataTests(unittest.TestCase):
    def fixture(self):
        return {
            "actions": {name: {"openAppWhenRun": True} for name in metadata.INTENTS},
            "autoShortcuts": [{"actionIdentifier": name, "phraseTemplates": [{"key": "Action in ${applicationName}"}]} for name in sorted(metadata.INTENTS)],
            "entities": {"TerminalEntity": {}},
        }

    def validate(self, value):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "extract.actionsdata"
            path.write_text(json.dumps(value))
            return metadata.validate_metadata(path)

    def test_actions_without_library_shortcuts_fail_packaging(self):
        data = self.fixture()
        self.validate(data)
        data["autoShortcuts"] = []
        with self.assertRaisesRegex(ValueError, "default App Shortcuts"):
            self.validate(data)

    def test_missing_actions_entities_and_foreground_fail_packaging(self):
        original = self.fixture()
        for field in ["actions", "entities"]:
            data = copy.deepcopy(original); data[field] = {}
            with self.assertRaises(ValueError):
                self.validate(data)
        data = copy.deepcopy(original)
        data["actions"]["RequestCommandIntent"]["openAppWhenRun"] = False
        with self.assertRaisesRegex(ValueError, "foreground"):
            self.validate(data)

    def test_phrase_without_application_name_fails_packaging(self):
        data = self.fixture()
        data["autoShortcuts"][0]["phraseTemplates"] = [{"key": "Run a command"}]
        with self.assertRaisesRegex(ValueError, "application name"):
            self.validate(data)

    def test_empty_phrase_training_fails_even_when_actions_exist(self):
        data = self.fixture()
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "root.ssu.yaml"
            path.write_text("\n".join("name: " + name + "_0\ntraining: []" for name in sorted(metadata.INTENTS)))
            with self.assertRaisesRegex(ValueError, "spoken phrases"):
                metadata.validate_training(data, path)
            path.write_text(path.read_text() + "\nAction in ${+applicationName}")
            metadata.validate_training(data, path)

    def test_debug_and_whole_module_release_constants(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            for module, anchor in [("AkittyKit", "SiriIntents"), ("Akitty", "AkittyShortcuts")]:
                objects = root / (module + ".build/Objects-normal/arm64")
                objects.mkdir(parents=True)
                per_file = objects / (anchor + ".swiftconstvalues")
                primary = objects / (module + "-primary.swiftconstvalues")
                per_file.write_text("[]")
                self.assertEqual(metadata.module_constants(root, module, anchor, "arm64"), [per_file])
                primary.write_text("[]")
                os.utime(primary, ns=(per_file.stat().st_mtime_ns + 1, per_file.stat().st_mtime_ns + 1))
                self.assertEqual(metadata.module_constants(root, module, anchor, "arm64"), [primary])
                with self.assertRaisesRegex(ValueError, "Missing Swift intent constants"):
                    metadata.module_constants(root, module, anchor, "x86_64")


if __name__ == "__main__":
    unittest.main()
