<#
ap.ps1 - OOBE bootstrapper for Get-WindowsAutoPilotInfo

Features:
- Non-interactive NuGet + PSGallery trust (no Y prompts)
- Pin modern-auth version (default 3.6: MSGraph -> MgGraph) [1](https://learn.microsoft.com/en-us/answers/questions/908202/error-running-%28get-windowsautopilotinfo-ps1%29)
- Patch to avoid "Assigned User" PropertyNotFoundStrict crash
- Show progress/wait/sync output on screen
- Hide GroupTag lines on screen (without breaking progress)
- Optionally add -Assign back (wait for profile assignment) [2](https://www.prajwaldesai.com/autopilot-profile-status-shows-not-assigned/)[1](https://learn.microsoft.com/en-us/answers/questions/908202/error-running-%28get-windowsautopilotinfo-ps1%29)

Logs:
- C:\Windows\Temp\ap-bootstrap.log
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------- CONFIG ----------------
$PinnedVersion = '3.6'                 # Modern auth pivot (MSGraph -> MgGraph) per release notes history [1](https://learn.microsoft.com/en-us/answers/questions/908202/error-running-%28get-windowsautopilotinfo-ps1%29)
$GroupTag      = 'AutoPilot-NonAdmin'  # Must be applied but not shown on-screen
$UseAssign     = $true                 # Add -Assign back (wait for profile assignment completion) [2](https://www.prajwaldesai.com/autopilot-profile-status-shows-not-assigned/)[1](https://learn.microsoft.com/en-us/answers/questions/908202/error-running-%28get-windowsautopilotinfo-ps1%29)

# What to suppress from on-screen output
$SuppressPatterns = @(
    'GroupTag',                         # any line mentioning GroupTag
    'Group Tag',                        # some scripts print it like this
    [regex]::Escape($GroupTag)          # hide the value if printed
)
# ----------------------------------------

$LogPath    = Join-Path $env:WINDIR 'Temp\ap-bootstrap.log'
$TempScript = Join-Path $env:WINDIR 'Temp\Get-WindowsAutoPilotInfo.patched.ps1'

function Log([string]$Message) {
    $ts = (Get-Date).ToString('s')
    "$ts $Message" | Out-File -FilePath $LogPath -Append -Encoding UTF8
}

function Say([string]$Message) {
    Write-Host $Message
}

function Should-SuppressLine([string]$Line) {
    foreach ($p in $SuppressPatterns) {
        if ($Line -match $p) { return $true }
    }
    return $false
}

try {
    Log "=== ap.ps1 starting ==="
    Log "PinnedVersion=$PinnedVersion; UseAssign=$UseAssign; GroupTag=$GroupTag (hidden on-screen)"

    Say "Uploading HWHash... (import/sync/wait status will appear below)"

    # Best-effort: suppress Graph welcome banner where applicable (depends on Graph module & script)
    # Graph SDK uses Connect-MgGraph for auth flows. [3](https://www.powershellgallery.com/packages/Get-WindowsAutoPilotInfo/3.5/Content/Get-WindowsAutoPilotInfo.ps1)
    $env:MG_NO_WELCOME = '1'

    # TLS 1.2 helps on older images
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    # --- Make PSGallery and NuGet installs non-interactive ---
    try {
        if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
            Register-PSRepository -Default -ErrorAction SilentlyContinue
        }
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Log "PSGallery set to Trusted."
    } catch {
        Log "Warning: Could not set PSGallery trust policy: $($_.Exception.Message)"
    }

    try {
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Log "Installing NuGet provider silently..."
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:$false -ErrorAction Stop | Out-Null
        } else {
            Log "NuGet provider already present."
        }
    } catch {
        throw "Failed to install NuGet provider non-interactively: $($_.Exception.Message)"
    }
    # --------------------------------------------------------

    # Remove installed versions (PowerShellGet compatibility: avoid -AllVersions)
    try {
        $installed = Get-InstalledScript -Name Get-WindowsAutoPilotInfo -ErrorAction SilentlyContinue
        if ($installed) {
            foreach ($v in @($installed.Version | Sort-Object -Unique)) {
                try {
                    Log "Uninstalling Get-WindowsAutoPilotInfo v$v"
                    Uninstall-Script -Name Get-WindowsAutoPilotInfo -RequiredVersion $v -Force -Confirm:$false -ErrorAction Stop
                } catch {
                    Log "Warning: could not uninstall v$v : $($_.Exception.Message)"
                }
            }
        }
    } catch {
        Log "Warning: Uninstall step failed: $($_.Exception.Message)"
    }

    # Install pinned version (modern auth)
    Log "Installing Get-WindowsAutoPilotInfo v$PinnedVersion..."
    Install-Script -Name Get-WindowsAutoPilotInfo -RequiredVersion $PinnedVersion -Force -Confirm:$false -ErrorAction Stop

    # Locate installed script and copy to temp
    $installedCmd = Get-Command Get-WindowsAutoPilotInfo.ps1 -ErrorAction Stop
    $src = $installedCmd.Source
    Log "Installed script located at: $src"

    Remove-Item $TempScript -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $src -Destination $TempScript -Force
    Log "Copied to temp: $TempScript"

    # ---------------- PATCH 1: Fix "Assigned User" missing property crash ----------------
    # Insert a guard immediately after the first "$computers | ForEach-Object {" line.
    $lines = Get-Content -Path $TempScript -Encoding UTF8

    $matchIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\$computers\s*\|\s*ForEach-Object\s*\{\s*$') { $matchIndex = $i; break }
    }
    if ($matchIndex -lt 0) {
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -like '*$computers*ForEach-Object*{*') { $matchIndex = $i; break }
        }
    }
    if ($matchIndex -lt 0) { throw "Patch point not found for `$computers | ForEach-Object {`" }

    $indent = ($lines[$matchIndex] -replace '(\S.*)$','')
    $patchLines = @(
        "$indent    # PATCH: ensure missing 'Assigned User' property does not crash",
        "$indent    if (-not `$_.PSObject.Properties.Match('Assigned User')) {",
        "$indent        `$null = `$_.PSObject.Properties.Add([System.Management.Automation.PSNoteProperty]::new('Assigned User', `$null))",
        "$indent    }"
    )

    $newLines = @()
    $newLines += $lines[0..$matchIndex]
    $newLines += $patchLines
    if ($matchIndex + 1 -lt $lines.Count) { $newLines += $lines[($matchIndex+1)..($lines.Count-1)] }

    Set-Content -Path $TempScript -Value $newLines -Encoding UTF8 -Force
    Log "Patched script (Assigned User guard) inserted after line $($matchIndex+1)."
    # -----------------------------------------------------------------------------------

    # ---------------- PATCH 2: Hide GroupTag lines without killing progress -------------
    # Best-effort: replace any Write-Host lines that contain GroupTag or the tag value.
    # This keeps sync/wait output but removes the sensitive lines.
    $lines2 = Get-Content -Path $TempScript -Encoding UTF8
    $replacedCount = 0

    for ($i = 0; $i -lt $lines2.Count; $i++) {
        $line = $lines2[$i]

        # Only target lines that print to host
        if ($line -match '^\s*Write-Host' -and (Should-SuppressLine $line)) {
            if ($replacedCount -eq 0) {
                $lines2[$i] = ($line -replace 'Write-Host.*', 'Write-Host "Uploading HWHash..."')
            } else {
                $lines2[$i] = ('# suppressed by ap.ps1')
            }
            $replacedCount++
        }
    }

    if ($replacedCount -gt 0) {
        Set-Content -Path $TempScript -Value $lines2 -Encoding UTF8 -Force
        Log "Suppressed $replacedCount host output lines that referenced GroupTag."
    } else {
        Log "No GroupTag host-output lines detected for suppression (script may not print it)."
    }
    # -----------------------------------------------------------------------------------

    # Build invocation (in-process, so progress appears on screen)
    $invokeArgs = @('-Online', '-GroupTag', $GroupTag)
    if ($UseAssign) { $invokeArgs += '-Assign' }  # wait for assignment [2](https://www.prajwaldesai.com/autopilot-profile-status-shows-not-assigned/)[1](https://learn.microsoft.com/en-us/answers/questions/908202/error-running-%28get-windowsautopilotinfo-ps1%29)

    Log "Executing patched script in-process: $TempScript $($invokeArgs -join ' ')"

    # IMPORTANT:
    # Running in-process preserves host output (Write-Host), so you see wait/sync messages.
    & $TempScript @invokeArgs

    Say "Upload complete."
    Log "=== ap.ps1 completed successfully ==="

    # Reminder about async portal updates
    # Autopilot import/processing may take time to reflect in the portal. [4](https://stackoverflow.com/questions/66107800/how-to-solve-aadsts700016-error-on-login-with-microsoft-account)
}
catch {
    Say "Upload failed. Please check: C:\Windows\Temp\ap-bootstrap.log"
    Log "ERROR: $($_.Exception.Message)"
    Log "STACK: $($_.ScriptStackTrace)"
    throw
}
