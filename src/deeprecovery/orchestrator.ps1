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

    $phaseResults = @(
        $preflightPhase,
        $checkPhase,
        $attemptPhase,
        Invoke-DeepRecoverySourceDiscoveryPhase -State $State,
        Invoke-DeepRecoverySourceValidationPhase -State $State,
        Invoke-DeepRecoveryDismPhase -State $State,
        Invoke-DeepRecoverySfcPhase -State $State,
        Invoke-DeepRecoveryPostcheckPhase -State $State,
        Invoke-DeepRecoveryEscalationDecisionPhase -State $State,
        Invoke-DeepRecoveryReinstallPathPhase -State $State,
        Invoke-DeepRecoveryClassificationPhase -State $State -CurrentReport $report
    )

    foreach ($pr in $phaseResults) {
        $report.phases += $pr
        $State.Context['deepRecovery']['phaseTransitions'].Add([pscustomobject]@{
            phase = $pr.phase
            status = $pr.status
            timestamp = Get-Date
        })
    }

    if ($State.Context['deepRecovery']['preflightResult']) {
        $report.preflightResult = $State.Context['deepRecovery']['preflightResult']
    }
    if ($State.Context['deepRecovery']['safeguardCheckResult']) {
        $report.safeguardCheckResult = $State.Context['deepRecovery']['safeguardCheckResult']
    }
    if ($State.Context['deepRecovery']['safeguardResult']) {
        $report.safeguardResult = $State.Context['deepRecovery']['safeguardResult']
    }

    $report.requiresStrongAck = [bool]$State.Context['deepRecovery']['requiresStrongAck']

    $hasFail = @($phaseResults | Where-Object { $_.status -eq 'FAIL' }).Count -gt 0
    $hasWarn = @($phaseResults | Where-Object { $_.status -eq 'WARN' }).Count -gt 0
    $report.overallStatus = if ($hasFail) { 'FAIL' } elseif ($hasWarn) { 'WARN' } else { 'OK' }

    Set-DeepRecoveryScaffoldState -State $State -Report $report

    $stage = New-Stage 'DR-S0' 'Deep Recovery scaffold orchestration'
    $stage.findings.Add("Preflight classification: $($report.preflightResult.classification)")
    $stage.findings.Add("Safeguard classification: $($report.safeguardResult.classification)")
    if ($report.requiresStrongAck) {
        $stage.findings.Add('Rollback safeguard could not be guaranteed; stronger acknowledgement is required in later phases.')
        $stage.recommendations.Add('Do not continue to source/repair phases without explicit stronger acknowledgement.')
    }
    $stage.recommendations.Add('Step 2 completed: preflight+safeguard logic implemented; later phases remain stubs.')

    $status = if ($hasFail) { 'FAIL' } elseif ($hasWarn) { 'WARN' } else { 'OK' }
    Complete-Stage -State $State -Stage $stage -Status $status -ExitCode ($(if($hasFail){1}else{0}))
    return ($(if($hasFail){1}else{0}))
}
