<#
ap.ps1 - OOBE bootstrapper for Get-WindowsAutoPilotInfo
- Minimal on-screen output (engineer sees "Uploading HWHash..." only)
- Full detail goes to log file: C:\Windows\Temp\ap-bootstrap.log
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------- CONFIG ----------------
$PinnedVersion = '3.6'                 # Modern auth pivot
$GroupTag      = 'AutoPilot-NonAdmin'  # DO NOT display on-screen
$UseAssign     = $false                # Optional later
# ----------------------------------------

$LogPath    = Join-Path $env:WINDIR 'Temp\ap-bootstrap.log'
$TempScript = Join-Path $env:WINDIR 'Temp\Get-WindowsAutoPilotInfo.patched.ps1'
$PsExe      = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Log([string]$Message) {
    $ts = (Get-Date).ToString('s')
    "$ts $Message" | Out-File -FilePath $LogPath -Append -Encoding UTF8
}

function Say([string]$Message) {
    # Minimal console output only
    Write-Host $Message
}

try {
    # Keep console quiet, log everything
    Log "=== ap.ps1 starting ==="
    Log "PinnedVersion=$PinnedVersion; GroupTag=$GroupTag; UseAssign=$UseAssign"

    # Engineer-friendly message (no group tag)
    Say "Uploading HWHash..."

    # TLS 1.2 helps on some older images
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    # Trust PSGallery (avoid prompts)
    try {
        if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
            Register-PSRepository -Default -ErrorAction SilentlyContinue
        }
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Log "PSGallery set to Trusted."
    } catch {
        Log "Warning: Could not set PSGallery trust policy: $($_.Exception.Message)"
    }

    # Ensure NuGet provider
    try {
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Log "Installing NuGet provider..."
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        }
    } catch {
        Log "Warning: NuGet provider install/check failed: $($_.Exception.Message)"
    }

    # Uninstall installed versions (PowerShellGet compatibility - no -AllVersions)
    try {
        $installed = Get-InstalledScript -Name Get-WindowsAutoPilotInfo -ErrorAction SilentlyContinue
        if ($installed) {
            foreach ($v in @($installed.Version | Sort-Object -Unique)) {
