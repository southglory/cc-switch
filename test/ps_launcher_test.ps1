# Verifies Use-ClaudeProfile expands a "~"-prefixed profile dir to an absolute path
# before exporting CLAUDE_CONFIG_DIR (PowerShell does NOT expand ~ in env-var strings,
# so a literal "~" would make Claude Code create a bogus "~" folder in the cwd).
$ErrorActionPreference = 'Stop'
$tmp = Join-Path $env:TEMP ("cclaunch_" + [guid]::NewGuid())
$env:CC_SWITCH_HOME = Join-Path $tmp '.cc-switch'
New-Item -ItemType Directory -Force -Path $env:CC_SWITCH_HOME | Out-Null
$reg = Join-Path $env:CC_SWITCH_HOME 'profiles.json'

# registry with a "~"-form work dir (as the extension / shared registry writes it)
'{"version":2,"default":"personal","profiles":{"personal":{"dir":null,"alias":"ccp"},"work":{"dir":"~/.claude-work","alias":"ccw"}}}' |
  Set-Content -LiteralPath $reg -Encoding utf8

# fake `claude` on PATH that records the CLAUDE_CONFIG_DIR it was launched with
$bin = Join-Path $tmp 'bin'; New-Item -ItemType Directory -Force $bin | Out-Null
$out = Join-Path $tmp 'env.txt'
@"
@echo off
echo %CLAUDE_CONFIG_DIR%> "$out"
"@ | Set-Content -LiteralPath (Join-Path $bin 'claude.cmd') -Encoding ascii
$env:PATH = "$bin;$env:PATH"

Import-Module "$PSScriptRoot/../cc-switch.psm1" -Force
Use-ClaudeProfile work | Out-Null

$recorded = (Get-Content -LiteralPath $out -Raw).Trim()
$expected = Join-Path $HOME '.claude-work'
$pass = $true
if ($recorded -match '~') { Write-Host "NOT OK - CLAUDE_CONFIG_DIR still contains '~' ($recorded)"; $pass = $false }
else { Write-Host "ok - tilde expanded" }
if ($recorded -ieq $expected) { Write-Host "ok - resolves to $expected" } else { Write-Host "NOT OK - got '$recorded' expected '$expected'"; $pass = $false }

Remove-Module cc-switch -Force; Remove-Item -Recurse -Force $tmp
if (-not $pass) { exit 1 }
