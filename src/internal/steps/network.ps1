function Invoke-NetworkRepairStep {
    [CmdletBinding()]
    param([pscustomobject]$State)
    return [pscustomobject]@{ Status='SKIPPED'; Details='Network repair step not enabled in MVP'; ExitCode=0; DurationMs=0 }
}
