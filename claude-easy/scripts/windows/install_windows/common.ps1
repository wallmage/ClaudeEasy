function Write-Info([string]$Message) {
    if ($Json) {
        [void]$script:ClaudeEasyMessages.Add((Protect-ClaudeEasyResultText $Message))
        return
    }
    Write-Host "[ClaudeEasy] $Message"
}

function Complete-InstallResult(
    [int]$ExitCode,
    [string]$Status,
    [string]$Code,
    [string]$SummaryZh,
    [object[]]$Changes = @(),
    [object[]]$Checks = @(),
    [object[]]$Items = @(),
    [object[]]$Warnings = @()
) {
    if ($Json) {
        $result = New-ClaudeEasyResult -Command "install" -Operation $script:ClaudeEasyOperation -Ok ($ExitCode -eq 0) -Status $Status -Code $Code -ExitCode $ExitCode -SummaryZh $SummaryZh -Profile $script:ClaudeEasyProfile -Changes $Changes -Checks $Checks -Items $Items -Messages @($script:ClaudeEasyMessages) -Warnings $Warnings
        Write-ClaudeEasyResult $result
    }
    exit $ExitCode
}

function Get-SavedUsageProfile([string]$Path) {
    $snapshot = Get-OptionalFileSnapshot $Path "用途档位状态"
    if (-not $snapshot.Exists) { return 0 }
    try {
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($snapshot.Bytes)
        if ([regex]::Matches($text, '(?i)"Version"\s*:').Count -ne 1 -or
            [regex]::Matches($text, '(?i)"Profile"\s*:').Count -ne 1) {
            throw "用途档位文件字段重复或缺失。"
        }
        $state = $text | ConvertFrom-Json
    } catch {
        throw "用途档位文件无效，无法确认之前的选择。"
    }
    $propertyNames = @($state.PSObject.Properties.Name)
    if ($propertyNames.Count -ne 2 -or
        $propertyNames -notcontains "Version" -or
        $propertyNames -notcontains "Profile") {
        throw "用途档位文件无效，无法确认之前的选择。"
    }
    $version = $state.Version
    $profile = $state.Profile
    $numericVersion = $version -is [int] -or $version -is [long]
    $numericProfile = $profile -is [int] -or $profile -is [long]
    if (-not $numericVersion -or [long]$version -ne 1 -or -not $numericProfile -or [long]$profile -notin @(1, 2, 3)) {
        throw "用途档位文件无效，无法确认之前的选择。"
    }
    return [int]$profile
}

function Save-UsageProfile([string]$Path, [int]$Profile) {
    $state = [ordered]@{ Version = 1; Profile = $Profile }
    Write-Utf8Atomic $Path (($state | ConvertTo-Json -Compress) + "`r`n")
}
