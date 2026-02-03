<#
ap.ps1 - OOBE bootstrapper for Get-WindowsAutoPilotInfo
- Pins a modern-auth version (3.6+ uses MgGraph) to avoid legacy auth issues like AADSTS700016. [1](https://support.nhs.net/2024/03/information-microsoft-detected-a-microsoft-intune-powershell-script-issue-in-your-environment/)[2](https://github.com/LegendEvent/Get-WindowsAutoPilotInfo/blob/main/Get-WindowsAutoPilotInfo.ps1)
- Patches the script safely (line-based insertion) to prevent "Assigned User" PropertyNotFoundStrict crashes.
- Runs -Online with your GroupTag (optional -Assign toggle).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------- CONFIG ----------------
$PinnedVersion = '3.6'                 # Modern auth pivot (MgGraph). Change to '3.8' if desired. [1](https://support.nhs.net/2024/03/information-microsoft-detected-a-microsoft-intune-powershell-script-issue-in-your-environment/)
$GroupTag      = 'AutoPilot-NonAdmin'
$UseAssign     = $false                # Start false; flip true later if you want -Assign

$LogPath       = Join-Path $env:WINDIR 'Temp\ap-bootstrap.log'
$TempScript    = Join-Path $env:WINDIR 'Temp\Get-WindowsAutoPilotInfo.patched.ps1'
# ----------------------------------------

function Log([string]$Message) {
    $ts = (Get-Date).ToString('s')
    "$ts $Message" | Tee-Object -FilePath $LogPath -Append | Out-Host
}

try {
    Log "=== ap.ps1 starting ==="
    Log "PinnedVersion=$PinnedVersion; GroupTag=$GroupTag; UseAssign=$UseAssign"

    # Helpful on older builds
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    # Trust PSGallery to avoid prompts in OOBE
    try {
        if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
            Register-PSRepository -Default -ErrorAction SilentlyContinue
        }
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    } catch {
        Log "Warning: Could not set PSGallery trust policy: $($_.Exception.Message)"
    }

    # Ensure NuGet provider (Install-Script may require it)
    try {
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Log "Installing NuGet provider..."
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        }
    } catch {
        Log "Warning: NuGet provider install/check failed: $($_.Exception.Message)"
    }

    # Uninstall any installed versions (PowerShellGet compatibility: no -AllVersions)
    try {
        $installed = Get-InstalledScript -Name Get-WindowsAutoPilotInfo -ErrorAction SilentlyContinue
        if ($installed) {
            foreach ($v in @($installed.Version | Sort-Object -Unique)) {
                try {
                    Log "Uninstalling Get-WindowsAutoPilotInfo v$v"
                    Uninstall-Script -Name Get-WindowsAutoPilotInfo -RequiredVersion $v -Force -ErrorAction Stop
                } catch {
                    Log "Warning: could not uninstall v$v : $($_.Exception.Message)"
                }
            }
        } else {
            Log "No installed Get-WindowsAutoPilotInfo versions found (or cannot enumerate)."
        }
    } catch {
        Log "Warning: Get-InstalledScript/Uninstall-Script step failed: $($_.Exception.Message)"
    }

    # Install pinned version
    Log "Installing Get-WindowsAutoPilotInfo v$PinnedVersion..."
    Install-Script -Name Get-WindowsAutoPilotInfo -RequiredVersion $PinnedVersion -Force -ErrorAction Stop

    # Locate installed script
    $installedCmd = Get-Command Get-WindowsAutoPilotInfo.ps1 -ErrorAction Stop
    $src = $installedCmd.Source
    Log "Installed script located at: $src"

    # Copy to temp for patching (always start clean)
    Remove-Item $TempScript -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $src -Destination $TempScript -Force
    Log "Copied to temp: $TempScript"

    # ---------- SAFE PATCH (line-based insertion) ----------
    # Insert guard immediately after the first line containing "$computers | ForEach-Object {"
    $lines = Get-Content -Path $TempScript -Encoding UTF8

    $matchIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\$computers\s*\|\s*ForEach-Object\s*\{\s*$') {
            $matchIndex = $i
            break
        }
    }

    if ($matchIndex -lt 0) {
        # Fallback: match if the token appears on the line (some versions have extra spacing)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -like '*$computers*ForEach-Object*{*') {
                $matchIndex = $i
                break
            }
        }
    }

    if ($matchIndex -lt 0) {
        Log "ERROR: Patch point not found in script. Not running unpatched (would likely fail)."
        Log "Tip: open $TempScript and search for '`$computers | ForEach-Object {' then tell me what you see."
        throw "Patch point not found."
    }

    $indent = ($lines[$matchIndex] -replace '(\S.*)$','')  # keep leading whitespace
    $patchLines = @(
        "$indent    # PATCH: ensure missing 'Assigned User' property does not crash under strict property access",
        "$indent    if (-not `$_.PSObject.Properties.Match('Assigned User')) {",
        "$indent        `$null = `$_.PSObject.Properties.Add([System.Management.Automation.PSNoteProperty]::new('Assigned User', `$null))",
        "$indent    }"
    )

    # Insert patch lines after the matchIndex line
    $newLines = @()
    $newLines += $lines[0..$matchIndex]
    $newLines += $patchLines
    if ($matchIndex + 1 -lt $lines.Count) { $newLines += $lines[($matchIndex+1)..($lines.Count-1)] }

    Set-Content -Path $TempScript -Value $newLines -Encoding UTF8 -Force
    Log "Patched script successfully (inserted guard after line $($matchIndex+1))."
    # -------------------------------------------------------

    # Build arguments for execution
    $args = @('-Online', '-GroupTag', $GroupTag)
    if ($UseAssign) { $args += '-Assign' }

    Log "Executing: $TempScript $($args -join ' ')"
    & $TempScript @args

    Log "=== ap.ps1 completed successfully ==="
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    Log "STACK: $($_.ScriptStackTrace)"
    throw
}
