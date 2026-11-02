$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
if ($env:OS -ne 'Windows_NT' -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') { throw 'Windows amd64 is required' }
function Invoke-Checked {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE" }
}
Invoke-Checked -Executable cargo -Arguments @('test','--locked','-p','akitty-agent-core')
Invoke-Checked -Executable cargo -Arguments @('test','--manifest-path','linux/src-tauri/Cargo.toml','--locked','--no-default-features','--','--test-threads=1')
Invoke-Checked -Executable cargo -Arguments @('clippy','--manifest-path','linux/src-tauri/Cargo.toml','--locked','--no-default-features','--all-targets','--','-D','warnings')
Invoke-Checked -Executable npm.cmd -Arguments @('ci','--ignore-scripts','--prefix','linux')
Invoke-Checked -Executable npm.cmd -Arguments @('ci','--ignore-scripts','--prefix','windows')
Invoke-Checked -Executable npm.cmd -Arguments @('--prefix','linux','run','build')
Invoke-Checked -Executable python -Arguments @('windows/scripts/prepare.py')
Invoke-Checked -Executable python -Arguments @('windows/scripts/licenses.py')
Invoke-Checked -Executable cargo -Arguments @('build','--manifest-path','windows/src-tauri/Cargo.toml','--locked','--features','custom-protocol')
Invoke-Checked -Executable cargo -Arguments @('clippy','--manifest-path','windows/src-tauri/Cargo.toml','--locked','--features','custom-protocol','--all-targets','--','-D','warnings')
