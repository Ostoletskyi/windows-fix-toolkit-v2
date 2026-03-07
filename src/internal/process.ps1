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

function Test-UseSeparateServiceWindow {
    param([string]$FilePath)
    $leaf = [System.IO.Path]::GetFileName($FilePath).ToLowerInvariant()
    return @('sfc.exe','dism.exe','chkdsk.exe') -contains $leaf
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

    $startTime = Get-Date
    if ($State) { Write-ToolkitLog -State $State -Message "[PROCESS] start=$($startTime.ToString('s')) cmd=$cmdline" }

    $timedOut = $false
    $uiTickMs = 120
    $lastHeartbeatSec = -1
    $spinnerFrames = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
    $spinnerIndex = 0
    $interactive = -not [Console]::IsOutputRedirected
    $displayCmd = if ($cmdline.Length -gt 64) { $cmdline.Substring(0,61) + '...' } else { $cmdline }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stdout = ''
    $stderr = ''
    $exitCode = 0

    if (Test-UseSeparateServiceWindow -FilePath $FilePath) {
        if ($interactive) {
            Write-Host "[WORK] Launching service command in a separate console window: $displayCmd"
        }

        # IMPORTANT: launch the real tool directly (no cmd.exe/powershell.exe wrapper),
        # so the PID we monitor is the same process that performs servicing.
        $proc = Start-Process -FilePath $FilePath -ArgumentList $argsClean -PassThru -NoNewWindow:$false -WindowStyle Normal

        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds $uiTickMs
            $elapsedSec = [int]$sw.Elapsed.TotalSeconds

            if ($interactive) {
                $frame = $spinnerFrames[$spinnerIndex % $spinnerFrames.Count]
                $spinnerIndex++
                Write-Host -NoNewline ("`r[WORK {0}] {1}  t={2}s   " -f $frame, $displayCmd, $elapsedSec)
            }

            if ($State -and ($lastHeartbeatSec -lt 0 -or ($elapsedSec - $lastHeartbeatSec) -ge $HeartbeatSec)) {
                $lastHeartbeatSec = $elapsedSec
                Write-ToolkitLog -State $State -Message "[HEARTBEAT] still running: pid=$($proc.Id) cmd=$cmdline elapsed=${elapsedSec}s"
            }

            if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) {
                $timedOut = $true
                try { $proc.Kill() } catch {}
                break
            }
        }

        if ($interactive) { Write-Host "" }

        if (-not $timedOut) {
            try { Wait-Process -Id $proc.Id -ErrorAction SilentlyContinue } catch {}
            $exitCode = $proc.ExitCode
        } else {
            $exitCode = 124
        }

        # No stdout/stderr redirection for native servicing commands: avoid altering
        # tool console behavior and keep native progress UI responsive.
        $stdout = ''
        $stderr = ''
    }
    else {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = ($argsClean -join ' ')
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $null = $proc.Start()

        while (-not $proc.WaitForExit($uiTickMs)) {
            $elapsedSec = [int]$sw.Elapsed.TotalSeconds

            if ($interactive) {
                $frame = $spinnerFrames[$spinnerIndex % $spinnerFrames.Count]
                $spinnerIndex++
                Write-Host -NoNewline ("`r[WORK {0}] {1}  t={2}s   " -f $frame, $displayCmd, $elapsedSec)
            }

            if ($State -and ($lastHeartbeatSec -lt 0 -or ($elapsedSec - $lastHeartbeatSec) -ge $HeartbeatSec)) {
                $lastHeartbeatSec = $elapsedSec
                Write-ToolkitLog -State $State -Message "[HEARTBEAT] still running: $cmdline elapsed=${elapsedSec}s"
            }

            if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) {
                $timedOut = $true
                try { $proc.Kill() } catch {}
                break
            }
        }

        if ($interactive) { Write-Host "" }

        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        if (-not $timedOut) { $null = $proc.WaitForExit() }
        $exitCode = if ($timedOut) { 124 } else { $proc.ExitCode }
    }

    $sw.Stop()
    $endTime = Get-Date
    if ($State) {
        Write-ToolkitLog -State $State -Message "[PROCESS] end=$($endTime.ToString('s')) cmd=$cmdline duration_ms=$([int]$sw.ElapsedMilliseconds) exit=$exitCode"
    }

    $result = [pscustomobject]@{
        FilePath    = $FilePath
        Arguments   = $argsClean
        CommandLine = $cmdline
        ExitCode    = $exitCode
        StdOut      = $stdout.Trim()
        StdErr      = $stderr.Trim()
        DurationMs  = [int]$sw.ElapsedMilliseconds
        TimedOut    = $timedOut
        StartedAt   = $startTime
        EndedAt     = $endTime
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
