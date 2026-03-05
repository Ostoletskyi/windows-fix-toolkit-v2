#==============================================================================
# src/internal/state.ps1
# State management for Windows Fix Toolkit
# Compatible with Windows PowerShell 5.1+ and PowerShell 7+
#==============================================================================

Set-StrictMode -Version Latest

# Global state object (script scope)
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
}

function Initialize-State {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('SelfTest','Diagnose','Repair','Full','DryRun')]
        [string]$Mode,

        [string]$CustomReportPath
    )

    $script:State.Mode = $Mode
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $runId = "WindowsFix_{0}_{1}" -f $timestamp, $Mode

    # Default output base: repo/Outputs
    $outputBase = Join-Path -Path $PSScriptRoot -ChildPath "..\..\Outputs"
    $outputBase = [System.IO.Path]::GetFullPath($outputBase)

    # If user specified a custom report path, treat it as the output directory
    if ($CustomReportPath) {
        $outDir = $CustomReportPath
    } else {
        $outDir = Join-Path -Path $outputBase -ChildPath $runId
    }

    try {
        New-Item -Path $outDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    } catch {
        # Fallback to temp if repo location is not writable
        $outDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath $runId
        New-Item -Path $outDir -ItemType Directory -Force | Out-Null
    }

    $script:State.OutputDir = $outDir

    # Separated files (CRITICAL FIX)
    $script:State.LogPath        = Join-Path -Path $outDir -ChildPath "toolkit.log"
    $script:State.TranscriptPath = Join-Path -Path $outDir -ChildPath "transcript.log"

    # Optional reports
    $script:State.ReportJsonPath = Join-Path -Path $outDir -ChildPath "report.json"
    $script:State.ReportMdPath   = Join-Path -Path $outDir -ChildPath "report.md"
}

function Get-State {
    [CmdletBinding()]
    param()
    return $script:State
}

Export-ModuleMember -Function Initialize-State, Get-State -Variable State
