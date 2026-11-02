# AkiTTY Experimental: process-local hooks; no user profile or policy is modified.
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$global:OutputEncoding = [Console]::OutputEncoding
Import-Module PSReadLine -ErrorAction Stop
# Delegate to the installed module's entry point so PSReadLine versions choose
# their own ReadLine overload and host arguments.
$global:AkittyOriginalReadLine = (Get-Command PSConsoleHostReadLine -CommandType Function).ScriptBlock
$global:AkittyStarted = $false
$global:AkittyEsc = [char]27
function global:PSConsoleHostReadLine {
    $line = & $global:AkittyOriginalReadLine
    if ($null -ne $line) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($line)
        if ($bytes.Length -le 4096 -and $line -notmatch '[\x00-\x1f\x7f-\x9f]') {
            [Console]::Write("${global:AkittyEsc}]772;" + [Convert]::ToBase64String($bytes) + "`a")
        }
        [Console]::Write("${global:AkittyEsc}]133;C`a")
        $global:AkittyStarted = $true
    }
    return $line
}
function global:prompt {
    if ($global:AkittyStarted) {
        # PowerShell success is observed; do not invent a native process exit code.
        [Console]::Write("${global:AkittyEsc}]133;D`a")
        $global:AkittyStarted = $false
    }
    if ($PWD.Provider.Name -eq 'FileSystem') {
        $uri = [Uri]::new($PWD.ProviderPath).AbsoluteUri
        [Console]::Write("${global:AkittyEsc}]7;$uri`a")
        [Console]::Write("${global:AkittyEsc}]133;A`a")
    }
    "PS $($PWD.Path)> ${global:AkittyEsc}]133;B`a"
}
$ErrorActionPreference = 'Continue'
