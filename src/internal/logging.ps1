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
