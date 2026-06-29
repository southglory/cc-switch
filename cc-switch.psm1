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

$script:ConfigDir  = if ($env:CC_SWITCH_HOME) { $env:CC_SWITCH_HOME } else { Join-Path $HOME '.cc-switch' }
$script:ConfigFile = Join-Path $script:ConfigDir 'profiles.json'

# --- profile registry -------------------------------------------------------

function Get-CcProfiles {
    [CmdletBinding()]
    param()
    if (-not (Test-Path -LiteralPath $script:ConfigFile)) {
        $seed = [ordered]@{
            version  = 2
            default  = 'personal'
            profiles = [ordered]@{
                personal = [ordered]@{ dir = $null;                           alias = 'ccp'; desc = 'Personal account (default ~/.claude)' }
                work     = [ordered]@{ dir = (Join-Path $HOME '.claude-work'); alias = 'ccw'; desc = 'Work account' }
            }
        }
        Save-CcProfiles -Data $seed
        return $seed
    }
    $raw = Get-Content -Raw -LiteralPath $script:ConfigFile | ConvertFrom-Json -AsHashtable
    if (-not $raw.ContainsKey('version') -or [int]$raw.version -lt 2) {
        Copy-Item -LiteralPath $script:ConfigFile -Destination "$($script:ConfigFile).bak" -Force
        foreach ($pair in @{ personal = 'ccp'; work = 'ccw' }.GetEnumerator()) {
            if ($raw.profiles.ContainsKey($pair.Key) -and -not $raw.profiles[$pair.Key].ContainsKey('alias')) {
                $raw.profiles[$pair.Key]['alias'] = $pair.Value
            }
        }
        $raw['version'] = 2
        Save-CcProfiles -Data $raw
    }
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
    # Expand "~" / relative paths to an absolute filesystem path. PowerShell does NOT
    # expand "~" when assigning to an env var, so a stored "~/.claude-work" would make
    # Claude Code create a literal "~" folder in the cwd. (POSIX cc_run does the same.)
    if (-not [string]::IsNullOrEmpty($dir)) {
        $dir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($dir)
    }

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
            Alias   = if ($p.alias) { $p.alias } else { '-' }
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
        [string]$Alias = '',
        [string]$Desc = ''
    )
    $cfg = Get-CcProfiles
    if ($cfg.profiles.ContainsKey($Name)) { throw "Profile '$Name' already exists." }
    if ($Alias) {
        if ($Alias -notmatch '^[a-zA-Z][a-zA-Z0-9_-]*$') { throw "Invalid alias '$Alias'." }
        foreach ($p in $cfg.profiles.Values) { if ($p.alias -eq $Alias) { throw "Alias '$Alias' is already in use." } }
    }
    if ([string]::IsNullOrEmpty($Dir)) { $Dir = Join-Path $HOME ".claude-$Name" }
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $cfg.profiles[$Name] = [ordered]@{ dir = $Dir; alias = ($Alias ? $Alias : $null); desc = $Desc }
    Save-CcProfiles -Data $cfg
    Register-CcAliases
    Write-Host "✔ Added profile '$Name' → $Dir$(if ($Alias) { "  (alias: $Alias)" })" -ForegroundColor Green
    Write-Host "  Launch it with:  $(if ($Alias) { $Alias } else { "ccx $Name" })   (then /login on first run)"
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
        'local'  { cclocal @rest }
        'alias'   { Set-CcAlias @rest }
        'unalias' { Remove-CcAlias @rest }
        'path'   { (Resolve-CcProfile -Name ([string]$rest[0])).dir }
        default  {
@"
cc-switch — multi-account launcher for Claude Code (Windows)

  cc-switch list                 list profiles + active account
  cc-switch new <name> [dir] [-Alias <short>]   register a profile (+shortcut)
  cc-switch remove <name> [-Purge]  unregister (optionally delete its dir)
  cc-switch alias <short> <name>    add/change a shortcut
  cc-switch unalias <short>         drop a shortcut
  cc-switch run <name> [args]    launch claude under a profile
  cc-switch local [args]         launch a PROJECT-LOCAL account ($PWD/.cc-local)

Shortcuts are generated from the registry, e.g.  ccp  ccw  ccx <name>
Project-local (current dir only, not a saved profile):  cclocal
"@ | Write-Host
        }
    }
}

# --- alias management + generation -------------------------------------------

function Set-CcAlias {
    [CmdletBinding()] param(
        [Parameter(Mandatory, Position=0)][string]$Alias,
        [Parameter(Mandatory, Position=1)][string]$Name)
    if ($Alias -notmatch '^[a-zA-Z][a-zA-Z0-9_-]*$') { throw "Invalid alias '$Alias'." }
    $cfg = Get-CcProfiles
    if (-not $cfg.profiles.ContainsKey($Name)) { throw "Unknown profile '$Name'." }
    foreach ($kv in $cfg.profiles.GetEnumerator()) {
        if ($kv.Value.alias -eq $Alias -and $kv.Key -ne $Name) { throw "Alias '$Alias' already used by '$($kv.Key)'." }
    }
    if (Get-Command $Alias -ErrorAction SilentlyContinue) { Write-Host "note — '$Alias' shadows an existing command." -ForegroundColor Yellow }
    $cfg.profiles[$Name].alias = $Alias
    Save-CcProfiles -Data $cfg
    Register-CcAliases
}

function Remove-CcAlias {
    [CmdletBinding()] param([Parameter(Mandatory, Position=0)][string]$Alias)
    $cfg = Get-CcProfiles
    foreach ($p in $cfg.profiles.Values) { if ($p.alias -eq $Alias) { $p.alias = $null } }
    Save-CcProfiles -Data $cfg
    if (Test-Path "Function:\$Alias") { Remove-Item "Function:\$Alias" }
    Register-CcAliases
}

# Generate one global function per aliased profile (replaces hard-coded ccp/ccw).
function Register-CcAliases {
    [CmdletBinding()] param()
    $cfg = Get-CcProfiles
    foreach ($kv in $cfg.profiles.GetEnumerator()) {
        $alias = $kv.Value.alias
        if (-not $alias) { continue }
        $name = $kv.Key
        $body = "param([Parameter(ValueFromRemainingArguments=`$true)][object[]]`$Rest) Use-ClaudeProfile -Name '$name' @Rest"
        Set-Item -Path "Function:\global:$alias" -Value ([ScriptBlock]::Create($body))
    }
}

function ccx {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(ValueFromRemainingArguments = $true)][object[]]$Rest
    )
    Use-ClaudeProfile -Name $Name @Rest
}

# --- project-local accounts -------------------------------------------------

# Ensure <dir>/.gitignore ignores .cc-local/ (create or append; idempotent).
function Set-CcLocalGitignore {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Dir)
    $gi = Join-Path $Dir '.gitignore'
    try {
        if (-not (Test-Path -LiteralPath $gi)) {
            Set-Content -LiteralPath $gi -Encoding utf8 -Value @('# cc-switch project-local account (keep out of git)', '.cc-local/')
        } elseif (-not (Select-String -LiteralPath $gi -SimpleMatch '.cc-local/' -Quiet)) {
            Add-Content -LiteralPath $gi -Encoding utf8 -Value '.cc-local/'
        }
    } catch { Write-Host "note — could not update $gi ($($_.Exception.Message))" -ForegroundColor Yellow }
}

# Run Claude Code with a PROJECT-LOCAL config dir ($PWD/.cc-local), isolated per
# directory. Not a registered profile — never appears in `cc-switch list`.
function cclocal {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Rest)
    $proj = (Get-Location).Path
    $dir  = Join-Path $proj '.cc-local'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-CcLocalGitignore -Dir $proj
    if ($null -eq (Get-CcAccountEmail -Dir $dir)) {
        Write-Host "ℹ  Local account in ./.cc-local is not logged in yet — run /login inside Claude." -ForegroundColor Yellow
    }
    $had = Test-Path Env:\CLAUDE_CONFIG_DIR
    $old = if ($had) { $env:CLAUDE_CONFIG_DIR } else { $null }
    try {
        $env:CLAUDE_CONFIG_DIR = $dir
        if ($Rest) { & claude @Rest } else { & claude }
    } finally {
        if ($had) { $env:CLAUDE_CONFIG_DIR = $old }
        elseif (Test-Path Env:\CLAUDE_CONFIG_DIR) { Remove-Item Env:\CLAUDE_CONFIG_DIR }
    }
}

Set-Alias -Name cc-switch -Value Invoke-CcSwitch

Register-CcAliases

Export-ModuleMember -Function `
    Use-ClaudeProfile, Show-CcStatus, New-CcProfile, Remove-CcProfile, Invoke-CcSwitch, `
    Get-CcProfiles, Get-CcAccountEmail, Set-CcAlias, Remove-CcAlias, Register-CcAliases, ccx, cclocal `
    -Alias cc-switch
