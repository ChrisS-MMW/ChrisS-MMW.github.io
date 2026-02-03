# ap.ps1 - bootstrapper (runs known-good Autopilot script, avoids local installed copy)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$log = Join-Path $env:WINDIR "Temp\ap-bootstrap.log"
function Log([string]$m){ "$(Get-Date -Format s) $m" | Tee-Object -FilePath $log -Append }

# Choose a known-good script source (example: a newer revision repo mirror)
$scriptUrl = "https://raw.githubusercontent.com/LegendEvent/Get-WindowsAutoPilotInfo/main/Get-WindowsAutoPilotInfo.ps1"  # [2](https://github.com/LegendEvent/Get-WindowsAutoPilotInfo/blob/main/Get-WindowsAutoPilotInfo.ps1)
$local     = Join-Path $env:WINDIR "Temp\Get-WindowsAutoPilotInfo.ps1"

Log "Downloading Get-WindowsAutoPilotInfo from: $scriptUrl"
Invoke-RestMethod -Uri $scriptUrl -OutFile $local

Log "Running online import with GroupTag AutoPilot-NonAdmin"
& $local -Online -GroupTag "AutoPilot-NonAdmin"
