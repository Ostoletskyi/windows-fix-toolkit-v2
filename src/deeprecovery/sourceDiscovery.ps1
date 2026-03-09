function Invoke-DeepRecoverySourceDiscoveryPhase {
    param([pscustomobject]$State)

    $phase = New-DeepRecoveryStageResultTemplate -Phase 'SOURCE_DISCOVERY' -Status 'OK' -Summary 'Source discovery completed'
    $result = New-DeepRecoverySourceDiscoveryResultTemplate

    $candidates = New-Object System.Collections.Generic.List[object]

    if ($State.RecoverySourcePath) {
        $p = [string]$State.RecoverySourcePath
        $candidates.Add([pscustomobject]@{ path=$p; origin='user_provided'; sourceType='unknown'; exists=(Test-Path $p); confidence='high' })
    }

    $known = @(
        'C:\sources\install.wim',
        'C:\sources\install.esd',
        'C:\Windows\Sources\install.wim',
        'C:\Windows\Sources\install.esd'
    )
    foreach ($k in $known) {
        if (Test-Path $k) {
            $ext = [System.IO.Path]::GetExtension($k).ToLowerInvariant().Trim('.')
            $candidates.Add([pscustomobject]@{ path=$k; origin='local_known_path'; sourceType=$ext; exists=$true; confidence='medium' })
        }
    }

    try {
        $fsDrives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
        foreach ($d in $fsDrives) {
            if (-not $d.Root) { continue }
            $probe = Join-Path $d.Root 'sources'
            foreach ($file in @('install.wim','install.esd','install.swm')) {
                $candidate = Join-Path $probe $file
                if (Test-Path $candidate) {
                    $ext = [System.IO.Path]::GetExtension($candidate).ToLowerInvariant().Trim('.')
                    $candidates.Add([pscustomobject]@{ path=$candidate; origin='mounted_media'; sourceType=$ext; exists=$true; confidence='medium' })
                }
            }
        }
    } catch {}

    # placeholder hook for future official download provider (not implemented in Step 3)
    $result.downloadHook = [pscustomobject]@{ supported = $false; reason = 'step3_placeholder_only' }

    $unique = @{}
    foreach ($c in $candidates) {
        $key = ([string]$c.path).ToLowerInvariant()
        if (-not $unique.ContainsKey($key)) { $unique[$key] = $c }
    }

    $ordered = @($unique.Values | Sort-Object @{Expression={ if($_.origin -eq 'user_provided'){0}elseif($_.origin -eq 'mounted_media'){1}else{2} }}, @{Expression='path'})
    $result.candidates = @($ordered)

    if ($ordered.Count -eq 0) {
        $phase.status = 'WARN'
        $phase.summary = 'No local official source candidates discovered.'
        $phase.recommendations += 'Provide -RecoverySourcePath or mount official installation media.'
    } else {
        $selected = $ordered[0]
        $result.selected = $selected
        $phase.findings += "SelectedSource=$($selected.path); Origin=$($selected.origin); Type=$($selected.sourceType)"
    }

    $State.Context['deepRecovery']['sourceDiscoveryResult'] = $result
    return $phase
}
