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

function New-DeepRecoverySourceDiscoveryResultTemplate {
    [pscustomobject]@{
        selected = $null
        candidates = @()
        downloadHook = [pscustomobject]@{ supported=$false; reason='not_set' }
    }
}

function New-DeepRecoverySourceValidationResultTemplate {
    [pscustomobject]@{
        sourceProvided = $false
        path = ''
        sourceType = 'unknown'
        isValid = $false
        matchConfidence = 'unknown'
        validation = 'unknown'
        reason = 'not_evaluated'
        osContext = $null
        imageInfo = $null
        details = @()
    }
}

function New-DeepRecoveryRepairResultTemplate {
    [pscustomobject]@{
        tool = 'unknown'
        command = ''
        exitCode = $null
        exitCodeCaptured = $false
        stdoutPath = $null
        stderrPath = $null
        usedValidatedLocalSource = $false
        classification = 'unknown'
        outcome = 'inconclusive'
        reason = 'not_run'
    }
}

function New-DeepRecoveryPostcheckResultTemplate {
    [pscustomobject]@{
        dismCheck = $null
        sfcVerify = $null
        signals = @()
        classification = 'inconclusive'
        outcome = 'inconclusive'
        rebootRecommended = $false
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
        step = 3
        phases = @()
        preflightResult = New-DeepRecoveryPreflightResultTemplate
        safeguardCheckResult = New-DeepRecoverySafeguardResultTemplate
        safeguardResult = New-DeepRecoverySafeguardResultTemplate
        sourceDiscoveryResult = New-DeepRecoverySourceDiscoveryResultTemplate
        sourceValidationResult = New-DeepRecoverySourceValidationResultTemplate
        dismResult = New-DeepRecoveryRepairResultTemplate
        sfcResult = New-DeepRecoveryRepairResultTemplate
        postcheckResult = New-DeepRecoveryPostcheckResultTemplate
        overallStatus = 'PLANNED'
        requiresStrongAck = $false
        confidence = 'medium'
        nextStep = 'Step 4: escalation and reinstall-path policy implementation'
    }
}
