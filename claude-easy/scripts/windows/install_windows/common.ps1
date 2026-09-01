function Write-ClaudeEasyHumanText([string]$Message, [switch]$ErrorStream) {
    $safeMessage = Protect-ClaudeEasyResultText $Message
    if ($ErrorStream) {
        [Console]::Error.WriteLine($safeMessage)
    } else {
        [Console]::Out.WriteLine($safeMessage)
    }
}

function Write-Info([string]$Message) {
    if ($Json) {
        [void]$script:ClaudeEasyMessages.Add((Protect-ClaudeEasyResultText $Message))
        return
    }
    Write-ClaudeEasyHumanText "[ClaudeEasy] $Message"
}

function Complete-InstallResult(
    [int]$ExitCode,
    [string]$Status,
    [string]$Code,
    [string]$SummaryZh,
    [object[]]$Changes = @(),
    [object[]]$Checks = @(),
    [object[]]$Items = @(),
    [object[]]$Warnings = @(),
    [object]$WorkflowComplete = $null,
    [object]$CompletedScope = $null,
    [object]$RequiredFollowups = $null
) {
    if ($Json) {
        $result = New-ClaudeEasyResult -Command "install" -Operation $script:ClaudeEasyOperation -Ok ($ExitCode -eq 0) -Status $Status -Code $Code -ExitCode $ExitCode -SummaryZh $SummaryZh -Profile $script:ClaudeEasyProfile -Changes $Changes -Checks $Checks -Items $Items -Messages @($script:ClaudeEasyMessages) -Warnings $Warnings -WorkflowComplete $WorkflowComplete -CompletedScope $CompletedScope -RequiredFollowups $RequiredFollowups
        Write-ClaudeEasyResult $result
    } elseif ($ExitCode -eq 0) {
        Write-ClaudeEasyHumanText "[ClaudeEasy] $SummaryZh"
    } else {
        Write-ClaudeEasyHumanText "[ClaudeEasy] $SummaryZh" -ErrorStream
    }
    exit $ExitCode
}

function Get-SafeUpdateRequiredFollowups([int]$Profile) {
    switch ($Profile) {
        1 { return @("client_switch_verification", "site_verification", "final_state_audit") }
        2 { return @("client_switch_verification", "site_verification", "final_state_audit") }
        3 {
            return @(
                "client_switch_verification", "site_verification",
                "route_verification", "dns_deep_test",
                "webrtc_test", "local_region_fingerprint_test", "final_state_audit"
            )
        }
        default { throw "用途档位无效，只能是 1、2 或 3。" }
    }
}

function Get-SavedUsageProfile([string]$Path, [object]$Snapshot = $null) {
    $snapshot = $Snapshot
    if ($null -eq $snapshot) {
        $snapshot = Get-OptionalFileSnapshot $Path "用途档位状态"
    }
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
    $version = $state.Version
    $profile = $state.Profile
    $numericVersion = $version -is [int] -or $version -is [long]
    $numericProfile = $profile -is [int] -or $profile -is [long]
    $propertyNames = @($state.PSObject.Properties.Name | Sort-Object)
    $expectedProperties = if ($numericVersion -and [long]$version -eq 1) {
        "Profile,Version"
    } elseif ($numericVersion -and [long]$version -eq 2) {
        "ManagedScriptSha256,Profile,Version"
    } else {
        ""
    }
    if (($propertyNames -join ",") -cne $expectedProperties -or
        -not $numericProfile -or [long]$profile -notin @(1, 2, 3)) {
        throw "用途档位文件无效，无法确认之前的选择。"
    }
    if ([long]$version -eq 2 -and (
        [regex]::Matches($text, '(?i)"ManagedScriptSha256"\s*:').Count -ne 1 -or
        -not ($state.ManagedScriptSha256 -is [string]) -or
        [string]$state.ManagedScriptSha256 -notmatch '^[0-9a-f]{64}$'
    )) {
        throw "用途档位文件无效，无法确认之前的选择。"
    }
    return [int]$profile
}
