function Invoke-DeepRecoveryPostcheckPhase {
    param([pscustomobject]$State)

    $phase = New-DeepRecoveryStageResultTemplate -Phase 'POSTCHECK' -Status 'OK' -Summary 'Postcheck completed'
    $result = New-DeepRecoveryPostcheckResultTemplate

    $dismCheck = $null
    try {
        $dismCheck = Invoke-ExternalCommand -FilePath 'dism.exe' -ArgumentList @('/Online','/Cleanup-Image','/CheckHealth') -TimeoutSec 1800 -HeartbeatSec 20 -State $State -IgnoreExitCode -ForceCaptured
        $result.dismCheck = [pscustomobject]@{
            exitCode = $dismCheck.ExitCode
            exitCodeCaptured = $dismCheck.ExitCodeCaptured
            stdoutPath = $dismCheck.StdOutPath
            stderrPath = $dismCheck.StdErrPath
        }
    } catch {
        $result.dismCheck = [pscustomobject]@{ exitCode=$null; exitCodeCaptured=$false; error=$_.Exception.Message }
    }

    $sfcVerify = $null
    try {
        $sfcVerify = Invoke-ExternalCommand -FilePath 'sfc.exe' -ArgumentList @('/verifyonly') -TimeoutSec 3600 -HeartbeatSec 20 -State $State -IgnoreExitCode -ForceCaptured
        $result.sfcVerify = [pscustomobject]@{
            exitCode = $sfcVerify.ExitCode
            exitCodeCaptured = $sfcVerify.ExitCodeCaptured
            stdoutPath = $sfcVerify.StdOutPath
            stderrPath = $sfcVerify.StdErrPath
        }
    } catch {
        $result.sfcVerify = [pscustomobject]@{ exitCode=$null; exitCodeCaptured=$false; error=$_.Exception.Message }
    }

    $signals = @()
    $dismOut = if ($dismCheck) { ($dismCheck.StdOut + "`n" + $dismCheck.StdErr) } else { '' }
    $sfcOut = if ($sfcVerify) { ($sfcVerify.StdOut + "`n" + $sfcVerify.StdErr) } else { '' }

    if ($dismOut -match 'No component store corruption detected') { $signals += 'DISM_HEALTHY' }
    if ($dismOut -match 'component store is repairable|0x800f') { $signals += 'DISM_CORRUPTION_SIGNAL' }
    if ($sfcOut -match 'did not find any integrity violations') { $signals += 'SFC_CLEAN' }
    if ($sfcOut -match 'found corrupt files but was unable to fix') { $signals += 'SFC_CORRUPTION_REMAINS' }

    $result.signals = $signals

    if (($signals -contains 'DISM_HEALTHY') -and ($signals -contains 'SFC_CLEAN')) {
        $result.classification = 'resolved'
        $result.outcome = 'success'
        $phase.status = 'OK'
        $phase.summary = 'Postcheck indicates corruption is likely resolved.'
    } elseif (($signals -contains 'DISM_CORRUPTION_SIGNAL') -or ($signals -contains 'SFC_CORRUPTION_REMAINS')) {
        $result.classification = 'remains'
        $result.outcome = 'failed'
        $phase.status = 'WARN'
        $phase.summary = 'Postcheck indicates corruption may remain.'
    } else {
        $result.classification = 'inconclusive'
        $result.outcome = 'partial_success'
        $phase.status = 'WARN'
        $phase.summary = 'Postcheck is inconclusive.'
    }

    $result.rebootRecommended = [bool]$State.Context['pending_reboot']
    if ($result.rebootRecommended) {
        $phase.recommendations += 'Reboot is recommended before additional servicing actions.'
    }

    $phase.findings += "Postcheck classification=$($result.classification); rebootRecommended=$($result.rebootRecommended)"
    $State.Context['deepRecovery']['postcheckResult'] = $result
    return $phase
}
