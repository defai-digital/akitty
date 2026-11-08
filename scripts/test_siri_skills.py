import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("siri_skills", Path(__file__).with_name("check-siri-skills.py"))
skills = importlib.util.module_from_spec(spec)
spec.loader.exec_module(skills)


class SiriSkillTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.bundle = Path(self.temporary.name) / "Skills.skillsbundle"
        self.folder = self.bundle / "Skills/inspect-terminal"
        self.folder.mkdir(parents=True)
        self.source = self.folder / "SKILL.md"
        self.write()

    def write(self, name="inspect-terminal", description="Inspect a terminal.", body="Get its current status."):
        self.source.write_text(f"---\nname: {name}\ndescription: {description}\n---\n{body}", encoding="utf-8")

    def test_repository_skills_and_valid_bundle(self):
        self.assertEqual(len(skills.validate_bundle(skills.DEFAULT_BUNDLE)), 2)
        self.assertEqual(skills.validate_bundle(self.bundle)[0]["name"], "inspect-terminal")

    def test_invalid_names_and_directory_mismatches(self):
        for name in ["Inspect-terminal", "inspect--terminal", "-terminal", "terminal-", "other", "x" * 65]:
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.write(name=name); skills.validate_bundle(self.bundle)

    def test_metadata_fields_and_frontmatter(self):
        original = self.source.read_text()
        for content in [original.lstrip("-\n"), original.replace("\n---\nGet", "\nGet"),
                        original.replace("description:", "unsupported:"),
                        original.replace("description:", "name: duplicate\ndescription:")]:
            with self.subTest(content=content), self.assertRaises(ValueError):
                self.source.write_text(content); skills.validate_bundle(self.bundle)

    def test_size_boundaries_and_single_line_descriptions(self):
        self.write(description="x" * 1024, body="x" * 10000)
        skills.validate_bundle(self.bundle)
        for description, body in [("x" * 1025, "body"), ("valid", "x" * 10001), ("valid", ""),
                                  ('"line\\nbreak"', "body"), ('"unterminated', "body")]:
            with self.subTest(description=description[:20]), self.assertRaises(ValueError):
                self.write(description=description, body=body); skills.validate_bundle(self.bundle)

    def test_extra_files_and_symlinks_are_rejected(self):
        extra = self.folder / "instructions.txt"
        extra.write_text("extra")
        with self.assertRaisesRegex(ValueError, "only SKILL.md"):
            skills.validate_bundle(self.bundle)
        extra.unlink()
        original = self.source.read_text()
        self.source.unlink()
        target = Path(self.temporary.name) / "outside.md"; target.write_text(original)
        self.source.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "regular file"):
            skills.validate_bundle(self.bundle)


if __name__ == "__main__":
    unittest.main()
