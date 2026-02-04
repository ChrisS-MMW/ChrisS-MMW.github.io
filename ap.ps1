# ap.ps1 - OOBE bootstrapper for Autopilot HWHash upload (with progress output)
# - Shows wait/sync output
# - Hides GroupTag lines on screen
# - Suppresses NuGet/PSGallery prompts
# - Uses -Assign

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# -------- CONFIG --------
$GroupTag   = 'AutoPilot-NonAdmin'   # applied, but hidden from on-screen output
$UseAssign  = $true                 # add -Assign back
# Pick a known-good script source (v4.0 visible in GitHub mirror) [3](https://andrewstaylor.com/2023/06/08/updated-get-windowsautopilotinfo-with-groups-fix/)
$ScriptUrl  = 'https://raw.githubusercontent.com/LegendEvent/Get-WindowsAutoPilotInfo/main/Get-WindowsAutoPilotInfo.ps1'
$LocalScript = Join-Path $env:WINDIR 'Temp\Get-WindowsAutoPilotInfo.downloaded.ps1'
$LogPath     = Join-Path $env:WINDIR 'Temp\ap-bootstrap.log'
# ------------------------

function Log([string]$m) { "$(Get-Date -Format s) $m" | Out-File -FilePath $LogPath -Append -Encoding UTF8 }
function Say([string]$m) { Microsoft.PowerShell.Utility\Write-Host $m }

try {
    Log "=== ap.ps1 starting ==="
    Say "Uploading HWHash... (import/sync/wait status will appear below)"

    if ($UseAssign) {
        Say "Deployment Profile assignment may take up to 30 minutes - please be patient."
        Say "If you are prompted to install any NuGet packages please accept."
        Say "DONT Forget to PIM elevate to Device Local Admin before Signing In."
        Say "When prompted to Sign In, Please choose Worplace or school account."
        Say "During Sign In please select - No, this app only"
        Say "Finally DONT forget to reboot after the HWHash import has been completed."
        # Autopilot import/processing can take time to reflect. [4](https://stackoverflow.com/questions/66107800/how-to-solve-aadsts700016-error-on-login-with-microsoft-account)
    }

    # TLS 1.2 for older images
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    # Trust PSGallery + install NuGet silently (avoid Y prompts)
    try {
        if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
            Register-PSRepository -Default -ErrorAction SilentlyContinue
        }
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Log "PSGallery set to Trusted."
    } catch { Log "Warning: could not set PSGallery trust." }

    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Log "Installing NuGet provider silently..."
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:$false | Out-Null
    }

    # Download known-good script (avoid corrupted Program Files copy)
    Log "Downloading Get-WindowsAutoPilotInfo from $ScriptUrl"
    Invoke-RestMethod -Uri $ScriptUrl -OutFile $LocalScript -ErrorAction Stop
    Log "Downloaded to $LocalScript"

    # Filter GroupTag output, but keep wait/sync messages
    $patterns = @('GroupTag', 'Group Tag', [regex]::Escape($GroupTag))

    function Write-Host {
        param([Parameter(ValueFromRemainingArguments = $true)] $Object)
        $text = ($Object | ForEach-Object { "$_" }) -join ' '
        foreach ($p in $patterns) { if ($text -match $p) { return } }
        Microsoft.PowerShell.Utility\Write-Host $text
    }

    # Use splatting for reliable parameter binding
    $params = @{
        Online   = $true
        GroupTag = $GroupTag
    }
    if ($UseAssign) { $params['Assign'] = $true }  # wait for assignment [2](https://www.prajwaldesai.com/autopilot-profile-status-shows-not-assigned/)[1](https://learn.microsoft.com/en-us/answers/questions/908202/error-running-%28get-windowsautopilotinfo-ps1%29)

    Log "Executing downloaded script in-process so progress is visible."
    # Avoid StrictMode property crashes during script run (e.g. missing Assigned User property)
    Set-StrictMode -Off
    & $LocalScript @params
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
