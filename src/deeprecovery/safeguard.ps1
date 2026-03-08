function Invoke-DeepRecoverySafeguardCheckPhase {
    param([pscustomobject]$State)

    $phase = New-DeepRecoveryStageResultTemplate -Phase 'SAFEGUARD_CHECK' -Status 'OK' -Summary 'Safeguard readiness check completed'
    $result = New-DeepRecoverySafeguardResultTemplate

    $pre = $State.Context['deepRecovery']['preflightResult']
    $osFamily = if ($pre -and $pre.os -and $pre.os.family) { [string]$pre.os.family } else { 'Unknown' }
    $result.osFamily = $osFamily

    if ($osFamily -eq 'Server') {
        $result.type = 'systemStateBackup'
        $wb = Get-Command wbadmin.exe -ErrorAction SilentlyContinue
        $result.capabilities.wbadminAvailable = [bool]$wb
        if ($result.capabilities.wbadminAvailable) {
            $targetDetected = $false
            try {
                $out = & wbadmin.exe get disks 2>&1
                $text = ($out | Out-String)
                if ($text -match 'Disk name|Wbadmin|Identifier') { $targetDetected = $true }
            } catch {}
            $result.capabilities.backupTargetDetected = $targetDetected
            if ($targetDetected) {
                $result.classification = 'safeguard already available'
                $result.available = $true
                $result.status = 'AVAILABLE'
                $phase.summary = 'Server safeguard readiness available (wbadmin + candidate target).'
            } else {
                $result.classification = 'safeguard unavailable but continuable'
                $result.available = $false
                $result.status = 'UNAVAILABLE_CONTINUABLE'
                $phase.status = 'WARN'
                $phase.recommendations += 'No clear wbadmin backup target detected. Stronger acknowledgement will be required later.'
            }
        } else {
            $result.classification = 'safeguard unsupported'
            $result.available = $false
            $result.status = 'UNSUPPORTED'
            $phase.status = 'WARN'
            $phase.recommendations += 'wbadmin is unavailable; server rollback safeguard cannot be prepared automatically.'
        }
    } else {
        $result.type = 'restorePoint'
        $systemDrive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
        $result.capabilities.systemDrive = $systemDrive

        $policyDisabled = $false
        try {
            $paths = @(
                'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore',
                'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
            )
            foreach ($p in $paths) {
                if (-not (Test-Path $p)) { continue }
                $v = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue
                if ($v -and (($v.DisableSR -eq 1) -or ($v.DisableConfig -eq 1))) { $policyDisabled = $true; break }
            }
        } catch {}
        $result.capabilities.policyDisabled = $policyDisabled

        $result.capabilities.systemRestoreCmdletsAvailable = [bool](Get-Command Enable-ComputerRestore -ErrorAction SilentlyContinue)
        $enabled = $false
        try {
            $ss = (& vssadmin list shadowstorage 2>$null | Out-String)
            if ($ss -match [regex]::Escape($systemDrive)) { $enabled = $true }
        } catch {}
        $result.capabilities.alreadyEnabledOnSystemDrive = $enabled

        if ($policyDisabled) {
            $result.classification = 'safeguard blocked by policy'
            $result.available = $false
            $result.status = 'BLOCKED_BY_POLICY'
            $phase.status = 'WARN'
            $phase.recommendations += 'System Restore is policy-disabled; do not override policy automatically.'
        } elseif (-not $result.capabilities.systemRestoreCmdletsAvailable) {
            $result.classification = 'safeguard unsupported'
            $result.available = $false
            $result.status = 'UNSUPPORTED'
            $phase.status = 'WARN'
            $phase.recommendations += 'System Restore cmdlets unavailable; safeguard cannot be prepared automatically.'
        } elseif ($enabled) {
            $result.classification = 'safeguard already available'
            $result.available = $true
            $result.status = 'AVAILABLE'
            $phase.summary = 'Client safeguard already available on system drive.'
        } else {
            $result.classification = 'safeguard unavailable but continuable'
            $result.available = $false
            $result.status = 'UNAVAILABLE_CONTINUABLE'
            $phase.status = 'WARN'
            $phase.recommendations += 'System Restore not yet enabled on system drive.'
        }
    }

    $State.Context['deepRecovery']['safeguardCheckResult'] = $result
    $phase.findings += "SafeguardType=$($result.type); Classification=$($result.classification); Status=$($result.status)"
    return $phase
}

function Invoke-DeepRecoverySafeguardAttemptPhase {
    param([pscustomobject]$State)

    $phase = New-DeepRecoveryStageResultTemplate -Phase 'SAFEGUARD_ATTEMPT' -Status 'OK' -Summary 'Safeguard attempt phase completed'
    $check = $State.Context['deepRecovery']['safeguardCheckResult']
    if (-not $check) {
        $phase.status = 'WARN'
        $phase.summary = 'Safeguard attempt skipped because check result is missing'
        return $phase
    }

    $result = $check
    $result.attempted = $false

    if ($check.status -in @('AVAILABLE','BLOCKED_BY_POLICY','UNSUPPORTED')) {
        if ($check.status -eq 'AVAILABLE') {
            $phase.summary = 'Safeguard already available; no attempt needed.'
        } elseif ($check.status -eq 'BLOCKED_BY_POLICY') {
            $phase.status = 'WARN'
            $phase.summary = 'Safeguard blocked by policy; explicit higher-risk acknowledgement required later.'
            $State.Context['deepRecovery']['requiresStrongAck'] = $true
        } else {
            $phase.status = 'WARN'
            $phase.summary = 'Safeguard unsupported on this system; explicit higher-risk acknowledgement required later.'
            $State.Context['deepRecovery']['requiresStrongAck'] = $true
        }
        $State.Context['deepRecovery']['safeguardResult'] = $result
        $State.Context['deep_safeguard_available'] = [bool]$result.available
        $State.Context['deep_safeguard_type'] = [string]$result.type
        $State.Context['deep_safeguard_status'] = [string]$result.status
        $State.Context['deep_safeguard_reason'] = [string]$result.classification
        return $phase
    }

    $result.attempted = $true
    if ($check.type -eq 'restorePoint') {
        $sysDrive = $check.capabilities.systemDrive
        try {
            Enable-ComputerRestore -Drive $sysDrive -ErrorAction SilentlyContinue
        } catch {
            $result.details += "Enable-ComputerRestore failed: $($_.Exception.Message)"
        }

        try {
            & vssadmin resize shadowstorage /for=$sysDrive /on=$sysDrive /maxsize=3% 1>$null 2>$null
            $result.details += 'Applied conservative shadowstorage maxsize=3% on system drive.'
        } catch {
            $result.details += "Shadowstorage resize failed: $($_.Exception.Message)"
        }

        try {
            Checkpoint-Computer -Description 'WindowsFixToolkit_DeepRecovery' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop | Out-Null
            $result.available = $true
            $result.status = 'CREATED'
            $result.classification = 'safeguard successfully created'
            $phase.summary = 'Restore point safeguard created successfully.'
        } catch {
            $result.available = $false
            $result.status = 'FAILED'
            $result.classification = 'safeguard failed'
            $result.reason = $_.Exception.Message
            $result.details += "Checkpoint-Computer failed: $($_.Exception.Message)"
            $phase.status = 'WARN'
            $phase.summary = 'Restore point safeguard attempt failed; higher-risk acknowledgement required later.'
            $phase.recommendations += 'Rollback safeguard not created; continue only with stronger explicit acknowledgement in next phases.'
            $State.Context['deepRecovery']['requiresStrongAck'] = $true
        }
    } elseif ($check.type -eq 'systemStateBackup') {
        # Step 2 scope: readiness check only, no automatic backup execution.
        $result.available = [bool]$check.capabilities.backupTargetDetected
        if ($result.available) {
            $result.status = 'AVAILABLE'
            $result.classification = 'safeguard already available'
            $phase.summary = 'Server system-state backup readiness is available.'
        } else {
            $result.status = 'UNAVAILABLE_CONTINUABLE'
            $result.classification = 'safeguard unavailable but continuable'
            $phase.status = 'WARN'
            $phase.summary = 'No validated backup target detected for wbadmin readiness.'
            $phase.recommendations += 'Rollback safeguard not created; continue only with stronger explicit acknowledgement in next phases.'
            $State.Context['deepRecovery']['requiresStrongAck'] = $true
        }
    }

    $State.Context['deepRecovery']['safeguardResult'] = $result
    $State.Context['deep_safeguard_available'] = [bool]$result.available
    $State.Context['deep_safeguard_type'] = [string]$result.type
    $State.Context['deep_safeguard_status'] = [string]$result.status
    $State.Context['deep_safeguard_reason'] = [string]$result.classification

    $phase.findings += "SafeguardAttemptClassification=$($result.classification); Status=$($result.status); Available=$($result.available)"
    return $phase
}
