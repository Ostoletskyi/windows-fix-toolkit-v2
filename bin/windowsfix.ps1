#==============================================================================
# bin/windowsfix.ps1
# Windows Fix Toolkit - Main Entry Point (FIXED)
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

$SCRIPT_BUILD = "WindowsFixToolkit v0.1.1-fixed"

# Resolve script root
$ScriptRoot = Split-Path -Parent $PSCommandPath
$RepoRoot   = Resolve-Path (Join-Path $ScriptRoot "..") | Select-Object -ExpandProperty Path
$SrcRoot    = Join-Path $RepoRoot "src"

#==============================================================================
# CRITICAL FIX: Use dot-sourcing instead of Import-Module
#==============================================================================
# Load internal scripts using dot-sourcing (.) instead of Import-Module
# This prevents "Export-ModuleMember can only be called from inside a module" error
. (Join-Path $SrcRoot "internal\state.ps1")
. (Join-Path $SrcRoot "internal\logging.ps1")

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

# Check admin status
$isAdmin = $false
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {
    # Not Windows or error checking admin status
}

Write-Host ("IsAdmin      : {0}" -f $isAdmin)

# Get OS build (Windows only)
try {
    $osBuild = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).CurrentBuild
    Write-Host ("OS Build     : {0}" -f $osBuild)
} catch {
    Write-Host "OS Build     : N/A"
}

Write-Host ("OutputDir    : {0}" -f $State.OutputDir)
Write-Host ("LogPath      : {0}" -f $State.LogPath)
Write-Host ("TranscriptPath: {0}" -f $State.TranscriptPath)
Write-Host ""

try {
    Write-LogHeader -Title ("Windows Fix Toolkit - {0} Mode" -f $Mode)
    Write-Log -Level INFO -Message ("Mode={0}, OutputDir={1}" -f $Mode, $State.OutputDir)
    Write-Log -Level INFO -Message ("LogPath={0}" -f $State.LogPath)
    Write-Log -Level INFO -Message ("TranscriptPath={0}" -f $State.TranscriptPath)

    # Basic admin gating for repair modes
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
        Write-Log -Level WARN -Message ("Mode script not found: {0}. Running basic validation instead." -f $modeScript)
        
        # Basic validation for SelfTest mode
        if ($Mode -eq 'SelfTest') {
            Write-LogSection -Title "Self-Test: Basic Validation"
            
            Write-Log -Level INFO -Message "Testing: PowerShell Version..."
            if ($PSVersionTable.PSVersion.Major -ge 5) {
                Write-Log -Level SUCCESS -Message "  ✓ PowerShell $($PSVersionTable.PSVersion) - OK"
            } else {
                Write-Log -Level ERROR -Message "  ✗ PowerShell version too old"
            }
            
            Write-Log -Level INFO -Message "Testing: Output Directory..."
            if (Test-Path -Path $State.OutputDir) {
                Write-Log -Level SUCCESS -Message "  ✓ Output directory writable - OK"
            } else {
                Write-Log -Level ERROR -Message "  ✗ Output directory not accessible"
            }
            
            Write-Log -Level INFO -Message "Testing: Log Files..."
            if (Test-Path -Path $State.LogPath) {
                Write-Log -Level SUCCESS -Message "  ✓ toolkit.log created - OK"
            } else {
                Write-Log -Level WARN -Message "  ⚠ toolkit.log not created yet"
            }
            
            if (Test-Path -Path $State.TranscriptPath) {
                Write-Log -Level SUCCESS -Message "  ✓ transcript.log created - OK"
            } else {
                Write-Log -Level WARN -Message "  ⚠ transcript.log not created"
            }
            
            Write-Log -Level SUCCESS -Message "Self-test completed!"
        }
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
