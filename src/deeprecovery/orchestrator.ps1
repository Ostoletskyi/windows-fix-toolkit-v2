function Invoke-DeepRecoveryScaffold {
    param([pscustomobject]$State)

    $report = New-DeepRecoveryFinalReportTemplate
    $phases = @(
        'PREFLIGHT',
        'SAFEGUARD_CHECK',
        'SAFEGUARD_ATTEMPT',
        'SOURCE_DISCOVERY',
        'SOURCE_VALIDATION',
        'REPAIR_STAGE_DISM',
        'REPAIR_STAGE_SFC',
        'POSTCHECK',
        'ESCALATION_DECISION',
        'REINSTALL_PATH',
        'FINAL_REPORT'
    )

    if (-not $State.Context['deepRecovery']) {
        $State.Context['deepRecovery'] = [ordered]@{}
    }
    $State.Context['deepRecovery']['phasePlan'] = $phases
    $State.Context['deepRecovery']['phaseTransitions'] = New-Object System.Collections.Generic.List[object]

    $preflightPhase = Invoke-DeepRecoveryPreflightPhase -State $State
    $checkPhase = Invoke-DeepRecoverySafeguardCheckPhase -State $State
    $attemptPhase = Invoke-DeepRecoverySafeguardAttemptPhase -State $State
    $sourceDiscoveryPhase = Invoke-DeepRecoverySourceDiscoveryPhase -State $State
    $sourceValidationPhase = Invoke-DeepRecoverySourceValidationPhase -State $State
    $dismPhase = Invoke-DeepRecoveryDismPhase -State $State
    $sfcPhase = Invoke-DeepRecoverySfcPhase -State $State
    $postcheckPhase = Invoke-DeepRecoveryPostcheckPhase -State $State

    $phaseResults = @(
        $preflightPhase,
        $checkPhase,
        $attemptPhase,
        $sourceDiscoveryPhase,
        $sourceValidationPhase,
        $dismPhase,
        $sfcPhase,
        $postcheckPhase,
        Invoke-DeepRecoveryEscalationDecisionPhase -State $State,
        Invoke-DeepRecoveryReinstallPathPhase -State $State
    )

    foreach ($pr in $phaseResults) {
        $report.phases += $pr
        $State.Context['deepRecovery']['phaseTransitions'].Add([pscustomobject]@{
            phase = $pr.phase
            status = $pr.status
            timestamp = Get-Date
        })
    }

    if ($State.Context['deepRecovery']['preflightResult']) { $report.preflightResult = $State.Context['deepRecovery']['preflightResult'] }
    if ($State.Context['deepRecovery']['safeguardCheckResult']) { $report.safeguardCheckResult = $State.Context['deepRecovery']['safeguardCheckResult'] }
    if ($State.Context['deepRecovery']['safeguardResult']) { $report.safeguardResult = $State.Context['deepRecovery']['safeguardResult'] }
    if ($State.Context['deepRecovery']['sourceDiscoveryResult']) { $report.sourceDiscoveryResult = $State.Context['deepRecovery']['sourceDiscoveryResult'] }
    if ($State.Context['deepRecovery']['sourceValidationResult']) { $report.sourceValidationResult = $State.Context['deepRecovery']['sourceValidationResult'] }
    if ($State.Context['deepRecovery']['dismResult']) { $report.dismResult = $State.Context['deepRecovery']['dismResult'] }
    if ($State.Context['deepRecovery']['sfcResult']) { $report.sfcResult = $State.Context['deepRecovery']['sfcResult'] }
    if ($State.Context['deepRecovery']['postcheckResult']) { $report.postcheckResult = $State.Context['deepRecovery']['postcheckResult'] }

    $report.requiresStrongAck = [bool]$State.Context['deepRecovery']['requiresStrongAck']

    $hasFail = @($phaseResults | Where-Object { $_.status -eq 'FAIL' }).Count -gt 0
    $hasWarn = @($phaseResults | Where-Object { $_.status -eq 'WARN' }).Count -gt 0
    $report.overallStatus = if ($hasFail) { 'FAIL' } elseif ($hasWarn) { 'WARN' } else { 'OK' }

    $finalPhase = Invoke-DeepRecoveryClassificationPhase -State $State -CurrentReport $report
    $phaseResults += $finalPhase
    $report.phases += $finalPhase
    $State.Context['deepRecovery']['phaseTransitions'].Add([pscustomobject]@{
        phase = $finalPhase.phase
        status = $finalPhase.status
        timestamp = Get-Date
    })

    $hasFail = @($phaseResults | Where-Object { $_.status -eq 'FAIL' }).Count -gt 0
    $hasWarn = @($phaseResults | Where-Object { $_.status -eq 'WARN' }).Count -gt 0

    Set-DeepRecoveryScaffoldState -State $State -Report $report

    $stage = New-Stage 'DR-S0' 'Deep Recovery scaffold orchestration'
    $stage.findings.Add("Preflight classification: $($report.preflightResult.classification)")
    $stage.findings.Add("Safeguard classification: $($report.safeguardResult.classification)")
    $stage.findings.Add("Source validation: $($report.sourceValidationResult.validation)")
    $stage.findings.Add("DISM outcome: $($report.dismResult.outcome); SFC outcome: $($report.sfcResult.outcome)")
    $stage.findings.Add("Postcheck classification: $($report.postcheckResult.classification)")

    if ($report.requiresStrongAck) {
        $stage.findings.Add('Rollback safeguard could not be guaranteed; stronger acknowledgement is required for high-risk continuation.')
    }

    $stage.recommendations.Add('Step 3 completed: source handling + DISM/SFC/postcheck implemented; escalation/reinstall remain stubs.')

    $status = if ($hasFail) { 'FAIL' } elseif ($hasWarn) { 'WARN' } else { 'OK' }
    Complete-Stage -State $State -Stage $stage -Status $status -ExitCode ($(if($hasFail){1}else{0}))
    return ($(if($hasFail){1}else{0}))
}
