<#
ap.ps1 - OOBE bootstrapper for Get-WindowsAutoPilotInfo
- Minimal on-screen output: shows only "Uploading HWHash..." and "Upload complete/failed"
- Keeps GroupTag hidden from on-screen output
- Pins Get-WindowsAutoPilotInfo to v3.6 (modern auth pivot: MSGraph -> MgGraph) [3](https://www.powershellgallery.com/packages/Get-WindowsAutoPilotInfo/3.8)
- Patches the script safely (line-based insertion) to avoid "Assigned User" PropertyNotFoundStrict crashes
- Runs child PowerShell IN THE SAME WINDOW (-NoNewWindow) and captures stdout/stderr to files
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------- CONFIG ----------------
$PinnedVersion = '3.6'                 # Modern auth pivot: "Switch from MSGraph to MgGraph" [3](https://www.powershellgallery.com/packages/Get-WindowsAutoPilotInfo/3.8)
$GroupTag      = 'AutoPilot-NonAdmin'  # Do NOT display on-screen
$UseAssign     = $false                # Optional later
# ----------------------------------------

$LogPath        = Join-Path $env:WINDIR 'Temp\ap-bootstrap.log'
$TempScript     = Join-Path $env:WINDIR 'Temp\Get-WindowsAutoPilotInfo.patched.ps1'
$ChildOut       = Join-Path $env:WINDIR 'Temp\Get-WindowsAutoPilotInfo.child.out.txt'
$ChildErr       = Join-Path $env:WINDIR 'Temp\Get-WindowsAutoPilotInfo.child.err.txt'
$PsExe          = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Log([string]$Message) {
    $ts = (Get-Date).ToString('s')
    "$ts $Message" | Out-File -FilePath $LogPath -Append -Encoding UTF8
}

function Say([string]$Message) {
    Write-Host $Message
}

try {
    Log "=== ap.ps1 starting ==="
    Log "PinnedVersion=$PinnedVersion; GroupTag=$GroupTag; UseAssign=$UseAssign"
    Say "Uploading HWHash..."

    # Hint for Graph welcome suppression (harmless if unused)
    $env:MG_NO_WELCOME = '1'
    Log "Set MG_NO_WELCOME=1 (best-effort, depends on Graph module/script implementation)."

    # TLS 1.2 helps on some older images
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

    # Uninstall installed versions (PowerShellGet compatibility: no -AllVersions)
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

    # Clear previous child output files
    Remove-Item $ChildOut, $ChildErr -Force -ErrorAction SilentlyContinue

    # Build args for child PowerShell
    $fileArgs = @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
        '-File', $TempScript,
        '-Online',
        '-GroupTag', $GroupTag
    )
    if ($UseAssign) { $fileArgs += '-Assign' }

    # IMPORTANT:
    # -NoNewWindow keeps output in the same console window
    # Redirect output/error to files so the console stays clean
    Log "Starting child PowerShell (same window)."
    $p = Start-Process -FilePath $PsExe `
        -ArgumentList $fileArgs `
        -NoNewWindow `
        -Wait `
        -PassThru `
        -RedirectStandardOutput $ChildOut `
        -RedirectStandardError  $ChildErr

    Log "Child exit code: $($p.ExitCode)"

    if ($p.ExitCode -ne 0) {
        # Keep screen output minimal
        Say "Upload failed. Check log."
        Log "Child stdout (first 2000 chars):"
        if (Test-Path $ChildOut) { Log ((Get-Content $ChildOut -Raw).Substring(0, [Math]::Min(2000, (Get-Item $ChildOut).Length))) }
        Log "Child stderr (first 2000 chars):"
        if (Test-Path $ChildErr) { Log ((Get-Content $ChildErr -Raw).Substring(0, [Math]::Min(2000, (Get-Item $ChildErr).Length))) }
        throw "Upload failed (exit code $($p.ExitCode))."
    }

    Say "Upload complete."
    Log "=== ap.ps1 completed successfully ==="
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    Log "STACK: $($_.ScriptStackTrace)"
    throw
}
