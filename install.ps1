# CyberStrike CLI Installer for Windows - shreyas-confido fork (Win10 1607 / Server 2016 compatible)
# Usage (the TLS 1.2 prefix is required on PS 5.1: it negotiates TLS 1.0 for the
# initial fetch and GitHub rejects it, so the script cannot fix this itself):
#   [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/shreyas-confido/CyberStrike/win1607-compat/install.ps1 | iex
# Fully automatic: removes any previous install (upstream or fork), installs,
# updates PATH if needed, and verifies the binary launches.
# Install upstream instead of the fork: $env:CYBERSTRIKE_REPO = "CyberStrikeus/CyberStrike"; then run the same command.

$ErrorActionPreference = "Stop"

# Windows PowerShell 5.1 negotiates TLS 1.0/1.1 by default, which the GitHub
# API and release CDN reject — the version check then fails silently and the
# install aborts with "Failed to fetch version information". Force TLS 1.2.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

$Repo = if ($env:CYBERSTRIKE_REPO) { $env:CYBERSTRIKE_REPO } else { "shreyas-confido/CyberStrike" }
$InstallDir = if ($env:CYBERSTRIKE_INSTALL_DIR) { $env:CYBERSTRIKE_INSTALL_DIR } else { "$env:LOCALAPPDATA\cyberstrike" }
$Beta = $env:CYBERSTRIKE_BETA -eq "1"

# Cyberstrike runtime data dir - matches xdg-basedir behavior used by the
# binary internally (Global.Path.data). xdg-basedir falls back to
# os.homedir()/.local/share on all platforms (no Windows-specific path),
# so the same logic must be mirrored here.
$DataDir = if ($env:XDG_DATA_HOME) {
    Join-Path $env:XDG_DATA_HOME "cyberstrike"
} else {
    Join-Path $env:USERPROFILE ".local\share\cyberstrike"
}
$DataBinDir = Join-Path $DataDir "bin"

function Write-Info { param($Message) Write-Host "[INFO] $Message" -ForegroundColor Green }
function Write-Warn { param($Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Err { param($Message) Write-Host "[ERROR] $Message" -ForegroundColor Red; exit 1 }

function Get-Architecture {
    if ([Environment]::Is64BitOperatingSystem) {
        if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
            return "arm64"
        }
        return "x64"
    }
    Write-Err "32-bit systems are not supported"
}

function Test-AVX2 {
    try {
        $code = @"
using System;
using System.Runtime.InteropServices;
public class CpuFeature {
    [DllImport("kernel32.dll")]
    public static extern bool IsProcessorFeaturePresent(int ProcessorFeature);
    public static bool HasAVX2() { return IsProcessorFeaturePresent(40); }
}
"@
        Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop
        return [CpuFeature]::HasAVX2()
    } catch {
        return $false
    }
}

function Get-LatestVersion {
    try {
        if ($Beta) {
            $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=1" -UseBasicParsing
            if ($releases.Count -gt 0) {
                return $releases[0].tag_name
            }
        } else {
            $response = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing
            return $response.tag_name
        }
    } catch {
        Write-Warn "GitHub API request failed: $($_.Exception.Message)"
        return $null
    }
    return $null
}

function Uninstall-Cyberstrike {
    # Remove a previous install — upstream cyberstrike or an older version of
    # this fork (identical paths, identical binary name). Idempotent: safe
    # when nothing is installed. Keeps user data/config and the PATH entry so
    # upgrades never re-prompt.
    $proc = Get-Process cyberstrike -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Info "Stopping running cyberstrike process..."
        $proc | Stop-Process -Force
        Start-Sleep -Milliseconds 500
    }
    $Exe = Join-Path $InstallDir "cyberstrike.exe"
    if (Test-Path $Exe) {
        Remove-Item $Exe -Force
        Write-Info "Removed previous install at $Exe"
    }
    $Worker = Join-Path $DataBinDir "hackbrowser-worker.js"
    if (Test-Path $Worker) {
        Remove-Item $Worker -Force
        Write-Info "Removed previous hackbrowser worker"
    }
}

function Install-Cyberstrike {
    $channel = if ($Beta) { "beta" } else { "stable" }
    Write-Info "Installing CyberStrike CLI ($channel) from $Repo..."

    Uninstall-Cyberstrike

    $Arch = Get-Architecture
    $Version = Get-LatestVersion

    if (-not $Version) {
        Write-Err "Failed to fetch version information from GitHub"
    }

    Write-Info "Detected: windows-$Arch"
    Write-Info "Version: $Version"

    # Determine target variant
    $target = "windows-$Arch"
    if ($Arch -eq "x64") {
        $hasAVX2 = Test-AVX2
        if (-not $hasAVX2) {
            $target = "windows-$Arch-baseline"
            Write-Info "CPU does not support AVX2, using baseline build"
        }
    }

    # Construct download URL
    $AssetName = "cyberstrike-$target.zip"
    $DownloadUrl = "https://github.com/$Repo/releases/download/$Version/$AssetName"

    # Create install directory
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    # Download
    Write-Info "Downloading from $DownloadUrl..."
    $TempDir = Join-Path $env:TEMP "cyberstrike-install"
    $TempFile = Join-Path $TempDir $AssetName

    if (Test-Path $TempDir) {
        Remove-Item -Recurse -Force $TempDir
    }
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

    try {
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $TempFile -UseBasicParsing
    } catch {
        Write-Err "Failed to download: $_"
    }

    # Extract
    Write-Info "Extracting..."
    Expand-Archive -Path $TempFile -DestinationPath $TempDir -Force

    # Find and move binary
    $Binary = Get-ChildItem -Path $TempDir -Recurse -Filter "cyberstrike.exe" | Select-Object -First 1
    if (-not $Binary) {
        $Binary = Get-ChildItem -Path $TempDir -Recurse -Filter "cyberstrike" | Select-Object -First 1
    }

    if (-not $Binary) {
        Write-Err "Could not find cyberstrike binary in archive"
    }

    $DestPath = Join-Path $InstallDir "cyberstrike.exe"
    Copy-Item -Path $Binary.FullName -Destination $DestPath -Force

    # Install hackbrowser worker - placed in the runtime data dir
    # ($DataBinDir), not in $InstallDir. The cyberstrike binary locates
    # the worker via Global.Path.bin (XDG-based), independent of the
    # binary's PATH location.
    $WorkerSrc = Get-ChildItem -Path $TempDir -Recurse -Filter "hackbrowser-worker.js" | Select-Object -First 1
    if ($WorkerSrc) {
        if (-not (Test-Path $DataBinDir)) {
            New-Item -ItemType Directory -Path $DataBinDir -Force | Out-Null
        }
        $WorkerDest = Join-Path $DataBinDir "hackbrowser-worker.js"
        Copy-Item -Path $WorkerSrc.FullName -Destination $WorkerDest -Force
        Write-Info "hackbrowser worker installed to $DataBinDir"
    } else {
        Write-Warn "hackbrowser-worker.js not found in archive - hackbrowser subcommand will not work"
    }

    # Cleanup
    Remove-Item -Recurse -Force $TempDir

    Write-Info "Installed to $DestPath"

    # Add install dir to PATH automatically if missing
    $UserPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($UserPath -notlike "*$InstallDir*") {
        [Environment]::SetEnvironmentVariable("PATH", "$InstallDir;$UserPath", "User")
        $env:PATH = "$InstallDir;$env:PATH"
        Write-Info "Added $InstallDir to PATH. You may need to restart your terminal."
    }

    # Verify the binary actually launches on this machine
    Write-Info "Verifying installation (cyberstrike --version)..."
    & $DestPath --version
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Write-Err "cyberstrike.exe failed to start (exit code $code). Install is present but the binary did not launch."
    }

    Write-Host ""
    Write-Info "CyberStrike CLI installed successfully! (exit code 0 on verify)"
    Write-Host ""
    Write-Host "  Run 'cyberstrike --help' to get started" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  To use the hackbrowser subcommand, install playwright once:" -ForegroundColor Cyan
    Write-Host "    npm install --prefix `"$DataDir`" playwright"
    Write-Host "    & `"$DataDir\node_modules\.bin\playwright.cmd`" install chromium"
    Write-Host ""
}

Install-Cyberstrike
