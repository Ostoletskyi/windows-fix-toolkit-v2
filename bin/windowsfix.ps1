[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

Write-Host "[INFO] PowerShell entrypoint is deprecated. Redirecting to bash runtime..."
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$bashEntry = Join-Path $scriptDir 'windowsfix.sh'

if (-not (Test-Path $bashEntry)) {
    Write-Error "Bash entrypoint not found: $bashEntry"
    exit 3
}

$bash = Get-Command bash -ErrorAction SilentlyContinue
if (-not $bash) {
    Write-Error "bash is required for the unified runtime but was not found in PATH."
    exit 3
}

& bash $bashEntry @Args
exit $LASTEXITCODE
