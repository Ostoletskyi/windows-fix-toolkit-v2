function ConvertTo-CommandLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [string[]]$ArgumentList
    )

    $safeArgs = @($ArgumentList | Where-Object { $_ -ne $null -and $_ -ne '' })
    $quoted = $safeArgs | ForEach-Object {
        if ($_ -match '\s|"') {
            '"{0}"' -f ($_ -replace '"','\"')
        } else {
            $_
        }
    }
    return ($FilePath + ' ' + ($quoted -join ' ')).Trim()
}

function Invoke-ExternalCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [string[]]$ArgumentList,
        [int]$TimeoutSec = 600,
        [pscustomobject]$State,
        [switch]$IgnoreExitCode
    )

    $argsClean = @($ArgumentList | Where-Object { $_ -ne $null -and $_ -ne '' })
    $cmdline = ConvertTo-CommandLine -FilePath $FilePath -ArgumentList $argsClean
    if ($State) { Write-ToolkitLog -Message ">> $cmdline" -State $State }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($argsClean -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = $proc.Start()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()

    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch {}
        throw "Command timeout after $TimeoutSec seconds: $cmdline"
    }

    $sw.Stop()
    $result = [pscustomobject]@{
        FilePath    = $FilePath
        Arguments   = $argsClean
        CommandLine = $cmdline
        ExitCode    = $proc.ExitCode
        StdOut      = $stdout.Trim()
        StdErr      = $stderr.Trim()
        DurationMs  = [int]$sw.ElapsedMilliseconds
        TimedOut    = $false
        Success     = ($proc.ExitCode -eq 0)
    }

    if (-not $IgnoreExitCode -and -not $result.Success) {
        throw "Command failed with exit code $($result.ExitCode): $cmdline`n$($result.StdErr)"
    }

    return $result
}
