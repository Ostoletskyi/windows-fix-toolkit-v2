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
    if ($text -match 'Access is denied|0x80070005') {
        return [pscustomobject]@{ category='environment_permissions_problem'; outcome='failed'; reason='access_denied' }
    }
    if ($text -match 'component store|0x800f|CBS_E_|corrupt files but was unable to fix') {
        return [pscustomobject]@{ category='servicing_component_store_problem'; outcome='failed'; reason='component_store_or_corruption' }
    }

    return [pscustomobject]@{ category='servicing_component_store_problem'; outcome='failed'; reason=("${Tool}_nonzero_exit_{0}" -f $Result.ExitCode) }
}

function Invoke-DeepRecoveryClassificationPhase {
    param([pscustomobject]$State,[pscustomobject]$CurrentReport)

    $summary = 'Classification summary generated from Step 3 execution artifacts'
    $status = 'PLANNED'

    if ($CurrentReport) {
        if ($CurrentReport.postcheckResult -and $CurrentReport.postcheckResult.classification -eq 'resolved') {
            $status = 'OK'
            $summary = 'Postcheck indicates corruption is likely resolved.'
        } elseif ($CurrentReport.postcheckResult -and $CurrentReport.postcheckResult.classification -eq 'remains') {
            $status = 'WARN'
            $summary = 'Postcheck indicates corruption remains.'
        } elseif ($CurrentReport.overallStatus -eq 'FAIL') {
            $status = 'FAIL'
            $summary = 'One or more Deep Recovery execution phases failed.'
        } elseif ($CurrentReport.overallStatus -eq 'WARN') {
            $status = 'WARN'
            $summary = 'Deep Recovery completed with warnings or inconclusive checks.'
        }
    }

    return (New-DeepRecoveryStageResultTemplate -Phase 'FINAL_REPORT' -Status $status -Summary $summary)
}
