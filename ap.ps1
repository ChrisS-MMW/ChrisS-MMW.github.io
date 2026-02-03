Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$pinned = '3.5'
$log = Join-Path $env:WINDIR 'Temp\ap-bootstrap.log'
function Log([string]$m){ "$(Get-Date -Format s) $m" | Tee-Object -FilePath $log -Append }

Log "Pinning Get-WindowsAutoPilotInfo to v$pinned"

Uninstall-Script -Name Get-WindowsAutoPilotInfo -AllVersions -Force -ErrorAction SilentlyContinue
Install-Script  -Name Get-WindowsAutoPilotInfo -RequiredVersion $pinned -Force

$inst = Get-InstalledScript -Name Get-WindowsAutoPilotInfo
Log "Installed: $($inst.Name) v$($inst.Version) at $($inst.InstalledLocation)"

Log "Running online import with GroupTag AutoPilot-NonAdmin"
Get-WindowsAutoPilotInfo.ps1 -Online -Assign -GroupTag "AutoPilot-NonAdmin"
