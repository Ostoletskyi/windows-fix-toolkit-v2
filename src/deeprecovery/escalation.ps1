function Resolve-DeepRecoveryScenario {
    param([pscustomobject]$State)

    $safeguard = $State.Context['deepRecovery']['safeguardResult']
    $source = $State.Context['deepRecovery']['sourceValidationResult']
    $dism = $State.Context['deepRecovery']['dismResult']
    $sfc = $State.Context['deepRecovery']['sfcResult']
    $post = $State.Context['deepRecovery']['postcheckResult']
    $pre = $State.Context['deepRecovery']['preflightResult']

    $normEvents = @()
    try { $normEvents = @($State.Context['normalized_events']) } catch { $normEvents = @() }
    if (@($normEvents | Where-Object { $_ -and $_.signature -eq 'EXIT_CODE_NOT_CAPTURED' }).Count -gt 0) {
        return 'toolkit_internal_failure'
    }

    if ($dism -and $dism.classification -eq 'toolkit_internal_execution_failure') { return 'toolkit_internal_failure' }
    if ($source -and $source.validation -eq 'mismatch') { return 'source_mismatch' }
    if ($source -and $source.reason -match 'offline') { return 'offline_required' }
    if ($pre -and $pre.winREStatus -eq 'Disabled' -and $post -and $post.classification -eq 'remains') { return 'winre_required' }

    if ($safeguard -and $safeguard.osFamily -eq 'Server') {
        if ($safeguard.classification -eq 'safeguard already available') { return 'server_backup_ready' }
        return 'server_no_rollback_artifact'
    }

    if ($safeguard -and $safeguard.classification -eq 'safeguard blocked by policy') { return 'client_policy_disabled_restore' }
    if ($safeguard -and $safeguard.classification -in @('safeguard already available','safeguard successfully created')) {
        if ($source -and $source.validation -in @('valid','partial match') -and $post -and $post.classification -in @('remains','inconclusive')) {
            return 'valid_source_failed_repair'
        }
        return 'client_restore_available'
    }

    if ($safeguard -and $safeguard.classification -in @('safeguard unavailable but continuable','safeguard unsupported','safeguard failed')) {
        return 'client_restore_unavailable'
    }

    if ($dism -and $dism.classification -eq 'servicing_component_store_problem') { return 'windows_servicing_failure' }

    return 'unsupported_high_risk'
}

function Invoke-DeepRecoveryEscalationDecisionPhase {
    param([pscustomobject]$State)

    $phase = New-DeepRecoveryStageResultTemplate -Phase 'ESCALATION_DECISION' -Status 'OK' -Summary 'Escalation decision completed'
    $result = New-DeepRecoveryEscalationDecisionResultTemplate

    $scenario = Resolve-DeepRecoveryScenario -State $State
    $policy = Get-DeepRecoveryPolicyForScenario -Scenario $scenario

    $result.scenario = $scenario
    $result.decision = [string]$policy.decision
    $result.risk = [string]$policy.risk
    $result.requiresSevereAcknowledgement = [bool]$policy.requiresAck

    switch ($result.decision) {
        'continue_without_escalation' {
            $phase.status = 'OK'
            $phase.summary = 'No escalation is required based on current evidence.'
        }
        'retry_with_different_source' {
            $phase.status = 'WARN'
            $phase.summary = 'Escalation: retry with a different validated official source.'
            $phase.recommendations += 'Mount matching official ISO/WIM/ESD and rerun Deep Recovery.'
        }
        'offline_required_guidance' {
            $phase.status = 'WARN'
            $phase.summary = 'Escalation: offline servicing guidance required.'
            $phase.recommendations += 'Use Microsoft-supported offline servicing workflow from WinRE/installation media.'
        }
        'winre_required_guidance' {
            $phase.status = 'WARN'
            $phase.summary = 'Escalation: WinRE-required guidance.'
            $phase.recommendations += 'Boot into WinRE and rerun supported servicing operations.'
        }
        'reinstall_recommended' {
            $phase.status = 'WARN'
            $phase.summary = 'Escalation: supported reinstall path is recommended.'
            $phase.recommendations += 'Proceed only with explicit severe acknowledgement; no silent reinstall is allowed.'
        }
        default {
            $phase.status = 'FAIL'
            $phase.summary = 'Escalation result: unsupported or too risky to continue automatically.'
            $phase.recommendations += 'Abort automated flow and switch to supervised Microsoft-supported recovery.'
        }
    }

    if ($result.requiresSevereAcknowledgement) {
        $State.Context['deepRecovery']['requiresStrongAck'] = $true
        $phase.findings += 'Severe acknowledgement is required for next high-risk action.'
    }

    $State.Context['deepRecovery']['escalationDecisionResult'] = $result
    $phase.findings += "Scenario=$($result.scenario); Decision=$($result.decision); Risk=$($result.risk)"
    return $phase
}
