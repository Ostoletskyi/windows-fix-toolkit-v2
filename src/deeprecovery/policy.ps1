function Get-DeepRecoveryPolicyMatrix {
    return @{
        client_restore_available = [pscustomobject]@{ decision='continue_without_escalation'; risk='low'; requiresAck=$false }
        client_restore_unavailable = [pscustomobject]@{ decision='continue_with_warning'; risk='medium'; requiresAck=$true }
        client_policy_disabled_restore = [pscustomobject]@{ decision='continue_with_warning'; risk='high'; requiresAck=$true }
        server_backup_ready = [pscustomobject]@{ decision='continue_without_escalation'; risk='medium'; requiresAck=$false }
        server_no_rollback_artifact = [pscustomobject]@{ decision='continue_with_warning'; risk='high'; requiresAck=$true }
        valid_source_failed_repair = [pscustomobject]@{ decision='reinstall_recommended'; risk='high'; requiresAck=$true }
        source_mismatch = [pscustomobject]@{ decision='retry_with_different_source'; risk='medium'; requiresAck=$false }
        offline_required = [pscustomobject]@{ decision='offline_required_guidance'; risk='medium'; requiresAck=$false }
        winre_required = [pscustomobject]@{ decision='winre_required_guidance'; risk='medium'; requiresAck=$false }
        unsupported_high_risk = [pscustomobject]@{ decision='abort_as_unsupported_or_too_risky'; risk='high'; requiresAck=$true }
        toolkit_internal_failure = [pscustomobject]@{ decision='abort_as_unsupported_or_too_risky'; risk='high'; requiresAck=$false }
        windows_servicing_failure = [pscustomobject]@{ decision='reinstall_recommended'; risk='high'; requiresAck=$true }
    }
}

function Get-DeepRecoveryPolicyForScenario {
    param([string]$Scenario)
    $m = Get-DeepRecoveryPolicyMatrix
    if ($m.ContainsKey($Scenario)) { return $m[$Scenario] }
    return [pscustomobject]@{ decision='continue_with_warning'; risk='medium'; requiresAck=$true }
}
