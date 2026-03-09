function Set-DeepRecoveryScaffoldState {
    param([pscustomobject]$State,[pscustomobject]$Report)
    if (-not $State.Context['deepRecovery']) {
        $State.Context['deepRecovery'] = [ordered]@{}
    }
    $State.Context['deepRecovery']['scaffoldReport'] = $Report
}
