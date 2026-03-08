function Get-DeepRecoverySignatures {
    return @(
        [pscustomobject]@{ signature='DR_SOURCE_MISMATCH'; pattern='does not match|source files could not be found|0x800f081f'; category='source_problem'; severity='error'; nextAction='retry_with_different_source' },
        [pscustomobject]@{ signature='DR_OFFLINE_REQUIRED'; pattern='offline servicing'; category='environment'; severity='warning'; nextAction='offline_required_guidance' },
        [pscustomobject]@{ signature='DR_WINRE_REQUIRED'; pattern='Windows Recovery Environment|WinRE'; category='environment'; severity='warning'; nextAction='winre_required_guidance' },
        [pscustomobject]@{ signature='DR_ACCESS_DENIED'; pattern='Access is denied|0x80070005'; category='environment_permissions_problem'; severity='error'; nextAction='abort_or_relaunch_elevated' },
        [pscustomobject]@{ signature='DR_INTERNAL_FAILURE'; pattern='exit_code_not_captured|no_result'; category='toolkit_internal_execution_failure'; severity='fatal'; nextAction='abort_and_fix_tooling' },
        [pscustomobject]@{ signature='DR_SERVICING_FAILURE'; pattern='component store|CBS_E_|corrupt files but was unable to fix'; category='windows_servicing_failure'; severity='error'; nextAction='reinstall_recommended' }
    )
}
