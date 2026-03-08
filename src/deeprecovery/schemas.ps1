function New-DeepRecoveryPreflightResultTemplate {
    [pscustomobject]@{
        classification = 'unknown'
        isElevated = $false
        os = [pscustomobject]@{
            family = 'Unknown'
            edition = 'Unknown'
            architecture = 'Unknown'
            build = 'Unknown'
            version = 'Unknown'
            uiLanguage = 'unknown'
        }
        pendingReboot = $false
        internetConnectivity = $false
        systemDriveFreeGb = 0.0
        winREStatus = 'Unknown'
        isLaptop = $false
        onACPower = $null
        warnings = @()
        blockingIssues = @()
    }
}

function New-DeepRecoverySafeguardResultTemplate {
    [pscustomobject]@{
        osFamily = 'Unknown'
        available = $false
        attempted = $false
        status = 'NOT_ATTEMPTED'
        classification = 'unknown'
        type = 'none'
        reason = 'not_evaluated'
        capabilities = [pscustomobject]@{
            systemDrive = 'C:'
            systemRestoreCmdletsAvailable = $false
            alreadyEnabledOnSystemDrive = $false
            policyDisabled = $false
            wbadminAvailable = $false
            backupTargetDetected = $false
        }
        details = @()
    }
}

function New-DeepRecoverySourceValidationResultTemplate {
    [pscustomobject]@{
        sourceProvided = $false
        sourceType = 'unknown'
        isValid = $false
        matchConfidence = 'unknown'
        reason = 'scaffold'
        details = @()
    }
}

function New-DeepRecoveryStageResultTemplate {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [string]$Status = 'PLANNED',
        [string]$Summary = 'Scaffold phase placeholder'
    )

    [pscustomobject]@{
        phase = $Phase
        status = $Status
        summary = $Summary
        startedAt = (Get-Date)
        endedAt = (Get-Date)
        decisions = @()
        findings = @()
        recommendations = @()
        artifacts = @()
        error = $null
    }
}

function New-DeepRecoveryFinalReportTemplate {
    [pscustomobject]@{
        feature = 'Deep Recovery (Official Microsoft Source)'
        step = 2
        phases = @()
        preflightResult = New-DeepRecoveryPreflightResultTemplate
        safeguardCheckResult = New-DeepRecoverySafeguardResultTemplate
        safeguardResult = New-DeepRecoverySafeguardResultTemplate
        sourceValidationResult = New-DeepRecoverySourceValidationResultTemplate
        overallStatus = 'PLANNED'
        requiresStrongAck = $false
        confidence = 'low'
        nextStep = 'Step 3: source discovery/validation and repair execution'
    }
}
