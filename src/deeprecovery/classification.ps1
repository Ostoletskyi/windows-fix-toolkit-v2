function Invoke-DeepRecoveryClassificationPhase {
    param([pscustomobject]$State,[pscustomobject]$CurrentReport)

    $summary = 'Classification scaffold finalized for Step 2 preflight+safeguard outputs'
    if ($CurrentReport -and $CurrentReport.requiresStrongAck) {
        $summary = 'Classification indicates stronger acknowledgement required due to missing rollback safeguard'
    }

    $status = 'PLANNED'
    if ($CurrentReport) {
        if ($CurrentReport.overallStatus -eq 'FAIL') { $status = 'FAIL' }
        elseif ($CurrentReport.overallStatus -eq 'WARN') { $status = 'WARN' }
        else { $status = 'OK' }
    }

    return (New-DeepRecoveryStageResultTemplate -Phase 'FINAL_REPORT' -Status $status -Summary $summary)
}
