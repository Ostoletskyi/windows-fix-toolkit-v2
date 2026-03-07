function Invoke-SfcStep {
    [CmdletBinding()]
    param([pscustomobject]$State)
    return [pscustomobject]@{ Status='SKIPPED'; Details='SFC step not enabled in MVP'; ExitCode=0; DurationMs=0 }
}
