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
        [int]$HeartbeatSec = 15,
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

    $timedOut = $false
    $spinChars = @('|','/','-','\')
    $spinIndex = 0
    while (-not $proc.WaitForExit($HeartbeatSec * 1000)) {
        if ($State) {
            $spin = $spinChars[$spinIndex % $spinChars.Count]
            $spinIndex++
            Write-ToolkitLog -State $State -Message "[HEARTBEAT $spin] still running: $cmdline elapsed=$([int]$sw.Elapsed.TotalSeconds)s"
        }
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) {
            $timedOut = $true
            try { $proc.Kill() } catch {}
            break
        }
    }

    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    if (-not $timedOut) { $null = $proc.WaitForExit() }

    $sw.Stop()
    $exitCode = if ($timedOut) { 124 } else { $proc.ExitCode }

    $result = [pscustomobject]@{
        FilePath    = $FilePath
        Arguments   = $argsClean
        CommandLine = $cmdline
        ExitCode    = $exitCode
        StdOut      = $stdout.Trim()
        StdErr      = $stderr.Trim()
        DurationMs  = [int]$sw.ElapsedMilliseconds
        TimedOut    = $timedOut
        Success     = (-not $timedOut -and $exitCode -eq 0)
    }

    if (-not $IgnoreExitCode -and -not $result.Success) {
        if ($timedOut) {
            throw "Command timeout after $TimeoutSec seconds: $cmdline"
        }
        throw "Command failed with exit code $($result.ExitCode): $cmdline`n$($result.StdErr)"
    }

    return $result
}
