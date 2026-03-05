function Write-ToolkitLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')]
        [string]$Level = 'INFO',
        [Parameter(Mandatory)]
        [pscustomobject]$State
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp][$Level] $Message"

    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'DEBUG' { Write-Verbose $line }
        default { Write-Host $line }
    }

    $targetLog = $State.LogPath
    if (-not $targetLog) { return }

    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            [System.IO.File]::AppendAllText($targetLog, $line + "`r`n", [System.Text.Encoding]::UTF8)
            return
        } catch {
            $msg = $_.Exception.Message
            $isLock = $msg -match 'used by another process' -or $msg -match 'being used by another process'
            if ($isLock -and $attempt -lt $maxAttempts) {
                Start-Sleep -Milliseconds 100
                continue
            }

            Write-Host "[WARN] Failed to write toolkit log after $attempt attempt(s): $targetLog. $msg" -ForegroundColor Yellow
            return
        }
    }
}
# src/internal/logging.ps1
# Robust logging (toolkit.log) with lock protection; NEVER writes to transcript.log
# Compatible with Windows PowerShell 5.1+ and PowerShell 7+
#==============================================================================

Set-StrictMode -Version Latest

function Write-LogFileSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

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

function Write-LogHeader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title,
        [char]$BorderChar = '='
    )

    # CRITICAL FIX: in PowerShell, [char] * [int] is NOT defined; cast to [string] first
    $border = ([string]$BorderChar) * 78
    $centered = " $Title "
    $padding = ($border.Length - $centered.Length) / 2
    $header = (([string]$BorderChar) * [Math]::Floor($padding)) + $centered + (([string]$BorderChar) * [Math]::Ceiling($padding))

    Write-Log -Level INFO -Message $border
    Write-Log -Level INFO -Message $header
    Write-Log -Level INFO -Message $border
}

function Write-LogSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )
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
