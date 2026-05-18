@{
    # PSScriptAnalyzer configuration for chrysalis.
    # Rule exclusions document intentional design choices; do not add
    # a rule to this list without first checking the SDD and an ADR.
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        # Write-Host is the intended console-output path for a CLI tool
        # designed to be watched over RDP. See src/lib/Logging.ps1.
        'PSAvoidUsingWriteHost'

        # Empty catch blocks in chrysalis are deliberate best-effort
        # cleanup (handle disposal, logout calls); they live inside
        # finally-style logic where a swallow is correct.
        'PSAvoidUsingEmptyCatchBlock'

        # 'New-' prefixed builders (LogContext, TestSecureString,
        # MinimalConfig) are not state-changing in the cmdlet-binding
        # sense; ShouldProcess would be ceremony with no benefit.
        'PSUseShouldProcessForStateChangingFunctions'

        # Plural nouns are correct where the cmdlet operates on a
        # collection or compound concept (Properties, Credentials).
        'PSUseSingularNouns'

        # chrysalis writes BOM-less UTF-8 for log/grep friendliness;
        # source files match for consistency.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
