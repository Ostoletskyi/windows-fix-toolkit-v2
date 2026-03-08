function New-DeepRecoverySafeguardResultTemplate {
    [pscustomobject]@{
        available = $false
        status = 'NOT_ATTEMPTED'
        type = 'none'
        reason = 'scaffold'
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
        recommendations = @('Step 1 scaffold: implementation deferred to next step')
        artifacts = @()
        error = $null
    }
}

function New-DeepRecoveryFinalReportTemplate {
    [pscustomobject]@{
        feature = 'Deep Recovery (Official Microsoft Source)'
        scaffoldStep = 1
        phases = @()
        safeguardResult = New-DeepRecoverySafeguardResultTemplate
        sourceValidationResult = New-DeepRecoverySourceValidationResultTemplate
        overallStatus = 'PLANNED'
        confidence = 'low'
        nextStep = 'Step 2: preflight+safeguard implementation'
    }
}
