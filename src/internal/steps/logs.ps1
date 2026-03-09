function Export-ToolkitLogs {
    [CmdletBinding()]
    param([pscustomobject]$State)

    $outDir = Join-Path $State.ReportPath 'collected-logs'
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    return [pscustomobject]@{ Status='OK'; Details="Created log export directory: $outDir"; ExitCode=0; DurationMs=0 }
}
