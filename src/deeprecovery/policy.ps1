function Get-DeepRecoveryPolicyPlaceholders {
    return @{
        DR_PLACEHOLDER = [pscustomobject]@{ action='none'; retry_allowed=$false; step='scaffold' }
    }
}
