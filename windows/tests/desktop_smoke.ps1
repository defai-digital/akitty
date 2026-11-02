# Requires tauri-driver, matching msedgedriver and Python Selenium in PATH.
param(
    [Parameter(Mandatory=$true)][string]$Application,
    [string]$Companion,
    [string]$Python = 'python',
    [string]$OutputDirectory = 'build/windows-smoke'
)
$ErrorActionPreference = 'Stop'
$applicationPath = (Resolve-Path $Application).Path
if (!$Companion) { $Companion = Join-Path (Split-Path $applicationPath -Parent) 'akitty-agent.exe' }
$companionPath = (Resolve-Path $Companion).Path
$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
& $Python "$PSScriptRoot/standard_user.py" $Python "$PSScriptRoot/run_desktop.py" --application $applicationPath --companion $companionPath --output $outputPath
if ($LASTEXITCODE -ne 0) { throw 'Installed Windows desktop smoke failed' }
