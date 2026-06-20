$ErrorActionPreference = 'Stop'
$tmp = Join-Path $env:TEMP ("ccsw_" + [guid]::NewGuid())
$env:CC_SWITCH_HOME = Join-Path $tmp '.cc-switch'
New-Item -ItemType Directory -Force -Path $env:CC_SWITCH_HOME | Out-Null
$reg = Join-Path $env:CC_SWITCH_HOME 'profiles.json'
# a v1 registry with NO aliases
'{"version":1,"default":"personal","profiles":{"personal":{"dir":null,"desc":"p"},"work":{"dir":"~/.claude-work","desc":"w"}}}' |
  Set-Content -LiteralPath $reg -Encoding utf8

Import-Module "$PSScriptRoot/../cc-switch.psm1" -Force
$cfg = Get-CcProfiles
$pass = $true
if ($cfg.version -ne 2) { Write-Host "NOT OK - migrated to v2"; $pass=$false } else { Write-Host "ok - migrated to v2" }
if ($cfg.profiles['personal'].alias -ne 'ccp') { Write-Host "NOT OK - ccp backfilled"; $pass=$false } else { Write-Host "ok - ccp backfilled" }
if ($cfg.profiles['work'].alias -ne 'ccw') { Write-Host "NOT OK - ccw backfilled"; $pass=$false } else { Write-Host "ok - ccw backfilled" }
if (-not (Test-Path "$reg.bak")) { Write-Host "NOT OK - backup written"; $pass=$false } else { Write-Host "ok - backup written" }

New-CcProfile -Name team -Alias cct
$cfg = Get-CcProfiles
if ($cfg.profiles['team'].alias -ne 'cct') { Write-Host "NOT OK - new -Alias"; $pass=$false } else { Write-Host "ok - new -Alias" }
if (-not (Get-Command cct -ErrorAction SilentlyContinue)) { Write-Host "NOT OK - cct function generated"; $pass=$false } else { Write-Host "ok - cct function generated" }

# alias / unalias
Set-CcAlias ccteam team
$cfg = Get-CcProfiles
if ($cfg.profiles['team'].alias -ne 'ccteam') { Write-Host "NOT OK - Set-CcAlias"; $pass=$false } else { Write-Host "ok - Set-CcAlias" }
Remove-CcAlias ccteam
$cfg = Get-CcProfiles
if ($cfg.profiles['team'].alias) { Write-Host "NOT OK - Remove-CcAlias"; $pass=$false } else { Write-Host "ok - Remove-CcAlias" }

# refuse removing default
try { Remove-CcProfile -Name personal; Write-Host "NOT OK - refuse remove default"; $pass=$false }
catch { Write-Host "ok - refuse remove default" }

Remove-Module cc-switch -Force; Remove-Item -Recurse -Force $tmp
if (-not $pass) { exit 1 }
