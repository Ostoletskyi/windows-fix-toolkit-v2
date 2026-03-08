function Get-DeepRecoverySignaturePlaceholders {
    return @(
        [pscustomobject]@{ signature='DR_PLACEHOLDER'; category='scaffold'; severity='info'; action='none' }
    )
}
