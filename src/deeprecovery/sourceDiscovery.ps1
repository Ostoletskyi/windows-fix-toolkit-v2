function Invoke-DeepRecoverySourceDiscoveryPhase {
    param([pscustomobject]$State)
    return (New-DeepRecoveryStageResultTemplate -Phase 'SOURCE_DISCOVERY' -Status 'PLANNED' -Summary 'Source discovery scaffold only')
}
