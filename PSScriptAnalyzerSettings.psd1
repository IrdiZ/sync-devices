# Lint: Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
@{
    ExcludeRules = @(
        # Script-internal helpers, not a published module: these module-design rules do not apply.
        'PSUseSingularNouns',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSAvoidUsingPositionalParameters',
        # Setup is an interactive console script; its Write-Host output is the point.
        'PSAvoidUsingWriteHost',
        # Empty catch blocks are deliberate probes ("does this folder or device exist yet?").
        'PSAvoidUsingEmptyCatchBlock'
    )
}
