function Invoke-DeepRecoveryPostcheckPhase {
    param([pscustomobject]$State)
    return (New-DeepRecoveryStageResultTemplate -Phase 'POSTCHECK' -Status 'PLANNED' -Summary 'Postcheck scaffold only')
}
