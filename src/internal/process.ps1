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

    # For long-running native servicing tools, prefer a separate console window.
    # This restores the expected on-screen DISM/SFC progress behavior and avoids
    # the launcher appearing frozen on spinner-only output.
    if (-not [Console]::IsOutputRedirected) {
        $tool = ''
        try { $tool = [System.IO.Path]::GetFileNameWithoutExtension([string]$FilePath).ToLowerInvariant() } catch { $tool = '' }
        if ($tool -in @('dism','sfc','chkdsk')) {
            return $true
        }
    }

    # Keep captured mode for everything else to maximize structured logs/artifacts.
    return $false
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

    if ($TimeoutSec -lt 1) { throw 'TimeoutSec must be >= 1 second.' }
    if ($HeartbeatSec -lt 1) { $HeartbeatSec = 1 }
    if ($HeartbeatSec -gt $TimeoutSec) { $HeartbeatSec = $TimeoutSec }

    $resolvedCmd = Get-Command $FilePath -ErrorAction SilentlyContinue
    if (-not $resolvedCmd) {
        throw "Executable not found in PATH: $FilePath"
    }

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
    $exitCode = $null
    $launchMode = 'InlineCaptured'
    $stdoutPath = $null
    $stderrPath = $null
    $processId = $null

    if (Test-UseSeparateServiceWindow -FilePath $FilePath) {
        $launchMode = 'NativeConsole'
        if ($interactive) {
            Write-Host "[WORK] Launching service command in a separate console window: $displayCmd"
        }

        # IMPORTANT: launch the real tool directly (no cmd.exe/powershell.exe wrapper),
        # so the PID we monitor is the same process that performs servicing.
        $servicePath = if ($resolvedCmd.Source) { $resolvedCmd.Source } else { $FilePath }
        $proc = Start-Process -FilePath $servicePath -ArgumentList $argsClean -PassThru -NoNewWindow:$false -WindowStyle Normal
        $processId = $proc.Id

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
            try { $proc.WaitForExit() } catch {}
            try { $proc.Refresh() } catch {}
            $exitCode = $proc.ExitCode
            if ($null -eq $exitCode) {
                $exitCode = -1
            }
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
        $psi.FileName = if ($resolvedCmd.Source) { $resolvedCmd.Source } else { $FilePath }
        $psi.Arguments = ($argsClean -join ' ')
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $null = $proc.Start()
        $processId = $proc.Id

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
        if ($null -eq $exitCode) { $exitCode = -1 }

        if ($State -and $State.ReportPath) {
            try {
                $streamsDir = Join-Path $State.ReportPath 'streams'
                New-Item -ItemType Directory -Path $streamsDir -Force | Out-Null
                $stamp = (Get-Date -Format 'yyyyMMdd_HHmmss_fff')
                $tool = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
                $stdoutPath = Join-Path $streamsDir ("{0}_{1}_stdout.log" -f $stamp,$tool)
                $stderrPath = Join-Path $streamsDir ("{0}_{1}_stderr.log" -f $stamp,$tool)
                [System.IO.File]::WriteAllText($stdoutPath, $stdout, [System.Text.Encoding]::UTF8)
                [System.IO.File]::WriteAllText($stderrPath, $stderr, [System.Text.Encoding]::UTF8)
            } catch {
                if ($State) { Write-ToolkitLog -State $State -Level WARN -Message "[PROCESS] failed to persist stdout/stderr streams: $($_.Exception.Message)" }
            }
        }
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
        ExitCodeCaptured = ($null -ne $exitCode -and $exitCode -ne -1)
        ProcessId   = $processId
        LaunchMode  = $launchMode
        StdOutPath  = $stdoutPath
        StdErrPath  = $stderrPath
        StdOut      = $stdout.Trim()
        StdErr      = $stderr.Trim()
        DurationMs  = [int]$sw.ElapsedMilliseconds
        TimedOut    = $timedOut
        StartedAt   = $startTime
        EndedAt     = $endTime
        Success     = (-not $timedOut -and $exitCode -eq 0 -and $exitCode -ne -1)
    }

    if (-not $IgnoreExitCode -and -not $result.Success) {
        if ($timedOut) {
            throw "Command timeout after $TimeoutSec seconds: $cmdline"
        }
        throw "Command failed with exit code $($result.ExitCode): $cmdline`n$($result.StdErr)"
    }

    return $result
}
