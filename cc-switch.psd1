@{
    RootModule        = 'cc-switch.psm1'
    ModuleVersion     = '0.3.0'
    GUID              = 'b3f0c4d2-1a6e-4c2a-9b7e-0c8f9a2d1e44'
    Author            = 'southglory'
    Description       = 'Run multiple Claude Code accounts on one machine (Windows/macOS/Linux) via CLAUDE_CONFIG_DIR isolation, with user-defined launch shortcuts.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('Use-ClaudeProfile','Show-CcStatus','New-CcProfile','Remove-CcProfile','Invoke-CcSwitch','Get-CcProfiles','Get-CcAccountEmail','Set-CcAlias','Remove-CcAlias','Register-CcAliases','ccx','cclocal')
    AliasesToExport   = @('cc-switch')
    CmdletsToExport   = @()
    VariablesToExport = @()
    PrivateData = @{ PSData = @{
        Tags       = @('claude','claude-code','account-switcher','windows','macos','linux','powershell')
        ProjectUri = 'https://github.com/southglory/cc-switch'
    } }
}
