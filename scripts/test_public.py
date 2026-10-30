import unittest
from check_public import violations
from pathlib import Path
class PublicationTests(unittest.TestCase):
    def test_private_names_are_case_insensitive_at_any_depth(self):
        for path in ['AGENTS.md','.ax-wiki/project.md','docs/Agents.md','CLAUDE.md','.internal/report.txt','.codex/config.toml','foo/.env.production','Gemini.md','native/a.zig']:
            self.assertTrue(violations(path,b''),path)
    def test_private_account_and_machine_data(self):
        for value in [b'/'+b'Users/example/private', b'user'+b'@icloud.com', b'ghp_'+b'A'*36]:
            self.assertTrue(violations('README.md',value))
    def test_public_license_exception_is_bound_to_exact_bytes(self):
        name = 'third_party/sparkle/LICENSE'
        data = (Path(__file__).resolve().parents[1] / name).read_bytes()
        self.assertEqual(violations(name, data), [])
        self.assertTrue(violations(name, data + b'changed'))
    def test_upstream_recording_exception_requires_exact_public_bytes(self):
        name = 'third_party/alacritty_terminal/tests/ref/alt_reset/alacritty.recording'
        data = (Path(__file__).resolve().parents[1] / name).read_bytes()
        self.assertEqual(violations(name, data), [])
        self.assertTrue(violations(name, data + b'changed'))
        self.assertTrue(violations(name, data + b'ghp_' + b'A' * 36))
        self.assertTrue(violations('other.recording', data))
    def test_normal_public_source_is_allowed(self):
        self.assertEqual(violations('src/main.rs',b'fn main() {}'),[])
if __name__ == '__main__': unittest.main()
