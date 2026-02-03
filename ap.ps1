# ap.ps1 - OOBE bootstrapper (PowerShellGet compatible)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- CONFIG ----
$pinnedVersion = '3.5'
$groupTag       = 'AutoPilot-NonAdmin'
$log            = Join-Path $env:WINDIR 'Temp\ap-bootstrap.log'
# ---------------

function Log([string]$m) {
    "$(Get-Date -Format s) $m" | Tee-Object -FilePath $log -Append | Out-Host
}

try {
    Log "Pinning Get-WindowsAutoPilotInfo to v$pinnedVersion"

    # Helpful on older images
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    # Ensure PSGallery exists + is trusted (avoid prompts in OOBE)
    try {
        if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
            Register-PSRepository -Default -ErrorAction SilentlyContinue
        }
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    } catch {
        Log "Warning: Could not set PSGallery policy: $($_.Exception.Message)"
    }

    # --- Uninstall ALL versions (compatible way: loop versions) ---
    $installed = @()
    try {
        $installed = Get-InstalledScript -Name Get-WindowsAutoPilotInfo -ErrorAction SilentlyContinue
    } catch {
        Log "Get-InstalledScript not available or failed: $($_.Exception.Message)"
    }

    if ($installed) {
        foreach ($v in @($installed.Version | Sort-Object -Unique)) {
            try {
                Log "Uninstalling Get-WindowsAutoPilotInfo version $v"
                Uninstall-Script -Name Get-WindowsAutoPilotInfo -RequiredVersion $v -Force -ErrorAction Stop
            } catch {
                Log "Warning: failed to uninstall version $v : $($_.Exception.Message)"
            }
        }
    } else {
        Log "No installed Get-WindowsAutoPilotInfo versions found (or cannot enumerate)."
    }

    # Install the pinned version
    Log "Installing Get-WindowsAutoPilotInfo version $pinnedVersion"
    Install-Script -Name Get-WindowsAutoPilotInfo -RequiredVersion $pinnedVersion -Force -ErrorAction Stop

    $inst = Get-InstalledScript -Name Get-WindowsAutoPilotInfo -ErrorAction Stop
    Log "Installed: $($inst.Name) v$($inst.Version) at $($inst.InstalledLocation)"

    # Run with your parameters
    Log "Running: Get-WindowsAutoPilotInfo.ps1 -Online -GroupTag '$groupTag'"
    Get-WindowsAutoPilotInfo.ps1 -Online -Assign -GroupTag $groupTag

    Log "Completed successfully."
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    Log "STACK: $($_.ScriptStackTrace)"
    throw
}
