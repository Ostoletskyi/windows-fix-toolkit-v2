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
    $escalationPhase = Invoke-DeepRecoveryEscalationDecisionPhase -State $State
    $reinstallPhase = Invoke-DeepRecoveryReinstallPathPhase -State $State

    $phaseResults = @(
        $preflightPhase,
        $checkPhase,
        $attemptPhase,
        $sourceDiscoveryPhase,
        $sourceValidationPhase,
        $dismPhase,
        $sfcPhase,
        $postcheckPhase,
        $escalationPhase,
        $reinstallPhase
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
    if ($State.Context['deepRecovery']['escalationDecisionResult']) { $report.escalationDecisionResult = $State.Context['deepRecovery']['escalationDecisionResult'] }
    if ($State.Context['deepRecovery']['reinstallPathResult']) { $report.reinstallPathResult = $State.Context['deepRecovery']['reinstallPathResult'] }

    $report.machineProfile = [pscustomobject]@{
        family = $report.preflightResult.os.family
        edition = $report.preflightResult.os.edition
        architecture = $report.preflightResult.os.architecture
        build = $report.preflightResult.os.build
        version = $report.preflightResult.os.version
        uiLanguage = $report.preflightResult.os.uiLanguage
    }

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

    if ($report.postcheckResult.classification -eq 'resolved') { $report.confidence = 'high' }
    elseif ($report.postcheckResult.classification -eq 'inconclusive') { $report.confidence = 'medium' }
    else { $report.confidence = 'low' }

    $report.finalSummary = "Escalation decision: $($report.escalationDecisionResult.decision). Reinstall recommended: $($report.reinstallPathResult.recommended). Reboot recommended: $($report.postcheckResult.rebootRecommended)."

    Set-DeepRecoveryScaffoldState -State $State -Report $report

    $stage = New-Stage 'DR-S0' 'Deep Recovery scaffold orchestration'
    $stage.findings.Add("Machine profile: $($report.machineProfile.family) | $($report.machineProfile.edition) | $($report.machineProfile.architecture) | build $($report.machineProfile.build)")
    $stage.findings.Add("Preflight classification: $($report.preflightResult.classification)")
    $stage.findings.Add("Safeguard classification: $($report.safeguardResult.classification)")
    $stage.findings.Add("Source validation: $($report.sourceValidationResult.validation)")
    $stage.findings.Add("DISM outcome: $($report.dismResult.outcome); SFC outcome: $($report.sfcResult.outcome)")
    $stage.findings.Add("Postcheck classification: $($report.postcheckResult.classification)")
    $stage.findings.Add("Escalation decision: $($report.escalationDecisionResult.decision)")
    $stage.findings.Add("Reinstall recommended: $($report.reinstallPathResult.recommended)")
    $stage.findings.Add("Final confidence: $($report.confidence)")

    if ($report.requiresStrongAck) {
        $stage.findings.Add('Severe acknowledgement remains required for high-risk continuation.')
    }
    $stage.recommendations.Add('Step 4 completed: final escalation/reinstall-path policy and reporting are in place.')
    $stage.recommendations.Add('Safety constraints enforced: no silent reinstall and no unsupported direct system-file transplantation.')

    $status = if ($hasFail) { 'FAIL' } elseif ($hasWarn) { 'WARN' } else { 'OK' }
    Complete-Stage -State $State -Stage $stage -Status $status -ExitCode ($(if($hasFail){1}else{0}))
    return ($(if($hasFail){1}else{0}))
}
