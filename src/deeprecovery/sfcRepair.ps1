function Invoke-DeepRecoverySfcPhase {
    param([pscustomobject]$State)

    $phase = New-DeepRecoveryStageResultTemplate -Phase 'REPAIR_STAGE_SFC' -Status 'PLANNED' -Summary 'SFC phase not executed'
    $result = New-DeepRecoveryRepairResultTemplate
    $result.tool = 'sfc'

    $dism = $State.Context['deepRecovery']['dismResult']
    if ($dism -and $dism.outcome -eq 'failed') {
        $phase.status = 'WARN'
        $phase.summary = 'SFC is skipped because DISM stage failed hard.'
        $result.classification = 'servicing/component store problem'
        $result.outcome = 'inconclusive'
        $result.reason = 'dism_failed'
        $State.Context['deepRecovery']['sfcResult'] = $result
        return $phase
    }

    try {
        $cmd = Invoke-ExternalCommand -FilePath 'sfc.exe' -ArgumentList @('/scannow') -TimeoutSec 7200 -HeartbeatSec 20 -State $State -IgnoreExitCode
        $class = Get-DeepRecoveryExecutionClassification -Result $cmd -Tool 'sfc'

        $result.command = $cmd.CommandLine
        $result.exitCode = $cmd.ExitCode
        $result.exitCodeCaptured = $cmd.ExitCodeCaptured
        $result.stdoutPath = $cmd.StdOutPath
        $result.stderrPath = $cmd.StdErrPath
        $result.classification = $class.category
        $result.outcome = $class.outcome
        $result.reason = $class.reason

        if ($class.outcome -eq 'success') {
            $phase.status = 'OK'
            $phase.summary = 'SFC completed successfully.'
        } elseif ($class.outcome -eq 'partial_success' -or $class.outcome -eq 'inconclusive') {
            $phase.status = 'WARN'
            $phase.summary = 'SFC completed with warnings/inconclusive result.'
        } else {
            $phase.status = 'FAIL'
            $phase.summary = 'SFC failed to complete cleanly.'
        }
    } catch {
        $phase.status = 'FAIL'
        $phase.summary = 'SFC execution failed with internal toolkit error.'
        $result.classification = 'toolkit internal execution failure'
        $result.outcome = 'failed'
        $result.reason = $_.Exception.Message
    }

    $phase.findings += "SFC outcome=$($result.outcome); class=$($result.classification); exit=$($result.exitCode)"
    $State.Context['deepRecovery']['sfcResult'] = $result
    return $phase
}
