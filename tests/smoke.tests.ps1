$modulePath = Join-Path $PSScriptRoot '..\src\WindowsFixToolkit.psm1'
Import-Module $modulePath -Force

$expected = @(
    'Invoke-WindowsFix',
    'New-ToolkitState',
    'Invoke-ExternalCommand',
    'Export-ToolkitReport',
    'Wait-ServiceState',
    'ConvertTo-CommandLine'
)

foreach ($name in $expected) {
    if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) {
        throw "Missing exported function: $name"
    }
}

$work = Join-Path $PSScriptRoot ('..\Outputs\PS_Smoke_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

$rc = Invoke-WindowsFix -Mode DryRun -ReportPath $work -LogPath (Join-Path $work 'toolkit.log') -TranscriptPath (Join-Path $work 'transcript.log') -AssumeYes
if ($rc -notin 0,1) {
    throw "Unexpected DryRun exit code: $rc"
}

$reportMd = Join-Path $work 'report.md'
if (-not (Test-Path $reportMd)) { throw 'Missing report.md' }
if (-not (Select-String -Path $reportMd -Pattern 'PLANNED' -Quiet)) {
    throw 'DryRun report does not contain PLANNED'
}

'OK: smoke tests passed'
