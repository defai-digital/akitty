#!/usr/bin/env python3
"""Exercise real interactive startup hooks without reading/writing the user's rc/history."""
import base64
import contextlib
import fcntl
import os
import pathlib
import pty
import re
import select
import signal
import shlex
import struct
import subprocess
import sys
import tempfile
import time
import termios
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'macos/Sources/AkittyKit/Resources/shell-integration/akitty.bash'
# The system shells by default. Point these at other builds to qualify newer versions: macOS ships bash 3.2, which
# runs only the first PROMPT_COMMAND element, so array hooks are only exercised by bash 5.1 or later.
BASH = os.environ.get('AKITTY_TEST_BASH', '/bin/bash')
ZSH = os.environ.get('AKITTY_TEST_ZSH', '/bin/zsh')
BASH_VERSION = tuple(int(part) for part in subprocess.run([BASH, '-c', 'echo ${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}'],
                                                          capture_output=True, text=True, check=True).stdout.split())

def shell_environment(home, **extra):
    # These pipe-driven checks inspect raw prompt bytes, not Readline redisplay. Inherited
    # widths and prompts can make Readline horizontally scroll away the OSC input marker.
    env = dict(os.environ, HOME=home, HISTFILE=os.path.join(home, 'history'), HISTCONTROL='ignorespace',
               TERM='dumb', COLUMNS='160', LINES='40', INPUTRC=os.devnull, PS1='test> ')
    env.update(extra)
    return env

def events(out):
    """Command text, start and end marks in the order the terminal receives them."""
    found = []
    for match in re.finditer(r'\x1b\]772;([^\x07]*)\x07|\x1b\]133;([CD][^\x07]*)\x07', out):
        found.append(base64.b64decode(match[1]).decode() if match[1] is not None else match[2])
    return found

def as_core_records(found):
    """Drops a start that repeats the running command before a prompt, as the core does: the shell restates at the
    prompt a line that PS0 or a subshell started, so that a line which ran no command still ends with a record."""
    kept, pending, active = [], None, None
    for event in found:
        if event == 'C':
            if pending is None or pending != active:
                kept += [pending, 'C'] if pending is not None else ['C']
                active = pending
            pending = None
        elif event.startswith('D;'):
            kept.append(event); active = None
        else:
            pending = event
    return kept

class ShellIntegrationTests(unittest.TestCase):
    def bash(self, commands):
        with tempfile.TemporaryDirectory(prefix='akitty-shell-hooks-') as directory:
            env = shell_environment(directory)
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

    def test_subshell_only_lines_are_recorded(self):
        # A line that is only a subshell runs no DEBUG trap in the interactive shell. Bash 4.4+ reports it from PS0;
        # older bash turns on functrace so the subshell reports it. The prompt restates such a line, so a line that
        # runs no command (a comment, a function definition) is recorded too, never as an end mark without a start.
        out = self.bash("source {source}\n(exit 7)\n( cd / && echo SUB )\n( echo A ) | cat\n (echo IGNORED_SUB)\n"
                        " echo IGNORED\n# noted\nf() {{ :; }}\nexit 0\n")
        found = events(out)
        self.assertEqual(as_core_records(found), ['(exit 7)', 'C', 'D;7', '( cd / && echo SUB )', 'C', 'D;0',
                                                  '( echo A ) | cat', 'C', 'D;0', 'echo IGNORED', 'C', 'D;0',
                                                  '# noted', 'C', 'D;0', 'f() { :; }', 'C', 'D;0', 'exit 0', 'C'])
        for index, event in enumerate(found):
            if event.startswith('D'):
                self.assertEqual(found[index - 1], 'C', f'end without start: {found}')
        started = out.index(base64.b64encode(b'( cd / && echo SUB )').decode())
        self.assertIn('SUB', out[started:out.index('\x1b]133;D;0\x07', started)], 'output falls inside the record')

    def test_functrace_reports_only_lines_not_function_or_prompt_commands(self):
        out = self.bash("source {source}\nf() {{ echo F; (echo FS); }}\nf\nPS1='$(echo P)> '\necho $( (echo X) )\n"
                        "exit 0\n")
        commands = [e for e in events(out) if e not in ('C',) and not e.startswith('D')]
        self.assertEqual(commands[-4:], ["f", "PS1='$(echo P)> '", 'echo $( (echo X) )', 'exit 0'])

    def test_wrappers_preserve_user_startup_files_and_completion_status(self):
        resources = SCRIPT.parent
        resource_names = {p.name for p in resources.iterdir()}
        for shell in ['bash', 'zsh']:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory(prefix='akitty-startup-') as directory:
                home = pathlib.Path(directory)
                files = {'.zshenv': 'export AKITTY_STARTUP_ENV=yes\n',
                         '.zprofile': 'printf PROFILE\n', '.zshrc': "printf RC; PS1='USER> '\n", '.zlogin': 'printf LOGIN\n'} if shell == 'zsh' else {
                         '.bash_profile': 'printf PROFILE; source "$HOME/.bashrc"\n', '.bashrc': 'printf RC\n'}
                for name, value in files.items():
                    (home / name).write_text(value)
                env = shell_environment(directory,
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
                    # The hooks load at the first prompt, after the user's .zshrc chose its prompt.
                    self.assertIn("USER> \x1b]133;B\x07", result.stderr)
                    self.assertTrue(result.stdout.split('LOGIN', 1)[1].startswith('\x1b]7;file://'), result.stdout)
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
            env = shell_environment(directory, AKITTY_INTEGRATION_DIR=str(resources))
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

    def test_bash_titles_name_the_directory_then_the_command(self):
        # Like Ghostty's title feature: the prompt names where the shell is (home as ~) and a running command names
        # itself. Control characters in a path are removed so the title cannot end or escape early.
        out = self.bash('source {source}\ncd "$HOME"\nmkdir -p "$(printf \'a\\033b\')/c" && cd "$(printf \'a\\033b\')/c"\necho TITLED\nexit\n')
        titles = re.findall(r'\x1b\]2;([^\x07]*)\x07', out)
        self.assertEqual(titles[0], os.getcwd(), 'the first prompt names the starting directory in full')
        self.assertEqual(titles[1:3], ['cd "$HOME"', '~'])
        self.assertEqual(titles[4:], ['~/ab/c', 'echo TITLED', '~/ab/c', 'exit'])
        # Only the home directory and what lies inside it are shortened, not a sibling that shares its prefix.
        out = self.bash('source {source}\nmkdir -p "$HOME/h" "$HOME/hh" && cd "$HOME/hh" && HOME=$HOME/h\nexit\n')
        self.assertTrue(re.findall(r'\x1b\]2;([^\x07]*)\x07', out)[2].endswith('/hh'), out)
        self.assertNotIn('\x1b]2;~h', out, 'a sibling of $HOME keeps its full path')
        self.assertNotIn('\x1b]2;', self.bash('AKITTY_SHELL_TITLE=0\nsource {source}\necho QUIET\nexit\n'), 'the opt-out emits no title')

    def test_zsh_titles_keep_the_last_three_directories(self):
        with tempfile.TemporaryDirectory(prefix='akitty-zsh-title-') as directory:
            home = pathlib.Path(directory)
            (home / '.zshrc').write_text(f'source {shlex.quote(str(SCRIPT.parent / "akitty.zsh"))}\n')
            env = shell_environment(directory, ZDOTDIR=directory)
            commands = 'cd /\nmkdir -p ~/a/b/c/d && cd ~/a/b/c/d\necho TITLED\nexit\n'
            result = subprocess.run([ZSH, '-i'], input=commands, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout)
            titles = re.findall(r'\x1b\]2;([^\x07]*)\x07', result.stdout)
            self.assertEqual(titles[1:3], ['cd /', '/'])
            self.assertEqual(titles[4:], ['…/b/c/d', 'echo TITLED', '…/b/c/d', 'exit'], 'a deep path keeps its last three directories')

    @contextlib.contextmanager
    def zsh_pty(self, home, rc='', **extra):
        """An interactive zsh on a real terminal in ~/project, with the hooks sourced after `rc`; returns send()."""
        (home / 'project').mkdir(exist_ok=True)
        (home / '.zshrc').write_text(f"PS1='P> '\n{rc}\nsource {shlex.quote(str(SCRIPT.parent / 'akitty.zsh'))}\n")
        env = shell_environment(str(home), ZDOTDIR=str(home), TERM='xterm-256color', **extra)
        pid, fd = pty.fork()
        if pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 160, 0, 0))
            os.chdir(home / 'project')
            os.execve(ZSH, [ZSH, '-i'], env)
        output = bytearray()
        def send(text, wait=0.5):
            os.write(fd, text.encode())
            deadline = time.time() + wait
            while time.time() < deadline:
                if select.select([fd], [], [], 0.05)[0]:
                    try: output.extend(os.read(fd, 65536))
                    except OSError: return
        try:
            # A fixed startup sleep can send the first command before the hosted runner's shell is ready.
            deadline = time.monotonic() + 10
            while b'P> \x1b]133;B\x07' not in output and time.monotonic() < deadline:
                send('', 0.05)
            self.assertIn(b'P> \x1b]133;B\x07', output, repr(bytes(output)))
            yield send, output
        finally:
            # Close before TemporaryDirectory removes HOME; otherwise the exit hook recreates it.
            os.close(fd)
            for termination, seconds in [(signal.SIGHUP, 2), (signal.SIGKILL, 2)]:
                try: os.kill(pid, termination)
                except ProcessLookupError: pass
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    if os.waitpid(pid, os.WNOHANG)[0]: break
                    time.sleep(0.01)
                else: continue
                break
            else: self.fail('test zsh did not exit after bounded cleanup')

    def ran(self, send, output, keys):
        """Types `keys`, then Enter, and returns what the command printed."""
        send(keys)
        output.clear()
        send('\r')
        return output.decode(errors='replace')

    def test_zsh_folder_history_saves_only_lines_zsh_keeps(self):
        with tempfile.TemporaryDirectory(prefix='akitty-zsh-folder-') as directory:
            home = pathlib.Path(directory)
            rc = "HISTORY_IGNORE='(echo ignored*)'\nfunction reject() { [[ $1 != 'echo rejected'* ]] }\nzshaddhistory_functions+=(reject)"
            with self.zsh_pty(home, rc) as (send, output):
                for line in ['echo kept', ' echo spaced', 'echo ignored', 'echo rejected', 'echo "two\nlines"']:
                    send(line + '\r')
                file = home / 'Library/Application Support/Akitty/folder-history'
                saved = [line.split('\t')[3] for line in file.read_text().splitlines()]
                self.assertEqual(saved, ['echo kept'], repr(bytes(output)))
                self.assertEqual(file.stat().st_mode & 0o777, 0o600)

    def test_zsh_tab_and_arrows_offer_this_folders_commands(self):
        with tempfile.TemporaryDirectory(prefix='akitty-zsh-folder-') as directory:
            home = pathlib.Path(directory)
            (home / 'link').symlink_to(home / 'project')
            with self.zsh_pty(home) as (send, output):
                for line in ['echo code-often', 'echo code-often', 'echo code-recent', 'echo "code-$(touch pwned)"',
                             'echo build-often', 'echo build-often', 'echo build-recent',
                             'cd ..', 'echo code-elsewhere', 'cd project']:
                    send(line + '\r')
                (home / 'project/pwned').unlink()
                output.clear(); send('echo cod\t')
                menu = output.decode(errors='replace')
                self.assertIn('Folder history:', menu)
                self.assertLess(menu.index('echo code-often'), menu.index('echo code-recent'), 'used more often ranks first')
                self.assertEqual(menu.count('echo code-often'), 1, 'each command once')
                self.assertNotIn('code-elsewhere', menu, 'only commands run in this folder')
                self.assertFalse((home / 'project/pwned').exists(), 'matching never evaluates saved command text')
                send('\x1b[B'); send('\x1b[B'); send('\r')
                self.assertIn('code-recent', self.ran(send, output, ''), 'Down twice then Enter keeps the second match')
                send('echo cod\t'); send('\x1b', 0.8)
                self.assertIn('codX', self.ran(send, output, 'X'), 'Esc restores the typed prefix')
                send('echo cod\t')
                self.assertIn('codY', self.ran(send, output, 'Y'), 'another key closes the list and is typed')
                send('echo cod\t'); send('\x03', 0.8)
                self.assertIn('after-break', self.ran(send, output, 'echo after-break'), 'Ctrl-C leaves keys working')
                self.assertIn('build-often', self.ran(send, output, 'echo bui\x1b[A'), 'Up on a prefix takes the best match')
                self.assertIn('build-recent', self.ran(send, output, 'echo bui\x1b[A\x1b[A'), 'Up again takes the next')
                self.assertIn('buiZ', self.ran(send, output, 'echo bui\x1b[A\x1b[BZ'), 'Down past the first restores the prefix')
                output.clear(); send('zzz\t')
                self.assertNotIn('Folder history:', output.decode(errors='replace'), 'Tab without a match completes as before')
                send('\x15cd ../link\r')
                output.clear(); send('echo cod\t')
                self.assertIn('echo code-often', output.decode(errors='replace'), 'a symlinked path shares the folder history')
                send('\x1b', 0.8)

    def test_zsh_folder_history_switch_turns_it_off(self):
        with tempfile.TemporaryDirectory(prefix='akitty-zsh-folder-') as directory:
            home = pathlib.Path(directory)
            with self.zsh_pty(home, AKITTY_FOLDER_HISTORY='0') as (send, output):
                send('echo code-one\r')
                output.clear(); send('echo cod\t')
                self.assertNotIn('Folder history:', output.decode(errors='replace'))
                self.assertFalse((home / 'Library/Application Support/Akitty').exists(), 'nothing is written when off')

    def test_zsh_folder_history_calls_named_hooks_once_and_respects_memory_only_lines(self):
        with tempfile.TemporaryDirectory(prefix='akitty-folder-hooks-') as directory:
            home = pathlib.Path(directory)
            rc = "function zshaddhistory() { print -r -- ${1%$'\\n'} >> \"$HOME/hook-calls\"; [[ $1 != *private* ]] || return 2; }"
            with self.zsh_pty(home, rc) as (send, output):
                send('echo visible\r'); send('echo private\r')
                calls = (home / 'hook-calls').read_text().splitlines()
                self.assertEqual(calls.count('echo visible'), 1, repr((calls, bytes(output))))
                self.assertEqual(calls.count('echo private'), 1)
                saved = (home / 'Library/Application Support/Akitty/folder-history').read_text()
                self.assertIn('echo visible', saved)
                self.assertNotIn('echo private', saved, 'status 2 permits memory history, not persistence')

    def folder_call(self, home, command):
        env = shell_environment(str(home), ZDOTDIR=str(home), AKITTY_FOLDER_HISTORY_FILE=str(home / 'folder-history'))
        return subprocess.run([ZSH, '-fic', f'source {shlex.quote(str(SCRIPT.parent / "akitty.zsh"))}; {command}'],
                              env=env, capture_output=True, text=True, timeout=6)

    def test_zsh_folder_history_does_not_write_without_its_lock(self):
        with tempfile.TemporaryDirectory(prefix='akitty-folder-lock-') as directory:
            home = pathlib.Path(directory)
            history = home / 'folder-history'; history.write_text('original\n'); history.chmod(0o600)
            lock = home / 'folder-history.lock'; lock.touch(mode=0o600)
            with lock.open('r+') as held:
                fcntl.lockf(held, fcntl.LOCK_EX)
                result = self.folder_call(home, '__akitty_folder_locked __akitty_folder_append blocked')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(history.read_text(), 'original\n')

    def test_zsh_folder_history_refuses_symlink_locks_and_public_files(self):
        with tempfile.TemporaryDirectory(prefix='akitty-folder-safety-') as directory:
            home = pathlib.Path(directory)
            history = home / 'folder-history'; history.write_text('original\n'); history.chmod(0o600)
            target = home / 'target'; target.write_text('keep\n'); target.chmod(0o600)
            lock = home / 'folder-history.lock'; lock.symlink_to(target)
            result = self.folder_call(home, '__akitty_folder_locked __akitty_folder_append blocked')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(history.read_text(), 'original\n')
            self.assertEqual(target.read_text(), 'keep\n')
            lock.unlink(); history.chmod(0o644)
            result = self.folder_call(home, '__akitty_folder_locked __akitty_folder_append blocked')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(history.read_text(), 'original\n')

    def test_zsh_folder_history_compacts_during_the_session(self):
        with tempfile.TemporaryDirectory(prefix='akitty-folder-trim-') as directory:
            home = pathlib.Path(directory)
            result = self.folder_call(home, "__akitty_folder_locked __akitty_folder_append first; "
                "for n in {1..700}; do print -r -- \"${(l:1000::x:)n}\" >> $__akitty_folder_file; done; __akitty_folder_locked __akitty_folder_append last")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertLessEqual((home / 'folder-history').stat().st_size, 524288)

    def test_zsh_folder_history_bounds_unicode_commands_in_bytes(self):
        with tempfile.TemporaryDirectory(prefix='akitty-folder-bytes-') as directory:
            home = pathlib.Path(directory)
            result = self.folder_call(home, '__akitty_folder_addhistory ' + shlex.quote('echo ' + '界' * 400 + '\n'))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((home / 'folder-history').exists(), 'the 1 KiB command bound counts UTF-8 bytes')

if __name__ == '__main__':
    unittest.main()
