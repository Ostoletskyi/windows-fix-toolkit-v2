Set-StrictMode -Version Latest

. $PSScriptRoot/internal/logging.ps1
. $PSScriptRoot/internal/process.ps1
. $PSScriptRoot/internal/checks.ps1
. $PSScriptRoot/internal/steps/dism.ps1
. $PSScriptRoot/internal/steps/sfc.ps1
. $PSScriptRoot/internal/steps/windowsupdate.ps1
. $PSScriptRoot/internal/steps/network.ps1
. $PSScriptRoot/internal/steps/wmi.ps1
. $PSScriptRoot/internal/steps/registry.ps1
. $PSScriptRoot/internal/steps/logs.ps1
. $PSScriptRoot/internal/steps/restorepoint.ps1
. $PSScriptRoot/internal/steps/chkdsk.ps1

function New-ToolkitState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Diagnose','Repair','Full','SelfTest','DryRun')]
        [string]$Mode,
        [Parameter(Mandatory)]
        [string]$ReportPath,
        [Parameter(Mandatory)]
        [string]$LogPath,
        [Parameter(Mandatory)]
        [string]$TranscriptPath,
        [switch]$NoNetwork,
        [switch]$AssumeYes,
        [switch]$Force,
        [switch]$DryRun
    )

    $resolvedLogPath = [System.IO.Path]::GetFullPath($LogPath)
    $resolvedTranscriptPath = [System.IO.Path]::GetFullPath($TranscriptPath)
    if ($resolvedLogPath.Equals($resolvedTranscriptPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $resolvedLogPath = Join-Path $ReportPath 'toolkit.log'
    }

    return [pscustomobject]@{
        Mode       = $Mode
        ReportPath = $ReportPath
        LogPath    = $resolvedLogPath
        TranscriptPath = $resolvedTranscriptPath
        NoNetwork  = [bool]$NoNetwork
        AssumeYes  = [bool]$AssumeYes
        Force      = [bool]$Force
        DryRun     = [bool]$DryRun
        StartedAt  = (Get-Date)
        IsAdmin    = (Test-IsAdmin)
        Steps      = New-Object System.Collections.Generic.List[object]
    }
}

function Add-ToolkitStepResult {
    param(
        [pscustomobject]$State,
        [string]$Name,
        [string]$Status,
        [int]$ExitCode = 0,
        [int]$DurationMs = 0,
        [string]$Details = ''
    )
    $State.Steps.Add([pscustomobject]@{
        name       = $Name
        status     = $Status
        exitCode   = $ExitCode
        durationMs = $DurationMs
        details    = $Details
    })
}

function Export-ToolkitReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$State)

    $jsonPath = Join-Path $State.ReportPath 'report.json'
    $mdPath = Join-Path $State.ReportPath 'report.md'

    $payload = [pscustomobject]@{
        mode      = $State.Mode
        startedAt = $State.StartedAt
        finishedAt= Get-Date
        isAdmin   = $State.IsAdmin
        logPath   = $State.LogPath
        transcriptPath = $State.TranscriptPath
        steps     = $State.Steps
    }

    $payload | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8

    $lines = @(
        '# Windows Fix Toolkit Report',
        "",
        "- Mode: $($State.Mode)",
        "- IsAdmin: $($State.IsAdmin)",
        "- StartedAt: $($State.StartedAt)",
        "",
        '## Steps'
    )
    foreach ($s in $State.Steps) {
        $lines += "- **$($s.name)**: $($s.status) (exit=$($s.exitCode), $($s.durationMs)ms)"
        if ($s.details) { $lines += "  - $($s.details -replace "`r?`n", ' ')" }
    }
    Set-Content -Path $mdPath -Value $lines -Encoding UTF8

    return [pscustomobject]@{ Json=$jsonPath; Markdown=$mdPath }
}

function Invoke-SelfTest {
    param([pscustomobject]$State)
    $checks = @(
        @{ Name='echo'; File='cmd.exe'; Args=@('/c','echo','OK') },
        @{ Name='where dism'; File='where.exe'; Args=@('dism.exe') },
        @{ Name='where sfc'; File='where.exe'; Args=@('sfc.exe') },
        @{ Name='where netsh'; File='where.exe'; Args=@('netsh.exe') },
        @{ Name='where ipconfig'; File='where.exe'; Args=@('ipconfig.exe') }
    )
    foreach ($c in $checks) {
        try {
            $r = Invoke-ExternalCommand -FilePath $c.File -ArgumentList $c.Args -TimeoutSec 30 -State $State
            Add-ToolkitStepResult -State $State -Name "SelfTest: $($c.Name)" -Status 'OK' -ExitCode $r.ExitCode -DurationMs $r.DurationMs -Details ($r.StdOut + ' ' + $r.StdErr).Trim()
        } catch {
            Add-ToolkitStepResult -State $State -Name "SelfTest: $($c.Name)" -Status 'FAIL' -ExitCode 1 -Details $_.Exception.Message
        }
    }
}

function Invoke-Diagnose {
    param([pscustomobject]$State)
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $details = "Caption=$($os.Caption); Build=$($os.BuildNumber); UptimeSince=$($os.LastBootUpTime)"
        Add-ToolkitStepResult -State $State -Name 'Snapshot: OS' -Status 'OK' -Details $details
    } catch {
        Add-ToolkitStepResult -State $State -Name 'Snapshot: OS' -Status 'WARN' -Details $_.Exception.Message
    }

    $services = 'wuauserv','bits','cryptsvc','trustedinstaller'
    foreach ($svcName in $services) {
        try {
            $svc = Get-Service -Name $svcName -ErrorAction Stop
            Add-ToolkitStepResult -State $State -Name "Service: $svcName" -Status 'OK' -Details "Status=$($svc.Status); StartType=$($svc.StartType)"
        } catch {
            Add-ToolkitStepResult -State $State -Name "Service: $svcName" -Status 'WARN' -Details $_.Exception.Message
        }
    }

    if (-not $State.NoNetwork) {
        try {
            $dns = Resolve-DnsName -Name 'www.microsoft.com' -ErrorAction Stop | Select-Object -First 1
            Add-ToolkitStepResult -State $State -Name 'Network: DNS resolve' -Status 'OK' -Details "$($dns.NameHost) -> $($dns.IPAddress)"
        } catch {
            Add-ToolkitStepResult -State $State -Name 'Network: DNS resolve' -Status 'WARN' -Details $_.Exception.Message
        }
    } else {
        Add-ToolkitStepResult -State $State -Name 'Network: DNS resolve' -Status 'SKIPPED' -Details 'NoNetwork switch specified'
    }

    Add-ToolkitStepResult -State $State -Name 'Integrity: DISM/SFC availability' -Status 'OK' -Details 'Use SelfTest mode to verify executable presence'
}

function Invoke-WindowsFix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Diagnose','Repair','Full','SelfTest','DryRun')]
        [string]$Mode,
        [Parameter(Mandatory)]
        [string]$ReportPath,
        [Parameter(Mandatory)]
        [string]$LogPath,
        [Parameter(Mandatory)]
        [string]$TranscriptPath,
        [switch]$NoNetwork,
        [switch]$AssumeYes,
        [switch]$Force
    )

    $isDry = $Mode -eq 'DryRun'
    $effectiveMode = if ($Mode -eq 'DryRun') { 'Full' } else { $Mode }

    $state = New-ToolkitState -Mode $Mode -ReportPath $ReportPath -LogPath $LogPath -TranscriptPath $TranscriptPath -NoNetwork:$NoNetwork -AssumeYes:$AssumeYes -Force:$Force -DryRun:$isDry
    Write-ToolkitLog -State $state -Message "Mode=$Mode, IsAdmin=$($state.IsAdmin), ReportPath=$ReportPath"

    if (($effectiveMode -in @('Repair','Full')) -and -not $state.IsAdmin) {
        Add-ToolkitStepResult -State $state -Name 'Admin check' -Status 'FAIL' -ExitCode 2 -Details 'Repair/Full requires Administrator privileges'
        Export-ToolkitReport -State $state | Out-Null
        return 2
    }

    try {
        switch ($effectiveMode) {
            'SelfTest' { Invoke-SelfTest -State $state }
            'Diagnose' { Invoke-Diagnose -State $state }
            'Repair' {
                $dism = Invoke-DismCheckHealthStep -State $state
                Add-ToolkitStepResult -State $state -Name 'Repair: DISM CheckHealth' -Status $dism.Status -ExitCode $dism.ExitCode -DurationMs $dism.DurationMs -Details $dism.Details
            }
            'Full' {
                Invoke-Diagnose -State $state
                $dism = Invoke-DismCheckHealthStep -State $state
                Add-ToolkitStepResult -State $state -Name 'Repair: DISM CheckHealth' -Status $dism.Status -ExitCode $dism.ExitCode -DurationMs $dism.DurationMs -Details $dism.Details
                $logs = Export-ToolkitLogs -State $state
                Add-ToolkitStepResult -State $state -Name 'Export logs' -Status $logs.Status -Details $logs.Details
            }
        }

        $report = Export-ToolkitReport -State $state
        Write-ToolkitLog -State $state -Message "Report generated: $($report.Json), $($report.Markdown)"

        $criticalFailed = @($state.Steps | Where-Object { $_.name -match 'DISM RestoreHealth|SFC' -and $_.status -eq 'FAIL' }).Count -gt 0
        if ($criticalFailed) { return 1 }

        $anyFailed = @($state.Steps | Where-Object { $_.status -eq 'FAIL' }).Count -gt 0
        if ($anyFailed -and $effectiveMode -eq 'SelfTest') { return 1 }

        return 0
    } catch {
        Add-ToolkitStepResult -State $state -Name 'Unhandled exception' -Status 'FAIL' -ExitCode 3 -Details $_.Exception.Message
        Export-ToolkitReport -State $state | Out-Null
        Write-ToolkitLog -State $state -Level ERROR -Message $_.Exception.Message
        return 3
    }
}

Export-ModuleMember -Function Invoke-WindowsFix,New-ToolkitState,Invoke-ExternalCommand,Export-ToolkitReport,Wait-ServiceState,ConvertTo-CommandLine
