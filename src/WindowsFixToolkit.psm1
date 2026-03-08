Set-StrictMode -Version Latest

. $PSScriptRoot/internal/logging.ps1
. $PSScriptRoot/internal/process.ps1
. $PSScriptRoot/internal/checks.ps1
. $PSScriptRoot/deeprecovery/schemas.ps1
. $PSScriptRoot/deeprecovery/preflight.ps1
. $PSScriptRoot/deeprecovery/safeguard.ps1
. $PSScriptRoot/deeprecovery/sourceDiscovery.ps1
. $PSScriptRoot/deeprecovery/sourceValidation.ps1
. $PSScriptRoot/deeprecovery/dismRepair.ps1
. $PSScriptRoot/deeprecovery/sfcRepair.ps1
. $PSScriptRoot/deeprecovery/postcheck.ps1
. $PSScriptRoot/deeprecovery/escalation.ps1
. $PSScriptRoot/deeprecovery/reinstallPath.ps1
. $PSScriptRoot/deeprecovery/classification.ps1
. $PSScriptRoot/deeprecovery/reporting.ps1
. $PSScriptRoot/deeprecovery/ui.ps1
. $PSScriptRoot/deeprecovery/signatures.ps1
. $PSScriptRoot/deeprecovery/policy.ps1
. $PSScriptRoot/deeprecovery/orchestrator.ps1

if (-not (Get-Variable -Name CompiledRegexCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:CompiledRegexCache = @{}
}

function Convert-ToSafeInt {
    param($Value,[int]$Default = 0)
    if ($null -eq $Value) { return $Default }
    try { return [int]$Value } catch { return $Default }
}

function Convert-ToArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) { return @($Value) }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        return @($Value)
    }
    return @($Value)
}

function New-ToolkitState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Diagnose','Repair','Full','DryRun','DeepRecovery')]
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
        [string]$SubsystemProfile = 'None',
        [ValidateSet('Quick','Normal','Deep')]
        [string]$RepairProfile = 'Normal',
        [ValidateSet('Quick','Normal','Deep')]
        [string]$DiagnoseProfile = 'Normal',
        [switch]$UiVerbose,
        [int]$KeepOutputRuns = 5,
        [string]$RecoverySourcePath,
        [switch]$DeepRecoveryAllowNoSafeguard
    )

    $ReportPath = $ReportPath.Trim()
    if ($ReportPath -match '[<>"|?*]') {
        throw "Invalid characters in ReportPath"
    }
    $resolvedReportPath = [System.IO.Path]::GetFullPath($ReportPath)
    if (-not $resolvedReportPath -or [System.IO.Path]::GetPathRoot($resolvedReportPath) -eq '') {
        throw "Unable to resolve ReportPath: $ReportPath"
    }

    try {
        $null = New-Item -ItemType Directory -Path $resolvedReportPath -Force -ErrorAction Stop
    } catch [System.UnauthorizedAccessException] {
        throw "Access denied creating report directory: $resolvedReportPath"
    } catch [System.IO.IOException] {
        throw "I/O error creating report directory: $resolvedReportPath - $($_.Exception.Message)"
    } catch {
        throw "Failed to create report directory: $($_.Exception.Message)"
    }

    $ReportPath = $resolvedReportPath
    $resolvedLogPath = [System.IO.Path]::GetFullPath($LogPath)
    $resolvedTranscriptPath = [System.IO.Path]::GetFullPath($TranscriptPath)
    if ($resolvedLogPath.Equals($resolvedTranscriptPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $resolvedLogPath = Join-Path $ReportPath 'toolkit.log'
    }

    $ctx = @{
        normalized_events = New-Object System.Collections.Generic.List[object]
        policy_decisions = New-Object System.Collections.Generic.List[object]
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
        RepairProfile = $RepairProfile
        DiagnoseProfile = $DiagnoseProfile
        UiVerbose = [bool]$UiVerbose
        KeepOutputRuns = $KeepOutputRuns
        RecoverySourcePath = $RecoverySourcePath
        DeepRecoveryAllowNoSafeguard = [bool]$DeepRecoveryAllowNoSafeguard
        StartedAt      = (Get-Date)
        IsAdmin        = (Test-IsAdmin)
        Stages         = New-Object System.Collections.Generic.List[object]
        Steps          = New-Object System.Collections.Generic.List[object]
        Context        = $ctx
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
        duration_ms = 0
    }
}

function Complete-Stage {
    param([pscustomobject]$State,[pscustomobject]$Stage,[string]$Status,[int]$ExitCode=0)
    $Stage.status = $Status
    $Stage.exit_code = $ExitCode
    $Stage.end_time = Get-Date
    $Stage.duration_ms = [int](($Stage.end_time - $Stage.start_time).TotalMilliseconds)
    $State.Stages.Add($Stage)
    $State.Steps.Add([pscustomobject]@{ name=$Stage.stage_name; status=$Status; exitCode=$ExitCode; durationMs=[int](($Stage.end_time-$Stage.start_time).TotalMilliseconds); details=($Stage.findings -join ' | ') })
    Write-StageJournal -State $State -Stage $Stage
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$MaxRetries = 3,
        [int]$DelaySeconds = 1,
        [scriptblock]$ShouldRetry = { param($ex) $true }
    )

    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        try {
            return & $ScriptBlock
        } catch {
            $attempt++
            if ($attempt -ge $MaxRetries -or -not (& $ShouldRetry $_)) { throw }
            $delay = [int]($DelaySeconds * [Math]::Pow(2, ($attempt - 1)))
            Start-Sleep -Seconds $delay
        }
    }
}

function Write-StageJournal {
    param([pscustomobject]$State,[pscustomobject]$Stage)
    if (-not $State -or -not $Stage) { return }
    try {
        $journalDir = Join-Path $State.ReportPath 'journal'
        New-Item -ItemType Directory -Path $journalDir -Force | Out-Null

        $eventsPool = Convert-ToArray -Value $State.Context['normalized_events']
        $decisionPool = Convert-ToArray -Value $State.Context['policy_decisions']
        $events = @($eventsPool | Where-Object { $_ -and $_.stage -eq $Stage.stage_id })
        $decisions = @($decisionPool | Where-Object { $_ -and $_.stage -eq $Stage.stage_id })

        $matchedSignatures = @()
        foreach ($ev in $events) {
            if ($ev -and $ev.PSObject.Properties.Name -contains 'signature') {
                $sig = [string]$ev.signature
                if ($sig -and -not ($matchedSignatures -contains $sig)) {
                    $matchedSignatures += $sig
                }
            }
        }

        $lastDecision = 'none'
        if ($decisions.Count -gt 0) {
            $last = $decisions | Select-Object -Last 1
            if ($last -and $last.PSObject.Properties.Name -contains 'decision') {
                $lastDecision = [string]$last.decision
            }
        }

        $entry = [pscustomobject]@{
            stage = [string]$Stage.stage_id
            stageName = [string]$Stage.stage_name
            status = [string]$Stage.status
            exitCode = (Convert-ToSafeInt -Value $Stage.exit_code)
            startTime = $Stage.start_time
            endTime = $Stage.end_time
            durationMs = (Convert-ToSafeInt -Value $Stage.duration_ms)
            actions = (Convert-ToArray -Value $Stage.actions)
            matchedSignatures = @($matchedSignatures)
            decision = $lastDecision
            humanSummary = if ((Convert-ToArray -Value $Stage.findings).Count -gt 0) { [string](Convert-ToArray -Value $Stage.findings)[0] } else { "Stage $($Stage.stage_id) completed with status $($Stage.status)" }
            normalizedEvents = @($events)
            policyDecisions = @($decisions)
        }

        $outPath = Join-Path $journalDir ("stage_{0}.json" -f $Stage.stage_id)
        $maxJournalSizeKB = 1024
        if (Test-Path $outPath) {
            $currentSizeKB = [math]::Round(((Get-Item $outPath).Length / 1KB), 2)
            if ($currentSizeKB -gt $maxJournalSizeKB) {
                $archive = $outPath -replace '\.json$', ("_{0}.json" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
                Move-Item -Path $outPath -Destination $archive -Force
            }
        }
        $entry | ConvertTo-Json -Depth 12 | Set-Content -Path $outPath -Encoding UTF8

        try {
            $artifactPath = [string]$outPath
            if ($artifactPath -and -not ($Stage.artifacts -contains $artifactPath)) {
                $Stage.artifacts.Add($artifactPath)
            }
        } catch {}
    } catch {
        if ($State) { Write-ToolkitLog -State $State -Level WARN -Message "Failed to write stage journal for $($Stage.stage_id): $($_.Exception.Message); stack=$($_.ScriptStackTrace)" }
    }
}

function Cleanup-OldOutputFolders {
    param([pscustomobject]$State)
    try {
        $keep = [int]$State.KeepOutputRuns
        if ($keep -lt 1) { $keep = 1 }
        $outputsRoot = Split-Path -Parent $State.ReportPath
        if (-not (Test-Path $outputsRoot)) { return }

        $dirs = @(Get-ChildItem -Path $outputsRoot -Directory -Filter 'WindowsFix_*' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
        if ($dirs.Count -le $keep) { return }

        $toDelete = $dirs[$keep..($dirs.Count-1)]
        foreach ($d in $toDelete) {
            if ($d.FullName -eq $State.ReportPath) { continue }
            try {
                Remove-Item -Path $d.FullName -Recurse -Force -ErrorAction Stop
                Write-ToolkitLog -State $State -Message "[CLEANUP] removed old output folder: $($d.FullName)"
            } catch {
                Write-ToolkitLog -State $State -Level WARN -Message "[CLEANUP] failed to remove old output folder: $($d.FullName) :: $($_.Exception.Message)"
            }
        }
    } catch {
        Write-ToolkitLog -State $State -Level WARN -Message "[CLEANUP] failed: $($_.Exception.Message)"
    }
}

function Resolve-SignatureCatalogPath {
    return Join-Path $PSScriptRoot 'config/error-signatures.json'
}

function Resolve-DecisionPolicyPath {
    return Join-Path $PSScriptRoot 'config/decision-policy.json'
}

function Add-ActionResult {
    param(
        [pscustomobject]$State,
        [pscustomobject]$Stage,
        [string]$Name,
        [pscustomobject]$Result,
        [string]$InterpretedStatus
    )
    $Stage.actions.Add([pscustomobject]@{
        name = $Name
        commandLine = $Result.CommandLine
        args = @($Result.Arguments)
        process_id = $Result.ProcessId
        launch_mode = $Result.LaunchMode
        exit_code = $Result.ExitCode
        exit_code_captured = $Result.ExitCodeCaptured
        duration_ms = $Result.DurationMs
        timed_out = $Result.TimedOut
        stdout_path = $Result.StdOutPath
        stderr_path = $Result.StdErrPath
        status = $InterpretedStatus
        stdout = $Result.StdOut
        stderr = $Result.StdErr
    })

    Add-NormalizedEventsFromResult -State $State -StageId $Stage.stage_id -Result $Result
}

function Get-SignatureCatalog {
    $path = Resolve-SignatureCatalogPath
    try {
        if (Test-Path $path) {
            $loaded = Get-Content -Raw -Path $path | ConvertFrom-Json
            if ($loaded) { return @($loaded) }
        }
    } catch {}

    @(
        [pscustomobject]@{ signature='DISM_SOURCE_MISSING'; regex='0x800f081f|source files could not be found'; tool='dism'; severity='error'; category='system'; hint='DISM source is unavailable.'; next_action='retry_with_source_or_abort' },
        [pscustomobject]@{ signature='ACCESS_DENIED'; regex='Access is denied|0x80070005'; tool='generic'; severity='error'; category='permissions'; hint='Permission/elevation issue.'; next_action='relaunch_elevated_or_unlock' },
        [pscustomobject]@{ signature='WRP_CORRUPTION_FOUND'; regex='Windows Resource Protection found corrupt files'; tool='sfc'; severity='warning'; category='system'; hint='SFC found corruption.'; next_action='review_repairability_then_reboot' },
        [pscustomobject]@{ signature='DISM_COMPONENT_REPAIRABLE'; regex='component store is repairable|repairable'; tool='dism'; severity='warning'; category='system'; hint='Component store corruption is repairable.'; next_action='run_restorehealth' },
        [pscustomobject]@{ signature='POWERSHELL_ARGUMENTLIST_NULL'; regex='ArgumentList.*null|cannot bind argument'; tool='powershell'; severity='fatal'; category='internal'; hint='Wrapper argument construction bug.'; next_action='abort_and_fix_tooling' },
        [pscustomobject]@{ signature='EXIT_CODE_NOT_CAPTURED'; regex=''; tool='internal'; severity='warning'; category='internal'; hint='External process finished but exit code was not captured.'; next_action='mark_unverified_and_retry' }
    )
}

function Get-DecisionPolicy {
    $path = Resolve-DecisionPolicyPath
    try {
        if (Test-Path $path) {
            $loaded = Get-Content -Raw -Path $path | ConvertFrom-Json -AsHashtable
            if ($loaded) { return $loaded }
        }
    } catch {}

    return @{
        'DISM_SOURCE_MISSING' = @{ severity='error'; category='system'; action='fallback_or_abort'; retry_allowed=$false; requires_source=$true }
        'POWERSHELL_ARGUMENTLIST_NULL' = @{ severity='fatal'; category='internal'; action='abort_pipeline'; retry_allowed=$false; requires_code_fix=$true }
        'EXIT_CODE_NOT_CAPTURED' = @{ severity='warning'; category='internal'; action='retry'; retry_allowed=$true; requires_code_fix=$true }
        'ACCESS_DENIED' = @{ severity='error'; category='permissions'; action='relaunch_elevated_or_unlock'; retry_allowed=$true; requires_code_fix=$false }
    }
}

function Add-NormalizedEvent {
    param(
        [pscustomobject]$State,
        [string]$StageId,
        [string]$Tool,
        [string]$Severity,
        [string]$Signature,
        [string]$Category = 'system',
        [string]$Raw,
        [string]$Hint,
        [string]$NextAction
    )
    if (-not $State) { return }
    if (-not $State.Context['normalized_events']) {
        $State.Context['normalized_events'] = New-Object System.Collections.Generic.List[object]
    }
    $State.Context['normalized_events'].Add([pscustomobject]@{
        stage = $StageId
        tool = $Tool
        severity = $Severity
        signature = $Signature
        category = $Category
        raw = $Raw
        hint = $Hint
        next_action = $NextAction
    })
}

function Register-PolicyDecision {
    param(
        [pscustomobject]$State,
        [string]$StageId,
        [string]$Decision,
        [string]$Reason,
        [string]$Evidence
    )
    if (-not $State) { return }
    if (-not $State.Context['policy_decisions']) {
        $State.Context['policy_decisions'] = New-Object System.Collections.Generic.List[object]
    }
    $State.Context['policy_decisions'].Add([pscustomobject]@{
        stage = $StageId
        decision = $Decision
        reason = $Reason
        evidence = $Evidence
    })
}

function Get-ToolNameFromCommand {
    param([pscustomobject]$Result)
    if (-not $Result -or -not $Result.FilePath) { return 'unknown' }
    return ([System.IO.Path]::GetFileNameWithoutExtension($Result.FilePath).ToLowerInvariant())
}

function Add-NormalizedEventsFromResult {
    param(
        [pscustomobject]$State,
        [string]$StageId,
        [pscustomobject]$Result
    )
    if (-not $State -or -not $Result) { return }
    $tool = Get-ToolNameFromCommand -Result $Result
    $catalog = Get-SignatureCatalog
    $policy = Get-DecisionPolicy

    if ($null -eq $script:CompiledRegexCache) {
        $script:CompiledRegexCache = @{}
    }
    foreach ($sig in $catalog) {
        if (-not $sig.regex) { continue }
        if (-not $script:CompiledRegexCache.ContainsKey($sig.signature)) {
            $script:CompiledRegexCache[$sig.signature] = [regex]::new([string]$sig.regex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
    }

    if (-not $Result.ExitCodeCaptured) {
        $sig = $catalog | Where-Object { $_.signature -eq 'EXIT_CODE_NOT_CAPTURED' } | Select-Object -First 1
        Add-NormalizedEvent -State $State -StageId $StageId -Tool $tool -Severity $sig.severity -Signature $sig.signature -Category $sig.category -Raw $Result.CommandLine -Hint $sig.hint -NextAction $sig.next_action
        $decision = if ($policy.ContainsKey('EXIT_CODE_NOT_CAPTURED')) { [string]$policy['EXIT_CODE_NOT_CAPTURED'].action } else { 'retry' }
        Register-PolicyDecision -State $State -StageId $StageId -Decision $decision -Reason 'Exit code not captured' -Evidence $Result.CommandLine
    }

    $lines = @()
    if ($Result.StdOut) { $lines += ($Result.StdOut -split "`r?`n") }
    if ($Result.StdErr) { $lines += ($Result.StdErr -split "`r?`n") }
    foreach ($line in $lines) {
        foreach ($sig in $catalog) {
            if (-not $sig.regex) { continue }
            $regex = $script:CompiledRegexCache[$sig.signature]
            if ($regex -and $regex.IsMatch($line)) {
                if ($sig.tool -ne 'generic' -and $sig.tool -ne $tool -and $sig.tool -ne 'powershell') { continue }
                Add-NormalizedEvent -State $State -StageId $StageId -Tool $tool -Severity $sig.severity -Signature $sig.signature -Category $sig.category -Raw $line -Hint $sig.hint -NextAction $sig.next_action
                $decision = 'suggest_manual_action'
                if ($policy.ContainsKey($sig.signature)) {
                    $decision = [string]$policy[$sig.signature].action
                } elseif ($sig.severity -eq 'fatal') {
                    $decision = 'abort'
                } elseif ($sig.signature -eq 'DISM_COMPONENT_REPAIRABLE') {
                    $decision = 'continue'
                }
                Register-PolicyDecision -State $State -StageId $StageId -Decision $decision -Reason $sig.signature -Evidence $line
            }
        }
    }
}

function Evaluate-PreflightPolicy {
    param([pscustomobject]$State,[bool]$PendingReboot,[bool]$CanRepair)
    if ($PendingReboot) {
        Register-PolicyDecision -State $State -StageId 'A' -Decision 'continue' -Reason 'Pending reboot present' -Evidence 'pending_reboot=true'
    }
    if (-not $CanRepair) {
        Register-PolicyDecision -State $State -StageId 'A' -Decision 'abort' -Reason 'Repair preconditions failed' -Evidence 'preflight'
    }
}

function Get-MissingTools {
    param([string[]]$Tools)
    $missing = @()
    foreach ($t in $Tools) {
        if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { $missing += $t }
    }
    return $missing
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

    $pending = $false

    $isWritable = Test-ReportPathWritable -Path $State.ReportPath
    $State.Context['report_writable'] = $isWritable
    if (-not $isWritable) {
        $stage.findings.Add("ReportPath is not writable: $($State.ReportPath)")
        Evaluate-PreflightPolicy -State $State -PendingReboot $pending -CanRepair $false
        Complete-Stage -State $State -Stage $stage -Status 'FAIL' -ExitCode 10
        return 10
    }

    $sysDrive = Get-PSDrive -Name C -ErrorAction SilentlyContinue
    if ($sysDrive) {
        $freeGb = [math]::Round($sysDrive.Free / 1GB, 2)
        $stage.findings.Add("SystemDriveFreeGB=$freeGb")
        if ($freeGb -lt 2) {
            $stage.recommendations.Add('Critical low disk space on C:; free space before repair.')
            Evaluate-PreflightPolicy -State $State -PendingReboot $pending -CanRepair $false
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
    $missing = @(Get-MissingTools -Tools $toolList)
    $State.Context['missing_tools'] = @($missing)
    if ($missing.Count -gt 0) {
        $stage.findings.Add("Missing tools: $($missing -join ', ')")
    }

    if (($State.EffectiveMode -in @('Repair','Full','DeepRecovery')) -and -not $State.IsAdmin) {
        $stage.findings.Add('Repair/Full requires elevation.')
        Evaluate-PreflightPolicy -State $State -PendingReboot $pending -CanRepair $false
        Complete-Stage -State $State -Stage $stage -Status 'FAIL' -ExitCode 2
        return 2
    }

    $status = if ($pending -or $missing.Count -gt 0) { 'WARN' } else { 'OK' }
    Evaluate-PreflightPolicy -State $State -PendingReboot $pending -CanRepair $true
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
        $osRaw = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $osNorm = if ($osRaw) {
            [pscustomobject]@{
                Caption = $osRaw.Caption
                Version = $osRaw.Version
                BuildNumber = $osRaw.BuildNumber
                OSArchitecture = $osRaw.OSArchitecture
                LastBootUpTime = $osRaw.LastBootUpTime
                SystemDrive = $osRaw.SystemDrive
                MUILanguages = @($osRaw.MUILanguages)
            }
        } else { $null }

        $snap = [pscustomobject]@{
            os = $osNorm
            services = $services
            adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object Name, Status, LinkSpeed
        }
        $snapshotPath = Join-Path $State.ReportPath 'snapshot.json'
        $snap | ConvertTo-Json -Depth 8 | Set-Content -Path $snapshotPath -Encoding UTF8
        $stage.artifacts.Add($snapshotPath)
        $stage.findings.Add('Baseline snapshot captured.')

        $eventsPath = Join-Path $State.ReportPath 'events-snapshot.txt'
        $maxEvents = if ($State.DiagnoseProfile -eq 'Quick') { 40 } elseif ($State.DiagnoseProfile -eq 'Deep') { 300 } else { 100 }
        Get-WinEvent -LogName System -MaxEvents $maxEvents -ErrorAction SilentlyContinue |
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
    $stage.findings.Add("DiagnoseProfile=$($State.DiagnoseProfile)")

    $dismCheck = $null
    $missingTools = @($State.Context['missing_tools'])
    if ($missingTools -contains 'dism') {
        $stage.actions.Add([pscustomobject]@{ name='DISM CheckHealth baseline'; status='FAIL'; reason='DISM is unavailable'; exit_code=127; duration_ms=0; timed_out=$false; commandLine='dism.exe /Online /Cleanup-Image /CheckHealth'; stdout=''; stderr='dism not found' })
        $stage.findings.Add('DISM is unavailable; servicing diagnostics are limited.')
        Complete-Stage -State $State -Stage $stage -Status 'WARN' -ExitCode 0
        return 0
    }

    if ($State.DiagnoseProfile -eq 'Quick') {
        $stage.actions.Add([pscustomobject]@{ name='DISM CheckHealth baseline'; status='SKIPPED'; reason='DiagnoseProfile=Quick'; exit_code=0; duration_ms=0; timed_out=$false; commandLine='dism.exe /Online /Cleanup-Image /CheckHealth'; stdout=''; stderr='' })
        $stage.findings.Add('Quick diagnose profile skips DISM CheckHealth baseline for speed.')
    } else {
        $dismCheck = Invoke-ExternalCommand -FilePath 'dism.exe' -ArgumentList @('/Online','/Cleanup-Image','/CheckHealth') -TimeoutSec 1800 -HeartbeatSec 20 -State $State -IgnoreExitCode
        $dismStatus = if (-not $dismCheck.ExitCodeCaptured) { 'WARN' } elseif ($dismCheck.ExitCode -eq 0) { 'OK' } else { 'WARN' }
        Add-ActionResult -State $State -Stage $stage -Name 'DISM CheckHealth baseline' -Result $dismCheck -InterpretedStatus $dismStatus
        $stage.findings.Add("DISM CheckHealth baseline exit=$($dismCheck.ExitCode)")
        if (-not $dismCheck.ExitCodeCaptured) {
            $stage.recommendations.Add('DISM baseline finished but exit code was not captured reliably.')
        }

        if ($dismCheck.StdOut -match 'repairable|corruption|component store') {
            $stage.recommendations.Add('Component store issues indicated; proceed with servicing readiness + DISM repair stages.')
        }
    }

    $diskErr = Get-WinEvent -FilterHashtable @{LogName='System'; Id=7,51,55,153} -MaxEvents 30 -ErrorAction SilentlyContinue
    if ($diskErr) {
        $stage.findings.Add('Disk error indicators found in System log.')
        $details = $diskErr | Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message
        $diskPath = Join-Path $State.ReportPath 'disk-indicators.json'
        $details | ConvertTo-Json -Depth 6 | Set-Content -Path $diskPath -Encoding UTF8
        $stage.artifacts.Add($diskPath)
        $sample = $details | Select-Object -First 3
        foreach ($d in $sample) {
            $stage.findings.Add("DiskEvent id=$($d.Id) provider=$($d.ProviderName)")
        }
        $stage.recommendations.Add('Run CHKDSK before deep component/system repair.')
    }

    $status = if (($dismCheck -and $dismCheck.ExitCode -ne 0) -or $diskErr) { 'WARN' } else { 'OK' }
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
    $allServices = @(Get-Service -Name $critical -ErrorAction SilentlyContinue)
    $serviceMap = @{}
    foreach ($svc in $allServices) { $serviceMap[$svc.Name] = $svc }

    foreach ($svcName in $critical) {
        $svc = $serviceMap[$svcName]
        if (-not $svc) {
            $stage.findings.Add("Service check failed: $svcName => not found")
            continue
        }

        $stage.findings.Add("Service $svcName state=$($svc.Status)")
        if ($svcName -eq 'TrustedInstaller' -and $svc.Status -ne 'Running') {
            try {
                Start-Service -Name $svcName -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
                $svcAfter = Get-Service -Name $svcName -ErrorAction SilentlyContinue
                if ($svcAfter) { $stage.findings.Add("Service $svcName after start attempt=$($svcAfter.Status)") }
            } catch {
                $stage.findings.Add("Service check failed: $svcName => $($_.Exception.Message)")
            }
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

    $stage.findings.Add("RepairProfile=$($State.RepairProfile)")

    $missingTools = @($State.Context['missing_tools'])
    if ($missingTools -contains 'dism') {
        $stage.findings.Add('DISM is unavailable; component store repair cannot run.')
        $stage.recommendations.Add('Restore DISM availability (servicing stack) and rerun repair.')
        Complete-Stage -State $State -Stage $stage -Status 'FAIL' -ExitCode 1
        return 1
    }

    $check = Invoke-ExternalCommand -FilePath 'dism.exe' -ArgumentList @('/Online','/Cleanup-Image','/CheckHealth') -TimeoutSec 1800 -HeartbeatSec 20 -State $State -IgnoreExitCode
    Add-ActionResult -State $State -Stage $stage -Name 'DISM CheckHealth' -Result $check -InterpretedStatus ($(if(-not $check.ExitCodeCaptured){'WARN'}elseif($check.ExitCode -eq 0){'OK'}else{'WARN'}))
    if (-not $check.ExitCodeCaptured) { $stage.recommendations.Add('DISM CheckHealth exit code was not captured; result verification is limited.') }

    if ($State.RepairProfile -eq 'Quick') {
        $stage.actions.Add([pscustomobject]@{ name='DISM ScanHealth'; status='SKIPPED'; reason='RepairProfile=Quick'; exit_code=0; duration_ms=0; timed_out=$false; commandLine='dism.exe /Online /Cleanup-Image /ScanHealth'; stdout=''; stderr='' })
        $stage.actions.Add([pscustomobject]@{ name='DISM RestoreHealth'; status='SKIPPED'; reason='RepairProfile=Quick'; exit_code=0; duration_ms=0; timed_out=$false; commandLine='dism.exe /Online /Cleanup-Image /RestoreHealth'; stdout=''; stderr='' })
        $stage.recommendations.Add('Quick profile skips ScanHealth/RestoreHealth for faster run. Use RepairProfile=Normal or Deep for full servicing repair.')
    } else {
        $scan = Invoke-ExternalCommand -FilePath 'dism.exe' -ArgumentList @('/Online','/Cleanup-Image','/ScanHealth') -TimeoutSec 3600 -HeartbeatSec 20 -State $State -IgnoreExitCode
        Add-ActionResult -State $State -Stage $stage -Name 'DISM ScanHealth' -Result $scan -InterpretedStatus ($(if(-not $scan.ExitCodeCaptured){'WARN'}elseif($scan.ExitCode -eq 0){'OK'}else{'FAIL'}))

        $needRestore = $true
        if ($scan.ExitCode -eq 0 -and $scan.StdOut -match 'No component store corruption detected' -and $State.RepairProfile -eq 'Normal') {
            $needRestore = $false
            $stage.findings.Add('ScanHealth reports no corruption; Normal profile skips RestoreHealth.')
        }

        if ($needRestore) {
            $restore = Invoke-ExternalCommand -FilePath 'dism.exe' -ArgumentList @('/Online','/Cleanup-Image','/RestoreHealth') -TimeoutSec 7200 -HeartbeatSec 20 -State $State -IgnoreExitCode
            Add-ActionResult -State $State -Stage $stage -Name 'DISM RestoreHealth' -Result $restore -InterpretedStatus ($(if(-not $restore.ExitCodeCaptured){'WARN'}elseif($restore.ExitCode -eq 0){'OK'}else{'FAIL'}))
        }
    }

    $verify = Invoke-ExternalCommand -FilePath 'dism.exe' -ArgumentList @('/Online','/Cleanup-Image','/CheckHealth') -TimeoutSec 1800 -HeartbeatSec 20 -State $State -IgnoreExitCode
    Add-ActionResult -State $State -Stage $stage -Name 'DISM CheckHealth verify' -Result $verify -InterpretedStatus ($(if(-not $verify.ExitCodeCaptured){'WARN'}elseif($verify.ExitCode -eq 0){'OK'}else{'WARN'}))

    $hasFail = @($stage.actions | Where-Object { $_.status -eq 'FAIL' }).Count -gt 0
    $hasUnverified = @($stage.actions | Where-Object { $_.exit_code_captured -eq $false }).Count -gt 0
    $stageStatus = if ($hasFail) { 'FAIL' } elseif ($hasUnverified -or $verify.ExitCode -ne 0) { 'WARN' } else { 'OK' }
    Complete-Stage -State $State -Stage $stage -Status $stageStatus -ExitCode ($(if($hasFail){1}else{0}))
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

    $missingTools = @($State.Context['missing_tools'])
    if ($missingTools -contains 'sfc') {
        $stage.findings.Add('SFC is unavailable; system file repair cannot run.')
        $stage.recommendations.Add('Restore sfc.exe availability and rerun stage F.')
        Complete-Stage -State $State -Stage $stage -Status 'FAIL' -ExitCode 1
        return 1
    }

    Write-Host '[WORK] Running SFC scan in a separate console window...'
    $sfc = Invoke-ExternalCommand -FilePath 'sfc.exe' -ArgumentList @('/scannow') -TimeoutSec 7200 -HeartbeatSec 20 -State $State -IgnoreExitCode
    $normalized = 'WARN'
    if (-not $sfc.ExitCodeCaptured) { $normalized = 'WARN'; $stage.recommendations.Add('SFC exit code was not captured reliably; verify via CBS.log and rerun if needed.') }
    elseif ($sfc.StdOut -match 'did not find any integrity violations') { $normalized = 'OK' }
    elseif ($sfc.StdOut -match 'found corrupt files and successfully repaired') { $normalized = 'WARN'; $stage.findings.Add('SFC repaired some files.') }
    elseif ($sfc.StdOut -match 'found corrupt files but was unable to fix') { $normalized = 'FAIL'; $stage.recommendations.Add('Unrepaired corruption remains. Review CBS.log and rerun DISM/SFC.') }
    elseif ($sfc.StdOut -match 'could not perform the requested operation') { $normalized = 'FAIL'; $stage.recommendations.Add('SFC could not run; verify servicing readiness and disk health.') }
    elseif ($sfc.ExitCode -eq 0) { $normalized = 'OK'; $stage.findings.Add('SFC completed with exit code 0 (native console mode).') }
    else { $normalized = 'FAIL' }

    Add-ActionResult -State $State -Stage $stage -Name 'SFC /scannow' -Result $sfc -InterpretedStatus $normalized
    if ($normalized -eq 'OK') { Write-Host '[OK] SFC completed successfully' }
    elseif ($normalized -eq 'WARN') { Write-Host '[WARN] SFC completed but requires attention' -ForegroundColor Yellow }
    else { Write-Host '[FAIL] SFC failed' -ForegroundColor Red }
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
            Add-ActionResult -State $State -Stage $stage -Name 'netsh winsock reset' -Result $winsock -InterpretedStatus ($(if($winsock.ExitCode -eq 0){'OK'}else{'WARN'}))
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
    Add-ActionResult -State $State -Stage $stage -Name 'DISM CheckHealth post' -Result $dism -InterpretedStatus ($(if(-not $dism.ExitCodeCaptured){'WARN'}elseif($dism.ExitCode -eq 0){'OK'}else{'WARN'}))

    $critical = 'TrustedInstaller','wuauserv','bits','cryptsvc' | ForEach-Object {
        $svc = Get-Service -Name $_ -ErrorAction SilentlyContinue
        [pscustomobject]@{ name=$_; status=if($svc){$svc.Status.ToString()}else{'Missing'} }
    }
    $criticalPath = Join-Path $State.ReportPath 'post-services.json'
    $critical | ConvertTo-Json -Depth 4 | Set-Content -Path $criticalPath -Encoding UTF8
    $stage.artifacts.Add($criticalPath)

    $status = if (-not $dism.ExitCodeCaptured) { 'WARN' } elseif ($dism.ExitCode -eq 0) { 'OK' } else { 'WARN' }
    Complete-Stage -State $State -Stage $stage -Status $status -ExitCode 0
    return 0
}

function Run-StageFinalSummary {
    param([pscustomobject]$State)
    $stage = New-Stage 'I' 'Final summary'

    $failed = @($State.Stages | Where-Object { $_.status -eq 'FAIL' }).Count
    $warned = @($State.Stages | Where-Object { $_.status -eq 'WARN' }).Count
    $overallPipelineStatus = if ($failed -gt 0) { 'FAIL' } elseif ($warned -gt 0) { 'WARN' } else { 'OK' }
    $stage.findings.Add("overall_pipeline_status=$overallPipelineStatus; stages_failed=$failed; stages_warn=$warned")

    $rebootRec = $State.Context['pending_reboot']
    if ($rebootRec) { $stage.recommendations.Add('Reboot recommended.') }

    # Stage I reflects summary generation itself (not previous repair health).
    Complete-Stage -State $State -Stage $stage -Status 'OK' -ExitCode 0
    return 0
}

function Run-StageDeepRecoveryEnvironment {
    param([pscustomobject]$State)
    $stage = New-Stage 'DR-A' 'Deep environment and servicing preflight'

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $lang = (Get-WinSystemLocale -ErrorAction SilentlyContinue).Name
    $isServer = $false
    if ($os -and $os.ProductType -and [int]$os.ProductType -ne 1) { $isServer = $true }

    $stage.findings.Add("OSFamily=$($(if($isServer){'Server'}else{'Client'})); Build=$($os.BuildNumber); Arch=$($os.OSArchitecture); Edition=$($os.Caption); Language=$lang")
    $stage.findings.Add("PendingReboot=$($State.Context['pending_reboot']); IsElevated=$($State.IsAdmin)")

    $freeGb = 0.0
    try {
        $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
        if ($drive) {
            $freeGb = [math]::Round(($drive.FreeSpace / 1GB), 2)
            $stage.findings.Add("SystemDriveFreeGB=$freeGb")
            $State.Context['deep_system_drive_free_gb'] = $freeGb
            if ($freeGb -lt 5) {
                $stage.recommendations.Add('Critical low disk space on C:. Deep Recovery reliability is reduced.')
            }
        }
    } catch {}

    $online = $true
    try { $null = Resolve-DnsName -Name 'www.microsoft.com' -ErrorAction Stop } catch { $online = $false }
    $stage.findings.Add("Online=$online")
    $State.Context['deep_is_server'] = $isServer
    $State.Context['deep_online'] = $online

    $wuPathAvailable = $false
    try {
        $wuSvc = Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
        $wuPathAvailable = [bool]$wuSvc
    } catch {}
    $State.Context['deep_wu_path_available'] = $wuPathAvailable
    $stage.findings.Add("WindowsUpdatePathAvailable=$wuPathAvailable")

    try {
        $reAgent = & reagentc.exe /info 2>$null
        if ($reAgent -match 'Windows RE status:\s+Enabled') { $stage.findings.Add('WinRE=Enabled') }
        elseif ($reAgent -match 'Windows RE status:\s+Disabled') { $stage.findings.Add('WinRE=Disabled') }
    } catch {}

    Complete-Stage -State $State -Stage $stage -Status 'OK' -ExitCode 0
    return 0
}

function Run-StageDeepRecoverySafeguard {
    param([pscustomobject]$State)
    $stage = New-Stage 'DR-B' 'Deep safeguard (restore point / system state backup)'
    $isServer = [bool]$State.Context['deep_is_server']

    $State.Context['deep_safeguard_type'] = 'none'
    $State.Context['deep_safeguard_status'] = 'unavailable'
    $State.Context['deep_safeguard_reason'] = 'unknown'

    function Test-SystemRestorePolicyDisabled {
        try {
            $paths = @(
                'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore',
                'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
            )
            foreach ($p in $paths) {
                if (-not (Test-Path $p)) { continue }
                $v = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue
                if ($v -and (($v.DisableSR -eq 1) -or ($v.DisableConfig -eq 1))) { return $true }
            }
        } catch {}
        return $false
    }

    function Test-IsManagedOrVDI {
        try {
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
            if ($cs -and $cs.PartOfDomain) { return $true }
        } catch {}
        try {
            $model = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Model
            if ($model -match 'Virtual|VMware|KVM|Hyper-V|VDI|Citrix') { return $true }
        } catch {}
        return $false
    }

    function Test-VssEcosystemHealthy {
        try {
            $vss = Get-Service -Name 'VSS' -ErrorAction SilentlyContinue
            $swprv = Get-Service -Name 'swprv' -ErrorAction SilentlyContinue
            if (-not $vss -or -not $swprv) { return $false }
            return $true
        } catch { return $false }
    }

    if ($isServer) {
        $wbadmin = Get-Command wbadmin.exe -ErrorAction SilentlyContinue
        if ($wbadmin) {
            $stage.findings.Add('Server OS detected: wbadmin workflow available for system-state backup.')
            $stage.recommendations.Add('Run supported wbadmin system state backup before continuing.')
            $State.Context['deep_safeguard_available'] = $true
            $State.Context['deep_safeguard_type'] = 'systemStateBackup'
            $State.Context['deep_safeguard_status'] = 'available'
            $State.Context['deep_safeguard_reason'] = 'wbadmin_detected'
            Complete-Stage -State $State -Stage $stage -Status 'WARN' -ExitCode 0
            return 0
        }

        $stage.findings.Add('Server OS detected: no wbadmin backup target/workflow confirmed.')
        $State.Context['deep_safeguard_available'] = $false
        $State.Context['deep_safeguard_type'] = 'systemStateBackup'
        $State.Context['deep_safeguard_status'] = 'unavailable'
        $State.Context['deep_safeguard_reason'] = 'no_wbadmin_or_target'
    } else {
        $sysDrive = $env:SystemDrive
        $restoreAvailable = [bool](Get-Command Enable-ComputerRestore -ErrorAction SilentlyContinue)
        $policyDisabled = Test-SystemRestorePolicyDisabled
        $managedOrVdi = Test-IsManagedOrVDI
        $vssHealthy = Test-VssEcosystemHealthy
        $freeGb = 0.0
        try { $freeGb = [double]$State.Context['deep_system_drive_free_gb'] } catch { $freeGb = 0.0 }

        $State.Context['deep_safeguard_type'] = 'restorePoint'
        $stage.findings.Add("RestorePolicyDisabled=$policyDisabled; ManagedOrVDI=$managedOrVdi; VSSHealthy=$vssHealthy")

        if ($policyDisabled) {
            $stage.findings.Add('System Restore is disabled by policy. Toolkit will not override policy settings.')
            $State.Context['deep_safeguard_available'] = $false
            $State.Context['deep_safeguard_status'] = 'policy_disabled'
            $State.Context['deep_safeguard_reason'] = 'policy_disabled'
        } elseif ($managedOrVdi) {
            $stage.findings.Add('Managed/VDI-like environment detected. Automatic System Restore enablement is skipped by design.')
            $State.Context['deep_safeguard_available'] = $false
            $State.Context['deep_safeguard_status'] = 'managed_or_vdi'
            $State.Context['deep_safeguard_reason'] = 'managed_or_vdi'
        } elseif ($freeGb -gt 0 -and $freeGb -lt 5) {
            $stage.findings.Add('Insufficient free disk space for safe restore-point provisioning.')
            $State.Context['deep_safeguard_available'] = $false
            $State.Context['deep_safeguard_status'] = 'insufficient_disk_space'
            $State.Context['deep_safeguard_reason'] = 'insufficient_disk_space'
        } elseif (-not $vssHealthy) {
            $stage.findings.Add('VSS ecosystem appears unhealthy (VSS/swprv service dependency issue).')
            $State.Context['deep_safeguard_available'] = $false
            $State.Context['deep_safeguard_status'] = 'vss_dependency_problem'
            $State.Context['deep_safeguard_reason'] = 'vss_dependency_problem'
        } elseif ($restoreAvailable) {
            try {
                Enable-ComputerRestore -Drive $sysDrive -ErrorAction SilentlyContinue
            } catch {}

            # Conservative storage configuration: only system drive, minimal footprint.
            try {
                $quotaMb = 4096
                & vssadmin resize shadowstorage /for=$sysDrive /on=$sysDrive /maxsize=${quotaMb}MB 1>$null 2>$null
                $stage.findings.Add("Applied conservative shadow storage target on $sysDrive (~${quotaMb}MB).")
            } catch {}

            try {
                Checkpoint-Computer -Description 'WindowsFixToolkit_DeepRecovery' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop | Out-Null
                $stage.findings.Add('Client safeguard: restore point created.')
                $State.Context['deep_safeguard_available'] = $true
                $State.Context['deep_safeguard_status'] = 'created'
                $State.Context['deep_safeguard_reason'] = 'restore_point_created'
                Complete-Stage -State $State -Stage $stage -Status 'OK' -ExitCode 0
                return 0
            } catch {
                $stage.findings.Add("Restore point could not be created: $($_.Exception.Message)")
                $State.Context['deep_safeguard_available'] = $false
                $State.Context['deep_safeguard_status'] = 'failed_to_create'
                $State.Context['deep_safeguard_reason'] = 'restore_point_create_failed'
            }
        } else {
            $stage.findings.Add('System Restore cmdlets unavailable or unsupported on this system.')
            $State.Context['deep_safeguard_available'] = $false
            $State.Context['deep_safeguard_status'] = 'unsupported'
            $State.Context['deep_safeguard_reason'] = 'cmdlets_unavailable'
        }
    }

    $stage.recommendations.Add('Rollback safeguard was not created; risk is higher.')
    if (-not $State.DeepRecoveryAllowNoSafeguard) {
        $stage.recommendations.Add('Continue only with explicit deep acknowledgement flag: -DeepRecoveryAllowNoSafeguard')
        Complete-Stage -State $State -Stage $stage -Status 'FAIL' -ExitCode 1
        return 1
    }

    Complete-Stage -State $State -Stage $stage -Status 'WARN' -ExitCode 0
    return 0
}

function Run-StageDeepRecoverySourceValidation {
    param([pscustomobject]$State)
    $stage = New-Stage 'DR-C' 'Official source validation'

    $source = [string]$State.RecoverySourcePath
    if (-not $source) {
        $State.Context['deep_source_valid'] = $false
        $stage.findings.Add('No recovery source path provided; fallback to Microsoft-supported online servicing path if available.')
        $stage.recommendations.Add('Provide -RecoverySourcePath (mounted ISO/WIM/ESD) for deterministic Deep Recovery.')
        Complete-Stage -State $State -Stage $stage -Status 'WARN' -ExitCode 0
        return 0
    }

    $resolved = [System.IO.Path]::GetFullPath($source)
    if (-not (Test-Path $resolved)) {
        $State.Context['deep_source_valid'] = $false
        $stage.findings.Add("Recovery source not found: $resolved")
        Complete-Stage -State $State -Stage $stage -Status 'FAIL' -ExitCode 1
        return 1
    }

    $ext = [System.IO.Path]::GetExtension($resolved).ToLowerInvariant()
    if ($ext -eq '.swm') {
        $State.Context['deep_source_valid'] = $false
        $stage.findings.Add('Split image (install.swm) detected; unsupported in current automated flow.')
        $stage.recommendations.Add('Provide install.wim/install.esd or mount official ISO and retry.')
        Complete-Stage -State $State -Stage $stage -Status 'FAIL' -ExitCode 1
        return 1
    }

    $stage.findings.Add("Recovery source validated path=$resolved")
    $State.Context['deep_validated_source'] = $resolved
    $State.Context['deep_source_valid'] = $true
    Complete-Stage -State $State -Stage $stage -Status 'OK' -ExitCode 0
    return 0
}

function Run-StageDeepRecoveryExecution {
    param([pscustomobject]$State)
    $stage = New-Stage 'DR-D' 'Official source-assisted DISM + SFC'

    $args = @('/Online','/Cleanup-Image','/RestoreHealth')
    if ($State.Context['deep_validated_source']) {
        $args += @('/Source:' + [string]$State.Context['deep_validated_source'], '/LimitAccess')
    }

    $dism = Invoke-ExternalCommand -FilePath 'dism.exe' -ArgumentList $args -TimeoutSec 7200 -HeartbeatSec 20 -State $State -IgnoreExitCode
    Add-ActionResult -State $State -Stage $stage -Name 'DISM RestoreHealth (official source)' -Result $dism -InterpretedStatus ($(if($dism.ExitCodeCaptured -and $dism.ExitCode -eq 0){'OK'}elseif(-not $dism.ExitCodeCaptured){'WARN'}else{'FAIL'}))

    $sfc = Invoke-ExternalCommand -FilePath 'sfc.exe' -ArgumentList @('/scannow') -TimeoutSec 7200 -HeartbeatSec 20 -State $State -IgnoreExitCode
    Add-ActionResult -State $State -Stage $stage -Name 'SFC /scannow post-DISM' -Result $sfc -InterpretedStatus ($(if($sfc.ExitCodeCaptured -and $sfc.ExitCode -eq 0){'OK'}elseif(-not $sfc.ExitCodeCaptured){'WARN'}else{'FAIL'}))

    $hasFail = @($stage.actions | Where-Object { $_.status -eq 'FAIL' }).Count -gt 0
    $hasWarn = @($stage.actions | Where-Object { $_.status -eq 'WARN' }).Count -gt 0
    $status = if ($hasFail) { 'FAIL' } elseif ($hasWarn) { 'WARN' } else { 'OK' }
    Complete-Stage -State $State -Stage $stage -Status $status -ExitCode ($(if($hasFail){1}else{0}))
    return ($(if($hasFail){1}else{0}))
}

function Run-StageDeepRecoveryEscalation {
    param([pscustomobject]$State)
    $stage = New-Stage 'DR-E' 'Supported escalation path decision'
    $stage.findings.Add('If corruption remains on supported Windows 11, use official path: Settings > Recovery > Fix problems using Windows Update > Reinstall now.')
    $stage.findings.Add('Direct manual transplantation into System32/WinSxS/Servicing is unsupported/high-risk expert-only fallback.')
    Complete-Stage -State $State -Stage $stage -Status 'WARN' -ExitCode 0
    return 0
}

function Get-RootCauseSummary {
    param([pscustomobject]$State)
    $events = @($State.Context['normalized_events'])
    if ($events.Count -eq 0) {
        return [pscustomobject]@{ rootCause='No strong signature matched'; affectedStage='unknown'; systemState='unknown'; confidence='low'; recommendedFix='Review toolkit.log and report.md' }
    }
    $chosen = $events | Where-Object { $_.category -eq 'internal' -and $_.severity -in @('fatal','error') } | Select-Object -First 1
    if (-not $chosen) { $chosen = $events | Where-Object { $_.severity -in @('fatal','error') } | Select-Object -First 1 }
    if (-not $chosen) { $chosen = $events | Select-Object -First 1 }

    $sysState = if ($chosen.category -eq 'internal') { 'unknown, execution reliability impacted' } else { 'degraded' }
    $confidence = if ($chosen.signature -eq 'EXIT_CODE_NOT_CAPTURED') { 'medium' } else { 'high' }
    return [pscustomobject]@{
        rootCause = $chosen.signature
        affectedStage = $chosen.stage
        systemState = $sysState
        confidence = $confidence
        recommendedFix = $chosen.next_action
    }
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
        repairRan = ($State.EffectiveMode -in @('Repair','Full','DeepRecovery') -and -not $State.IsDryRun)
        reportExported = $true
        overallPipelineStatus = $(if(@($State.Stages | Where-Object { $_.status -eq 'FAIL' }).Count -gt 0){'FAIL'}elseif(@($State.Stages | Where-Object { $_.status -eq 'WARN' }).Count -gt 0){'WARN'}else{'OK'})
        logPath   = $State.LogPath
        transcriptPath = $State.TranscriptPath
        stages    = $State.Stages
        steps     = $State.Steps
        normalizedEvents = @($State.Context['normalized_events'])
        policyDecisions = @($State.Context['policy_decisions'])
        rootCauseSummary = Get-RootCauseSummary -State $State
        safeguard = [pscustomobject]@{
            available = [bool]$State.Context['deep_safeguard_available']
            type = [string]$State.Context['deep_safeguard_type']
            status = [string]$State.Context['deep_safeguard_status']
            reason = [string]$State.Context['deep_safeguard_reason']
        }
        sourceValidationPassed = [bool]$State.Context['deep_source_valid']
        safeToReboot = -not [bool]$State.Context['pending_reboot']
        finalConfidence = (Get-RootCauseSummary -State $State).confidence
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
        "- OverallPipelineStatus: $($payload.overallPipelineStatus)",
        '',
        '## Stages'
    )
    foreach ($st in $State.Stages) {
        $lines += "- **[$($st.stage_id)] $($st.stage_name)**: $($st.status) (exit=$($st.exit_code), $($st.duration_ms)ms)"
        foreach ($f in $st.findings) { $lines += "  - $f" }
        foreach ($r in $st.recommendations) { $lines += "  - Recommendation: $r" }
        foreach ($a in $st.artifacts) { $lines += "  - Artifact: $a" }
    }

    if ($payload.normalizedEvents.Count -gt 0) {
        $lines += ''
        $lines += '## Normalized events (sample)'
        foreach ($ev in ($payload.normalizedEvents | Select-Object -First 20)) {
            $lines += "- [$($ev.stage)] $($ev.tool) $($ev.severity) $($ev.signature): $($ev.hint)"
        }
    }

    $lines += ''
    $lines += '## Post-run diagnosis summary'
    $lines += "- Root cause: $($payload.rootCauseSummary.rootCause)"
    $lines += "- Affected stage: $($payload.rootCauseSummary.affectedStage)"
    $lines += "- System state: $($payload.rootCauseSummary.systemState)"
    $lines += "- Confidence: $($payload.rootCauseSummary.confidence)"
    $lines += "- Recommended fix: $($payload.rootCauseSummary.recommendedFix)"
    $lines += "- Safeguard: available=$($payload.safeguard.available), type=$($payload.safeguard.type), status=$($payload.safeguard.status), reason=$($payload.safeguard.reason)"
    $lines += "- Source validation passed: $($payload.sourceValidationPassed)"
    $lines += "- Safe to reboot: $($payload.safeToReboot)"
    $lines += "- Final confidence: $($payload.finalConfidence)"

    if ($payload.policyDecisions.Count -gt 0) {
        $lines += ''
        $lines += '## Policy decisions (sample)'
        foreach ($pd in ($payload.policyDecisions | Select-Object -First 20)) {
            $lines += "- [$($pd.stage)] $($pd.decision): $($pd.reason)"
        }
    }

    Set-Content -Path $mdPath -Value $lines -Encoding UTF8
    return [pscustomobject]@{ Json=$jsonPath; Markdown=$mdPath }
}

function Invoke-WindowsFix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Diagnose','Repair','Full','DryRun','DeepRecovery')]
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
        [string]$SubsystemProfile = 'None',
        [ValidateSet('Quick','Normal','Deep')]
        [string]$RepairProfile = 'Normal',
        [ValidateSet('Quick','Normal','Deep')]
        [string]$DiagnoseProfile = 'Normal',
        [switch]$UiVerbose,
        [int]$KeepOutputRuns = 5,
        [string]$RecoverySourcePath,
        [switch]$DeepRecoveryAllowNoSafeguard
    )

    $state = New-ToolkitState -Mode $Mode -ReportPath $ReportPath -LogPath $LogPath -TranscriptPath $TranscriptPath -NoNetwork:$NoNetwork -AssumeYes:$AssumeYes -Force:$Force -SubsystemProfile $SubsystemProfile -RepairProfile $RepairProfile -DiagnoseProfile $DiagnoseProfile -UiVerbose:$UiVerbose -KeepOutputRuns $KeepOutputRuns -RecoverySourcePath $RecoverySourcePath -DeepRecoveryAllowNoSafeguard:$DeepRecoveryAllowNoSafeguard
    Write-ToolkitLog -State $state -Message "Mode=$Mode, EffectiveMode=$($state.EffectiveMode), IsAdmin=$($state.IsAdmin), ReportPath=$ReportPath"
    Cleanup-OldOutputFolders -State $state

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

            if ($state.EffectiveMode -eq 'DeepRecovery') {
                if ((Invoke-DeepRecoveryScaffold -State $state) -ne 0) { $exitCode = 1 }
            } elseif ($state.EffectiveMode -in @('Repair','Full')) {
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
