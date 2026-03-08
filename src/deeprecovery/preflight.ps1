function Invoke-DeepRecoveryPreflightPhase {
    param([pscustomobject]$State)

    $phase = New-DeepRecoveryStageResultTemplate -Phase 'PREFLIGHT' -Status 'OK' -Summary 'Deep Recovery preflight completed'
    $result = New-DeepRecoveryPreflightResultTemplate

    $result.isElevated = [bool]$State.IsAdmin
    if (-not $result.isElevated) {
        $result.blockingIssues += 'NOT_ELEVATED'
        $phase.recommendations += 'Deep Recovery requires elevation.'
    }

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) {
        $result.os.edition = [string]$os.Caption
        $result.os.architecture = [string]$os.OSArchitecture
        $result.os.build = [string]$os.BuildNumber
        $result.os.version = [string]$os.Version
        $result.os.family = if ([int]$os.ProductType -eq 1) { 'Client' } else { 'Server' }
    }

    try {
        $result.os.uiLanguage = [string](Get-WinSystemLocale -ErrorAction SilentlyContinue).Name
    } catch {
        $result.os.uiLanguage = 'unknown'
    }

    $pending = $false
    $pendingKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($k in $pendingKeys) {
        if (Test-Path $k) { $pending = $true; break }
    }
    $result.pendingReboot = $pending
    $State.Context['pending_reboot'] = $pending
    if ($pending) {
        $result.warnings += 'PENDING_REBOOT'
        $phase.recommendations += 'Reboot is recommended before Deep Recovery.'
    }

    $result.internetConnectivity = $false
    try {
        $null = Resolve-DnsName -Name 'www.microsoft.com' -ErrorAction Stop
        $result.internetConnectivity = $true
    } catch {
        try {
            $ping = Test-Connection -ComputerName 'www.microsoft.com' -Count 1 -Quiet -ErrorAction SilentlyContinue
            $result.internetConnectivity = [bool]$ping
        } catch {}
    }
    if (-not $result.internetConnectivity) {
        $result.warnings += 'OFFLINE_MODE'
        $phase.recommendations += 'Online Microsoft-supported recovery options may be unavailable.'
    }

    try {
        $drv = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
        if ($drv) {
            $result.systemDriveFreeGb = [math]::Round(($drv.FreeSpace / 1GB), 2)
            if ($result.systemDriveFreeGb -lt 2) {
                $result.blockingIssues += 'LOW_DISK_CRITICAL'
            } elseif ($result.systemDriveFreeGb -lt 8) {
                $result.warnings += 'LOW_DISK_WARN'
            }
        }
    } catch {}

    try {
        $reInfo = & reagentc.exe /info 2>$null
        if ($reInfo -match 'Windows RE status:\s+Enabled') { $result.winREStatus = 'Enabled' }
        elseif ($reInfo -match 'Windows RE status:\s+Disabled') { $result.winREStatus = 'Disabled' }
    } catch {
        $result.winREStatus = 'Unknown'
    }

    try {
        $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($battery) {
            $result.isLaptop = $true
            $acCodes = @(2,6,7,8,9,11)
            $result.onACPower = ($acCodes -contains [int]$battery.BatteryStatus)
            if (-not $result.onACPower) {
                $result.warnings += 'LAPTOP_NOT_ON_AC'
                $phase.recommendations += 'Connect laptop to AC power before long servicing operations.'
            }
        }
    } catch {}

    $phase.findings += "OSFamily=$($result.os.family); Build=$($result.os.build); Arch=$($result.os.architecture); Lang=$($result.os.uiLanguage)"
    $phase.findings += "Elevated=$($result.isElevated); PendingReboot=$($result.pendingReboot); Online=$($result.internetConnectivity); FreeGB=$($result.systemDriveFreeGb); WinRE=$($result.winREStatus)"

    if ($result.blockingIssues.Count -gt 0) {
        $phase.status = 'FAIL'
        $phase.summary = 'Deep Recovery preflight has blocking conditions'
    } elseif ($result.warnings.Count -gt 0) {
        $phase.status = 'WARN'
        $phase.summary = 'Deep Recovery preflight completed with warnings'
    }

    $result.classification = if ($result.blockingIssues.Count -gt 0) { 'blocking' } elseif ($result.warnings.Count -gt 0) { 'warning' } else { 'ok' }
    $State.Context['deepRecovery']['preflightResult'] = $result

    return $phase
}
