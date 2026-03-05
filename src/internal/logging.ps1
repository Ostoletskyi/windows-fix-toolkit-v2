#==============================================================================
<<<<<<< Updated upstream
# src/internal/logging.ps1
# Robust logging (toolkit.log) with lock protection; NEVER writes to transcript.log
# Compatible with Windows PowerShell 5.1+ and PowerShell 7+
#==============================================================================

Set-StrictMode -Version Latest

=======
# Logging Module - Enhanced with Lock Protection
#==============================================================================

<#
.SYNOPSIS
    Robust logging with file lock protection and retry mechanism
.DESCRIPTION
    - Uses toolkit.log for application events (not transcript.log)
    - Implements retry with exponential backoff
    - Falls back to console if file write fails
#>

#------------------------------------------------------------------------------
# Internal Helper: Safe File Append
#------------------------------------------------------------------------------
>>>>>>> Stashed changes
function Write-LogFileSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
<<<<<<< Updated upstream

        [Parameter(Mandatory)]
        [string]$Content,

        [int]$MaxRetries = 3,
        [int]$RetryDelayMs = 75
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            [System.IO.File]::AppendAllText($Path, $Content, $utf8NoBom)
            return $true
        }
        catch [System.IO.IOException] {
            if ($attempt -lt $MaxRetries) {
                Start-Sleep -Milliseconds ($RetryDelayMs * $attempt)
                continue
            }
            Write-Warning ("[LOGGING] Cannot write to log file (locked): {0}. Continuing without file logging for this line." -f $Path)
            return $false
        }
        catch {
            Write-Warning ("[LOGGING] Unexpected error writing to log file {0}: {1}" -f $Path, $_.Exception.Message)
            return $false
        }
    }

    return $false
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('INFO','WARN','ERROR','DEBUG','SUCCESS','TRACE')]
        [string]$Level,

        [Parameter(Mandatory, Position = 1)]
        [string]$Message,

        [switch]$NoConsole,
        [switch]$NoFile
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[{0}] [{1}] {2}" -f $timestamp, $Level, $Message

    if (-not $NoFile) {
        try {
            if ($script:State -and $script:State.LogPath) {
                $dir = Split-Path -Parent $script:State.LogPath
                if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                    New-Item -Path $dir -ItemType Directory -Force | Out-Null
                }
                if (-not (Test-Path -LiteralPath $script:State.LogPath -PathType Leaf)) {
                    New-Item -Path $script:State.LogPath -ItemType File -Force | Out-Null
                }
                [void](Write-LogFileSafe -Path $script:State.LogPath -Content ($line + "`r`n"))
            }
        } catch {
            Write-Warning ("[LOGGING] File logging suppressed due to error: {0}" -f $_.Exception.Message)
        }
    }

    if (-not $NoConsole) {
        $color = switch ($Level) {
            'INFO'    { 'Cyan' }
            'WARN'    { 'Yellow' }
            'ERROR'   { 'Red' }
            'DEBUG'   { 'Gray' }
            'SUCCESS' { 'Green' }
            'TRACE'   { 'DarkGray' }
            default   { 'White' }
        }
        Write-Host $line -ForegroundColor $color
    }
}

=======
        
        [Parameter(Mandatory)]
        [string]$Content,
        
        [int]$MaxRetries = 3,
        [int]$RetryDelayMs = 50
    )
    
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            # Use .NET method for more reliable file access
            $utf8NoBom = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::AppendAllText($Path, $Content, $utf8NoBom)
            return $true
        }
        catch [System.IO.IOException] {
            if ($attempt -lt $MaxRetries) {
                Start-Sleep -Milliseconds ($RetryDelayMs * $attempt)
            }
            else {
                Write-Warning "[LOGGING] Failed to write to $Path after $MaxRetries attempts: $_"
                # Fallback: write to console only
                Write-Host $Content.TrimEnd() -ForegroundColor Yellow
                return $false
            }
        }
        catch {
            Write-Warning "[LOGGING] Unexpected error writing to $Path: $_"
            Write-Host $Content.TrimEnd() -ForegroundColor Yellow
            return $false
        }
    }
}

#------------------------------------------------------------------------------
# Public Function: Write-Log
#------------------------------------------------------------------------------
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG', 'SUCCESS', 'TRACE')]
        [string]$Level,
        
        [Parameter(Mandatory, Position = 1)]
        [string]$Message,
        
        [switch]$NoConsole,
        
        [switch]$NoFile
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    
    # Write to toolkit log file (NOT transcript.log)
    if (-not $NoFile -and $State.LogPath) {
        if (Test-Path -LiteralPath $State.LogPath -PathType Leaf -ErrorAction SilentlyContinue) {
            Write-LogFileSafe -Path $State.LogPath -Content "$line`n"
        }
        else {
            # First write - create file
            try {
                $null = New-Item -Path $State.LogPath -ItemType File -Force -ErrorAction Stop
                Write-LogFileSafe -Path $State.LogPath -Content "$line`n"
            }
            catch {
                Write-Warning "[LOGGING] Cannot create log file: $_"
            }
        }
    }
    
    # Console output
    if (-not $NoConsole) {
        $color = switch ($Level) {
            'INFO'    { 'Cyan' }
            'WARN'    { 'Yellow' }
            'ERROR'   { 'Red' }
            'DEBUG'   { 'Gray' }
            'SUCCESS' { 'Green' }
            'TRACE'   { 'DarkGray' }
            default   { 'White' }
        }
        
        Write-Host $line -ForegroundColor $color
    }
}

#------------------------------------------------------------------------------
# Public Function: Write-LogHeader
#------------------------------------------------------------------------------
>>>>>>> Stashed changes
function Write-LogHeader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title,
<<<<<<< Updated upstream
        [char]$BorderChar = '='
    )

    # CRITICAL FIX: in PowerShell, [char] * [int] is NOT defined; cast to [string] first
    $border = ([string]$BorderChar) * 78
    $centered = " $Title "
    $padding = ($border.Length - $centered.Length) / 2
    $header = (([string]$BorderChar) * [Math]::Floor($padding)) + $centered + (([string]$BorderChar) * [Math]::Ceiling($padding))

=======
        
        [char]$BorderChar = '='
    )
    
    $border = $BorderChar * 78
    $centered = " $Title "
    $padding = ($border.Length - $centered.Length) / 2
    $header = $BorderChar * [Math]::Floor($padding) + $centered + $BorderChar * [Math]::Ceiling($padding)
    
>>>>>>> Stashed changes
    Write-Log -Level INFO -Message $border
    Write-Log -Level INFO -Message $header
    Write-Log -Level INFO -Message $border
}

<<<<<<< Updated upstream
=======
#------------------------------------------------------------------------------
# Public Function: Write-LogSection
#------------------------------------------------------------------------------
>>>>>>> Stashed changes
function Write-LogSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )
<<<<<<< Updated upstream
    Write-Log -Level INFO -Message ""
    Write-Log -Level INFO -Message ("─" * 78)
    Write-Log -Level INFO -Message ("  {0}" -f $Title)
    Write-Log -Level INFO -Message ("─" * 78)
}

function Close-Log {
    [CmdletBinding()]
    param()
    Write-Log -Level INFO -Message "Log session ended."
}

Export-ModuleMember -Function Write-Log, Write-LogHeader, Write-LogSection, Close-Log
=======
    
    Write-Log -Level INFO -Message ""
    Write-Log -Level INFO -Message ("─" * 78)
    Write-Log -Level INFO -Message "  $Title"
    Write-Log -Level INFO -Message ("─" * 78)
}

#------------------------------------------------------------------------------
# Public Function: Close-Log
#------------------------------------------------------------------------------
function Close-Log {
    [CmdletBinding()]
    param()
    
    Write-Log -Level INFO -Message "Log session ended."
}

# Export functions
Export-ModuleMember -Function Write-Log, Write-LogHeader, Write-LogSection, Close-Log
>>>>>>> Stashed changes
