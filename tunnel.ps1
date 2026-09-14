# CyberStrike remote tunnel - exposes `cyberstrike serve` on this box over the
# team ngrok account at https://cyberstrike-bhc.ngrok.app, with HTTP Basic auth
# enforced at BOTH the ngrok edge and the cyberstrike server (same credential,
# one header). The server detects proxied requests via X-Forwarded-For and
# requires the password even though the tunnel agent connects from loopback.
#
# One-time setup on the box (then open a NEW PowerShell window):
#   [Environment]::SetEnvironmentVariable("NGROK_AUTHTOKEN","<scoped token>","User")
#   [Environment]::SetEnvironmentVariable("CYBERSTRIKE_TUNNEL_PASSWORD","<password>","User")
#
# Run whenever the box is awake (first run also downloads ngrok.exe, bundled as
# a fork release asset):
#   [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/shreyas-confido/CyberStrike/win1607-compat/tunnel.ps1 | iex
#
# Then from any machine:
#   curl -u cyberstrike:<password> https://cyberstrike-bhc.ngrok.app/session/ingest -d '{"text":"hello"}'
#
# Stop: close the two spawned PowerShell windows (server + tunnel).

$ErrorActionPreference = "Stop"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

$InstallDir = if ($env:CYBERSTRIKE_INSTALL_DIR) { $env:CYBERSTRIKE_INSTALL_DIR } else { "$env:LOCALAPPDATA\cyberstrike" }
$Domain = "cyberstrike-bhc.ngrok.app"
$Port = 4096
$Exe = Join-Path $InstallDir "cyberstrike.exe"

function Write-Info { param($Message) Write-Host "[INFO] $Message" -ForegroundColor Green }
function Write-Err { param($Message) Write-Host "[ERROR] $Message" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $Exe)) {
    Write-Err "cyberstrike.exe not found at $Exe - run install.ps1 first"
}
if (-not $env:NGROK_AUTHTOKEN) {
    Write-Err "NGROK_AUTHTOKEN not set. One-time: [Environment]::SetEnvironmentVariable('NGROK_AUTHTOKEN','<token>','User'), then open a new PowerShell."
}

$Password = $env:CYBERSTRIKE_TUNNEL_PASSWORD
if (-not $Password) {
    Write-Err "CYBERSTRIKE_TUNNEL_PASSWORD not set. One-time: [Environment]::SetEnvironmentVariable('CYBERSTRIKE_TUNNEL_PASSWORD','<password>','User'), then open a new PowerShell."
}

$Ngrok = Join-Path $InstallDir "ngrok.exe"
if (-not (Test-Path $Ngrok)) {
    Write-Info "Downloading ngrok.exe from the fork release..."
    Invoke-WebRequest -Uri "https://github.com/shreyas-confido/CyberStrike/releases/latest/download/ngrok.exe" -OutFile $Ngrok -UseBasicParsing
}

# Install the `cyberstrike-tunnel` command (same dir as cyberstrike.exe, already on PATH)
$Shim = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/shreyas-confido/CyberStrike/win1607-compat/tunnel.ps1 | iex"
'@
Set-Content -Path (Join-Path $InstallDir "cyberstrike-tunnel.cmd") -Value $Shim
Write-Info "Command installed: type 'cyberstrike-tunnel' any time to spin up the stack"

# Child windows inherit this, so the server enforces the same credential remotely
$env:CYBERSTRIKE_SERVER_PASSWORD = $Password

Write-Info "Starting cyberstrike serve (window 1) and ngrok tunnel (window 2)..."

$serverCmd = "& '$Exe' serve --port $Port"
$ngrokCmd = "& '$Ngrok' http $Port --url=$Domain --authtoken $env:NGROK_AUTHTOKEN --basic-auth cyberstrike:$Password"

Start-Process powershell -ArgumentList @("-NoExit", "-Command", $serverCmd)
Start-Process powershell -ArgumentList @("-NoExit", "-Command", $ngrokCmd)

Start-Sleep -Seconds 4

Write-Host ""
Write-Info "Remote URL:  https://$Domain"
Write-Info "Auth:        HTTP Basic, user 'cyberstrike' + your CYBERSTRIKE_TUNNEL_PASSWORD"
Write-Host ""
Write-Host "  TUI from another machine (opencode attach):" -ForegroundColor Cyan
Write-Host "    opencode attach https://$Domain -u cyberstrike -p <password>" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Or plain API:" -ForegroundColor Cyan
Write-Host "    curl -u cyberstrike:<password> https://$Domain/session/ingest -d '{`"text`":`"hello`"}'" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Stop by closing the two spawned windows." -ForegroundColor Cyan
