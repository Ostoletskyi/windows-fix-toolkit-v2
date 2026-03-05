#==============================================================================
# bin/windowsfix.ps1
# Windows Fix Toolkit - Main Entry Point (fixpack)
# Compatible: Windows PowerShell 5.1+ and PowerShell 7+
#==============================================================================

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('SelfTest','Diagnose','Repair','Full','DryRun')]
    [string]$Mode,

    [string]$ReportPath,

    [switch]$NoNetwork,
    [switch]$AssumeYes,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$SCRIPT_BUILD = "WindowsFixToolkit v0.1.0"

# Resolve script root
$ScriptRoot = Split-Path -Parent $PSCommandPath
$RepoRoot   = Resolve-Path (Join-Path $ScriptRoot "..") | Select-Object -ExpandProperty Path
$SrcRoot    = Join-Path $RepoRoot "src"

# Load internal modules
Import-Module (Join-Path $SrcRoot "internal\state.ps1")   -Force
Import-Module (Join-Path $SrcRoot "internal\logging.ps1") -Force

# Make flags available (if other scripts rely on them)
$global:NoNetwork = [bool]$NoNetwork
$global:AssumeYes = [bool]$AssumeYes
$global:Force     = [bool]$Force

# Initialize state (creates OutputDir and separated log paths)
Initialize-State -Mode $Mode -CustomReportPath $ReportPath

# Expose state to callers (some code may reference $State directly)
$global:State = $script:State

# Transcript management (writes ONLY to TranscriptPath)
$transcriptStarted = $false
try {
    Start-Transcript -Path $State.TranscriptPath -Force -ErrorAction Stop | Out-Null
    $transcriptStarted = $true
} catch {
    Write-Warning ("Could not start transcript: {0}" -f $_.Exception.Message)
}

# Print basic runtime header
Write-Host ""
Write-Host ("SCRIPT_BUILD : {0}" -f $SCRIPT_BUILD)
Write-Host ("ScriptPath   : {0}" -f $PSCommandPath)
Write-Host ("PWD          : {0}" -f (Get-Location))
Write-Host ("PSVersion    : {0}" -f $PSVersionTable.PSVersion)
Write-Host ("IsAdmin      : {0}" -f ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
Write-Host ("OS Build     : {0}" -f (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).CurrentBuild)
Write-Host ("ReportPath   : {0}" -f $State.OutputDir)
Write-Host ("LogPath      : {0}" -f $State.LogPath)

try {
    Write-LogHeader -Title ("Windows Fix Toolkit - {0} Mode" -f $Mode)
    Write-Log -Level INFO -Message ("Mode={0}, ReportPath={1}" -f $Mode, $State.OutputDir)

    # Basic admin gating for repair modes
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (($Mode -in @('Repair','Full')) -and (-not $isAdmin)) {
        Write-Log -Level ERROR -Message "Repair/Full requires Administrator. Re-run PowerShell as Administrator."
        exit 2
    }

    # Minimal mode routing (placeholder) – your existing mode scripts may exist; call if present.
    $modeScript = Join-Path $SrcRoot ("modes\{0}.ps1" -f $Mode.ToLowerInvariant())
    if (Test-Path -LiteralPath $modeScript) {
        Write-LogSection -Title ("Executing mode script: {0}" -f (Split-Path $modeScript -Leaf))
        & $modeScript
    } else {
        Write-Log -Level WARN -Message ("Mode script not found: {0}. Nothing to do yet." -f $modeScript)
    }

    Write-Log -Level SUCCESS -Message "Execution completed."
    Write-Log -Level INFO -Message ("Results saved to: {0}" -f $State.OutputDir)
    exit 0
}
catch {
    try {
        Write-Log -Level ERROR -Message ("Fatal error: {0}" -f $_.Exception.Message)
        Write-Log -Level ERROR -Message ("Stack: {0}" -f $_.ScriptStackTrace)
    } catch {
        Write-Warning ("Fatal error (logging failed): {0}" -f $_.Exception.Message)
    }
    exit 1
}
finally {
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
    try { Close-Log } catch {}
}
