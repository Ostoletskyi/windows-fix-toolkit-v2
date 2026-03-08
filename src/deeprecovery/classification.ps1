function Get-DeepRecoveryExecutionClassification {
    param(
        [pscustomobject]$Result,
        [string]$Tool = 'unknown'
    )

    if (-not $Result) {
        return [pscustomobject]@{ category='toolkit_internal_execution_failure'; outcome='failed'; reason='no_result' }
    }

    if (-not $Result.ExitCodeCaptured) {
        return [pscustomobject]@{ category='toolkit_internal_execution_failure'; outcome='inconclusive'; reason='exit_code_not_captured' }
    }

    $text = (($Result.StdOut + "`n" + $Result.StdErr) | Out-String)

    if ($Result.ExitCode -eq 0) {
        if ($text -match 'found corrupt files and successfully repaired|The restore operation completed successfully|No component store corruption detected') {
            return [pscustomobject]@{ category='success'; outcome='success'; reason='healthy_or_repaired' }
        }
        return [pscustomobject]@{ category='success'; outcome='partial_success'; reason='exit_0_without_strong_signature' }
    }

    if ($text -match '0x800f081f|source files could not be found|does not match|image version is different|edition do not match') {
        return [pscustomobject]@{ category='source_problem'; outcome='failed'; reason='source_mismatch_or_missing' }
    }
    if ($text -match 'offline servicing') {
        return [pscustomobject]@{ category='environment'; outcome='failed'; reason='offline_required' }
    }
    if ($text -match 'Windows Recovery Environment|WinRE') {
        return [pscustomobject]@{ category='environment'; outcome='failed'; reason='winre_required' }
    }
    if ($text -match 'Access is denied|0x80070005') {
        return [pscustomobject]@{ category='environment_permissions_problem'; outcome='failed'; reason='access_denied' }
    }
    if ($text -match 'component store|0x800f|CBS_E_|corrupt files but was unable to fix') {
        return [pscustomobject]@{ category='windows_servicing_failure'; outcome='failed'; reason='component_store_or_corruption' }
    }

    return [pscustomobject]@{ category='windows_servicing_failure'; outcome='failed'; reason=("${Tool}_nonzero_exit_{0}" -f $Result.ExitCode) }
}

function Invoke-DeepRecoveryClassificationPhase {
    param([pscustomobject]$State,[pscustomobject]$CurrentReport)

    $summary = 'Final classification generated from policy matrix and execution evidence'
    $status = 'PLANNED'

    if ($CurrentReport) {
        $decision = $CurrentReport.escalationDecisionResult.decision
        if ($decision -eq 'abort_as_unsupported_or_too_risky') {
            $status = 'FAIL'
            $summary = 'Flow aborted as unsupported/high-risk according to final policy.'
        } elseif ($CurrentReport.postcheckResult.classification -eq 'resolved') {
            $status = 'OK'
            $summary = 'Corruption likely resolved; no escalation required.'
        } elseif ($decision -eq 'reinstall_recommended') {
            $status = 'WARN'
            $summary = 'Servicing did not fully recover system; supported reinstall path recommended.'
        } elseif ($CurrentReport.overallStatus -eq 'FAIL') {
            $status = 'FAIL'
            $summary = 'One or more Deep Recovery phases failed.'
        } elseif ($CurrentReport.overallStatus -eq 'WARN') {
            $status = 'WARN'
            $summary = 'Deep Recovery completed with warnings/inconclusive evidence.'
        } else {
            $status = 'OK'
        }
    }

    $phase = New-DeepRecoveryStageResultTemplate -Phase 'FINAL_REPORT' -Status $status -Summary $summary
    if ($CurrentReport -and $CurrentReport.escalationDecisionResult) {
        $phase.findings += "PolicyDecision=$($CurrentReport.escalationDecisionResult.decision); Risk=$($CurrentReport.escalationDecisionResult.risk)"
    }
    return $phase
}
