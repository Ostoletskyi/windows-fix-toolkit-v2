function New-ToolkitRestorePoint {
    [CmdletBinding()]
    param([pscustomobject]$State)
    return [pscustomobject]@{ Status='SKIPPED'; Details='Restore point not implemented in MVP'; ExitCode=0; DurationMs=0 }
}
