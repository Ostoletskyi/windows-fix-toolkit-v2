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

'OK: smoke tests passed'
