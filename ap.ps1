<#
ap.ps1 - OOBE bootstrapper for Get-WindowsAutoPilotInfo
- Shows on-screen progress (wait/sync messages) by NOT redirecting child output
- Runs in the same console window (no new window)
- Supports -Assign (toggle)
- Pins modern auth version 3.6+ (3.6 switched MSGraph -> MgGraph) [2](https://learn.microsoft.com/en-us/answers/questions/908202/error-running-%28get-windowsautopilotinfo-ps1%29)
- Patches to avoid "Assigned User" PropertyNotFoundStrict crash
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------- CONFIG ----------------
$PinnedVersion = '3.6'                 # Modern auth pivot (MSGraph -> MgGraph) [2](https://learn.microsoft.com/en-us/answers/questions/908202/error-running-%28get-windowsautopilotinfo-ps1%29)
$GroupTag      = 'AutoPilot-NonAdmin'  # DO NOT display in wrapper output
$UseAssign     = $true                 # <-- Set to $true to add -Assign back
# ----------------------------------------

$LogPath    = Join-Path $env:WINDIR 'Temp\ap-bootstrap.log'
$TempScript = Join-Path $env:WINDIR 'Temp\Get-WindowsAutoPilotInfo.patched.ps1'
$PsExe      = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Log([string]$Message) {
    $ts = (Get-Date).ToString('s')
    "$ts $Message" | Out-File -FilePath $LogPath -Append -Encoding UTF8
}

function Say([string]$Message) {
    Write-Host $Message
}

try {
    Log "=== ap.ps1 starting ==="
    Log "PinnedVersion=$PinnedVersion; UseAssign=$UseAssign"
    Say "Uploading HWHash... (progress will appear below)"

    # Best-effort suppression for Graph welcome (depends on module/script)
    $env:MG_NO_WELCOME = '1'

    # TLS 1.2 for older images
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    # Trust PSGallery to avoid prompts
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

    # Uninstall installed versions (PowerShellGet compatibility)
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
        }
    } catch {
        Log "Warning: Uninstall step failed: $($_.Exception.Message)"
    }

    # Install pinned version
    Log "Installing Get-WindowsAutoPilotInfo v$PinnedVersion..."
    Install-Script -Name Get-WindowsAutoPilotInfo -RequiredVersion $PinnedVersion -Force -ErrorAction Stop

    # Locate installed script and copy to temp
    $installedCmd = Get-Command Get-WindowsAutoPilotInfo.ps1 -ErrorAction Stop
    $src = $installedCmd.Source
    Log "Installed script located at: $src"

    Remove-Item $TempScript -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $src -Destination $TempScript -Force
    Log "Copied to temp: $TempScript"

    # ---------- SAFE PATCH (line-based insertion) ----------
    $lines = Get-Content -Path $TempScript -Encoding UTF8

    $matchIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\$computers\s*\|\s*ForEach-Object\s*\{\s*$') {
            $matchIndex = $i
            break
        }
    }
    if ($matchIndex -lt 0) {
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -like '*$computers*ForEach-Object*{*') {
                $matchIndex = $i
                break
            }
        }
    }

    if ($matchIndex -lt 0) {
        Log "ERROR: Patch point not found in script."
        throw "Patch point not found."
    }

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
    Log "Patched script successfully (inserted guard after line $($matchIndex+1))."
    # -------------------------------------------------------

    # Build args for child PowerShell
    $fileArgs = @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
        '-File', $TempScript,
        '-Online',
        '-GroupTag', $GroupTag
    )
    if ($UseAssign) { $fileArgs += '-Assign' }  # Wait for assignment to complete [1](https://www.prajwaldesai.com/autopilot-profile-status-shows-not-assigned/)

    Log "Executing child script (same window, visible progress)."

    # IMPORTANT: No -RedirectStandardOutput/Error here, so you see the wait notifications.
    # -NoNewWindow keeps it in the same console.
    $p = Start-Process -FilePath $PsExe -ArgumentList $fileArgs -NoNewWindow -Wait -PassThru

    Log "Child exit code: $($p.ExitCode)"
    if ($p.ExitCode -ne 0) { throw "Upload failed (exit code $($p.ExitCode))." }

    Say "Upload complete."
    Log "=== ap.ps1 completed successfully ==="
}
catch {
    Say "Upload failed. Please check the log: C:\Windows\Temp\ap-bootstrap.log"
    Log "ERROR: $($_.Exception.Message)"
    Log "STACK: $($_.ScriptStackTrace)"
    throw
}
