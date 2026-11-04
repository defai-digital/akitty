"""Build scripts must select the pinned toolchain without changing user defaults."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ToolchainTests(unittest.TestCase):
    def run_helper(self, compiler='1.99.1', distribution=False, wrong_cargo=False):
        with tempfile.TemporaryDirectory(prefix='akitty-toolchain-') as directory:
            binary = Path(directory) / 'rustc'
            binary.write_text(f'#!/bin/bash\necho "rustc {compiler} (test)"\n')
            binary.chmod(0o755)
            # Shell functions isolate discovery from the caller's installed tools.
            script = f'''
set -eu
unset RUSTUP_TOOLCHAIN
rustup() {{ echo '{binary}'; }}
rustc() {{ echo 'rustc {compiler} (test)'; }}
rustdoc() {{ :; }}
cargo() {{
    if [[ ${{RUSTUP_TOOLCHAIN:-}} == 1.99.1 || {'true' if distribution else 'false'} == true ]]; then
        echo 'cargo {'1.98.0' if wrong_cargo else '1.99.1'} (test)'
    else
        echo 'cargo 1.98.0 (different default)'
    fi
}}
'''
            if distribution:
                script += '''
command() {
    if [[ ${1:-} == -v && ${2:-} == rustup ]]; then return 1; fi
    builtin command "$@"
}
'''
            script += '''
source scripts/rust-toolchain.sh
echo "selected:${AKITTY_RUST_DISTRIBUTION}:${RUSTUP_TOOLCHAIN:-none}"
'''
            return subprocess.run(['/bin/bash', '-c', script], cwd=ROOT, text=True, capture_output=True)

    def test_rustup_selects_pinned_cargo_even_when_default_differs(self):
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('selected:false:1.99.1', result.stdout)

    def test_exact_distribution_compiler_still_works_without_rustup(self):
        result = self.run_helper(distribution=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('selected:true:none', result.stdout)

    def test_wrong_compiler_is_rejected(self):
        result = self.run_helper(compiler='1.98.0')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Rust 1.99.1 is required', result.stderr)

    def test_wrong_cargo_is_rejected(self):
        result = self.run_helper(wrong_cargo=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Cargo 1.99.1 is required', result.stderr)


if __name__ == '__main__':
    unittest.main()
