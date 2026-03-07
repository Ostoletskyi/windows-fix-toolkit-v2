function Invoke-ChkdskScheduleStep {
    [CmdletBinding()]
    param([pscustomobject]$State)
    return [pscustomobject]@{ Status='SKIPPED'; Details='CHKDSK scheduling not enabled in MVP'; ExitCode=0; DurationMs=0 }
}
