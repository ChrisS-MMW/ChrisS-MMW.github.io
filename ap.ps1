# ap.ps1 - bootstrapper for OOBE use
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Ensure TLS 1.2 (helps on older images)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$target = 'https://raw.githubusercontent.com/ChrisS-MMW/HWHash/refs/heads/main/maersk-hwhash'

$script = Invoke-RestMethod -Uri $target -UseBasicParsing
Invoke-Expression $script
