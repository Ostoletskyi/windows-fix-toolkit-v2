#==============================================================================
# src/internal/state.ps1
# State management for Windows Fix Toolkit
# Compatible with Windows PowerShell 5.1+ and PowerShell 7+
#==============================================================================
Set-StrictMode -Version Latest

#------------------------------------------------------------------------------
# Global State Object
#------------------------------------------------------------------------------
$script:State = [ordered]@{
    Mode           = $null
    StartTime      = Get-Date
    OutputDir      = $null
    # Separated log targets:
    LogPath        = $null          # toolkit.log (our logger)
    TranscriptPath = $null          # transcript.log (Start-Transcript)
    # Report paths (optional):
    ReportJsonPath = $null
    ReportMdPath   = $null
    ErrorCount     = 0
    WarningCount   = 0
}

#------------------------------------------------------------------------------
# Initialize-State Function
#------------------------------------------------------------------------------
function Initialize-State {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('SelfTest','Diagnose','Repair','Full','DryRun')]
        [string]$Mode,
        
        [string]$CustomReportPath
    )
    
    $script:State.Mode = $Mode
    $script:State.StartTime = Get-Date
    
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $runId = "WindowsFix_{0}_{1}" -f $timestamp, $Mode
    
    # Default output base: repo/Outputs
    $outputBase = Join-Path -Path $PSScriptRoot -ChildPath "..\..\Outputs"
    
    # Normalize path
    try {
        $outputBase = [System.IO.Path]::GetFullPath($outputBase)
    }
    catch {
        Write-Warning "Cannot resolve output base path: $_"
    }
    
    # Determine output directory
    if ($CustomReportPath) {
        if (Test-Path -Path $CustomReportPath -PathType Container -ErrorAction SilentlyContinue) {
            $outDir = $CustomReportPath
        }
        else {
            # Custom path is a file, use its directory
            $outDir = Split-Path -Path $CustomReportPath -Parent
            if (-not $outDir) {
                $outDir = Join-Path -Path $outputBase -ChildPath $runId
            }
        }
    }
    else {
        $outDir = Join-Path -Path $outputBase -ChildPath $runId
    }
    
    # Create output directory with fallback
    try {
        if (-not (Test-Path -Path $outDir)) {
            $null = New-Item -Path $outDir -ItemType Directory -Force -ErrorAction Stop
        }
        
        # Test write permissions
        $testFile = Join-Path -Path $outDir -ChildPath ".writetest"
        [System.IO.File]::WriteAllText($testFile, "test")
        Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Warning "Cannot write to $outDir : $_"
        # Fallback to temp
        $outDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath $runId
        try {
            $null = New-Item -Path $outDir -ItemType Directory -Force -ErrorAction Stop
        }
        catch {
            throw "Failed to create output directory even in temp: $_"
        }
    }
    
    $script:State.OutputDir = $outDir
    
    # Separated files (CRITICAL FIX)
    $script:State.LogPath        = Join-Path -Path $outDir -ChildPath "toolkit.log"
    $script:State.TranscriptPath = Join-Path -Path $outDir -ChildPath "transcript.log"
    
    # Optional reports
    $script:State.ReportJsonPath = Join-Path -Path $outDir -ChildPath "report.json"
    $script:State.ReportMdPath   = Join-Path -Path $outDir -ChildPath "report.md"
    
    # Initialize counters
    $script:State.ErrorCount = 0
    $script:State.WarningCount = 0
}

#------------------------------------------------------------------------------
# Get-State Function
#------------------------------------------------------------------------------
function Get-State {
    [CmdletBinding()]
    param()
    
    return $script:State
}

# This script is loaded via dot-sourcing, not Import-Module
# Do NOT use Export-ModuleMember here
