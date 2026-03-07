Set-StrictMode -Version Latest

. $PSScriptRoot/internal/logging.ps1
. $PSScriptRoot/internal/process.ps1
. $PSScriptRoot/internal/checks.ps1

function New-ToolkitState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Diagnose','Repair','Full','DryRun')]
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
        [ValidateSet('None','Update','Network','All')]
        [string]$SubsystemProfile = 'None'
    )

    New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null
    $resolvedLogPath = [System.IO.Path]::GetFullPath($LogPath)
    $resolvedTranscriptPath = [System.IO.Path]::GetFullPath($TranscriptPath)
    if ($resolvedLogPath.Equals($resolvedTranscriptPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $resolvedLogPath = Join-Path $ReportPath 'toolkit.log'
    }

    [pscustomobject]@{
        Mode           = $Mode
        IsDryRun       = ($Mode -eq 'DryRun')
        EffectiveMode  = if ($Mode -eq 'DryRun') { 'Full' } else { $Mode }
        ReportPath     = $ReportPath
        LogPath        = $resolvedLogPath
        TranscriptPath = $resolvedTranscriptPath
        NoNetwork      = [bool]$NoNetwork
        AssumeYes      = [bool]$AssumeYes
        Force          = [bool]$Force
        SubsystemProfile = $SubsystemProfile
        StartedAt      = (Get-Date)
        IsAdmin        = (Test-IsAdmin)
        Stages         = New-Object System.Collections.Generic.List[object]
        Steps          = New-Object System.Collections.Generic.List[object]
        Context        = @{}
        ExitCode       = 0
    }
}

function New-Stage {
    param([string]$Id,[string]$Name)
    [pscustomobject]@{
        stage_id = $Id
        stage_name = $Name
        status = 'PLANNED'
        start_time = (Get-Date)
        end_time = $null
        exit_code = 0
        actions = New-Object System.Collections.Generic.List[object]
        findings = New-Object System.Collections.Generic.List[string]
        recommendations = New-Object System.Collections.Generic.List[string]
        artifacts = New-Object System.Collections.Generic.List[string]
    }
}

function Complete-Stage {
    param([pscustomobject]$State,[pscustomobject]$Stage,[string]$Status,[int]$ExitCode=0)
    $Stage.status = $Status
    $Stage.exit_code = $ExitCode
    $Stage.end_time = Get-Date
    $State.Stages.Add($Stage)
    $State.Steps.Add([pscustomobject]@{ name=$Stage.stage_name; status=$Status; exitCode=$ExitCode; durationMs=[int](($Stage.end_time-$Stage.start_time).TotalMilliseconds); details=($Stage.findings -join ' | ') })
}

function Add-ActionResult {
    param(
        [pscustomobject]$Stage,
        [string]$Name,
        [pscustomobject]$Result,
        [string]$InterpretedStatus
    )
    $Stage.actions.Add([pscustomobject]@{
        name = $Name
        commandLine = $Result.CommandLine
        exit_code = $Result.ExitCode
        duration_ms = $Result.DurationMs
        timed_out = $Result.TimedOut
        status = $InterpretedStatus
        stdout = $Result.StdOut
        stderr = $Result.StdErr
    })
}

function Test-ReportPathWritable {
    param([string]$Path)
    try {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        $probe = Join-Path $Path (".write_test_{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
        'ok' | Set-Content -Path $probe -Encoding UTF8
        Remove-Item -Path $probe -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Run-StagePreflight {
    param([pscustomobject]$State)
    $stage = New-Stage 'A' 'Preflight'

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $arch = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).OSArchitecture
    $stage.findings.Add("Mode=$($State.Mode); EffectiveMode=$($State.EffectiveMode); IsAdmin=$($State.IsAdmin)")
    if ($os) { $stage.findings.Add("OS=$($os.Caption) Build=$($os.BuildNumber) Arch=$arch") }
    $stage.findings.Add("PowerShell=$($PSVersionTable.PSVersion.ToString())")

    $isWritable = Test-ReportPathWritable -Path $State.ReportPath
    $State.Context['report_writable'] = $isWritable
    if (-not $isWritable) {
        $stage.findings.Add("ReportPath is not writable: $($State.ReportPath)")
        Complete-Stage -State $State -Stage $stage -Status 'FAIL' -ExitCode 10
        return 10
    }

    $sysDrive = Get-PSDrive -Name C -ErrorAction SilentlyContinue
    if ($sysDrive) {
        $freeGb = [math]::Round($sysDrive.Free / 1GB, 2)
        $stage.findings.Add("SystemDriveFreeGB=$freeGb")
        if ($freeGb -lt 2) {
            $stage.recommendations.Add('Critical low disk space on C:; free space before repair.')
            Complete-Stage -State $State -Stage $stage -Status 'FAIL' -ExitCode 1
            return 1
        } elseif ($freeGb -lt 8) {
            $stage.recommendations.Add('Low disk space on C: may degrade repair reliability.')
        }
    }

    $pendingRebootKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    $pending = $false
    foreach ($k in $pendingRebootKeys) {
        if (Test-Path $k) { $pending = $true; break }
    }
    $State.Context['pending_reboot'] = $pending
    if ($pending) {
        $stage.findings.Add('Pending reboot markers detected.')
        $stage.recommendations.Add('Reboot before Repair/Full for best servicing reliability.')
    }

    $toolList = 'dism','sfc','chkdsk','sc','reg','netsh','wevtutil'
    $missing = @()
    foreach ($t in $toolList) {
        if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { $missing += $t }
    }
    if ($missing.Count -gt 0) {
        $stage.findings.Add("Missing tools: $($missing -join ', ')")
    }

    if (($State.EffectiveMode -in @('Repair','Full')) -and -not $State.IsAdmin) {
        $stage.findings.Add('Repair/Full requires elevation.')
        Complete-Stage -State $State -Stage $stage -Status 'FAIL' -ExitCode 2
        return 2
    }

    $status = if ($pending -or $missing.Count -gt 0) { 'WARN' } else { 'OK' }
    Complete-Stage -State $State -Stage $stage -Status $status -ExitCode 0
    return 0
}

function Run-StageSnapshot {
    param([pscustomobject]$State)
    $stage = New-Stage 'B' 'Snapshot'

    try {
        $services = 'TrustedInstaller','wuauserv','bits','cryptsvc','eventlog','rpcss' |
            ForEach-Object {
                $svc = Get-Service -Name $_ -ErrorAction Stop
                [pscustomobject]@{ name=$svc.Name; status=$svc.Status.ToString(); startType=$svc.StartType.ToString() }
            }
        $snap = [pscustomobject]@{
            os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
            services = $services
            adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object Name, Status, LinkSpeed
        }
        $snapshotPath = Join-Path $State.ReportPath 'snapshot.json'
        $snap | ConvertTo-Json -Depth 8 | Set-Content -Path $snapshotPath -Encoding UTF8
        $stage.artifacts.Add($snapshotPath)
        $stage.findings.Add('Baseline snapshot captured.')

        $eventsPath = Join-Path $State.ReportPath 'events-snapshot.txt'
        Get-WinEvent -LogName System -MaxEvents 100 -ErrorAction SilentlyContinue |
            Where-Object { $_.ProviderName -match 'Microsoft-Windows-WindowsUpdateClient|Service Control Manager|DISM|CBS' } |
            Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
            Format-List | Out-File -FilePath $eventsPath -Encoding UTF8
        $stage.artifacts.Add($eventsPath)

        Complete-Stage -State $State -Stage $stage -Status 'OK' -ExitCode 0
        return 0
    } catch {
        $stage.findings.Add($_.Exception.Message)
        Complete-Stage -State $State -Stage $stage -Status 'WARN' -ExitCode 0
        return 0
    }
}

function Run-StageEnvironmentValidation {
    param([pscustomobject]$State)
    $stage = New-Stage 'C' 'Environment validation'

    $dismCheck = Invoke-ExternalCommand -FilePath 'dism.exe' -ArgumentList @('/Online','/Cleanup-Image','/CheckHealth') -TimeoutSec 1800 -HeartbeatSec 20 -State $State -IgnoreExitCode
    $dismStatus = if ($dismCheck.ExitCode -eq 0) { 'OK' } else { 'WARN' }
    Add-ActionResult -Stage $stage -Name 'DISM CheckHealth baseline' -Result $dismCheck -InterpretedStatus $dismStatus
    $stage.findings.Add("DISM CheckHealth baseline exit=$($dismCheck.ExitCode)")

    if ($dismCheck.StdOut -match 'repairable|corruption|component store') {
        $stage.recommendations.Add('Component store issues indicated; proceed with servicing readiness + DISM repair stages.')
    }

    $diskErr = Get-WinEvent -FilterHashtable @{LogName='System'; Id=7,51,55,153} -MaxEvents 30 -ErrorAction SilentlyContinue
    if ($diskErr) {
        $stage.findings.Add('Disk error indicators found in System log.')
        $stage.recommendations.Add('Run CHKDSK before deep component/system repair.')
    }

    $status = if ($dismCheck.ExitCode -ne 0 -or $diskErr) { 'WARN' } else { 'OK' }
    Complete-Stage -State $State -Stage $stage -Status $status -ExitCode 0
    return 0
}

function Run-StageReadiness {
    param([pscustomobject]$State)
    $stage = New-Stage 'D' 'Permission / servicing readiness'

    if ($State.EffectiveMode -eq 'Diagnose') {
        $stage.findings.Add('Diagnose-only mode: readiness repair changes skipped.')
        Complete-Stage -State $State -Stage $stage -Status 'SKIPPED' -ExitCode 0
        return 0
    }

    $critical = 'TrustedInstaller','wuauserv','bits','cryptsvc'
    foreach ($svcName in $critical) {
        try {
            $svc = Get-Service -Name $svcName -ErrorAction Stop
            $stage.findings.Add("Service $svcName state=$($svc.Status)")
            if ($svcName -eq 'TrustedInstaller' -and $svc.Status -ne 'Running') {
                Start-Service -Name $svcName -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
                $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
                $stage.findings.Add("Service $svcName after start attempt=$($svc.Status)")
            }
        } catch {
            $stage.findings.Add("Service check failed: $svcName => $($_.Exception.Message)")
        }
    }

    $status = if ($stage.findings -match 'failed') { 'WARN' } else { 'OK' }
    Complete-Stage -State $State -Stage $stage -Status $status -ExitCode 0
    return 0
}

function Run-StageComponentStoreRepair {
    param([pscustomobject]$State)
    $stage = New-Stage 'E' 'Component store repair'

    if ($State.EffectiveMode -eq 'Diagnose') {
        $stage.findings.Add('Diagnose-only mode: repair actions skipped.')
        Complete-Stage -State $State -Stage $stage -Status 'SKIPPED' -ExitCode 0
        return 0
    }

    if ($State.IsDryRun) {
        $stage.actions.Add([pscustomobject]@{ name='DISM CheckHealth'; status='PLANNED' })
        $stage.actions.Add([pscustomobject]@{ name='DISM ScanHealth'; status='PLANNED' })
        $stage.actions.Add([pscustomobject]@{ name='DISM RestoreHealth'; status='PLANNED' })
        Complete-Stage -State $State -Stage $stage -Status 'PLANNED' -ExitCode 0
        return 0
    }

    $check = Invoke-ExternalCommand -FilePath 'dism.exe' -ArgumentList @('/Online','/Cleanup-Image','/CheckHealth') -TimeoutSec 1800 -HeartbeatSec 20 -State $State -IgnoreExitCode
    Add-ActionResult -Stage $stage -Name 'DISM CheckHealth' -Result $check -InterpretedStatus ($(if($check.ExitCode -eq 0){'OK'}else{'WARN'}))

    $scan = Invoke-ExternalCommand -FilePath 'dism.exe' -ArgumentList @('/Online','/Cleanup-Image','/ScanHealth') -TimeoutSec 3600 -HeartbeatSec 20 -State $State -IgnoreExitCode
    Add-ActionResult -Stage $stage -Name 'DISM ScanHealth' -Result $scan -InterpretedStatus ($(if($scan.ExitCode -eq 0){'OK'}else{'FAIL'}))

    $needRestore = $true
    if ($scan.ExitCode -eq 0 -and $scan.StdOut -match 'No component store corruption detected') {
        $needRestore = $false
        $stage.findings.Add('ScanHealth reports no corruption; conservative mode skipping RestoreHealth.')
    }

    if ($needRestore) {
        $restore = Invoke-ExternalCommand -FilePath 'dism.exe' -ArgumentList @('/Online','/Cleanup-Image','/RestoreHealth') -TimeoutSec 7200 -HeartbeatSec 20 -State $State -IgnoreExitCode
        Add-ActionResult -Stage $stage -Name 'DISM RestoreHealth' -Result $restore -InterpretedStatus ($(if($restore.ExitCode -eq 0){'OK'}else{'FAIL'}))
    }

    $verify = Invoke-ExternalCommand -FilePath 'dism.exe' -ArgumentList @('/Online','/Cleanup-Image','/CheckHealth') -TimeoutSec 1800 -HeartbeatSec 20 -State $State -IgnoreExitCode
    Add-ActionResult -Stage $stage -Name 'DISM CheckHealth verify' -Result $verify -InterpretedStatus ($(if($verify.ExitCode -eq 0){'OK'}else{'WARN'}))

    $hasFail = @($stage.actions | Where-Object { $_.status -eq 'FAIL' }).Count -gt 0
    Complete-Stage -State $State -Stage $stage -Status ($(if($hasFail){'FAIL'}elseif($verify.ExitCode -ne 0){'WARN'}else{'OK'})) -ExitCode ($(if($hasFail){1}else{0}))
    return ($(if($hasFail){1}else{0}))
}

function Run-StageSystemFileRepair {
    param([pscustomobject]$State)
    $stage = New-Stage 'F' 'System file repair'

    if ($State.EffectiveMode -eq 'Diagnose') {
        Complete-Stage -State $State -Stage $stage -Status 'SKIPPED' -ExitCode 0
        return 0
    }
    if ($State.IsDryRun) {
        $stage.actions.Add([pscustomobject]@{ name='SFC /scannow'; status='PLANNED' })
        Complete-Stage -State $State -Stage $stage -Status 'PLANNED' -ExitCode 0
        return 0
    }

    $sfc = Invoke-ExternalCommand -FilePath 'sfc.exe' -ArgumentList @('/scannow') -TimeoutSec 7200 -HeartbeatSec 20 -State $State -IgnoreExitCode
    $normalized = 'WARN'
    if ($sfc.StdOut -match 'did not find any integrity violations') { $normalized = 'OK' }
    elseif ($sfc.StdOut -match 'found corrupt files and successfully repaired') { $normalized = 'WARN'; $stage.findings.Add('SFC repaired some files.') }
    elseif ($sfc.StdOut -match 'found corrupt files but was unable to fix') { $normalized = 'FAIL'; $stage.recommendations.Add('Unrepaired corruption remains. Review CBS.log and rerun DISM/SFC.') }
    elseif ($sfc.StdOut -match 'could not perform the requested operation') { $normalized = 'FAIL'; $stage.recommendations.Add('SFC could not run; verify servicing readiness and disk health.') }
    elseif ($sfc.ExitCode -eq 0) { $normalized = 'WARN' }
    else { $normalized = 'FAIL' }

    Add-ActionResult -Stage $stage -Name 'SFC /scannow' -Result $sfc -InterpretedStatus $normalized
    Complete-Stage -State $State -Stage $stage -Status $normalized -ExitCode ($(if($normalized -eq 'FAIL'){1}else{0}))
    return ($(if($normalized -eq 'FAIL'){1}else{0}))
}

function Run-StageSubsystemRepairs {
    param([pscustomobject]$State)
    $stage = New-Stage 'G' 'Windows subsystem repairs'

    if ($State.EffectiveMode -eq 'Diagnose') {
        Complete-Stage -State $State -Stage $stage -Status 'SKIPPED' -ExitCode 0
        return 0
    }
    if ($State.IsDryRun) {
        $stage.actions.Add([pscustomobject]@{ name='Subsystem profile'; status='PLANNED'; profile=$State.SubsystemProfile })
        Complete-Stage -State $State -Stage $stage -Status 'PLANNED' -ExitCode 0
        return 0
    }

    switch ($State.SubsystemProfile) {
        'None' {
            $stage.findings.Add('Subsystem profile None; no subsystem resets executed.')
            Complete-Stage -State $State -Stage $stage -Status 'SKIPPED' -ExitCode 0
            return 0
        }
        'Update' {
            $stage.findings.Add('Update subsystem profile selected (conservative checks only).')
            Complete-Stage -State $State -Stage $stage -Status 'WARN' -ExitCode 0
            return 0
        }
        'Network' {
            if (-not ($State.Force -or $State.AssumeYes)) {
                $stage.recommendations.Add('Network reset requires -Force or -AssumeYes.')
                Complete-Stage -State $State -Stage $stage -Status 'SKIPPED' -ExitCode 0
                return 0
            }
            $winsock = Invoke-ExternalCommand -FilePath 'netsh.exe' -ArgumentList @('winsock','reset') -TimeoutSec 120 -HeartbeatSec 10 -State $State -IgnoreExitCode
            Add-ActionResult -Stage $stage -Name 'netsh winsock reset' -Result $winsock -InterpretedStatus ($(if($winsock.ExitCode -eq 0){'OK'}else{'WARN'}))
            $stage.recommendations.Add('Reboot required after winsock reset.')
            Complete-Stage -State $State -Stage $stage -Status ($(if($winsock.ExitCode -eq 0){'WARN'}else{'FAIL'})) -ExitCode ($(if($winsock.ExitCode -eq 0){0}else{1}))
            return ($(if($winsock.ExitCode -eq 0){0}else{1}))
        }
        'All' {
            $stage.recommendations.Add('Profile All is intentionally conservative in this build; select explicit profiles.')
            Complete-Stage -State $State -Stage $stage -Status 'SKIPPED' -ExitCode 0
            return 0
        }
    }
}

function Run-StagePostValidation {
    param([pscustomobject]$State)
    $stage = New-Stage 'H' 'Post-repair validation'

    $dism = Invoke-ExternalCommand -FilePath 'dism.exe' -ArgumentList @('/Online','/Cleanup-Image','/CheckHealth') -TimeoutSec 1800 -HeartbeatSec 20 -State $State -IgnoreExitCode
    Add-ActionResult -Stage $stage -Name 'DISM CheckHealth post' -Result $dism -InterpretedStatus ($(if($dism.ExitCode -eq 0){'OK'}else{'WARN'}))

    $critical = 'TrustedInstaller','wuauserv','bits','cryptsvc' | ForEach-Object {
        $svc = Get-Service -Name $_ -ErrorAction SilentlyContinue
        [pscustomobject]@{ name=$_; status=if($svc){$svc.Status.ToString()}else{'Missing'} }
    }
    $criticalPath = Join-Path $State.ReportPath 'post-services.json'
    $critical | ConvertTo-Json -Depth 4 | Set-Content -Path $criticalPath -Encoding UTF8
    $stage.artifacts.Add($criticalPath)

    $status = if ($dism.ExitCode -eq 0) { 'OK' } else { 'WARN' }
    Complete-Stage -State $State -Stage $stage -Status $status -ExitCode 0
    return 0
}

function Run-StageFinalSummary {
    param([pscustomobject]$State)
    $stage = New-Stage 'I' 'Final summary and export'

    $failed = @($State.Stages | Where-Object { $_.status -eq 'FAIL' }).Count
    $warned = @($State.Stages | Where-Object { $_.status -eq 'WARN' }).Count
    $stage.findings.Add("stages_failed=$failed; stages_warn=$warned")

    $rebootRec = $State.Context['pending_reboot']
    if ($rebootRec) { $stage.recommendations.Add('Reboot recommended.') }

    Complete-Stage -State $State -Stage $stage -Status ($(if($failed -gt 0){'FAIL'}elseif($warned -gt 0){'WARN'}else{'OK'})) -ExitCode 0
    return 0
}

function Export-ToolkitReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$State)

    $jsonPath = Join-Path $State.ReportPath 'report.json'
    $mdPath = Join-Path $State.ReportPath 'report.md'

    $payload = [pscustomobject]@{
        mode      = $State.Mode
        effectiveMode = $State.EffectiveMode
        startedAt = $State.StartedAt
        finishedAt= Get-Date
        isAdmin   = $State.IsAdmin
        repairRan = ($State.EffectiveMode -in @('Repair','Full') -and -not $State.IsDryRun)
        reportExported = $true
        logPath   = $State.LogPath
        transcriptPath = $State.TranscriptPath
        stages    = $State.Stages
        steps     = $State.Steps
    }

    $payload | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8

    $lines = @(
        '# Windows Fix Toolkit Report',
        '',
        "- Mode: $($State.Mode)",
        "- EffectiveMode: $($State.EffectiveMode)",
        "- IsAdmin: $($State.IsAdmin)",
        "- StartedAt: $($State.StartedAt)",
        "- RepairRan: $($payload.repairRan)",
        '',
        '## Stages'
    )
    foreach ($st in $State.Stages) {
        $lines += "- **[$($st.stage_id)] $($st.stage_name)**: $($st.status) (exit=$($st.exit_code))"
        foreach ($f in $st.findings) { $lines += "  - $f" }
        foreach ($r in $st.recommendations) { $lines += "  - Recommendation: $r" }
        foreach ($a in $st.artifacts) { $lines += "  - Artifact: $a" }
    }

    Set-Content -Path $mdPath -Value $lines -Encoding UTF8
    return [pscustomobject]@{ Json=$jsonPath; Markdown=$mdPath }
}

function Invoke-WindowsFix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Diagnose','Repair','Full','DryRun')]
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
        [ValidateSet('None','Update','Network','All')]
        [string]$SubsystemProfile = 'None'
    )

    $state = New-ToolkitState -Mode $Mode -ReportPath $ReportPath -LogPath $LogPath -TranscriptPath $TranscriptPath -NoNetwork:$NoNetwork -AssumeYes:$AssumeYes -Force:$Force -SubsystemProfile $SubsystemProfile
    Write-ToolkitLog -State $state -Message "Mode=$Mode, EffectiveMode=$($state.EffectiveMode), IsAdmin=$($state.IsAdmin), ReportPath=$ReportPath"

    $exitCode = 0
    try {
        $preflightCode = Run-StagePreflight -State $state
        if ($preflightCode -in 2,10) {
            $exitCode = $preflightCode
        } elseif ($preflightCode -eq 1) {
            $exitCode = 1
        }

        if ($exitCode -eq 0) {
            $null = Run-StageSnapshot -State $state
            $null = Run-StageEnvironmentValidation -State $state

            if ($state.EffectiveMode -in @('Repair','Full')) {
                if ((Run-StageReadiness -State $state) -ne 0) { $exitCode = 1 }
                if ((Run-StageComponentStoreRepair -State $state) -ne 0) { $exitCode = 1 }
                if ((Run-StageSystemFileRepair -State $state) -ne 0) { $exitCode = 1 }
                if ((Run-StageSubsystemRepairs -State $state) -ne 0) { $exitCode = 1 }
            } else {
                $skipStage = New-Stage 'D' 'Permission / servicing readiness'; Complete-Stage -State $state -Stage $skipStage -Status 'SKIPPED' -ExitCode 0
                $skipStage = New-Stage 'E' 'Component store repair'; Complete-Stage -State $state -Stage $skipStage -Status 'SKIPPED' -ExitCode 0
                $skipStage = New-Stage 'F' 'System file repair'; Complete-Stage -State $state -Stage $skipStage -Status 'SKIPPED' -ExitCode 0
                $skipStage = New-Stage 'G' 'Windows subsystem repairs'; Complete-Stage -State $state -Stage $skipStage -Status 'SKIPPED' -ExitCode 0
            }

            $null = Run-StagePostValidation -State $state
            $null = Run-StageFinalSummary -State $state

            if (@($state.Stages | Where-Object { $_.status -eq 'FAIL' }).Count -gt 0 -and $exitCode -eq 0) {
                $exitCode = 1
            }
        }

        $report = Export-ToolkitReport -State $state
        Write-ToolkitLog -State $state -Message "Report generated: $($report.Json), $($report.Markdown)"

        if (-not (Test-Path $report.Json) -or -not (Test-Path $report.Markdown)) {
            Write-ToolkitLog -State $state -Level ERROR -Message 'Report export failed.'
            return 10
        }

        return $exitCode
    } catch {
        Write-ToolkitLog -State $state -Level ERROR -Message $_.Exception.Message
        $errStage = New-Stage 'X' 'Unhandled exception'
        $errStage.findings.Add($_.Exception.Message)
        Complete-Stage -State $state -Stage $errStage -Status 'FAIL' -ExitCode 3
        try {
            $report = Export-ToolkitReport -State $state
            if (-not (Test-Path $report.Json) -or -not (Test-Path $report.Markdown)) { return 10 }
        } catch {
            return 10
        }
        return 3
    }
}

Export-ModuleMember -Function Invoke-WindowsFix,New-ToolkitState,Invoke-ExternalCommand,Export-ToolkitReport,Wait-ServiceState,ConvertTo-CommandLine
