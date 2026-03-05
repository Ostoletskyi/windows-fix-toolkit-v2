[CmdletBinding()]
param(
    [ValidateSet('Diagnose','Repair','Full','SelfTest','DryRun')]
    [string]$Mode = 'Diagnose',
    [string]$ReportPath,
    [string]$LogPath,
    [switch]$NoNetwork,
    [switch]$AssumeYes,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SCRIPT_BUILD = 'WindowsFixToolkit v0.1.1'
$scriptPath = $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptPath)

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
if (-not $ReportPath) {
    $ReportPath = Join-Path $repoRoot ("Outputs/WindowsFix_{0}" -f $timestamp)
}
New-Item -Path $ReportPath -ItemType Directory -Force | Out-Null

$transcriptPath = Join-Path $ReportPath 'transcript.log'
if (-not $LogPath) {
    $LogPath = Join-Path $ReportPath 'toolkit.log'
}

$resolvedTranscriptPath = [System.IO.Path]::GetFullPath($transcriptPath)
if ($LogPath) {
    $resolvedLogPath = [System.IO.Path]::GetFullPath($LogPath)
    if ($resolvedLogPath.Equals($resolvedTranscriptPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $fallbackLogPath = Join-Path $ReportPath 'toolkit.log'
        Write-Host "[WARN] Requested LogPath points to transcript.log. Switching toolkit log to: $fallbackLogPath" -ForegroundColor Yellow
        $LogPath = $fallbackLogPath
    }
}

$modulePath = Join-Path $repoRoot 'src/WindowsFixToolkit.psm1'
Import-Module $modulePath -Force

$isAdmin = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    $isAdmin = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {}

$osBuild = try { (Get-CimInstance Win32_OperatingSystem).BuildNumber } catch { 'unknown' }
Write-Host "SCRIPT_BUILD    : $SCRIPT_BUILD"
Write-Host "ScriptPath      : $scriptPath"
Write-Host "PWD             : $(Get-Location)"
Write-Host "PSVersion       : $($PSVersionTable.PSVersion)"
Write-Host "IsAdmin         : $isAdmin"
Write-Host "OS Build        : $osBuild"
Write-Host "ReportPath      : $ReportPath"
Write-Host "ToolkitLogPath  : $LogPath"
Write-Host "TranscriptPath  : $transcriptPath"

$transcriptStarted = $false
try {
    Start-Transcript -Path $transcriptPath -Force | Out-Null
    $transcriptStarted = $true
} catch {
    Write-Host "[WARN] Failed to start transcript at $transcriptPath: $($_.Exception.Message)" -ForegroundColor Yellow
}

try {
    $exitCode = Invoke-WindowsFix -Mode $Mode -ReportPath $ReportPath -LogPath $LogPath -TranscriptPath $transcriptPath -NoNetwork:$NoNetwork -AssumeYes:$AssumeYes -Force:$Force
    exit $exitCode
} finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}
