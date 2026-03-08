function Invoke-DeepRecoveryReinstallPathPhase {
    param([pscustomobject]$State)

    $phase = New-DeepRecoveryStageResultTemplate -Phase 'REINSTALL_PATH' -Status 'SKIPPED' -Summary 'Reinstall path modeling completed (no silent execution)'
    $result = New-DeepRecoveryReinstallPathResultTemplate

    $pre = $State.Context['deepRecovery']['preflightResult']
    $esc = $State.Context['deepRecovery']['escalationDecisionResult']

    $isWin11 = $false
    if ($pre -and $pre.os -and $pre.os.version) {
        try {
            $major = [int]($pre.os.version.Split('.')[0])
            if ($major -ge 10 -and [int]$pre.os.build -ge 22000) { $isWin11 = $true }
        } catch {}
    }

    $result.windows11SupportedReinstallPath = $isWin11
    $result.inPlaceUpgradeRepairInstallSupportedPath = $true
    $result.silentExecutionAllowed = $false
    $result.acknowledgementRequired = $true
    $result.invoked = $false

    if ($esc -and $esc.decision -eq 'reinstall_recommended') {
        $result.recommended = $true
        $phase.status = 'WARN'
        $phase.summary = 'Supported reinstall path is recommended; execution is intentionally not automated.'
        if ($isWin11) {
            $result.recommendations += 'Windows 11: Settings > System > Recovery > Fix problems using Windows Update > Reinstall now.'
        }
        $result.recommendations += 'Supported repair install / in-place upgrade path can be used with matching official media.'
        $result.recommendations += 'Explicit severe acknowledgement is required before any reinstall action.'
        $result.recommendations += 'Toolkit does not launch reinstall automatically in Deep Recovery.'
    } else {
        $phase.summary = 'Reinstall path not recommended at this time.'
    }

    if ($State.Context['deepRecovery']['requiresStrongAck']) {
        $result.acknowledgementText = 'I UNDERSTAND THIS MAY CHANGE SYSTEM COMPONENTS'
        $phase.findings += 'Severe acknowledgement text requirement recorded for reinstall path.'
    }

    $State.Context['deepRecovery']['reinstallPathResult'] = $result
    return $phase
}
