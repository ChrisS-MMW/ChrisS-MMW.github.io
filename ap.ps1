# ap.ps1 - GitHub Pages bootstrapper for OOBE
# Pins Get-WindowsAutoPilotInfo to a known version and runs it with your parameters.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PinnedVersion = '3.8'   # Pin to known-good version (PSGallery lists 3.8 + notes) [1](https://www.powershellgallery.com/packages/Get-WindowsAutoPilotInfo/3.8)
$GroupTag       = 'AutoPilot-NonAdmin'

$Log = Join-Path $env:WINDIR 'Temp\ap-bootstrap.log'
function Log { param([string]$m) $ts=(Get-Date).ToString('s'); "$ts $m" | Tee-Object -FilePath $Log -Append }

try {
    Log "=== Autopilot bootstrap starting ==="
    Log "Pinning Get-WindowsAutoPilotInfo to version $PinnedVersion"

    # Help older environments negotiate TLS 1.2 (safe no-op if not needed)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    # Ensure PSGallery is available (won't break if already set)
    try {
        if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
            Register-PSRepository -Default -ErrorAction SilentlyContinue
        }
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    } catch {
        Log "Warning: Could not set PSGallery trust policy: $($_.Exception.Message)"
    }

    # Remove any installed versions (including 3.9)
    try {
        Uninstall-Script -Name Get-WindowsAutoPilotInfo -AllVersions -Force -ErrorAction SilentlyContinue
        Log "Removed existing Get-WindowsAutoPilotInfo script versions (if any)."
    } catch {
        Log "Warning: Uninstall-Script encountered: $($_.Exception.Message)"
    }

    # Install pinned version
    Install-Script -Name Get-WindowsAutoPilotInfo -RequiredVersion $PinnedVersion -Force -ErrorAction Stop
    $installed = Get-InstalledScript -Name Get-WindowsAutoPilotInfo -ErrorAction Stop
    Log "Installed Get-WindowsAutoPilotInfo version: $($installed.Version) at $($installed.InstalledLocation)"

    # Run with your required parameters
    Log "Running: Get-WindowsAutoPilotInfo.ps1 -Online -Assign -GroupTag '$GroupTag'"
    Get-WindowsAutoPilotInfo.ps1 -Online -Assign -GroupTag $GroupTag

    Log "=== Autopilot bootstrap completed successfully ==="
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    Log "Stack: $($_.ScriptStackTrace)"
    throw
}
