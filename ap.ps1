# ap.ps1 - OOBE bootstrapper for Get-WindowsAutoPilotInfo
# Shows wait/sync progress but hides GroupTag lines; suppresses NuGet prompts; supports -Assign.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# -------- CONFIG --------
$pinnedVersion = '3.6'                 # Modern auth pivot in this toolchain
$groupTag      = 'AutoPilot-NonAdmin'  # Applied but hidden from on-screen output
$useAssign     = $true                 # Add -Assign back
# ------------------------

$logPath = Join-Path $env:WINDIR 'Temp\ap-bootstrap.log'

function Log([string]$m) {
    "$(Get-Date -Format s) $m" | Out-File -FilePath $logPath -Append -Encoding UTF8
}

function Say([string]$m) {
    Microsoft.PowerShell.Utility\Write-Host $m
}

try {
    Log "=== ap.ps1 starting ==="
    Say "Uploading HWHash... (import/sync/wait status will appear below)"

    if ($useAssign) {
        Say "Deployment Profile assignment may take up to 30 minutes - please be patient."
    }

    # TLS 1.2 for older images
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    # Best-effort: suppress Graph welcome banner if Connect-MgGraph supports -NoWelcome
    try {
        $cmg = Get-Command Connect-MgGraph -ErrorAction SilentlyContinue
        if ($cmg -and $cmg.Parameters.ContainsKey('NoWelcome')) {
            $global:PSDefaultParameterValues['Connect-MgGraph:NoWelcome'] = $true
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

    # Ensure NuGet provider silently (avoid Y prompt)
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Log "Installing NuGet provider silently..."
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:$false | Out-Null
    }

    # Remove existing versions (compat: avoid -AllVersions)
    $installed = Get-InstalledScript -Name Get-WindowsAutoPilotInfo -ErrorAction SilentlyContinue
    if ($installed) {
        foreach ($v in @($installed.Version | Sort-Object -Unique)) {
            try {
                Uninstall-Script -Name Get-WindowsAutoPilotInfo -RequiredVersion $v -Force -Confirm:$false -ErrorAction Stop
            } catch { }
        }
    }

    # Install pinned version
    Log ("Installing Get-WindowsAutoPilotInfo v{0}..." -f $pinnedVersion)
    Install-Script -Name Get-WindowsAutoPilotInfo -RequiredVersion $pinnedVersion -Force -Confirm:$false -ErrorAction Stop

    $scriptPath = (Get-Command Get-WindowsAutoPilotInfo.ps1 -ErrorAction Stop).Source
    Log ("Using script: {0}" -f $scriptPath)

    # Filter GroupTag output but keep wait/sync output
    $patterns = @('GroupTag', 'Group Tag', [regex]::Escape($groupTag))

    function Write-Host {
        param([Parameter(ValueFromRemainingArguments = $true)] $Object)
        $text = ($Object | ForEach-Object { "$_" }) -join ' '
        foreach ($p in $patterns) { if ($text -match $p) { return } }
        Microsoft.PowerShell.Utility\Write-Host $text
    }

    $invokeArgs = @('-Online', '-GroupTag', $groupTag)
    if ($useAssign) { $invokeArgs += '-Assign' }

    Log ("Executing: {0} {1}" -f $scriptPath, ($invokeArgs -join ' '))

    # Avoid StrictMode property crashes during script run (Assigned User missing, etc.)
    Set-StrictMode -Off
    & $scriptPath @invokeArgs
    Set-StrictMode -Version Latest

    Say "Upload complete."
    Log "=== ap.ps1 completed successfully ==="
}
catch {
    Say "Upload failed. Check log: C:\Windows\Temp\ap-bootstrap.log"
    Log ("ERROR: {0}" -f $_.Exception.Message)
    Log ("STACK: {0}" -f $_.ScriptStackTrace)
    throw
}
