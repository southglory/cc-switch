<#
.SYNOPSIS
  cc-switch - Run multiple Claude Code accounts on one Windows machine.

.DESCRIPTION
  Each Claude Code account gets its own config directory via the
  CLAUDE_CONFIG_DIR environment variable. Claude Code 2.1+ relocates BOTH the
  ~/.claude/ directory AND the ~/.claude.json global-state file into that dir,
  so two profiles are fully isolated and can run side by side in two terminals.

  - "personal" = the default profile = ~/.claude (CLAUDE_CONFIG_DIR unset).
  - other profiles = their own directory (default ~/.claude-<name>).

  Credentials, history, projects and memory are NEVER shared between profiles.

.NOTES
  Windows / PowerShell 7+. No admin rights required.
#>

Set-StrictMode -Version Latest

$script:ConfigDir  = Join-Path $HOME '.cc-switch'
$script:ConfigFile = Join-Path $script:ConfigDir 'profiles.json'

# --- profile registry -------------------------------------------------------

function Get-CcProfiles {
    [CmdletBinding()]
    param()
    if (-not (Test-Path -LiteralPath $script:ConfigFile)) {
        $seed = [ordered]@{
            version  = 1
            default  = 'personal'
            profiles = [ordered]@{
                personal = [ordered]@{ dir = $null;                              desc = '개인 계정 (기본 ~/.claude)' }
                work     = [ordered]@{ dir = (Join-Path $HOME '.claude-work');    desc = '회사 계정' }
            }
        }
        Save-CcProfiles -Data $seed
        return $seed
    }
    $raw = Get-Content -Raw -LiteralPath $script:ConfigFile | ConvertFrom-Json -AsHashtable
    return $raw
}

function Save-CcProfiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Data)
    if (-not (Test-Path -LiteralPath $script:ConfigDir)) {
        New-Item -ItemType Directory -Force -Path $script:ConfigDir | Out-Null
    }
    $Data | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ConfigFile -Encoding utf8
}

function Resolve-CcProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $cfg = Get-CcProfiles
    if (-not $cfg.profiles.ContainsKey($Name)) {
        throw "Unknown profile '$Name'. Known: $($cfg.profiles.Keys -join ', '). Add one with: cc-switch new <name>"
    }
    return $cfg.profiles[$Name]
}

# --- account inspection -----------------------------------------------------

function Get-CcAccountEmail {
    [CmdletBinding()]
    param([AllowNull()][string]$Dir)
    $json = if ([string]::IsNullOrEmpty($Dir)) { Join-Path $HOME '.claude.json' }
            else { Join-Path $Dir '.claude.json' }
    if (-not (Test-Path -LiteralPath $json)) { return $null }
    try {
        # -AsHashtable: ~/.claude.json can hold project keys differing only by
        # casing (C:/… vs c:/…), which makes plain ConvertFrom-Json throw.
        $o = Get-Content -Raw -LiteralPath $json | ConvertFrom-Json -AsHashtable
        if ($o.ContainsKey('oauthAccount') -and $o.oauthAccount -is [hashtable] -and
            $o.oauthAccount.ContainsKey('emailAddress')) {
            return $o.oauthAccount.emailAddress
        }
        return $null
    } catch { return $null }
}

# --- core launcher ----------------------------------------------------------

function Use-ClaudeProfile {
    <#
    .SYNOPSIS  Launch Claude Code under a named profile, then restore the env.
    .EXAMPLE   Use-ClaudeProfile work --version
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(ValueFromRemainingArguments = $true)][object[]]$ClaudeArgs
    )
    $p   = Resolve-CcProfile -Name $Name
    $dir = $p.dir

    if (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    # Warn (once) if this profile has never logged in.
    if ($null -eq (Get-CcAccountEmail -Dir $dir)) {
        Write-Host "ℹ  Profile '$Name' is not logged in yet — run /login inside Claude." -ForegroundColor Yellow
    }

    $had = Test-Path Env:\CLAUDE_CONFIG_DIR
    $old = if ($had) { $env:CLAUDE_CONFIG_DIR } else { $null }
    try {
        if ([string]::IsNullOrEmpty($dir)) {
            if (Test-Path Env:\CLAUDE_CONFIG_DIR) { Remove-Item Env:\CLAUDE_CONFIG_DIR }
        } else {
            $env:CLAUDE_CONFIG_DIR = $dir
        }
        if ($ClaudeArgs) { & claude @ClaudeArgs } else { & claude }
    } finally {
        if ($had) { $env:CLAUDE_CONFIG_DIR = $old }
        elseif (Test-Path Env:\CLAUDE_CONFIG_DIR) { Remove-Item Env:\CLAUDE_CONFIG_DIR }
    }
}

# --- management commands -----------------------------------------------------

function Show-CcStatus {
    [CmdletBinding()]
    param()
    $cfg = Get-CcProfiles
    $activeDir = if (Test-Path Env:\CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { $null }

    $rows = foreach ($name in $cfg.profiles.Keys) {
        $p     = $cfg.profiles[$name]
        $dir   = $p.dir
        $email = Get-CcAccountEmail -Dir $dir
        $isActive = ($null -eq $activeDir -and [string]::IsNullOrEmpty($dir)) -or
                    ($activeDir -and $dir -and ($activeDir.TrimEnd('\') -eq ([string]$dir).TrimEnd('\')))
        [pscustomobject]@{
            ' '     = if ($isActive) { '●' } else { ' ' }
            Profile = $name
            Account = if ($email) { $email } else { '(not logged in)' }
            Dir     = if ([string]::IsNullOrEmpty($dir)) { "$HOME\.claude (default)" } else { $dir }
        }
    }
    $rows | Format-Table -AutoSize
}

function New-CcProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Position = 1)][string]$Dir,
        [string]$Desc = ''
    )
    $cfg = Get-CcProfiles
    if ($cfg.profiles.ContainsKey($Name)) { throw "Profile '$Name' already exists." }
    if ([string]::IsNullOrEmpty($Dir)) { $Dir = Join-Path $HOME ".claude-$Name" }
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $cfg.profiles[$Name] = [ordered]@{ dir = $Dir; desc = $Desc }
    Save-CcProfiles -Data $cfg
    Write-Host "✔ Added profile '$Name' → $Dir" -ForegroundColor Green
    Write-Host "  Launch it with:  Use-ClaudeProfile $Name   (then /login on first run)"
}

function Remove-CcProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [switch]$Purge
    )
    $cfg = Get-CcProfiles
    if (-not $cfg.profiles.ContainsKey($Name)) { throw "Unknown profile '$Name'." }
    if ($Name -eq $cfg.default) { throw "Refusing to remove the default profile '$Name'." }
    $dir = $cfg.profiles[$Name].dir
    $cfg.profiles.Remove($Name)
    Save-CcProfiles -Data $cfg
    Write-Host "✔ Unregistered profile '$Name'." -ForegroundColor Green
    if ($Purge -and -not [string]::IsNullOrEmpty($dir) -and (Test-Path -LiteralPath $dir)) {
        Remove-Item -Recurse -Force -LiteralPath $dir
        Write-Host "  Deleted $dir" -ForegroundColor Green
    } elseif (-not [string]::IsNullOrEmpty($dir)) {
        Write-Host "  Config dir kept at $dir (use -Purge to delete)."
    }
}

# --- CLI dispatcher ----------------------------------------------------------

function Invoke-CcSwitch {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Args)
    $cmd  = if ($Args.Count -ge 1) { [string]$Args[0] } else { 'list' }
    $rest = if ($Args.Count -ge 2) { $Args[1..($Args.Count - 1)] } else { @() }
    switch ($cmd) {
        { $_ -in 'list', 'ls', 'status' } { Show-CcStatus }
        'new'    { New-CcProfile @rest }
        'remove' { Remove-CcProfile @rest }
        'rm'     { Remove-CcProfile @rest }
        'run'    { Use-ClaudeProfile @rest }
        'path'   { (Resolve-CcProfile -Name ([string]$rest[0])).dir }
        default  {
@"
cc-switch — multi-account launcher for Claude Code (Windows)

  cc-switch list                 list profiles + active account
  cc-switch new <name> [dir]     register a new profile
  cc-switch remove <name> [-Purge]  unregister (optionally delete its dir)
  cc-switch run <name> [args]    launch claude under a profile

Daily shortcuts:
  ccp [args]    personal account
  ccw [args]    work account
  ccx <name> [args]   any profile
"@ | Write-Host
        }
    }
}

# --- daily shortcuts ---------------------------------------------------------

function ccp { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Rest) Use-ClaudeProfile -Name 'personal' @Rest }
function ccw { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Rest) Use-ClaudeProfile -Name 'work'     @Rest }
function ccx {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(ValueFromRemainingArguments = $true)][object[]]$Rest
    )
    Use-ClaudeProfile -Name $Name @Rest
}

Set-Alias -Name cc-switch -Value Invoke-CcSwitch

Export-ModuleMember -Function `
    Use-ClaudeProfile, Show-CcStatus, New-CcProfile, Remove-CcProfile, Invoke-CcSwitch, `
    Get-CcProfiles, Get-CcAccountEmail, ccp, ccw, ccx `
    -Alias cc-switch
