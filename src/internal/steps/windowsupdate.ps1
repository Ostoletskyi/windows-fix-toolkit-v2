function Invoke-WindowsUpdateResetStep {
    [CmdletBinding()]
    param([pscustomobject]$State)
    return [pscustomobject]@{ Status='SKIPPED'; Details='WU reset step not enabled in MVP'; ExitCode=0; DurationMs=0 }
}
