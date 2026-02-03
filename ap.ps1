<#
ap.ps1 - OOBE bootstrapper for Get-WindowsAutoPilotInfo

- Pins to a modern-auth version (default 3.6; release history notes 3.6 switched MSGraph -> MgGraph) [2](https://learn.microsoft.com/en-us/answers/questions/908202/error-running-%28get-windowsautopilotinfo-ps1%29)
- Suppresses NuGet/PSGallery prompts (no "Y")
- Shows wait/sync output on screen (runs in-process so Write-Host output appears)
- Adds -Assign back (wait for deployment profile assignment) [1](https://www.prajwaldesai.com/autopilot-profile-status-shows-not-assigned/)[2](https://learn.microsoft.com/en-us/answers/questions/908202/error-running-%28get-windowsautopilotinfo-ps1%29)
- Hides GroupTag lines on screen (patches only message lines that print GroupTag/value)
- Fixes crash when "Assigned User" property is missing (defensive patch)

Log: C:\Windows\Temp\ap-bootstrap.log
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------- CONFIG ----------------
$PinnedVersion = '3.6'                 # Modern-auth pivot (MSGraph -> MgGraph) [2](https://learn.microsoft.com/en-us/answers/questions/908202/error-running-%28get-windowsautopilotinfo-ps1%29)
$GroupTag      = 'AutoPilot-NonAdmin'  # Apply, but hide from console
$UseAssign     = $true                 # Add -Assign back [1](https://www.prajwaldesai.com/autopilot-profile-status-shows-not-assigned/)[2](https://learn.microsoft.com/en-us/answers/questions/908202/error-running-%28get-windowsautopilotinfo-ps1%29)
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

function Insert-LinesAfterFirstMatch {
    param(
        [string[]]$Lines,
        [ScriptBlock]$Predicate,
        [string[]]$InsertLines
    )
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if (& $Predicate $Lines[$i]) {
            $before = $Lines[0..$i]
            $after  = @()
            if ($i + 1 -lt $Lines.Count) { $after = $Lines[($i+1)..($Lines.Count-1)] }
            return @($before + $InsertLines + $after)
        }
    }
    return $null
}

try {
    Log "=== ap.ps1 starting ==="
    Log ("PinnedVersion={0}; UseAssign={1}; GroupTag={2} (hidden on-screen)" -f $PinnedVersion, $UseAssign, $GroupTag)

    Say "Uploading HWHash... (import/sync/wait status will appear below)"
    if ($UseAssign) {
        Say "Deployment Profile assignment may take up to 30 minutes — please be patient."
        # Autopilot import/processing/assignment is asynchronous and can take time. [3](https://stackoverflow.com/questions/66107800/how-to-solve-aadsts700016-error-on-login-with-microsoft-account)
    }

    # TLS 1.2 helps on older images
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    # Best-effort: suppress Graph welcome banner if supported by Connect-MgGraph
    # Graph auth is via Connect-MgGraph in the Graph PowerShell SDK. [4](https://www.powershellgallery.com/packages/Get-WindowsAutoPilotInfo/3.5/Content/Get-WindowsAutoPilotInfo.ps1)
    try {
        $cmd = Get-Command Connect-MgGraph -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Parameters.ContainsKey('NoWelcome')) {
            $global:PSDefaultParameterValues['Connect-MgGraph:NoWelcome'] = $true
            Log "Enabled Connect-MgGraph:NoWelcome via PSDefaultParameterValues."
        }
    } catch { }

    # Trust PSGallery (avoid "Untrusted repository" prompt)
    try {
        if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
            Register-PSRepository -Default -ErrorAction SilentlyContinue
        }
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Log "PSGallery set to Trusted."
    } catch {
        Log "Warning: PSGallery trust policy not set: $($_.Exception.Message)"
    }

    # Ensure NuGet provider (avoid prompt)
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

    # Remove any installed versions (PowerShellGet compatibility; avoid -AllVersions)
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
        Log "Warning: uninstall step failed: $($_.Exception.Message)"
    }

    # Install pinned version
    Log "Installing Get-WindowsAutoPilotInfo v$PinnedVersion..."
    Install-Script -Name Get-WindowsAutoPilotInfo -RequiredVersion $PinnedVersion -Force -Confirm:$false -ErrorAction Stop

    # Locate installed script and copy to temp
    $src = (Get-Command Get-WindowsAutoPilotInfo.ps1 -ErrorAction Stop).Source
    Log "Installed script located at: $src"

    Remove-Item $TempScript -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $src -Destination $TempScript -Force

    # Load script as lines for safe patching
    $lines = Get-Content -Path $TempScript -Encoding UTF8

    # ---- PATCH 1: prevent crash if 'Assigned User' property doesn't exist ----
    # Insert guard right after first "$computers | ForEach-Object {" line
    $patched = Insert-LinesAfterFirstMatch -Lines $lines -Predicate {
        param($l)
        ($l -match '^\s*\$computers\s*\|\s*ForEach-Object\s*\{') -or ($l -like '*$computers*ForEach-Object*{*')
    } -InsertLines @(
        '    # PATCH: ensure missing ''Assigned User'' property does not crash',
        '    if (-not $_.PSObject.Properties.Match(''Assigned User'')) {',
        '        $null = $_.PSObject.Properties.Add([System.Management.Automation.PSNoteProperty]::new(''Assigned User'', $null))',
        '    }'
    )

    if (-not $patched) { throw "Patch point not found for `$computers | ForEach-Object {`" }
    $lines = $patched
    Log "Applied Assigned User guard patch."

    # ---- PATCH 2: hide GroupTag output lines (but keep wait/sync output) ----
    # Only replace *message* lines that are clearly output statements.
    $gtReplacements = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]

        $mentionsTag = ($l -match 'GroupTag') -or ($l -match 'Group Tag') -or ($l -match [regex]::Escape($GroupTag))
        $isOutputLine = ($l -match '^\s*Write-Host') -or ($l -match '^\s*Write-Output') -or ($l -match '^\s*Write-Information')

        if ($mentionsTag -and $isOutputLine) {
            if ($gtReplacements -eq 0) {
                $lines[$i] = 'Write-Host "Uploading HWHash..."'
            } else {
                $lines[$i] = '# suppressed GroupTag output'
            }
            $gtReplacements++
        }
    }
    Log "Suppressed $gtReplacements GroupTag-related output lines."

    # Save patched script
    Set-Content -Path $TempScript -Value $lines -Encoding UTF8 -Force

    # Build args and RUN IN-PROCESS so wait/sync output appears (Write-Host is visible)
    $invokeArgs = @('-Online', '-GroupTag', $GroupTag)
    if ($UseAssign) { $invokeArgs += '-Assign' }  # wait for assignment [1](https://www.prajwaldesai.com/autopilot-profile-status-shows-not-assigned/)[2](https://learn.microsoft.com/en-us/answers/questions/908202/error-running-%28get-windowsautopilotinfo-ps1%29)

    Log ("Executing patched script in-process: {0} {1}" -f $TempScript, ($invokeArgs -join ' '))
    & $TempScript @invokeArgs

    Say "Upload complete."
    Log "=== ap.ps1 completed successfully ==="
}
catch {
    Say "Upload failed. Please check: C:\Windows\Temp\ap-bootstrap.log"
    Log "ERROR: $($_.Exception.Message)"
    Log "STACK: $($_.ScriptStackTrace)"
    throw
}
