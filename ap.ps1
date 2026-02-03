# ap.ps1 - OOBE bootstrapper for Get-WindowsAutoPilotInfo
# Shows wait/sync progress but hides GroupTag lines; suppresses NuGet prompts; supports -Assign.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ---------------- CONFIG ----------------
$PinnedVersion = "3.6"                 # 3.6 is the modern-auth pivot (MSGraph -> MgGraph) per release notes. [1](https://learn.microsoft.com/en-us/answers/questions/908202/error-running-%28get-windowsautopilotinfo-ps1%29)
$GroupTag      = "AutoPilot-NonAdmin"  # Applied, but not shown on screen
$UseAssign     = $true                # Add -Assign back [2](https://www.prajwaldesai.com/autopilot-profile-status-shows-not-assigned/)[1](https://learn.microsoft.com/en-us/answers/questions/908202/error-running-%28get-windowsautopilotinfo-ps1%29)
# ----------------------------------------

$LogPath = Join-Path $env:WINDIR "Temp\ap-bootstrap.log"

function Log {
    param([string]$Message)
    $ts = (Get-Date).ToString("s")
    "$ts $Message" | Out-File -FilePath $LogPath -Append -Encoding UTF8
}

function Say {
    param([string]$Message)
    Microsoft.PowerShell.Utility\Write-Host $Message
}

try {
    Log "=== ap.ps1 starting ==="
    Log ("PinnedVersion={0}; UseAssign={1}; GroupTag={2} (hidden on-screen)" -f $PinnedVersion, $UseAssign, $GroupTag)

    Say "Uploading HWHash... (import/sync/wait status will appear below)"
    if ($UseAssign) {
        Say "Deployment Profile assignment may take up to 30 minutes — please be patient."
        # Autopilot import/processing can take time to reflect in the portal. [3](https://stackoverflow.com/questions/66107800/how-to-solve-aadsts700016-error-on-login-with-microsoft-account)
    }

    # TLS 1.2 helps on older images
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    # Best-effort: suppress Graph welcome if Connect-MgGraph supports -NoWelcome [4](https://www.powershellgallery.com/packages/Get-WindowsAutoPilotInfo/3.5/Content/Get-WindowsAutoPilotInfo.ps1)
    try {
        $cmg = Get-Command Connect-MgGraph -ErrorAction SilentlyContinue
        if ($cmg -and $cmg.Parameters.ContainsKey("NoWelcome")) {
            $global:PSDefaultParameterValues["Connect-MgGraph:NoWelcome"] = $true
            Log "Enabled Connect-MgGraph:NoWelcome via PSDefaultParameterValues."
        }
    } catch { }

    # Trust PSGallery to avoid prompts
    try {
        if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
            Register-PSRepository -Default -ErrorAction SilentlyContinue
        }
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Log "PSGallery set to Trusted."
    } catch {
        Log ("Warning: could not set PSGallery trust: {0}" -f $_.Exception.Message)
    }

    # Ensure NuGet provider silently (no Y prompts)
    try {
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Log "Installing NuGet provider silently..."
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:$false -ErrorAction Stop | Out-Null
        } else {
            Log "NuGet provider already present."
        }
    } catch {
        throw ("Failed to install NuGet provider non-interactively: {0}" -f $_.Exception.Message)
    }

    # Remove installed Get-WindowsAutoPilotInfo versions (compat: no -AllVersions)
    try {
        $installed = Get-InstalledScript -Name Get-WindowsAutoPilotInfo -ErrorAction SilentlyContinue
        if ($installed) {
            foreach ($v in @($installed.Version | Sort-Object -Unique)) {
                try {
                    Log ("Uninstalling Get-WindowsAutoPilotInfo v{0}" -f $v)
                    Uninstall-Script -Name Get-WindowsAutoPilotInfo -RequiredVersion $v -Force -Confirm:$false -ErrorAction Stop
                } catch {
                    Log ("Warning: could not uninstall v{0}: {1}" -f $v, $_.Exception.Message)
                }
            }
        }
    } catch {
        Log ("Warning: uninstall step failed: {0}" -f $_.Exception.Message)
    }

    # Install pinned version
    Log ("Installing Get-WindowsAutoPilotInfo v{0}..." -f $PinnedVersion)
    Install-Script -Name Get-WindowsAutoPilotInfo -RequiredVersion $PinnedVersion -Force -Confirm:$false -ErrorAction Stop

    # Locate installed script
    $scriptPath = (Get-Command Get-WindowsAutoPilotInfo.ps1 -ErrorAction Stop).Source
    Log ("Installed script path: {0}" -f $scriptPath)

    # ---- Run the Autopilot script with output filtering ----
    # We intercept Write-Host so we can hide GroupTag lines but keep wait/sync messages.
    # Also disable StrictMode during the run to avoid PropertyNotFoundStrict issues.
    $patterns = @("GroupTag", "Group Tag", [regex]::Escape($GroupTag))

    function Write-Host {
        param(
            [Parameter(ValueFromRemainingArguments = $true)]
            $Object
        )
        $text = ($Object | ForEach-Object { "$_" }) -join " "
        foreach ($p in $patterns) {
            if ($text -match $p) {
                # Hide tag-related lines from screen
                return
            }
        }
        Microsoft.PowerShell.Utility\Write-Host $text
    }

    $invokeArgs = @("-Online", "-GroupTag", $GroupTag)
    if ($UseAssign) { $invokeArgs += "-Assign" }  # Wait for profile assignment [2](https://www.prajwaldesai.com/autopilot-profile-status-shows-not-assigned/)[1](https://learn.microsoft.com/en-us/answers/questions/908202/error-running-%28get-windowsautopilotinfo-ps1%29)

    Log ("Executing: {0} {1}" -f $scriptPath, ($invokeArgs -join " "))

    # Disable strict mode in this scope to prevent missing-property crashes
    Set-StrictMode -Off
    & $scriptPath @invokeArgs
    Set-StrictMode -Version Latest

    Say "Upload complete."
    Log "=== ap.ps1 completed successfully ==="
}
catch {
    Say "Upload failed. Please check: C:\Windows\Temp\ap-bootstrap.log"
    Log ("ERROR: {0}" -f $_.Exception.Message)
    Log ("STACK: {0}" -f $_.ScriptStackTrace)
    throw
}
