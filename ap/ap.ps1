# ap.ps1 - bootstrapper
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$target = 'https://raw.githubusercontent.com/ChrisS-MMW/HWHash/refs/heads/main/maersk-hwhash'

# Optional: make sure TLS 1.2 is enabled (useful on older builds)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# Download and execute
$script = Invoke-RestMethod -Uri $target -UseBasicParsing
Invoke-Expression $script
