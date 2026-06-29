# Verifies `cclocal` launches Claude with a PROJECT-LOCAL config dir ($PWD/.cc-local),
# creates it, and keeps it out of git via .gitignore.
$ErrorActionPreference = 'Stop'
$tmp = Join-Path $env:TEMP ("cclocal_" + [guid]::NewGuid())
$proj = Join-Path $tmp 'proj'
New-Item -ItemType Directory -Force $proj | Out-Null
$env:CC_SWITCH_HOME = Join-Path $tmp '.cc-switch'

# fake `claude` on PATH that records CLAUDE_CONFIG_DIR
$bin = Join-Path $tmp 'bin'; New-Item -ItemType Directory -Force $bin | Out-Null
$out = Join-Path $tmp 'env.txt'
@"
@echo off
echo %CLAUDE_CONFIG_DIR%> "$out"
"@ | Set-Content -LiteralPath (Join-Path $bin 'claude.cmd') -Encoding ascii
$env:PATH = "$bin;$env:PATH"

Import-Module "$PSScriptRoot/../cc-switch.psm1" -Force
Push-Location $proj
$pass = $true
cclocal --hi | Out-Null
$rec = (Get-Content -LiteralPath $out -Raw).Trim()
$expected = Join-Path $proj '.cc-local'
if ($rec -ieq $expected) { Write-Host "ok - cclocal exports `$PWD/.cc-local" } else { Write-Host "NOT OK - got '$rec' expected '$expected'"; $pass = $false }
if (Test-Path -LiteralPath $expected) { Write-Host "ok - .cc-local created" } else { Write-Host "NOT OK - .cc-local created"; $pass = $false }
$gi = Join-Path $proj '.gitignore'
if ((Test-Path -LiteralPath $gi) -and (Select-String -LiteralPath $gi -SimpleMatch '.cc-local/' -Quiet)) { Write-Host "ok - .gitignore ignores .cc-local" } else { Write-Host "NOT OK - .gitignore"; $pass = $false }
cclocal --hi | Out-Null   # second run must not duplicate
$count = (Select-String -LiteralPath $gi -SimpleMatch '.cc-local/').Count
if ($count -eq 1) { Write-Host "ok - gitignore line not duplicated" } else { Write-Host "NOT OK - duplicated ($count)"; $pass = $false }
Pop-Location

Remove-Module cc-switch -Force; Remove-Item -Recurse -Force $tmp
if (-not $pass) { exit 1 }
