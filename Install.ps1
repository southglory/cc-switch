<#
.SYNOPSIS
  Install cc-switch into the current user's PowerShell (no admin required).
.DESCRIPTION
  - Copies the module to the user module path.
  - Adds 'Import-Module cc-switch' to your PowerShell profile.
  - Seeds the profile registry (personal + work).
.EXAMPLE
  pwsh -File .\Install.ps1
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot

# 1. Copy module to the user module path -------------------------------------
$moduleRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules\cc-switch'
if (Test-Path $moduleRoot) {
    if (-not $Force) { Write-Host "Updating existing install at $moduleRoot" }
    Remove-Item -Recurse -Force $moduleRoot
}
New-Item -ItemType Directory -Force -Path $moduleRoot | Out-Null
Copy-Item (Join-Path $src 'cc-switch.psm1') $moduleRoot
Copy-Item (Join-Path $src 'cc-switch.psd1') $moduleRoot -ErrorAction SilentlyContinue
Write-Host "✔ Installed module → $moduleRoot" -ForegroundColor Green

# 2. Ensure the profile imports it -------------------------------------------
$profilePath = $PROFILE.CurrentUserAllHosts
$profileDir  = Split-Path $profilePath
if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }
if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Path $profilePath | Out-Null }

$line = 'Import-Module cc-switch'
$content = Get-Content -Raw -LiteralPath $profilePath -ErrorAction SilentlyContinue
if ($null -eq $content -or $content -notmatch [regex]::Escape($line)) {
    Add-Content -LiteralPath $profilePath -Value "`n# cc-switch: multi-account Claude Code`n$line"
    Write-Host "✔ Added '$line' to $profilePath" -ForegroundColor Green
} else {
    Write-Host "• Profile already imports cc-switch ($profilePath)"
}

# 3. Seed the registry + load now --------------------------------------------
Import-Module $moduleRoot\cc-switch.psm1 -Force
Get-CcProfiles | Out-Null
Write-Host ""
Write-Host "Done. Open a NEW terminal (or run: Import-Module cc-switch -Force), then:" -ForegroundColor Cyan
Write-Host "  cc-switch list      # see profiles"
Write-Host "  ccw                 # launch work account → run /login on first start"
Write-Host "  ccp                 # launch personal account"
Show-CcStatus
