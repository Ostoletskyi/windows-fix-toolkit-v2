function Invoke-DeepRecoveryDismPhase {
    param([pscustomobject]$State)

    $phase = New-DeepRecoveryStageResultTemplate -Phase 'REPAIR_STAGE_DISM' -Status 'PLANNED' -Summary 'DISM phase not executed'
    $result = New-DeepRecoveryRepairResultTemplate
    $result.tool = 'dism'

    $validation = $State.Context['deepRecovery']['sourceValidationResult']
    $pre = $State.Context['deepRecovery']['preflightResult']

    if ($pre -and $pre.classification -eq 'blocking') {
        $phase.status = 'FAIL'
        $phase.summary = 'DISM blocked by preflight conditions.'
        $result.classification = 'environment/permissions problem'
        $result.outcome = 'failed'
        $result.reason = 'preflight_blocking'
        $State.Context['deepRecovery']['dismResult'] = $result
        return $phase
    }

    $args = @('/Online','/Cleanup-Image','/RestoreHealth')
    if ($validation -and $validation.isValid -and $State.Context['deep_validated_source']) {
        $args += @('/Source:' + [string]$State.Context['deep_validated_source'], '/LimitAccess')
        $result.usedValidatedLocalSource = $true
    }

    try {
        $cmd = Invoke-ExternalCommand -FilePath 'dism.exe' -ArgumentList $args -TimeoutSec 7200 -HeartbeatSec 20 -State $State -IgnoreExitCode
        $class = Get-DeepRecoveryExecutionClassification -Result $cmd -Tool 'dism'

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
            $phase.summary = 'DISM RestoreHealth completed successfully.'
        } elseif ($class.outcome -eq 'partial_success' -or $class.outcome -eq 'inconclusive') {
            $phase.status = 'WARN'
            $phase.summary = 'DISM completed but outcome is partial/inconclusive.'
        } else {
            $phase.status = 'FAIL'
            $phase.summary = 'DISM RestoreHealth failed.'
        }
    } catch {
        $phase.status = 'FAIL'
        $phase.summary = 'DISM execution failed with internal toolkit error.'
        $result.classification = 'toolkit internal execution failure'
        $result.outcome = 'failed'
        $result.reason = $_.Exception.Message
    }

    $phase.findings += "DISM outcome=$($result.outcome); class=$($result.classification); exit=$($result.exitCode)"
    $State.Context['deepRecovery']['dismResult'] = $result
    return $phase
}
