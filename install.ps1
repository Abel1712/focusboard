# FocusBoard - create the two desktop shortcuts.
#
#   Right-click this file > "Run with PowerShell"   (or: powershell -ExecutionPolicy Bypass -File install.ps1)
#
# FocusBoard      opens index.html as its own app window, with its own browser profile (chrome-profile\),
#                 so your data stays separate from your normal browsing.
# Sync phone      starts the one-time phone sync (sync\receive.ps1). Hotkey: Ctrl+Alt+P.
param([string]$Dest = [Environment]::GetFolderPath('Desktop'))

$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path

$browser = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
             "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
             "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
             "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { throw 'Chrome or Edge is needed. Install one of them and run this again.' }

$url     = ([Uri](Join-Path $dir 'index.html')).AbsoluteUri
$profileDir = Join-Path $dir 'chrome-profile'
$shell   = New-Object -ComObject WScript.Shell

$app = $shell.CreateShortcut((Join-Path $Dest 'FocusBoard.lnk'))
$app.TargetPath = $browser
$app.Arguments = "--app=`"$url`" --user-data-dir=`"$profileDir`" --no-first-run --no-default-browser-check --disable-background-mode --window-size=1150,860"
$app.WorkingDirectory = $dir
$app.IconLocation = "$browser,0"
$app.Save()

$sync = $shell.CreateShortcut((Join-Path $Dest 'Sync phone.lnk'))
$sync.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$sync.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $dir 'sync\receive.ps1')`""
$sync.WorkingDirectory = Join-Path $dir 'sync'
$sync.Hotkey = 'CTRL+ALT+P'
$sync.Save()

Write-Host "Done. Two shortcuts are on your desktop: FocusBoard and Sync phone (Ctrl+Alt+P)."
