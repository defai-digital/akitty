import unittest
from check_public import message_violations, violations
from pathlib import Path
class PublicationTests(unittest.TestCase):
    def test_private_names_are_case_insensitive_at_any_depth(self):
        for path in ['AGENTS.md','.ax-wiki/project.md','docs/Agents.md','CLAUDE.md','.internal/report.txt','.codex/config.toml','foo/.env.production','Gemini.md','native/a.zig','resources/.zsh_history','nested/.bash_history']:
            self.assertTrue(violations(path,b''),path)
    def test_private_account_and_machine_data(self):
        for value in [b'/'+b'Users/example/private', b'user'+b'@icloud.com', b'ghp_'+b'A'*36]:
            self.assertTrue(violations('README.md',value))
    def test_public_license_exception_is_bound_to_exact_bytes(self):
        name = 'third_party/sparkle/LICENSE'
        data = (Path(__file__).resolve().parents[1] / name).read_bytes()
        self.assertEqual(violations(name, data), [])
        self.assertTrue(violations(name, data + b'changed'))
    def test_recordings_have_no_private_path_exception(self):
        data = b'/'+b'Users/example/private'
        self.assertTrue(violations('fixtures/terminal.recording', data))
    def test_normal_public_source_is_allowed(self):
        self.assertEqual(violations('src/main.rs',b'fn main() {}'),[])
    def test_messages_reject_real_home_directories_and_private_identities(self):
        for value in [b'such as /'+b'Users/jdoe2 for the user', b'see /'+b'home/jdoe', b'Author <x'+b'@gmail.com>', b'ghp_'+b'A'*36]:
            self.assertTrue(message_violations(value), value)
    def test_messages_allow_placeholder_home_directories(self):
        for value in [b'such as /'+b'Users/alice2 for the user alice', b'/'+b'home/runner/work', b'AutomatosX <1+automatosx@users.noreply.github.com>']:
            self.assertEqual(message_violations(value), [], value)
    def test_messages_reject_the_local_login_as_a_word(self):
        self.assertTrue(message_violations(b'for the user Jdoe9, titled ~2', (b'jdoe9',)))
        self.assertEqual(message_violations(b'xjdoe9y', (b'jdoe9',)), [])
if __name__ == '__main__': unittest.main()
