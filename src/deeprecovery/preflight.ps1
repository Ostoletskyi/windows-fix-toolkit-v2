function Invoke-DeepRecoveryPreflightPhase {
    param([pscustomobject]$State)
    return (New-DeepRecoveryStageResultTemplate -Phase 'PREFLIGHT' -Status 'OK' -Summary 'Preflight scaffold created')
}
