function Get-DeepRecoveryOsContext {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if (-not $os) { return $null }

    return [pscustomobject]@{
        architecture = [string]$os.OSArchitecture
        edition = [string]$os.Caption
        build = [string]$os.BuildNumber
        version = [string]$os.Version
        language = try { [string](Get-WinSystemLocale -ErrorAction SilentlyContinue).Name } catch { 'unknown' }
    }
}

function Parse-DismWimInfo {
    param([string]$WimPath)

    $info = [pscustomobject]@{ raw=''; index=''; name=''; architecture=''; version=''; language=''; usable=$false }
    try {
        $res = Invoke-ExternalCommand -FilePath 'dism.exe' -ArgumentList @('/Get-WimInfo',('/WimFile:' + $WimPath),'/index:1') -TimeoutSec 900 -HeartbeatSec 15 -IgnoreExitCode -ForceCaptured
        $text = ($res.StdOut + "`n" + $res.StdErr)
        $info.raw = $text
        if ($text -match 'Name\s*:\s*(.+)') { $info.name = $Matches[1].Trim() }
        if ($text -match 'Architecture\s*:\s*(.+)') { $info.architecture = $Matches[1].Trim() }
        if ($text -match 'Version\s*:\s*([0-9\.]+)') { $info.version = $Matches[1].Trim() }
        if ($text -match 'Default\s*:\s*([a-zA-Z\-]+)') { $info.language = $Matches[1].Trim() }
        $info.usable = ($res.ExitCodeCaptured -and $res.ExitCode -eq 0)
    } catch {}
    return $info
}

function Invoke-DeepRecoverySourceValidationPhase {
    param([pscustomobject]$State)

    $phase = New-DeepRecoveryStageResultTemplate -Phase 'SOURCE_VALIDATION' -Status 'OK' -Summary 'Source validation completed'
    $result = New-DeepRecoverySourceValidationResultTemplate

    $discovery = $State.Context['deepRecovery']['sourceDiscoveryResult']
    $selected = $null
    if ($discovery -and $discovery.selected) { $selected = $discovery.selected }

    if (-not $selected) {
        $phase.status = 'WARN'
        $phase.summary = 'No source selected; online servicing only path will be used if available.'
        $result.reason = 'no_source_selected'
        $result.validation = 'partial match'
        $State.Context['deepRecovery']['sourceValidationResult'] = $result
        return $phase
    }

    $path = [string]$selected.path
    $result.sourceProvided = $true
    $result.path = $path
    $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant().Trim('.')
    $result.sourceType = $ext

    if (-not (Test-Path $path)) {
        $phase.status = 'FAIL'
        $phase.summary = 'Selected source path is not accessible.'
        $result.reason = 'source_missing'
        $result.validation = 'corrupted/unusable'
        $State.Context['deepRecovery']['sourceValidationResult'] = $result
        return $phase
    }

    if ($ext -eq 'swm') {
        $phase.status = 'FAIL'
        $phase.summary = 'Split image (install.swm) is unsupported in automated flow.'
        $result.reason = 'split_image_unsupported'
        $result.validation = 'unsupported'
        $State.Context['deepRecovery']['sourceValidationResult'] = $result
        return $phase
    }

    $osCtx = Get-DeepRecoveryOsContext
    $result.osContext = $osCtx

    if ($ext -in @('wim','esd')) {
        $wimInfo = Parse-DismWimInfo -WimPath $path
        $result.imageInfo = $wimInfo

        if (-not $wimInfo.usable) {
            $phase.status = 'FAIL'
            $phase.summary = 'Source image could not be read by DISM.'
            $result.reason = 'image_unusable'
            $result.validation = 'corrupted/unusable'
            $State.Context['deepRecovery']['sourceValidationResult'] = $result
            return $phase
        }

        $archMatch = $true
        $buildMatch = $true
        $langMatch = $true

        if ($osCtx -and $osCtx.architecture -and $wimInfo.architecture) {
            $archMatch = ($wimInfo.architecture -match 'x64|amd64' -and $osCtx.architecture -match '64') -or
                         ($wimInfo.architecture -match 'x86' -and $osCtx.architecture -match '32') -or
                         ($wimInfo.architecture -eq $osCtx.architecture)
        }
        if ($osCtx -and $osCtx.version -and $wimInfo.version) {
            $buildMatch = ($wimInfo.version.Split('.')[0..1] -join '.') -eq ($osCtx.version.Split('.')[0..1] -join '.')
        }
        if ($osCtx -and $osCtx.language -and $wimInfo.language) {
            $langMatch = ($osCtx.language.ToLowerInvariant().StartsWith($wimInfo.language.ToLowerInvariant()) -or
                          $wimInfo.language.ToLowerInvariant().StartsWith($osCtx.language.ToLowerInvariant()))
        }

        $score = @(@($archMatch,$buildMatch,$langMatch) | Where-Object { $_ }).Count
        if ($score -eq 3) {
            $result.isValid = $true
            $result.matchConfidence = 'high'
            $result.validation = 'valid'
            $result.reason = 'arch_build_language_match'
        } elseif ($score -ge 1) {
            $result.isValid = $true
            $result.matchConfidence = 'medium'
            $result.validation = 'partial match'
            $result.reason = 'partial_metadata_match'
            $phase.status = 'WARN'
            $phase.recommendations += 'Source partially matches OS metadata; proceed conservatively.'
        } else {
            $result.isValid = $false
            $result.matchConfidence = 'low'
            $result.validation = 'mismatch'
            $result.reason = 'metadata_mismatch'
            $phase.status = 'FAIL'
            $phase.recommendations += 'Use source media matching architecture/build/language.'
        }
    } else {
        $result.isValid = $false
        $result.matchConfidence = 'low'
        $result.validation = 'unsupported'
        $result.reason = 'unsupported_source_type'
        $phase.status = 'FAIL'
        $phase.summary = 'Unsupported source type for automated validation.'
    }

    $State.Context['deepRecovery']['sourceValidationResult'] = $result
    $State.Context['deep_validated_source'] = if ($result.isValid) { $path } else { $null }
    $State.Context['deep_source_valid'] = [bool]$result.isValid

    $phase.findings += "SourceType=$($result.sourceType); Validation=$($result.validation); MatchConfidence=$($result.matchConfidence)"
    return $phase
}
