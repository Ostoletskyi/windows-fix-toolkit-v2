function Get-ToolkitRoot {
    [CmdletBinding()]
    param(
        [string]$StartPath
    )

    $start = $StartPath
    if (-not $start) {
        if ($PSScriptRoot) {
            $start = $PSScriptRoot
        } elseif ($PSCommandPath) {
            $start = Split-Path -Parent $PSCommandPath
        } else {
            $start = (Get-Location).Path
        }
    }

    $current = [System.IO.Path]::GetFullPath($start)
    while ($true) {
        $binPath = Join-Path $current 'bin/windowsfix.ps1'
        $srcPath = Join-Path $current 'src/WindowsFixToolkit.psm1'
        if ((Test-Path -LiteralPath $binPath) -and (Test-Path -LiteralPath $srcPath)) {
            return $current
        }

        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) {
            break
        }
        $current = $parent
    }

    throw "Toolkit root could not be resolved from: $start"
}

function Get-ToolkitPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath
    )

    return (Join-Path $Root $RelativePath)
}

function New-ToolkitRuntimePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolkitRoot,
        [string]$ReportPath,
        [string]$Prefix = 'WindowsFix'
    )

    if ($ReportPath -and $ReportPath.Trim()) {
        $resolved = [System.IO.Path]::GetFullPath($ReportPath)
        New-Item -ItemType Directory -Path $resolved -Force | Out-Null
        return $resolved
    }

    $outputsRoot = Join-Path $ToolkitRoot 'Outputs'
    New-Item -ItemType Directory -Path $outputsRoot -Force | Out-Null
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $path = Join-Path $outputsRoot ("{0}_{1}" -f $Prefix, $ts)
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Test-ToolkitLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolkitRoot
    )

    $required = @(
        'bin/windowsfix.ps1',
        'src/WindowsFixToolkit.psm1',
        'src/internal'
    )

    $missing = @()
    foreach ($rel in $required) {
        $full = Join-Path $ToolkitRoot $rel
        if (-not (Test-Path -LiteralPath $full)) {
            $missing += $rel
        }
    }

    return [pscustomobject]@{
        IsValid = ($missing.Count -eq 0)
        Missing = @($missing)
    }
}
