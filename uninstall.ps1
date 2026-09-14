# Uninstall the CyberStrike CLI - removes installs from upstream cyberstrike
# or the shreyas-confido fork (identical paths, identical binary name).
# Keeps user data/config and the PATH entry.
# Usage: irm https://raw.githubusercontent.com/shreyas-confido/CyberStrike/win1607-compat/uninstall.ps1 | iex

$ErrorActionPreference = "Stop"

$InstallDir = if ($env:CYBERSTRIKE_INSTALL_DIR) { $env:CYBERSTRIKE_INSTALL_DIR } else { "$env:LOCALAPPDATA\cyberstrike" }
$DataDir = if ($env:XDG_DATA_HOME) {
    Join-Path $env:XDG_DATA_HOME "cyberstrike"
} else {
    Join-Path $env:USERPROFILE ".local\share\cyberstrike"
}
$DataBinDir = Join-Path $DataDir "bin"

$proc = Get-Process cyberstrike -ErrorAction SilentlyContinue
if ($proc) {
    Write-Host "[INFO] Stopping running cyberstrike process..." -ForegroundColor Green
    $proc | Stop-Process -Force
    Start-Sleep -Milliseconds 500
}

$removed = $false
$Exe = Join-Path $InstallDir "cyberstrike.exe"
if (Test-Path $Exe) {
    Remove-Item $Exe -Force
    Write-Host "[INFO] Removed $Exe" -ForegroundColor Green
    $removed = $true
}

$Worker = Join-Path $DataBinDir "hackbrowser-worker.js"
if (Test-Path $Worker) {
    Remove-Item $Worker -Force
    Write-Host "[INFO] Removed $Worker" -ForegroundColor Green
    $removed = $true
}

if ($removed) {
    Write-Host "[INFO] CyberStrike CLI uninstalled (user data and PATH entry kept)." -ForegroundColor Green
} else {
    Write-Host "[INFO] No CyberStrike install found - nothing to remove." -ForegroundColor Yellow
}
