<#
ap.ps1 - OOBE bootstrapper for Get-WindowsAutoPilotInfo
- Pins a chosen Get-WindowsAutoPilotInfo version (default 3.8)
- Works on older PowerShellGet builds (no -AllVersions usage)
- Patches the installed script in a temp copy to prevent "Assigned User" PropertyNotFoundStrict crashes
- Runs the script with -Online and your GroupTag (and optional -Assign)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------- CONFIG ----------------
# Use 3.6+ to ensure "modern auth" (MgGraph). Release notes indicate 3.6 switched from MSGraph to MgGraph. [3](https://support.nhs.net/2024/03/information-microsoft-detected-a-microsoft-intune-powershell-script-issue-in-your-environment/)
$PinnedVersion = '3.8'                 # Change if you want (must exist on PSGallery)
$GroupTag      = 'AutoPilot-NonAdmin'  # Your tag
$UseAssign     = $false                # Set $true if you later want -Assign (after confirming stability)

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

    # TLS 1.2 helps on older images
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    # Ensure PSGallery is registered and trusted (reduces prompts)
    try {
        if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
            Register-PSRepository -Default -ErrorAction SilentlyContinue
        }
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    } catch {
        Log "Warning: Could not set PSGallery trust policy: $($_.Exception.Message)"
    }

    # Ensure NuGet provider is available (Install-Script often needs it)
    try {
        $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
        if (-not $nuget) {
            Log "Installing NuGet package provider..."
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        Log "Warning: NuGet provider install/check failed: $($_.Exception.Message)"
    }

    # Remove existing installed script files we can see on PATH (handles old PowerShellGet without -AllVersions)
    $existing = @(Get-Command Get-WindowsAutoPilotInfo.ps1 -All -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        foreach ($cmd in $existing) {
            if ($cmd.Source -and (Test-Path $cmd.Source)) {
                try {
                    Log "Removing existing script at $($cmd.Source)"
                    Remove-Item -Path $cmd.Source -Force -ErrorAction Stop
                } catch {
                    Log "Warning: failed to remove $($cmd.Source): $($_.Exception.Message)"
                }
            }
        }
    } else {
        Log "No existing Get-WindowsAutoPilotInfo.ps1 found on PATH."
    }

    # Install pinned version
    Log "Installing Get-WindowsAutoPilotInfo v$PinnedVersion from PSGallery..."
    Install-Script -Name Get-WindowsAutoPilotInfo -RequiredVersion $PinnedVersion -Force -ErrorAction Stop

    # Locate installed script
    $installedCmd = Get-Command Get-WindowsAutoPilotInfo.ps1 -ErrorAction Stop
    Log "Installed script located at: $($installedCmd.Source)"

    # Copy to temp for patching
    Copy-Item -Path $installedCmd.Source -Destination $TempScript -Force
    Log "Copied to temp for patching: $TempScript"

    # Patch to avoid "Assigned User" PropertyNotFoundStrict
    # We insert a guard immediately after the $computers | ForEach-Object { line.
    $content = Get-Content -Path $TempScript -Raw

    $regex = [regex]'(\$computers\s*\|\s*ForEach-Object\s*\{)'
    if (-not $regex.IsMatch($content)) {
        Log "Patch point not found (pattern '\$computers | ForEach-Object {')."
        Log "Running unpatched script anyway (may fail)."
    } else {
        $patch = @"
`$1
    # --- PATCH: prevent crash if Assigned User property isn't present ---
    if (-not `$_.PSObject.Properties.Match('Assigned User')) {
        `$null = `$_.PSObject.Properties.Add([System.Management.Automation.PSNoteProperty]::new('Assigned User', `$null))
    }
"@

        # Replace only the first occurrence
        $content2 = $regex.Replace($content, $patch, 1)
        Set-Content -Path $TempScript -Value $content2 -Encoding UTF8 -Force
        Log "Patched script to tolerate missing 'Assigned User' property."
    }

    # Build argument list
    $args = @('-Online', '-GroupTag', $GroupTag)
    if ($UseAssign) { $args += '-Assign' }

    Log "Executing patched script: $TempScript $($args -join ' ')"
    & $TempScript @args

    Log "=== ap.ps1 completed successfully ==="
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    Log "STACK: $($_.ScriptStackTrace)"
    throw
}
