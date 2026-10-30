import unittest
from check_public import violations
class PublicationTests(unittest.TestCase):
    def test_private_names_are_case_insensitive_at_any_depth(self):
        for path in ['AGENTS.md','.ax-wiki/project.md','docs/Agents.md','CLAUDE.md','.internal/report.txt','.codex/config.toml','foo/.env.production','Gemini.md','native/a.zig']:
            self.assertTrue(violations(path,b''),path)
    def test_private_account_and_machine_data(self):
        for value in [b'/'+b'Users/example/private', b'user'+b'@icloud.com', b'ghp_'+b'A'*36]:
            self.assertTrue(violations('README.md',value))
    def test_normal_public_source_is_allowed(self):
        self.assertEqual(violations('src/main.rs',b'fn main() {}'),[])
if __name__ == '__main__': unittest.main()
