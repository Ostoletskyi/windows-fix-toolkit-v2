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

    $uiVerbose = $false
    if ($State.PSObject.Properties.Name -contains 'UiVerbose') {
        $uiVerbose = [bool]$State.UiVerbose
    }

    $printToConsole = $true
    if ($Level -eq 'DEBUG') { $printToConsole = $uiVerbose }
    elseif ($Level -eq 'INFO') {
        if (-not $uiVerbose) { $printToConsole = $false }
        if ($Message -like '[HEARTBEAT]*' -or $Message -like '>> *') { $printToConsole = $false }
    }

    if ($printToConsole) {
        switch ($Level) {
            'ERROR' { Write-Host $line -ForegroundColor Red }
            'WARN'  { Write-Host $line -ForegroundColor Yellow }
            'DEBUG' { Write-Verbose $line }
            default { Write-Host $line }
        }
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


function Write-StructuredLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [ValidateSet('INFO','WARN','ERROR','DEBUG','METRICS')]
        [string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Properties = @{}
    )

    $entry = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        level = $Level
        message = $Message
        stage = if ($State.Stages.Count -gt 0) { $State.Stages[$State.Stages.Count-1].stage_id } else { 'none' }
        thread_id = [Threading.Thread]::CurrentThread.ManagedThreadId
    }

    foreach ($key in $Properties.Keys) {
        $entry[$key] = $Properties[$key]
    }

    $json = $entry | ConvertTo-Json -Compress
    Write-ToolkitLog -State $State -Level $Level -Message $json
}
