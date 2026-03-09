[CmdletBinding()]
param(
    [ValidateSet('Diagnose','Repair','Full','DryRun','DeepRecovery')]
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
    [string]$DiagnoseProfile = 'Normal',
    [switch]$UiVerbose,
    [string]$RecoverySourcePath,
    [switch]$DeepRecoveryAllowNoSafeguard
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$pathsHelper = Join-Path $scriptDir '..\src\internal\paths.ps1'
if (-not (Test-Path -LiteralPath $pathsHelper)) {
    Write-Error "Toolkit path helper not found: $pathsHelper"
    exit 10
}

. $pathsHelper

try {
    $repoRoot = Get-ToolkitRoot -StartPath $scriptDir
} catch {
    Write-Error $_.Exception.Message
    exit 10
}

$layout = Test-ToolkitLayout -ToolkitRoot $repoRoot
if (-not $layout.IsValid) {
    Write-Error ("Toolkit layout is invalid. Missing: {0}" -f (($layout.Missing | ForEach-Object { [string]$_ }) -join ', '))
    exit 10
}

$modulePath = Get-ToolkitPath -Root $repoRoot -RelativePath 'src\WindowsFixToolkit.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Error "Toolkit module not found: $modulePath"
    exit 10
}

$ReportPath = New-ToolkitRuntimePath -ToolkitRoot $repoRoot -ReportPath $ReportPath -Prefix 'WindowsFix'
if (-not $LogPath) { $LogPath = Join-Path $ReportPath 'toolkit.log' }
if (-not $TranscriptPath) { $TranscriptPath = Join-Path $ReportPath 'transcript.log' }

Import-Module $modulePath -Force

$meta = @(
    "SCRIPT_BUILD    : WindowsFixToolkit-PS v2.0.0",
    "Mode            : $Mode",
    "ToolkitRoot     : $repoRoot",
    "ReportPath      : $ReportPath",
    "ToolkitLogPath  : $LogPath"
)
$meta | Tee-Object -FilePath $TranscriptPath -Append | Out-Null
Write-Host "[START] $Mode | profile: diag=$DiagnoseProfile repair=$RepairProfile"
Write-Host "[REPORT] $ReportPath"

$exitCode = Invoke-WindowsFix -Mode $Mode -ReportPath $ReportPath -LogPath $LogPath -TranscriptPath $TranscriptPath -NoNetwork:$NoNetwork -AssumeYes:$AssumeYes -Force:$Force -SubsystemProfile $SubsystemProfile -RepairProfile $RepairProfile -DiagnoseProfile $DiagnoseProfile -UiVerbose:$UiVerbose -RecoverySourcePath $RecoverySourcePath -DeepRecoveryAllowNoSafeguard:$DeepRecoveryAllowNoSafeguard
"ExitCode=$exitCode" | Tee-Object -FilePath $TranscriptPath -Append | Out-Null
exit $exitCode
