function Invoke-RegistrySafeStep {
    [CmdletBinding()]
    param([pscustomobject]$State)
    return [pscustomobject]@{ Status='SKIPPED'; Details='Registry modifications disabled by default'; ExitCode=0; DurationMs=0 }
}
