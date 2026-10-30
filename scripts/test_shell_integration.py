#!/usr/bin/env python3
"""Exercise real interactive startup hooks without reading/writing the user's rc/history."""
import base64
import os
import pathlib
import re
import shlex
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'macos/Sources/AkittyKit/Resources/shell-integration/akitty.bash'

class ShellIntegrationTests(unittest.TestCase):
    def bash(self, commands):
        with tempfile.TemporaryDirectory(prefix='akitty-shell-hooks-') as directory:
            env = dict(os.environ, HOME=directory, HISTFILE=os.path.join(directory, 'history'), HISTCONTROL='ignorespace')
            script = commands.format(source=shlex.quote(str(SCRIPT)))
            result = subprocess.run(['/bin/bash', '--noprofile', '--norc', '-i'], input=script,
                                    text=True, capture_output=True, env=env, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout

    def test_prompt_array_hooks_run_without_becoming_commands(self):
        out = self.bash('PROMPT_COMMAND=("printf HOOK_A" "printf HOOK_B")\nsource {source}\necho REAL_COMMAND\nexit\n')
        self.assertIn('HOOK_AHOOK_B', out)
        commands = [base64.b64decode(value).decode() for value in re.findall(r'\x1b\]772;([^\x07]*)\x07', out)]
        self.assertIn('echo REAL_COMMAND', commands)
        self.assertFalse(any('HOOK_' in command for command in commands), commands)

    def test_history_ignored_command_never_reports_previous_command(self):
        out = self.bash('source {source}\necho PREVIOUS_COMMAND\n echo FRESH_IGNORED\nexit\n')
        commands = [base64.b64decode(value).decode() for value in re.findall(r'\x1b\]772;([^\x07]*)\x07', out)]
        self.assertIn('echo FRESH_IGNORED', commands)
        self.assertEqual(commands.count('echo PREVIOUS_COMMAND'), 1, commands)

    def test_wrappers_preserve_user_startup_files_and_completion_status(self):
        resources = SCRIPT.parent
        resource_names = {p.name for p in resources.iterdir()}
        for shell in ['bash', 'zsh']:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory(prefix='akitty-startup-') as directory:
                home = pathlib.Path(directory)
                files = {'.zshenv': 'export AKITTY_STARTUP_ENV=yes\n',
                         '.zprofile': 'printf PROFILE\n', '.zshrc': 'printf RC\n', '.zlogin': 'printf LOGIN\n'} if shell == 'zsh' else {
                         '.bash_profile': 'printf PROFILE; source "$HOME/.bashrc"\n', '.bashrc': 'printf RC\n'}
                for name, value in files.items():
                    (home / name).write_text(value)
                env = dict(os.environ, HOME=directory, HISTFILE=str(home / 'history'),
                           AKITTY_INTEGRATION_DIR=str(resources), AKITTY_USER_ZDOTDIR=directory)
                if shell == 'zsh':
                    env['ZDOTDIR'] = str(resources)
                    argv = ['/bin/zsh', '-l', '-i']
                else:
                    argv = ['/bin/bash', '--rcfile', str(resources / 'bashrc'), '-i']
                result = subprocess.run(argv, input="printf 'HISTORY=%s\\n' \"$HISTFILE\"\nfalse\nexit 0\n", text=True,
                                        capture_output=True, env=env, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('PROFILE', result.stdout)
                self.assertIn('RC', result.stdout)
                self.assertIn('\x1b]133;D;1\x07', result.stdout)
                if shell == 'zsh':
                    self.assertIn('LOGIN', result.stdout)
                    self.assertIn('HISTORY=' + str(home / '.zsh_history'), result.stdout)
                    self.assertEqual({p.name for p in resources.iterdir()}, resource_names)
                for name, value in files.items():
                    self.assertEqual((home / name).read_text(), value)

if __name__ == '__main__':
    unittest.main()
