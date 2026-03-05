function Invoke-WmiVerifyStep {
    [CmdletBinding()]
    param([pscustomobject]$State)
    return [pscustomobject]@{ Status='SKIPPED'; Details='WMI verify step placeholder'; ExitCode=0; DurationMs=0 }
}
