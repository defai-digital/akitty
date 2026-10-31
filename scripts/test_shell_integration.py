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

    def test_prompt_array_preserves_status_between_user_hooks(self):
        out = self.bash("""PROMPT_COMMAND=("false" 'printf "HOOK_STATUS=%s\\n" "$?"')\nsource {source}\necho READY\nexit\n""")
        self.assertIn('HOOK_STATUS=1', out)
        self.assertNotIn('HOOK_STATUS=0', out, 'later prompt hooks must see the previous hook status')

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

    def app_bash(self, profile, commands):
        """Starts bash the way the app does, with `profile` as the user's login profile."""
        resources = SCRIPT.parent
        with tempfile.TemporaryDirectory(prefix='akitty-app-bash-') as directory:
            (pathlib.Path(directory) / '.bash_profile').write_text(profile)
            env = dict(os.environ, HOME=directory, HISTFILE=os.path.join(directory, 'history'), AKITTY_INTEGRATION_DIR=str(resources))
            result = subprocess.run(['/bin/bash', '--rcfile', str(resources / 'bashrc'), '-i'], input=commands + 'exit 0\n',
                                    text=True, capture_output=True, env=env, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result

    def test_existing_debug_trap_declines_quietly_only_in_the_app_wrapper(self):
        # Bash 3.2 hides the profile's trap inside sourced files, so only the first prompt can see it.
        result = self.app_bash("trap 'true' DEBUG\nPROMPT_COMMAND='echo USER_PROMPT'\n",
                               'echo "TRAP=[$(trap -p DEBUG)]"\nset | grep -c "^__akitty_quiet=" || true\n')
        self.assertIn("TRAP=[trap -- 'true' DEBUG]", result.stdout, 'the existing trap keeps ownership')
        self.assertNotIn('\x1b]133;', result.stdout + result.stderr, 'no partial integration is left behind')
        self.assertGreaterEqual(result.stdout.count('USER_PROMPT'), 3, 'the user prompt command still runs every prompt')
        self.assertNotIn('integration unavailable', result.stderr)
        self.assertIn('\n0\n', result.stdout, 'the wrapper does not leak its quiet flag')
        out = subprocess.run(['/bin/bash', '--noprofile', '--norc', '-i'], input=f"trap 'true' DEBUG\nsource {shlex.quote(str(SCRIPT))}\nexit 0\n",
                             text=True, capture_output=True, timeout=10)
        self.assertIn('integration unavailable', out.stderr, 'sourcing the hooks by hand still explains why they are off')

    def test_bash_preexec_hooks_are_joined_not_replaced(self):
        # Stands in for bash-preexec at load time: it owns PROMPT_COMMAND and installs its DEBUG trap at the first prompt.
        profile = "bash_preexec_imported=defined\npreexec_functions=()\nprecmd_functions=(user_precmd)\nPROMPT_COMMAND='echo BP_PROMPT'\n"
        result = self.app_bash(profile, 'echo "HOOKS=[${preexec_functions[*]}|${precmd_functions[*]}|$(trap -p DEBUG)]"\n'
                                        '__akitty_bp_preexec "echo one"\nfalse\n__akitty_bp_precmd\necho "ORDER=[${precmd_functions[*]}]"\n')
        self.assertIn('HOOKS=[__akitty_bp_preexec|user_precmd __akitty_bp_precmd|]', result.stdout, 'no DEBUG trap of our own')
        self.assertIn('BP_PROMPT', result.stdout, 'bash-preexec keeps PROMPT_COMMAND')
        commands = [base64.b64decode(value).decode() for value in re.findall(r'\x1b\]772;([^\x07]*)\x07', result.stdout)]
        self.assertEqual(commands, ['echo one'])
        self.assertIn('\x1b]133;C\x07', result.stdout)
        self.assertIn('\x1b]133;D;1\x07', result.stdout)
        self.assertIn('\x1b]133;B\x07', result.stderr, 'the prompt (on stderr without a terminal) still marks input start')
        self.assertIn('ORDER=[user_precmd __akitty_bp_precmd]', result.stdout, 'prompt start stays the last precmd hook')

if __name__ == '__main__':
    unittest.main()
