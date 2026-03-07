function Invoke-DismCheckHealthStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State
    )

    if ($State.DryRun) {
        return [pscustomobject]@{ Status='SKIPPED'; Details='DryRun: dism.exe /Online /Cleanup-Image /CheckHealth'; ExitCode=0; DurationMs=0 }
    }

    $result = Invoke-ExternalCommand -FilePath 'dism.exe' -ArgumentList @('/Online','/Cleanup-Image','/CheckHealth') -TimeoutSec 1800 -State $State
    return [pscustomobject]@{ Status=($(if($result.Success){'OK'}else{'FAIL'})); Details=$result.StdOut; ExitCode=$result.ExitCode; DurationMs=$result.DurationMs }
}
