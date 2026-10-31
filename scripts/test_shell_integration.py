#!/usr/bin/env python3
"""Exercise real interactive startup hooks without reading/writing the user's rc/history."""
import base64
import os
import pathlib
import re
import shlex
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'macos/Sources/AkittyKit/Resources/shell-integration/akitty.bash'
# The system shells by default. Point these at other builds to qualify newer versions: macOS ships bash 3.2, which
# runs only the first PROMPT_COMMAND element, so array hooks are only exercised by bash 5.1 or later.
BASH = os.environ.get('AKITTY_TEST_BASH', '/bin/bash')
ZSH = os.environ.get('AKITTY_TEST_ZSH', '/bin/zsh')
BASH_VERSION = tuple(int(part) for part in subprocess.run([BASH, '-c', 'echo ${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}'],
                                                          capture_output=True, text=True, check=True).stdout.split())

def events(out):
    """Command text, start and end marks in the order the terminal receives them."""
    found = []
    for match in re.finditer(r'\x1b\]772;([^\x07]*)\x07|\x1b\]133;([CD][^\x07]*)\x07', out):
        found.append(base64.b64decode(match[1]).decode() if match[1] is not None else match[2])
    return found

class ShellIntegrationTests(unittest.TestCase):
    def bash(self, commands):
        with tempfile.TemporaryDirectory(prefix='akitty-shell-hooks-') as directory:
            env = dict(os.environ, HOME=directory, HISTFILE=os.path.join(directory, 'history'), HISTCONTROL='ignorespace')
            script = commands.format(source=shlex.quote(str(SCRIPT)))
            # Prompts, PS0 included, go to stderr; one pipe keeps their marks in order with command output.
            result = subprocess.run([BASH, '--noprofile', '--norc', '-i'], input=script, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout)
            return result.stdout

    def test_prompt_array_hooks_run_without_becoming_commands(self):
        out = self.bash('PROMPT_COMMAND=("printf HOOK_A" "printf HOOK_B")\nsource {source}\necho REAL_COMMAND\nexit\n')
        self.assertIn('HOOK_AHOOK_B', out)
        # Readline echoes the typed input on stderr; count only what the hooks print.
        ran = re.sub(r'printf HOOK_', '', out)
        self.assertEqual(ran.count('HOOK_B'), ran.count('HOOK_AHOOK_B'), 'each hook runs once per prompt, in order')
        commands = [base64.b64decode(value).decode() for value in re.findall(r'\x1b\]772;([^\x07]*)\x07', out)]
        self.assertIn('echo REAL_COMMAND', commands)
        self.assertFalse(any('HOOK_' in command for command in commands), commands)

    def test_prompt_hooks_added_after_startup_never_become_commands(self):
        # Re-sourced rc files and lazily loaded tools append to PROMPT_COMMAND after the hooks are installed.
        cases = {'array': 'PROMPT_COMMAND+=("printf LATE")', 'string': 'PROMPT_COMMAND+="; printf LATE"',
                 'prepended': 'PROMPT_COMMAND="printf LATE;$PROMPT_COMMAND"'}
        for name, append in cases.items():
            with self.subTest(name):
                out = self.bash('source {source}\n' + append + '\necho AFTER\necho AGAIN\nexit\n')
                commands = [base64.b64decode(value).decode() for value in re.findall(r'\x1b\]772;([^\x07]*)\x07', out)]
                self.assertEqual(commands, [append, 'echo AFTER', 'echo AGAIN', 'exit'])
                # Bash runs (or, before 5.1, ignores) a new array element itself on the prompt that adds it.
                after = out.split('\x1b]772;' + base64.b64encode(b'echo AFTER').decode())[1]
                self.assertEqual(after.count('LATE'), 2, 'the added hook runs once on each later prompt')

    def test_prompt_array_hooks_each_see_the_command_status(self):
        # Bash 5.1+ gives every PROMPT_COMMAND element the last command's status, not the previous element's.
        out = self.bash("""PROMPT_COMMAND=("(exit 3)" 'printf "HOOK_STATUS=%s\\n" "$?"')\nsource {source}\nsh -c 'exit 7'\nexit 0\n""")
        self.assertIn('HOOK_STATUS=7', out.split('\x1b]133;D;7\x07')[1], 'a later hook sees the command status')
        self.assertNotIn('HOOK_STATUS=3', out, 'a hook never sees the status left by the hook before it')

    def test_hooks_preserve_user_regex_captures_between_commands(self):
        out = self.bash("source {source}\n[[ alphabeta =~ (alpha)(beta) ]]\nprintf 'MATCH=[%s|%s|%s]\\n' \"${{BASH_REMATCH[0]}}\" \"${{BASH_REMATCH[1]}}\" \"${{BASH_REMATCH[2]}}\"\nexit\n")
        self.assertIn('MATCH=[alphabeta|alpha|beta]', out)
        out = self.bash("source {source}\n[[ alphabeta =~ (missing) ]]\nprintf 'CAPTURES=%s\\n' \"${{#BASH_REMATCH[@]}}\"\nexit\n")
        self.assertIn('CAPTURES=0', out)

    def test_history_ignored_command_never_reports_previous_command(self):
        out = self.bash('source {source}\necho PREVIOUS_COMMAND\n echo FRESH_IGNORED\nexit\n')
        commands = [base64.b64decode(value).decode() for value in re.findall(r'\x1b\]772;([^\x07]*)\x07', out)]
        self.assertIn('echo FRESH_IGNORED', commands)
        self.assertEqual(commands.count('echo PREVIOUS_COMMAND'), 1, commands)

    def test_subshell_only_lines_are_recorded_from_bash_4_4(self):
        # A line that is only a subshell runs no DEBUG trap in the interactive shell; bash 4.4+ PS0 still sees it.
        out = self.bash("source {source}\n(exit 7)\n( cd / && echo SUB )\n echo IGNORED\nexit 0\n")
        if BASH_VERSION < (4, 4):
            self.assertEqual(events(out), [' echo IGNORED'.strip(), 'C', 'D;0', 'exit 0', 'C'], 'documented limitation')
            return
        self.assertEqual(events(out), ['(exit 7)', 'C', 'D;7', '( cd / && echo SUB )', 'C', 'D;0',
                                       'echo IGNORED', 'C', 'D;0', 'exit 0', 'C'])
        started = out.index(base64.b64encode(b'( cd / && echo SUB )').decode())
        self.assertIn('SUB', out[started:out.index('\x1b]133;D;0\x07', started)], 'output falls inside the record')

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
                    argv = [ZSH, '-l', '-i']
                else:
                    argv = [BASH, '--rcfile', str(resources / 'bashrc'), '-i']
                result = subprocess.run(argv, input="printf 'HISTORY=%s\\n' \"$HISTFILE\"\nfalse\nexit 0\n", text=True,
                                        capture_output=True, env=env, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('PROFILE', result.stdout)
                self.assertIn('RC', result.stdout)
                self.assertIn('\x1b]133;D;1\x07', result.stdout)
                if shell == 'zsh':
                    self.assertIn('LOGIN', result.stdout)
                    if sys.platform == 'darwin':
                        # macOS /etc/zshrc chooses $ZDOTDIR/.zsh_history; other systems leave HISTFILE to the user.
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
            result = subprocess.run([BASH, '--rcfile', str(resources / 'bashrc'), '-i'], input=commands + 'exit 0\n',
                                    text=True, capture_output=True, env=env, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result

    def test_existing_debug_trap_declines_quietly_only_in_the_app_wrapper(self):
        # Bash 3.2 hides the profile's trap inside sourced files, so only the first prompt can see it.
        result = self.app_bash("trap 'true' DEBUG\nPROMPT_COMMAND='echo USER_PROMPT'\n",
                               'echo "TRAP=[$(trap -p DEBUG)]"\nset | grep -c "^__akitty_quiet=" || true\n'
                               'echo "PS0=[${PS0-unset}]"\n')
        self.assertIn("TRAP=[trap -- 'true' DEBUG]", result.stdout, 'the existing trap keeps ownership')
        self.assertIn('PS0=[unset]', result.stdout, 'a declined integration leaves no PS0 behind')
        self.assertNotIn('\x1b]133;', result.stdout + result.stderr, 'no partial integration is left behind')
        self.assertGreaterEqual(result.stdout.count('USER_PROMPT'), 3, 'the user prompt command still runs every prompt')
        self.assertNotIn('integration unavailable', result.stderr)
        self.assertIn('\n0\n', result.stdout, 'the wrapper does not leak its quiet flag')
        out = subprocess.run([BASH, '--noprofile', '--norc', '-i'], input=f"trap 'true' DEBUG\nsource {shlex.quote(str(SCRIPT))}\nexit 0\n",
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
