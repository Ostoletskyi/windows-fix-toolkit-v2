[CmdletBinding()]
param(
    [ValidateSet('Diagnose','Repair','Full','DryRun')]
    [string]$Mode = 'Diagnose',
    [string]$ReportPath,
    [string]$LogPath,
    [string]$TranscriptPath,
    [switch]$NoNetwork,
    [switch]$AssumeYes,
    [switch]$Force,
    [ValidateSet('None','Update','Network','All')]
    [string]$SubsystemProfile = 'None',
    [ValidateSet('Quick','Normal','Deep')]
    [string]$RepairProfile = 'Normal',
    [ValidateSet('Quick','Normal','Deep')]
    [string]$DiagnoseProfile = 'Normal'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
$modulePath = Join-Path $repoRoot 'src\WindowsFixToolkit.psm1'

if (-not (Test-Path $modulePath)) {
    Write-Error "Toolkit module not found: $modulePath"
    exit 10
}

$ts = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
if (-not $ReportPath) { $ReportPath = Join-Path $repoRoot "Outputs\WindowsFix_$ts" }
New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null
if (-not $LogPath) { $LogPath = Join-Path $ReportPath 'toolkit.log' }
if (-not $TranscriptPath) { $TranscriptPath = Join-Path $ReportPath 'transcript.log' }

Import-Module $modulePath -Force

$meta = @(
    "SCRIPT_BUILD    : WindowsFixToolkit-PS v2.0.0",
    "ScriptPath      : $($MyInvocation.MyCommand.Path)",
    "PWD             : $(Get-Location)",
    "PSVersion       : $($PSVersionTable.PSVersion)",
    "Mode            : $Mode",
    "ReportPath      : $ReportPath",
    "ToolkitLogPath  : $LogPath",
    "TranscriptPath  : $TranscriptPath"
)
$meta | Tee-Object -FilePath $TranscriptPath -Append

$exitCode = Invoke-WindowsFix -Mode $Mode -ReportPath $ReportPath -LogPath $LogPath -TranscriptPath $TranscriptPath -NoNetwork:$NoNetwork -AssumeYes:$AssumeYes -Force:$Force -SubsystemProfile $SubsystemProfile -RepairProfile $RepairProfile -DiagnoseProfile $DiagnoseProfile
"ExitCode=$exitCode" | Tee-Object -FilePath $TranscriptPath -Append | Out-Null
exit $exitCode
