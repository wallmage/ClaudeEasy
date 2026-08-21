param(
    [string]$AppHome = "",
    [string]$MihomoPath = "",
    [object]$UsageProfile = "0",
    [switch]$ShowUsageProfile,
    [switch]$BackupSubscriptions,
    [switch]$SnapshotProfiles,
    [switch]$VerifySafeUpdate,
    [switch]$RefreshConfirmed,
    [switch]$ListBackups,
    [string]$CompareBackup = "",
    [string]$RestoreBackup = "",
    [string]$ExpectedCurrentSha256 = "",
    [switch]$Json
)

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$ErrorActionPreference = "Stop"
$resultContractPath = Join-Path (Join-Path $PSScriptRoot "windows") "result_contract.ps1"
$resultContractLoaded = $false
if (Test-Path -LiteralPath $resultContractPath -PathType Leaf) {
    try {
        $null = . $resultContractPath
        $resultContractLoaded = $true
        foreach ($requiredResultFunction in @(
            "Protect-ClaudeEasyResultText",
            "Protect-ClaudeEasyResultValue",
            "New-ClaudeEasyResult",
            "Write-ClaudeEasyResult"
        )) {
            if ($null -eq (Get-Command $requiredResultFunction -CommandType Function -ErrorAction SilentlyContinue)) {
                $resultContractLoaded = $false
                break
            }
        }
    } catch {
        $resultContractLoaded = $false
    }
}
if (-not $resultContractLoaded) {
    if ($Json) {
        [Console]::Out.WriteLine('{"schema":"claude-easy.result","version":1,"command":"install","platform":"windows","client":"clash-verge-rev","operation":"load","ok":false,"status":"failed","code":"incomplete_package","exit_code":6,"summary_zh":"安装包不完整。","profile":null,"changes":[],"checks":[],"items":[],"messages":[],"warnings":[]}')
    } else {
        [Console]::Error.WriteLine("[ClaudeEasy] 安装包不完整。")
    }
    exit 6
}
$script:ClaudeEasyMessages = New-Object System.Collections.ArrayList
$script:ClaudeEasyOperation = if ($BackupSubscriptions) { "backup_subscriptions" } elseif ($SnapshotProfiles) { "snapshot_profiles" } elseif ($VerifySafeUpdate) { "verify_safe_update" } elseif ($ListBackups) { "list_backups" } elseif (-not [string]::IsNullOrWhiteSpace($CompareBackup)) { "compare_backup" } elseif (-not [string]::IsNullOrWhiteSpace($RestoreBackup)) { "restore_backup" } elseif ($ShowUsageProfile) { "show_usage_profile" } else { "install" }
$script:ClaudeEasyProfile = $null

$installerModuleRoot = Join-Path (Join-Path $PSScriptRoot "windows") "install_windows"
$enginePath = Join-Path (Join-Path $PSScriptRoot "windows") "clash_verge_global.js"
$installerModules = @(
    "common.ps1",
    "yaml.ps1",
    "profiles.ps1",
    "mihomo.ps1",
    "transaction.ps1",
    "script_js.ps1",
    "runtime.ps1",
    "safe_update.ps1"
)
try {
    if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
        throw "安装包不完整：缺少 Windows 全局扩展脚本。"
    }
    foreach ($installerModule in $installerModules) {
        $installerModulePath = Join-Path $installerModuleRoot $installerModule
        if (-not (Test-Path -LiteralPath $installerModulePath -PathType Leaf)) {
            throw "安装包不完整：缺少 Windows 安装模块。"
        }
        $null = . $installerModulePath
    }
    foreach ($requiredInstallerFunction in @(
        "Complete-InstallResult", "Write-Info", "Write-ClaudeEasyHumanText", "Get-SafeUpdateRequiredFollowups", "Get-SavedUsageProfile", "Resolve-ClashVergeAppHome", "ConvertTo-NormalizedWindowsPath",
        "Enter-AppHomeMutationLock", "Exit-AppHomeMutationLock", "Assert-NoReparsePointPath", "Get-OptionalFileSnapshot",
        "ConvertTo-Utf8Bytes", "Get-BytesSha256", "Get-FileSha256", "Get-StreamBytes", "Remove-VerifiedOwnedFile",
        "Backup-InitialOnce", "Backup-Versioned", "Invoke-VerifiedFileTransaction", "Get-BackupTarget", "Get-PublicBackupDescriptor", "Test-RestoreCandidate",
        "Get-InstallStateEntry", "Assert-InstallState", "Assert-StateSnapshotUnchanged", "New-InstallStateEntry",
        "Split-YamlLines", "Set-YamlTopLevelScalar", "Set-YamlTunMapping", "Test-GeneratedYaml", "Get-RedactedYamlChangedPaths",
        "Get-RemoteSubscriptionProfileItems", "Get-RemoteSubscriptionTargets", "Get-RemoteSubscriptionAutoUpdateOwnership", "Get-PublicSubscriptionLabel", "Get-PublicSubscriptionResult",
        "Assert-RemoteSubscriptionAutoUpdateOwnershipState", "Merge-RemoteSubscriptionAutoUpdateOwnership", "Assert-ClaudeEasyProxyGroupCollection",
        "Set-RemoteSubscriptionAutoUpdateDisabled", "Assert-RemoteSubscriptionAutoUpdateDisabled",
        "Find-MihomoCore", "Test-MihomoVersion", "Test-MihomoCandidate", "Test-ClashVergeRunning", "Get-ClashVergeProcessIdentity", "Test-ClashVergeProcessIdentity",
        "Build-GlobalScript", "Get-ClaudeEasyManagedScriptEnvelope", "Assert-ClaudeEasyManagedScriptCurrent",
        "Get-ClaudeEasyReactivationHotkey", "Set-ClaudeEasyReactivationHotkey", "Get-ClashVergeReactivationShortcut",
        "Get-ClashControllerContext", "Get-ClashRuntimeState", "Restore-ClashRuntimeSelections", "Invoke-ClashVergeReactivationShortcut",
        "Wait-ClashVergeRuntimeRefresh", "Wait-ClashVergeRuntimeHealthy", "Assert-ClashRuntimeHealthy",
        "Get-SafeUpdateRecoveryItems", "Get-SafeUpdateVerificationTargets", "New-SafeUpdateSnapshotContext",
        "Open-SafeUpdateVersionGuard", "Restore-SafeUpdateFiles", "Test-SafeUpdateActivationRecord", "Set-SafeUpdateActivationAttempt"
    )) {
        if ($null -eq (Get-Command $requiredInstallerFunction -CommandType Function -ErrorAction SilentlyContinue)) {
            throw "安装包不完整：安装模块缺少必要接口。"
        }
    }
} catch {
    if ($Json) {
        [Console]::Out.WriteLine('{"schema":"claude-easy.result","version":1,"command":"install","platform":"windows","client":"clash-verge-rev","operation":"load","ok":false,"status":"failed","code":"incomplete_package","exit_code":6,"summary_zh":"安装包不完整。","profile":null,"changes":[],"checks":[],"items":[],"messages":[],"warnings":[]}')
    } else {
        [Console]::Error.WriteLine("[ClaudeEasy] 安装包不完整。")
    }
    exit 6
}

$parsedUsageProfileArgument = 0
if (-not [int]::TryParse(
        [string]$UsageProfile,
        [System.Globalization.NumberStyles]::Integer,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$parsedUsageProfileArgument
    )) {
    Complete-InstallResult 64 "invalid_request" "invalid_usage_profile" "用途档位无效，只能是 1、2 或 3。"
}
$UsageProfile = $parsedUsageProfileArgument

if ([string]::IsNullOrWhiteSpace($AppHome)) {
    try {
        $AppHome = Resolve-ClashVergeAppHome
    } catch {
        Complete-InstallResult 2 "invalid_request" "ambiguous_app_home" "检测到多个 Clash Verge Rev 配置目录；未执行任何操作。"
    }
}
if (-not [string]::IsNullOrWhiteSpace($AppHome)) {
    $AppHome = ConvertTo-NormalizedWindowsPath $AppHome
}

if ([string]::IsNullOrWhiteSpace($AppHome) -or -not (Test-Path -LiteralPath $AppHome -PathType Container)) {
    Complete-InstallResult 2 "unsupported" "client_not_found" "没有找到受支持的 Clash Verge Rev。"
}

$requestedOperations = @(
    [bool]$BackupSubscriptions,
    [bool]$SnapshotProfiles,
    [bool]$VerifySafeUpdate,
    [bool]$ListBackups,
    (-not [string]::IsNullOrWhiteSpace($CompareBackup)),
    (-not [string]::IsNullOrWhiteSpace($RestoreBackup)),
    [bool]$ShowUsageProfile
) | Where-Object { $_ }
if ($requestedOperations.Count -gt 1) {
    Complete-InstallResult 64 "invalid_request" "conflicting_operations" "一次只能执行一个操作。"
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedCurrentSha256) -and [string]::IsNullOrWhiteSpace($RestoreBackup)) {
    Complete-InstallResult 64 "invalid_request" "unexpected_hash" "只有恢复备份时才能提供预期 SHA-256。"
}
if (-not [string]::IsNullOrWhiteSpace($RestoreBackup) -and
    $ExpectedCurrentSha256 -notmatch '^[0-9a-fA-F]{64}$') {
    Complete-InstallResult 64 "invalid_request" "expected_current_sha256_required" "恢复备份必须提供比较时取得的当前配置 SHA-256。"
}
if ($RefreshConfirmed -and -not $VerifySafeUpdate) {
    Complete-InstallResult 64 "invalid_request" "unexpected_refresh_confirmation" "只有验收安全更新时才能确认客户端刷新。"
}
if ($VerifySafeUpdate -and -not $RefreshConfirmed) {
    Complete-InstallResult 64 "invalid_request" "missing_refresh_confirmation" "请先在客户端完成更新所有订阅，再明确确认本轮刷新。"
}

# Clash Verge Rev 的全局扩展脚本位置：profiles/Script.js。
$profilesDirectory = Join-Path $AppHome "profiles"
$backupRoot = Join-Path $AppHome "claude-easy-backups"
$profilesIndexPath = Join-Path $AppHome "profiles.yaml"
$vergePath = Join-Path $AppHome "verge.yaml"
$configPath = Join-Path $AppHome "config.yaml"
$runtimeConfigPath = Join-Path $AppHome "clash-verge.yaml"
$statePath = Join-Path $AppHome "claude-easy-install-state.json"
$autoUpdateStatePath = Join-Path $AppHome "claude-easy-auto-update-state.json"
$usageStatePath = Join-Path $AppHome "claude-easy-usage-profile.json"
$safeUpdateStatePath = Join-Path $AppHome "claude-easy-safe-update.json"
$targetScript = Join-Path $profilesDirectory "Script.js"

$mutationLock = $null
try {
    $mutationLock = Enter-AppHomeMutationLock $AppHome
} catch {
    $lockMessage = $_.Exception.Message
    if ($lockMessage -eq "客户端保持运行；中断的客户端敏感事务等待恢复。") {
        Complete-InstallResult 1 "partial" "transaction_recovery_pending" "客户端保持运行；中断的客户端敏感事务仍在等待安全恢复，请稍后重试。"
    }
    if ($lockMessage -eq "同一配置目录已有 ClaudeEasy 操作正在进行，请稍后重试。") {
        Complete-InstallResult 1 "failed" "operation_in_progress" $lockMessage
    }
    Complete-InstallResult 1 "failed" "state_recovery_failed" $lockMessage
}

try {
try {
if ($script:ClaudeEasyOperation -eq "install" -or $script:ClaudeEasyOperation -eq "restore_backup") {
    $pendingSafeUpdate = $false
    try {
        $pendingSafeUpdate = (Get-OptionalFileSnapshot $safeUpdateStatePath "安全更新准备记录").Exists
    } catch {
        Complete-InstallResult 1 "failed" "safe_update_state_read_failed" "安全更新状态无法安全读取；本次操作未修改任何文件。"
    }
    if ($pendingSafeUpdate) {
        Complete-InstallResult 1 "partial" "safe_update_pending" "发现尚未验收的安全更新，本次操作未修改任何文件。"
    }
}

$clientStoppedPreCommit = {
    return (-not (Test-ClashVergeRunning))
}

$usageProfileSnapshot = $null
$savedUsageProfile = 0
$needsUsageProfile = $SnapshotProfiles -or $VerifySafeUpdate -or $ShowUsageProfile -or (-not [string]::IsNullOrWhiteSpace($RestoreBackup)) -or (-not $BackupSubscriptions -and (
    -not $ListBackups -and
    [string]::IsNullOrWhiteSpace($CompareBackup) -and
    [string]::IsNullOrWhiteSpace($RestoreBackup)
))
if ($needsUsageProfile) {
    try {
        $usageProfileSnapshot = Get-OptionalFileSnapshot $usageStatePath "用途档位状态"
        $savedUsageProfile = Get-SavedUsageProfile $usageStatePath $usageProfileSnapshot
    } catch {
        Complete-InstallResult 1 "failed" "usage_profile_read_failed" ("读取用途档位失败：" + $_.Exception.Message)
    }
}

if ($BackupSubscriptions) {
    if (-not (Test-Path -LiteralPath $profilesIndexPath -PathType Leaf)) { throw "找不到远程订阅清单。" }
    $indexSnapshot = Get-OptionalFileSnapshot $profilesIndexPath "远程订阅清单"
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $indexText = $strictUtf8.GetString($indexSnapshot.Bytes)
    if ($indexText.Length -gt 0 -and $indexText[0] -eq [char]0xFEFF) {
        $indexText = $indexText.Substring(1)
    }
    $profiles = @(Get-RemoteSubscriptionTargets $indexText $profilesDirectory)
    foreach ($profile in $profiles) {
        $profileSnapshot = Get-OptionalFileSnapshot $profile.Path "远程订阅"
        Backup-InitialOnce `
            $profile.Path $backupRoot `
            -SourceBytes $profileSnapshot.Bytes -UseSourceBytes | Out-Null
        Backup-Versioned `
            $profile.Path $backupRoot "pre-update" `
            -SourceBytes $profileSnapshot.Bytes -UseSourceBytes | Out-Null
    }
    Write-Info "已为 $($profiles.Count) 份远程订阅创建更新前备份。"
    $backupItems = @($profiles | ForEach-Object {
        Get-PublicSubscriptionResult ([string]$_.Uid) ([string]$_.Name) "unchanged"
    })
    Complete-InstallResult 0 "ok" "subscription_backups_created" `
        "已为全部远程订阅创建更新前备份。" `
        @("profile_backups") @() $backupItems
}

if ($SnapshotProfiles -or $VerifySafeUpdate) {
    if ($savedUsageProfile -eq 0) {
        Complete-InstallResult 10 "invalid_request" "usage_profile_required" "还没有选择用途档位。"
    }
    if ($UsageProfile -ne 0 -and $UsageProfile -ne $savedUsageProfile) {
        Complete-InstallResult 64 "invalid_request" "usage_profile_mismatch" "请求档位与已保存档位不一致；未执行安全更新。"
    }
    $script:ClaudeEasyProfile = $savedUsageProfile
}

if ($SnapshotProfiles) {
    $newManifestSnapshot = Get-OptionalFileSnapshot $safeUpdateStatePath "安全更新准备记录"
    if ($newManifestSnapshot.Exists) {
        throw "发现尚未验收的安全更新；请在客户端刷新完成后运行 -VerifySafeUpdate -RefreshConfirmed，不能覆盖更新前清单。"
    }
    if (-not (Test-ClashVergeRunning)) {
        throw "Clash Verge Rev 没有运行，无法记录更新前的 TUN 和代理选择。"
    }
    if (-not (Test-Path -LiteralPath $profilesIndexPath -PathType Leaf)) { throw "找不到远程订阅清单。" }
    $snapshotContext = $null
    try {
        $snapshotContext = New-SafeUpdateSnapshotContext `
            $profilesIndexPath `
            $profilesDirectory
        $profiles = @($snapshotContext.Profiles)
        $manifestItems = @()
        foreach ($profile in $profiles) {
            Backup-InitialOnce `
                $profile.Path `
                $backupRoot `
                -SourceBytes $profile.SnapshotBytes `
                -UseSourceBytes | Out-Null
            $backup = Backup-Versioned `
                $profile.Path `
                $backupRoot `
                "pre-update" `
                -WithMetadata `
                -SourceBytes $profile.SnapshotBytes `
                -UseSourceBytes
            if ($backup.Sha256 -cne [string]$profile.SnapshotSha256) {
                throw "远程订阅在安全更新快照期间发生变化。"
            }
            $manifestItems += [ordered]@{
                Uid = $profile.Uid
                File = (Split-Path -Leaf $profile.Path)
                BeforeSha256 = $backup.Sha256
                BeforeUpdated = [string]$profile.Updated
                Backup = (Split-Path -Leaf $backup.Path)
            }
        }
        $runtimeContext = Get-ClashControllerContext $runtimeConfigPath
        $runtimeState = Get-ClashRuntimeState $runtimeContext
        $runtimeSelections = @($runtimeState.Selections.Keys | Sort-Object | ForEach-Object {
            [ordered]@{
                Group = [string]$_
                Selection = [string]$runtimeState.Selections[$_]
            }
        })
        $runtimeSnapshot = [ordered]@{
            TunEnabled = [bool]$runtimeState.TunEnabled
            Selections = $runtimeSelections
        }
        $manifest = [ordered]@{
            Version = 4
            CreatedAt = [DateTimeOffset]::Now.ToString("o")
            Profiles = $manifestItems
            Runtime = $runtimeSnapshot
            UpdateDispatchCommittedFor = $null
        }
        $manifestBytes = ConvertTo-Utf8Bytes (($manifest | ConvertTo-Json -Depth 5) + "`r`n")
        Invoke-VerifiedFileTransaction @(
            [pscustomobject]@{
                Path = $safeUpdateStatePath
                Bytes = $manifestBytes
                Existed = $false
                OriginalBytes = $null
                OriginalIdentity = $null
            }
        ) -InterruptedRecoveryPolicy "safe_update_running_client"
    } finally {
        if ($null -ne $snapshotContext) {
            foreach ($guard in @($snapshotContext.Guards)) { $guard.Dispose() }
        }
    }
    Write-Info "已核对远程清单，并为 $($profiles.Count) 份订阅创建安全更新前备份。"
    foreach ($profile in $profiles) {
        Write-Info ("待更新：" + (Get-PublicSubscriptionLabel ([string]$profile.Uid) ([string]$profile.Name)))
    }
    $snapshotItems = @($profiles | ForEach-Object {
        Get-PublicSubscriptionResult ([string]$_.Uid) ([string]$_.Name) "pending"
    })
    $snapshotFollowups = @("subscription_refresh", "safe_update_verification") +
        @(Get-SafeUpdateRequiredFollowups $script:ClaudeEasyProfile)
    Complete-InstallResult 0 "ok" "snapshot_created" `
        "已创建全部远程订阅的安全更新前备份；订阅刷新、验收和最终复核尚未完成。" `
        @("profile_backups") @() $snapshotItems @() `
        $false "subscription_snapshot" $snapshotFollowups
}

if ($VerifySafeUpdate) {
    $manifestSnapshot = Get-OptionalFileSnapshot $safeUpdateStatePath "安全更新准备记录"
    if (-not $manifestSnapshot.Exists) { throw "没有找到本次安全更新的准备记录。" }
    $manifestText = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($manifestSnapshot.Bytes)
    $manifest = $manifestText | ConvertFrom-Json
    if ($null -ne $manifest.PSObject.Properties["Kind"]) {
        $runtimeRecoveryProperties = @($manifest.PSObject.Properties.Name | Sort-Object)
        $runtimeRecoveryVersionIsNumeric = $manifest.Version -is [int] -or $manifest.Version -is [long]
        $runtimeRecoveryVersion = if ($runtimeRecoveryVersionIsNumeric) { [long]$manifest.Version } else { 0L }
        $expectedRuntimeRecoveryProperties = if ($runtimeRecoveryVersion -eq 2) {
            "Kind,RestoreDispatchCommittedFor,Runtime,UsageProfile,Version"
        } else {
            "Kind,Runtime,UsageProfile,Version"
        }
        $runtimeRecoveryProfileIsNumeric = $manifest.UsageProfile -is [int] -or $manifest.UsageProfile -is [long]
        if (($runtimeRecoveryProperties -join ",") -cne $expectedRuntimeRecoveryProperties -or
            -not $runtimeRecoveryVersionIsNumeric -or $runtimeRecoveryVersion -notin @(1, 2) -or
            -not ($manifest.Kind -is [string]) -or
            [string]$manifest.Kind -cne "safe_update_runtime_recovery" -or
            -not $runtimeRecoveryProfileIsNumeric -or
            [long]$manifest.UsageProfile -notin @(1, 2, 3) -or
            [long]$manifest.UsageProfile -ne $savedUsageProfile) {
            throw "安全更新运行状态恢复记录无效。"
        }
        if ($runtimeRecoveryVersion -eq 2 -and $null -ne $manifest.RestoreDispatchCommittedFor -and
            -not (Test-SafeUpdateActivationRecord $manifest.RestoreDispatchCommittedFor)) {
            throw "安全更新运行状态恢复记录无效。"
        }
        $runtimeRecoveryRuntimeProperties = @($manifest.Runtime.PSObject.Properties.Name | Sort-Object)
        if (($runtimeRecoveryRuntimeProperties -join ",") -cne "Selections,TunEnabled" -or
            -not ($manifest.Runtime.TunEnabled -is [bool])) {
            throw "安全更新运行状态恢复记录无效。"
        }
        $runtimeRecoverySelections = New-OrdinalStringDictionary
        $runtimeRecoveryGroups = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($selection in @($manifest.Runtime.Selections)) {
            $selectionProperties = @($selection.PSObject.Properties.Name | Sort-Object)
            if (($selectionProperties -join ",") -cne "Group,Selection" -or
                -not ($selection.Group -is [string]) -or
                -not ($selection.Selection -is [string]) -or
                [string]::IsNullOrWhiteSpace([string]$selection.Group) -or
                [string]::IsNullOrWhiteSpace([string]$selection.Selection) -or
                -not $runtimeRecoveryGroups.Add([string]$selection.Group)) {
                throw "安全更新运行状态恢复记录无效。"
            }
            $runtimeRecoverySelections[[string]$selection.Group] = [string]$selection.Selection
        }
        try {
            $vergeSnapshot = Get-OptionalFileSnapshot $vergePath "verge.yaml"
            if (-not $vergeSnapshot.Exists) { throw "找不到 verge.yaml。" }
            $vergeText = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($vergeSnapshot.Bytes)
            $reactivationShortcut = Get-ClashVergeReactivationShortcut $vergeText
            $runtimeRecoveryContext = Get-ClashControllerContext $runtimeConfigPath
            $runtimeRecoveryPolicyPath = Join-Path (Join-Path $PSScriptRoot "..\references") "policy.json"
            $runtimeRecoveryPolicy = (New-Object System.Text.UTF8Encoding($false, $true)).GetString(
                [System.IO.File]::ReadAllBytes($runtimeRecoveryPolicyPath)
            ) | ConvertFrom-Json
            $runtimeRecoveryCurl = Get-Command curl.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
            if ($runtimeRecoveryVersion -eq 1) {
                try {
                    Assert-ClashRuntimeHealthy `
                        $runtimeRecoveryContext $runtimeRecoverySelections `
                        ([bool]$manifest.Runtime.TunEnabled) $savedUsageProfile `
                        ([string]$runtimeRecoveryCurl.Source) $runtimeRecoveryPolicy -ReadOnly
                    Remove-VerifiedOwnedFile $safeUpdateStatePath $manifestSnapshot.Bytes `
                        $manifestSnapshot.Identity "safe_update_running_client"
                    Complete-InstallResult 1 "rolled_back" "safe_update_rolled_back" "更新验收失败；已确认全部订阅文件和更新前运行状态均已恢复。"
                } catch {
                    Complete-InstallResult 1 "partial" "safe_update_legacy_runtime_recovery_pending" "旧版运行状态恢复记录无法确认是否已触发过客户端重载；未重复发送，请手动确认运行状态。" @() @("runtime_unverified")
                }
            }
            $runtimeRecoveryIdentity = Get-ClashVergeProcessIdentity
            $runtimeRecoveryAttempt = Set-SafeUpdateActivationAttempt `
                $safeUpdateStatePath $manifestSnapshot $manifest `
                "RestoreDispatchCommittedFor" $runtimeRecoveryIdentity $runtimeRecoveryContext
            $manifestSnapshot = $runtimeRecoveryAttempt.Snapshot
            $manifest = $runtimeRecoveryAttempt.Manifest
            if ([bool]$runtimeRecoveryAttempt.Allowed) {
                if (-not (Test-ClashVergeProcessIdentity (Get-ClashVergeProcessIdentity) $runtimeRecoveryIdentity)) {
                    Complete-InstallResult 1 "partial" "safe_update_client_changed" "客户端进程在恢复请求发送前发生变化；未发送重载，请重试。" @() @("runtime_unverified")
                }
                Invoke-ClashVergeReactivationShortcut $reactivationShortcut
            }
            $null = Wait-ClashVergeRuntimeHealthy `
                $runtimeConfigPath $manifest.RestoreDispatchCommittedFor.RuntimeBefore $runtimeRecoverySelections `
                ([bool]$manifest.Runtime.TunEnabled) $savedUsageProfile `
                ([string]$runtimeRecoveryCurl.Source) $runtimeRecoveryPolicy
            Remove-VerifiedOwnedFile $safeUpdateStatePath $manifestSnapshot.Bytes `
                $manifestSnapshot.Identity "safe_update_running_client"
            Complete-InstallResult 1 "rolled_back" "safe_update_rolled_back" "更新验收失败；已恢复全部订阅文件和更新前运行状态。"
        } catch {
            Complete-InstallResult 1 "partial" "safe_update_runtime_unverified" "更新验收失败；全部订阅文件已恢复，但客户端运行配置尚未验证。" @() @() @() @("runtime_unverified")
        }
    }
    $manifestProperties = @($manifest.PSObject.Properties.Name | Sort-Object)
    $createdAtIsJsonString = [regex]::Matches(
        $manifestText,
        '(?i)"CreatedAt"\s*:\s*"(?:[^"\\]|\\.)*"'
    ).Count -eq 1
    $manifestVersionIsNumeric = $manifest.Version -is [int] -or $manifest.Version -is [long]
    $manifestVersion = if ($manifestVersionIsNumeric) { [long]$manifest.Version } else { 0L }
    $expectedManifestProperties = if ($manifestVersion -eq 4) {
        "CreatedAt,Profiles,Runtime,UpdateDispatchCommittedFor,Version"
    } elseif ($manifestVersion -eq 3) {
        "CreatedAt,Profiles,Runtime,Version"
    } else {
        "CreatedAt,Profiles,Version"
    }
    if (($manifestProperties -join ",") -cne $expectedManifestProperties -or
        -not $manifestVersionIsNumeric -or
        $manifestVersion -notin @(1, 2, 3, 4) -or
        -not $createdAtIsJsonString -or
        @($manifest.Profiles).Count -eq 0) {
        throw "安全更新准备记录无效。"
    }
    $expectedSelections = New-OrdinalStringDictionary
    $expectedTunEnabled = $false
    $hasRuntimeSnapshot = $manifestVersion -in @(3, 4)
    if ($manifestVersion -eq 4 -and $null -ne $manifest.UpdateDispatchCommittedFor -and
        -not (Test-SafeUpdateActivationRecord $manifest.UpdateDispatchCommittedFor)) {
        throw "安全更新准备记录中的客户端激活状态无效。"
    }
    if ($hasRuntimeSnapshot) {
        $runtimeProperties = @($manifest.Runtime.PSObject.Properties.Name | Sort-Object)
        if (($runtimeProperties -join ",") -cne "Selections,TunEnabled" -or
            -not ($manifest.Runtime.TunEnabled -is [bool])) {
            throw "安全更新准备记录中的运行状态无效。"
        }
        $seenRuntimeGroups = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($selection in @($manifest.Runtime.Selections)) {
            $selectionProperties = @($selection.PSObject.Properties.Name | Sort-Object)
            if (($selectionProperties -join ",") -cne "Group,Selection" -or
                -not ($selection.Group -is [string]) -or
                -not ($selection.Selection -is [string]) -or
                [string]::IsNullOrWhiteSpace([string]$selection.Group) -or
                [string]::IsNullOrWhiteSpace([string]$selection.Selection) -or
                -not $seenRuntimeGroups.Add([string]$selection.Group)) {
                throw "安全更新准备记录中的代理选择无效。"
            }
            $expectedSelections[[string]$selection.Group] = [string]$selection.Selection
        }
        $expectedTunEnabled = [bool]$manifest.Runtime.TunEnabled
    }
    $recoveryItems = @(Get-SafeUpdateRecoveryItems $manifest $profilesDirectory $backupRoot)
    $validated = @()
    $observedCurrentHashes = @{}
    $legacySnapshotRetirement = -not $hasRuntimeSnapshot
    $safeUpdateContentRestoreEligible = $false
    $indexSnapshot = $null
    $scriptSnapshot = $null
    try {
        $indexSnapshot = Get-OptionalFileSnapshot $profilesIndexPath "profiles.yaml"
        if (-not $indexSnapshot.Exists) { throw "远程订阅清单在更新期间消失。" }
        $indexText = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($indexSnapshot.Bytes)
        $currentTargets = @(
            Get-SafeUpdateVerificationTargets $indexText $profilesDirectory $recoveryItems
        )
        $scriptSnapshot = Get-OptionalFileSnapshot $targetScript "全局扩展脚本"
        $missingTarget = $false
        foreach ($recovery in $recoveryItems) {
            $targetSnapshot = Get-OptionalFileSnapshot $recovery.TargetPath "更新后的订阅"
            if ($targetSnapshot.Exists) {
                $observedCurrentHashes[$recovery.TargetPath] = Get-BytesSha256 $targetSnapshot.Bytes
            } else {
                $observedCurrentHashes[$recovery.TargetPath] = ""
                $missingTarget = $true
            }
        }
        if ($missingTarget) {
            $safeUpdateContentRestoreEligible = $true
            throw "更新后的订阅文件缺失。"
        }
        $savedProfile = $savedUsageProfile
        if ($savedProfile -notin @(1, 2, 3)) { throw "没有可用于安全更新验收的用途档位。" }
        if (-not $scriptSnapshot.Exists) { throw "没有找到已安装的全局扩展脚本。" }
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $scriptText = $strictUtf8.GetString($scriptSnapshot.Bytes)
        Assert-ClaudeEasyManagedScriptCurrent $scriptText $savedProfile $enginePath $targetScript
        $core = Find-MihomoCore $MihomoPath
        foreach ($item in @($manifest.Profiles)) {
            try {
                $target = @($currentTargets | Where-Object { $_.Uid -eq [string]$item.Uid -and (Split-Path -Leaf $_.Path) -eq [string]$item.File })
                if ($target.Count -ne 1) { throw "远程订阅清单在更新期间发生变化。" }
                $targetGuard = Open-SafeUpdateVersionGuard $target[0].Path "远程订阅"
                try {
                    $validatedBytes = Get-StreamBytes $targetGuard.Stream
                    $validatedHash = Get-BytesSha256 $validatedBytes
                    $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($validatedBytes)
                    $recovery = @($recoveryItems | Where-Object { $_.Uid -eq [string]$item.Uid })
                    if ($recovery.Count -ne 1) { throw "安全更新准备记录中的订阅清单无效。" }
                    if ([bool]$recovery[0].CanAutoRestore) {
                        $backupGuard = Open-SafeUpdateVersionGuard $recovery[0].BackupPath "安全更新前备份"
                        try {
                            $beforeBytes = Get-StreamBytes $backupGuard.Stream
                        } finally {
                            $backupGuard.Stream.Dispose()
                            foreach ($directoryGuard in @($backupGuard.DirectoryGuards)) { $directoryGuard.Dispose() }
                        }
                        if ((Get-BytesSha256 $beforeBytes) -ne [string]$recovery[0].BeforeSha256) {
                            throw "安全更新前备份在验收期间发生变化。"
                        }
                        $beforeText = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($beforeBytes)
                        Assert-SubscriptionProtocolPreserved $beforeText $text
                    }
                    $publicSubscriptionLabel = Get-PublicSubscriptionLabel ([string]$target[0].Uid) ([string]$target[0].Name)
                    Test-GeneratedYaml $text $publicSubscriptionLabel | Out-Null
                    Assert-ClaudeEasyProxyGroupCollection $text $publicSubscriptionLabel
                    Test-MihomoCandidate $core $text $profilesDirectory
                    $targetGuard.Stream.Position = 0
                    if ((Get-BytesSha256 (Get-StreamBytes $targetGuard.Stream)) -ne $validatedHash) {
                        throw "订阅在验收期间再次发生变化。"
                    }
                } finally {
                    $targetGuard.Stream.Dispose()
                    foreach ($directoryGuard in @($targetGuard.DirectoryGuards)) { $directoryGuard.Dispose() }
                }
                $validated += [pscustomobject]@{
                    Target = $target[0]
                    Manifest = $item
                    ValidatedSha256 = $validatedHash
                }
            } catch {
                $safeUpdateContentRestoreEligible = $true
                throw
            }
        }
        Assert-RemoteSubscriptionAutoUpdateDisabled $indexText | Out-Null
        if ($hasRuntimeSnapshot) {
            $safeUpdateContentRestoreEligible = $true
            $vergeSnapshot = Get-OptionalFileSnapshot $vergePath "verge.yaml"
            if (-not $vergeSnapshot.Exists) { throw "找不到 verge.yaml。" }
            $vergeText = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($vergeSnapshot.Bytes)
            $reactivationShortcut = Get-ClashVergeReactivationShortcut $vergeText
            $runtimeContext = Get-ClashControllerContext $runtimeConfigPath
            $runtimePolicyPath = Join-Path (Join-Path $PSScriptRoot "..\references") "policy.json"
            $runtimePolicy = (New-Object System.Text.UTF8Encoding($false, $true)).GetString(
                [System.IO.File]::ReadAllBytes($runtimePolicyPath)
            ) | ConvertFrom-Json
            $runtimeCurl = Get-Command curl.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
            if ($manifestVersion -eq 3) {
                throw "旧版安全更新记录无法确认是否已触发过客户端加载；未重复发送，改为恢复更新前订阅。"
            }
            $updateIdentity = Get-ClashVergeProcessIdentity
            $updateAttempt = Set-SafeUpdateActivationAttempt `
                $safeUpdateStatePath $manifestSnapshot $manifest `
                "UpdateDispatchCommittedFor" $updateIdentity $runtimeContext
            $manifestSnapshot = $updateAttempt.Snapshot
            $manifest = $updateAttempt.Manifest
            if ([bool]$updateAttempt.Allowed) {
                if (-not (Test-ClashVergeProcessIdentity (Get-ClashVergeProcessIdentity) $updateIdentity)) {
                    Complete-InstallResult 1 "partial" "safe_update_client_changed" "客户端进程在加载请求发送前发生变化；未发送重载，请重试。" @() @("runtime_unverified")
                }
                Invoke-ClashVergeReactivationShortcut $reactivationShortcut
            }
            $runtimeContext = Wait-ClashVergeRuntimeHealthy `
                $runtimeConfigPath $manifest.UpdateDispatchCommittedFor.RuntimeBefore `
                $expectedSelections $expectedTunEnabled `
                $savedUsageProfile ([string]$runtimeCurl.Source) $runtimePolicy
        }
        $versionGuards = @()
        try {
            foreach ($entry in @($validated | Sort-Object { $_.Target.Path })) {
                $opened = Open-SafeUpdateVersionGuard $entry.Target.Path "远程订阅"
                $versionGuards += $opened
                if ((Get-BytesSha256 (Get-StreamBytes $opened.Stream)) -ne $entry.ValidatedSha256) {
                    throw "订阅在验收期间再次发生变化。"
                }
            }
            $indexOpened = Open-SafeUpdateVersionGuard $profilesIndexPath "远程订阅清单"
            $versionGuards += $indexOpened
            if ((Get-BytesSha256 (Get-StreamBytes $indexOpened.Stream)) -ne (Get-BytesSha256 $indexSnapshot.Bytes)) {
                throw "远程订阅清单在验收期间发生变化。"
            }
            $scriptOpened = Open-SafeUpdateVersionGuard $targetScript "全局扩展脚本"
            $versionGuards += $scriptOpened
            if ((Get-BytesSha256 (Get-StreamBytes $scriptOpened.Stream)) -ne (Get-BytesSha256 $scriptSnapshot.Bytes)) {
                throw "全局扩展脚本在验收期间发生变化。"
            }
            Remove-VerifiedOwnedFile $safeUpdateStatePath $manifestSnapshot.Bytes $manifestSnapshot.Identity "safe_update_running_client"
        } finally {
            foreach ($guard in $versionGuards) {
                $guard.Stream.Dispose()
                foreach ($directoryGuard in @($guard.DirectoryGuards)) { $directoryGuard.Dispose() }
            }
        }
    } catch {
        [void]$script:ClaudeEasyMessages.Add(
            (Protect-ClaudeEasyResultText $_.Exception.Message)
        )
        if (@($recoveryItems | Where-Object { -not $_.CanAutoRestore }).Count -gt 0) {
            Complete-InstallResult 1 "partial" "safe_update_legacy_recovery_pending" "旧版安全更新记录中的备份无法确认来自一致快照；已保留当前订阅和清单，请在客户端重新更新全部订阅后重试验收。" @() @("legacy_recovery")
        }
        if (-not $safeUpdateContentRestoreEligible) {
            Complete-InstallResult 1 "partial" "safe_update_verification_retry_pending" "验收依赖的清单、脚本或状态在检查期间变化；已保留当前订阅和安全更新清单，请待客户端写入完成后重试。" @() @("verification_state")
        }
        $controlGuards = @()
        $controlStateStable = $true
        try {
            if ($null -eq $indexSnapshot -or
                -not [bool]$indexSnapshot.Exists -or
                $null -eq $scriptSnapshot -or
                -not [bool]$scriptSnapshot.Exists) {
                throw "缺少安全更新恢复所需的控制文件快照。"
            }
            foreach ($control in @(
                [pscustomobject]@{ Path = $profilesIndexPath; Snapshot = $indexSnapshot; Label = "远程订阅清单" },
                [pscustomobject]@{ Path = $targetScript; Snapshot = $scriptSnapshot; Label = "全局扩展脚本" }
            )) {
                $opened = Open-SafeUpdateVersionGuard $control.Path $control.Label
                $controlGuards += $opened
                if ((Get-BytesSha256 (Get-StreamBytes $opened.Stream)) -ne
                    (Get-BytesSha256 $control.Snapshot.Bytes)) {
                    throw "安全更新恢复所需的控制文件在验收期间变化。"
                }
            }
        } catch {
            $controlStateStable = $false
        }
        if (-not $controlStateStable) {
            foreach ($controlGuard in $controlGuards) {
                $controlGuard.Stream.Dispose()
                foreach ($directoryGuard in @($controlGuard.DirectoryGuards)) { $directoryGuard.Dispose() }
            }
            Complete-InstallResult 1 "partial" "safe_update_verification_retry_pending" "验收依赖的清单、脚本或状态在检查期间变化；已保留当前订阅和安全更新清单，请待客户端写入完成后重试。" @() @("verification_state")
        }
        $runtimeRecoveryBytes = $null
        if ($hasRuntimeSnapshot) {
            $runtimeRecoveryRecord = [ordered]@{
                Version = 2
                Kind = "safe_update_runtime_recovery"
                UsageProfile = [int]$savedUsageProfile
                RestoreDispatchCommittedFor = $null
                Runtime = [ordered]@{
                    TunEnabled = [bool]$manifest.Runtime.TunEnabled
                    Selections = @($manifest.Runtime.Selections | ForEach-Object {
                        [ordered]@{
                            Group = [string]$_.Group
                            Selection = [string]$_.Selection
                        }
                    })
                }
            }
            $runtimeRecoveryBytes = ConvertTo-Utf8Bytes (($runtimeRecoveryRecord | ConvertTo-Json -Depth 5) + "`r`n")
        }
        try {
            $restoreResult = Restore-SafeUpdateFiles `
                $recoveryItems $observedCurrentHashes $safeUpdateStatePath `
                $manifestSnapshot $runtimeRecoveryBytes
        } finally {
            foreach ($controlGuard in $controlGuards) {
                $controlGuard.Stream.Dispose()
                foreach ($directoryGuard in @($controlGuard.DirectoryGuards)) { $directoryGuard.Dispose() }
            }
        }
        if ($restoreResult.Conflicts.Count -gt 0) {
            throw "更新验收失败；检测到订阅同时发生变化，未覆盖新内容：$($restoreResult.Conflicts -join '、')。安全更新记录已保留。"
        }
        if ($restoreResult.Failures.Count -gt 0) { throw "更新验收失败，且部分订阅未能恢复：$($restoreResult.Failures -join '、')。安全更新记录已保留。" }
        $rollbackItems = @($recoveryItems | ForEach-Object {
            Get-PublicSubscriptionResult ([string]$_.Uid) ([string]$_.Name) "rolled_back"
        })
        if ($hasRuntimeSnapshot) {
            try {
                $vergeSnapshot = Get-OptionalFileSnapshot $vergePath "verge.yaml"
                if (-not $vergeSnapshot.Exists) { throw "找不到 verge.yaml。" }
                $vergeText = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($vergeSnapshot.Bytes)
                $reactivationShortcut = Get-ClashVergeReactivationShortcut $vergeText
                $rollbackRuntime = Get-ClashControllerContext $runtimeConfigPath
                $rollbackPolicyPath = Join-Path (Join-Path $PSScriptRoot "..\references") "policy.json"
                $rollbackPolicy = (New-Object System.Text.UTF8Encoding($false, $true)).GetString(
                    [System.IO.File]::ReadAllBytes($rollbackPolicyPath)
                ) | ConvertFrom-Json
                $rollbackCurl = Get-Command curl.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
                $runtimeRecoverySnapshot = Get-OptionalFileSnapshot $safeUpdateStatePath "安全更新运行状态恢复记录"
                if (-not $runtimeRecoverySnapshot.Exists) { throw "安全更新运行状态恢复记录已消失。" }
                $runtimeRecoveryManifest = (
                    (New-Object System.Text.UTF8Encoding($false, $true)).GetString($runtimeRecoverySnapshot.Bytes) |
                        ConvertFrom-Json
                )
                $rollbackIdentity = Get-ClashVergeProcessIdentity
                $rollbackAttempt = Set-SafeUpdateActivationAttempt `
                    $safeUpdateStatePath $runtimeRecoverySnapshot $runtimeRecoveryManifest `
                    "RestoreDispatchCommittedFor" $rollbackIdentity $rollbackRuntime
                $runtimeRecoverySnapshot = $rollbackAttempt.Snapshot
                $runtimeRecoveryManifest = $rollbackAttempt.Manifest
                if ([bool]$rollbackAttempt.Allowed) {
                    if (-not (Test-ClashVergeProcessIdentity (Get-ClashVergeProcessIdentity) $rollbackIdentity)) {
                        Complete-InstallResult 1 "partial" "safe_update_client_changed" "客户端进程在恢复请求发送前发生变化；未发送重载，请重试。" @() @("runtime_unverified")
                    }
                    Invoke-ClashVergeReactivationShortcut $reactivationShortcut
                }
                $null = Wait-ClashVergeRuntimeHealthy `
                    $runtimeConfigPath $runtimeRecoveryManifest.RestoreDispatchCommittedFor.RuntimeBefore `
                    $expectedSelections $expectedTunEnabled `
                    $savedUsageProfile ([string]$rollbackCurl.Source) $rollbackPolicy
                Remove-VerifiedOwnedFile $safeUpdateStatePath $runtimeRecoverySnapshot.Bytes `
                    $runtimeRecoverySnapshot.Identity "safe_update_running_client"
                Complete-InstallResult 1 "rolled_back" "safe_update_rolled_back" "更新验收失败；已恢复全部订阅文件和更新前运行状态。" @() @() $rollbackItems
            } catch {
                Complete-InstallResult 1 "partial" "safe_update_runtime_unverified" "更新验收失败；全部订阅文件已恢复，但客户端运行配置尚未验证。" @() @() $rollbackItems @("runtime_unverified")
            }
        }
        Complete-InstallResult 1 "partial" "safe_update_runtime_unverified" "更新验收失败；全部订阅文件已恢复，但客户端运行配置尚未验证。" @() @() $rollbackItems @("runtime_unverified")
    }
    foreach ($entry in $validated) {
        $changed = [string]$entry.ValidatedSha256 -ne [string]$entry.Manifest.BeforeSha256
        Write-Info ($(if ($changed) { "已更新并通过检查：" } else { "内容未变化并通过检查：" }) +
            (Get-PublicSubscriptionLabel ([string]$entry.Target.Uid) ([string]$entry.Target.Name)))
    }
    Write-Info "全部远程订阅已逐份通过全局脚本、代理组、YAML 与 Mihomo 检查。"
    if ($legacySnapshotRetirement) {
        Complete-InstallResult 1 "partial" "safe_update_legacy_snapshot_required" "当前订阅已通过检查，旧版安全更新记录已安全结束；请重新创建 v4 快照后再更新。" @() @("legacy_manifest_retired")
    }
    $verifiedItems = @($validated | ForEach-Object {
        $itemStatus = if ([string]$_.ValidatedSha256 -ne [string]$_.Manifest.BeforeSha256) {
            "updated"
        } else {
            "unchanged"
        }
        Get-PublicSubscriptionResult ([string]$_.Target.Uid) ([string]$_.Target.Name) $itemStatus
    })
    $requiredFollowups = @(Get-SafeUpdateRequiredFollowups $script:ClaudeEasyProfile)
    Complete-InstallResult 0 "ok" "safe_update_verified" `
        "订阅、补丁和平台检查已完成；当前档位的后续验收尚未完成。" `
        @() @("global_script", "yaml", "mihomo", "auto_update") $verifiedItems @() `
        $false "subscription_update" $requiredFollowups
}

if ($ListBackups) {
    $backupItems = @()
    $backupFiles = @()
    $backupRootSafe = $true
    try {
        Assert-NoReparsePointPath $backupRoot "备份目录"
    } catch {
        $backupRootSafe = $false
    }
    if ($backupRootSafe -and (Test-Path -LiteralPath $backupRoot -PathType Container)) {
        $backupFiles = @(Get-ChildItem -LiteralPath $backupRoot -File -Filter "*.backup" | Sort-Object Name -Descending)
    }
    foreach ($backupFile in $backupFiles) {
        $backupGuard = $null
        try {
            $backupGuard = Open-SafeUpdateVersionGuard (Join-Path $backupRoot $backupFile.Name) "备份"
            $publicBackup = Get-PublicBackupDescriptor $backupFile.Name
        } catch {
            continue
        } finally {
            if ($null -ne $backupGuard) {
                $backupGuard.Stream.Dispose()
                for ($guardIndex = $backupGuard.DirectoryGuards.Count - 1; $guardIndex -ge 0; $guardIndex--) {
                    $backupGuard.DirectoryGuards[$guardIndex].Dispose()
                }
            }
        }
        $backupItems += $publicBackup
        if (-not $Json) {
            $safeCreatedAt = Protect-ClaudeEasyResultText $publicBackup.created_at
            $safeBackupId = Protect-ClaudeEasyResultText $publicBackup.id
            [Console]::Out.WriteLine(("{0}`t{1}" -f $safeCreatedAt, $safeBackupId))
        }
    }
    $backupStatus = if ($backupItems.Count -eq 0) { "no_change" } else { "ok" }
    Complete-InstallResult 0 $backupStatus "backups_listed" "备份清单已读取。" @() @() $backupItems
}

if (-not [string]::IsNullOrWhiteSpace($CompareBackup)) {
    $resolved = Get-BackupTarget $CompareBackup
    $currentSnapshot = Get-OptionalFileSnapshot $resolved.TargetPath "当前配置"
    if (-not $currentSnapshot.Exists) { throw "当前配置不存在，无法比较。" }
    $backupHash = Get-BytesSha256 $resolved.BackupSnapshot.Bytes
    $currentHash = Get-BytesSha256 $currentSnapshot.Bytes
    $same = ($backupHash -eq $currentHash)
    $changedFields = @()
    if (-not $same) {
        if ([System.IO.Path]::GetExtension($resolved.TargetPath) -match '^\.ya?ml$') {
            $backupText = [System.Text.Encoding]::UTF8.GetString($resolved.BackupSnapshot.Bytes)
            $currentText = [System.Text.Encoding]::UTF8.GetString($currentSnapshot.Bytes)
            $changedFields = @(Get-RedactedYamlChangedPaths $backupText $currentText)
        } else {
            $changedFields = @("文件内容")
        }
    }
    $comparison = [pscustomobject][ordered]@{
        id = [string]$resolved.PublicId
        same = $same
        backup_sha256 = $backupHash
        current_sha256 = $currentHash
    }
    if (-not $Json) {
        $humanComparison = [pscustomobject][ordered]@{
            id = [string]$resolved.PublicId
            same = $same
            backup_sha256 = $backupHash
            current_sha256 = $currentHash
            changed_fields = $changedFields
        }
        $safeComparison = Protect-ClaudeEasyResultValue $humanComparison
        [Console]::Out.WriteLine(($safeComparison | ConvertTo-Json -Compress))
    }
    Complete-InstallResult 0 $(if ($same) { "no_change" } else { "ok" }) "backup_compared" "备份比较已完成。" @($changedFields) @() @($comparison)
}

if (-not [string]::IsNullOrWhiteSpace($RestoreBackup)) {
    if (Test-ClashVergeRunning) { throw "Clash Verge Rev 正在运行，不能安全恢复配置；未修改任何文件。" }
    if ($ExpectedCurrentSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "恢复时必须提供预期 SHA-256。" }
    $resolved = Get-BackupTarget $RestoreBackup
    $currentSnapshot = Get-OptionalFileSnapshot $resolved.TargetPath "当前配置"
    if (-not $currentSnapshot.Exists) { throw "当前配置不存在，拒绝恢复。" }
    $currentHash = Get-BytesSha256 $currentSnapshot.Bytes
    if ($currentHash -ne $ExpectedCurrentSha256.ToLowerInvariant()) { throw "当前配置已变化，拒绝覆盖。" }
    $restoreBytes = $resolved.BackupSnapshot.Bytes
    Test-RestoreCandidate $resolved.TargetPath $restoreBytes $savedUsageProfile
    $validatedCurrentSnapshot = Get-OptionalFileSnapshot $resolved.TargetPath "当前配置"
    if (-not $validatedCurrentSnapshot.Exists -or
        $validatedCurrentSnapshot.Identity -cne $currentSnapshot.Identity -or
        (Get-BytesSha256 $validatedCurrentSnapshot.Bytes) -ne $currentHash) {
        throw "当前配置在检查期间发生变化，拒绝覆盖。"
    }
    Backup-Versioned $resolved.TargetPath $backupRoot "pre-restore" -SourceBytes $currentSnapshot.Bytes -UseSourceBytes | Out-Null
    $restoreCommitted = Invoke-VerifiedFileTransaction @(
        [pscustomobject]@{
            Path = $resolved.TargetPath
            Bytes = $restoreBytes
            Existed = $true
            OriginalBytes = $currentSnapshot.Bytes
            OriginalIdentity = $currentSnapshot.Identity
        }
    ) $clientStoppedPreCommit
    if (-not $restoreCommitted) {
        throw "检测到 Clash Verge Rev 在备份恢复期间启动；本次没有修改当前配置。"
    }
    Write-Info "备份已恢复；恢复前版本已经另行备份。"
    Complete-InstallResult 0 "ok" "backup_restored" "备份已恢复；恢复前版本已经另行备份。" @("configuration")
}
} catch {
    $operationStatus = if ($_.Exception.Message -match "已恢复") { "rolled_back" } else { "failed" }
    Complete-InstallResult 1 $operationStatus "operation_failed" ("操作失败：" + $_.Exception.Message)
}
if ($ShowUsageProfile) {
    if ($savedUsageProfile -ne 0) { $script:ClaudeEasyProfile = $savedUsageProfile }
    if (-not $Json) { Write-ClaudeEasyHumanText $(if ($savedUsageProfile -eq 0) { "unset" } else { [string]$savedUsageProfile }) }
    Complete-InstallResult 0 "ok" "usage_profile_shown" "用途档位已读取。"
}

$profileSource = "saved"
$resolvedUsageProfile = $UsageProfile
if ($resolvedUsageProfile -eq 0 -and -not [string]::IsNullOrWhiteSpace($env:CLAUDE_EASY_USAGE_PROFILE)) {
    $parsedUsageProfile = 0
    if (-not [int]::TryParse($env:CLAUDE_EASY_USAGE_PROFILE, [ref]$parsedUsageProfile)) {
        Complete-InstallResult 64 "invalid_request" "invalid_usage_profile" "用途档位无效，只能是 1、2 或 3。"
    }
    $resolvedUsageProfile = $parsedUsageProfile
    $profileSource = "environment"
} elseif ($resolvedUsageProfile -ne 0) {
    $profileSource = "argument"
}
if ($resolvedUsageProfile -eq 0) {
    $resolvedUsageProfile = $savedUsageProfile
}
if ($resolvedUsageProfile -eq 0) {
    Complete-InstallResult 10 "invalid_request" "usage_profile_required" "还没有选择用途档位。"
}
if ($resolvedUsageProfile -notin @(1, 2, 3)) {
    Complete-InstallResult 64 "invalid_request" "invalid_usage_profile" "用途档位无效，只能是 1、2 或 3。"
}
$script:ClaudeEasyProfile = $resolvedUsageProfile

try {
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $clientRunning = Test-ClashVergeRunning
    $corePath = Find-MihomoCore $MihomoPath
    Test-MihomoVersion $corePath | Out-Null
    $installState = $null
    $stateSnapshot = Get-OptionalFileSnapshot $statePath "安装状态"
    $stateExisted = [bool]$stateSnapshot.Exists
    $stateOriginalBytes = $stateSnapshot.Bytes
    if ($stateExisted) {
        $installState = $strictUtf8.GetString($stateOriginalBytes) | ConvertFrom-Json
        Assert-InstallState $installState
    }
    if (($savedUsageProfile -eq 3 -or ($stateExisted -and $savedUsageProfile -eq 0)) -and
        $resolvedUsageProfile -ne 3) {
        throw "从档位 3 改为轻量档位前，必须先运行安全卸载。"
    }
    if ($clientRunning) {
        $runningCode = if ($resolvedUsageProfile -eq 3) {
            "client_running_profile_three_deferred"
        } else {
            "client_running_auto_update_deferred"
        }
        Complete-InstallResult 1 "partial" $runningCode "客户端正在运行；本次未修改用途档位、自动更新所有权、脚本或客户端配置，请在客户端未运行时按当前档位重试。"
    }
    $profilesIndexSnapshot = Get-OptionalFileSnapshot $profilesIndexPath "profiles.yaml"
    if (-not $profilesIndexSnapshot.Exists) {
        throw "找不到 Clash Verge Rev 的 profiles.yaml，无法自动关闭订阅更新。"
    }
    $profilesIndexOriginalBytes = $profilesIndexSnapshot.Bytes
    $profilesIndexInput = $strictUtf8.GetString($profilesIndexOriginalBytes)
    $currentAutoUpdateOwnership = @(Get-RemoteSubscriptionAutoUpdateOwnership $profilesIndexInput)
    $autoUpdateStateSnapshot = Get-OptionalFileSnapshot $autoUpdateStatePath "订阅自动更新所有权状态"
    if ($autoUpdateStateSnapshot.Exists) {
        $autoUpdateStateExisted = $true
        $autoUpdateStateOriginalBytes = $autoUpdateStateSnapshot.Bytes
        try {
            $existingAutoUpdateState = $strictUtf8.GetString($autoUpdateStateOriginalBytes) | ConvertFrom-Json
        } catch {
            throw "订阅自动更新所有权状态文件无效。"
        }
        $existingAutoUpdateOwnership = @(Assert-RemoteSubscriptionAutoUpdateOwnershipState $existingAutoUpdateState)
    } else {
        $autoUpdateStateExisted = $false
        $autoUpdateStateOriginalBytes = $null
        $existingAutoUpdateOwnership = @()
    }
    $mergedAutoUpdateOwnership = @(
        Merge-RemoteSubscriptionAutoUpdateOwnership $existingAutoUpdateOwnership $currentAutoUpdateOwnership
    )
    $autoUpdateStateTarget = $null
    if ($autoUpdateStateExisted -or $mergedAutoUpdateOwnership.Count -gt 0) {
        $autoUpdateStateBytes = ConvertTo-Utf8Bytes ((([ordered]@{
            Version = 1
            Profiles = $mergedAutoUpdateOwnership
        }) | ConvertTo-Json -Depth 5) + "`r`n")
        $autoUpdateStateTarget = [pscustomobject]@{
            Path = $autoUpdateStatePath
            Bytes = $autoUpdateStateBytes
            Existed = $autoUpdateStateExisted
            OriginalBytes = $autoUpdateStateOriginalBytes
            OriginalIdentity = $autoUpdateStateSnapshot.Identity
        }
    }
    $profilesIndexOutput = Set-RemoteSubscriptionAutoUpdateDisabled $profilesIndexInput
    Assert-RemoteSubscriptionAutoUpdateDisabled $profilesIndexOutput | Out-Null
    $profilesIndexBytes = ConvertTo-Utf8Bytes $profilesIndexOutput

    $scriptSnapshot = Get-OptionalFileSnapshot $targetScript "Script.js"
    $scriptExisted = [bool]$scriptSnapshot.Exists
    $scriptOriginalBytes = $scriptSnapshot.Bytes
    $scriptCurrentText = if ($scriptExisted) { $strictUtf8.GetString($scriptOriginalBytes) } else { $null }
    $scriptOutput = Build-GlobalScript $enginePath $targetScript $resolvedUsageProfile $scriptCurrentText
    $scriptBytes = ConvertTo-Utf8Bytes $scriptOutput
    $managedScriptBytes = ConvertTo-Utf8Bytes (Get-ClaudeEasyManagedScriptEnvelope $scriptOutput $resolvedUsageProfile)
    $usageProfileBytes = ConvertTo-Utf8Bytes ((([ordered]@{
        Version = 2
        Profile = $resolvedUsageProfile
        ManagedScriptSha256 = (Get-BytesSha256 $managedScriptBytes)
    }) | ConvertTo-Json -Compress) + "`r`n")
    $usageProfileTarget = [pscustomobject]@{
        Path = $usageStatePath
        Bytes = $usageProfileBytes
        Existed = [bool]$usageProfileSnapshot.Exists
        OriginalBytes = $usageProfileSnapshot.Bytes
        OriginalIdentity = $usageProfileSnapshot.Identity
    }

    $previousVerge = Get-InstallStateEntry $installState "VergeYaml"
    $previousConfig = Get-InstallStateEntry $installState "ConfigYaml"
    $vergeSnapshot = Get-OptionalFileSnapshot $vergePath "verge.yaml"
    $vergeExisted = [bool]$vergeSnapshot.Exists
    $vergeOriginalBytes = $vergeSnapshot.Bytes
    Assert-StateSnapshotUnchanged $previousVerge $vergeSnapshot "verge.yaml"
    $vergeInput = if ($vergeExisted) { $strictUtf8.GetString($vergeOriginalBytes) } else { "" }
    $vergeOutput = Set-ClaudeEasyReactivationHotkey $vergeInput
    $vergeOutput = Set-YamlTopLevelScalar $vergeOutput "enable_global_hotkey" "true"
    Test-GeneratedYaml $vergeOutput "verge.yaml" | Out-Null
    $configSnapshot = Get-OptionalFileSnapshot $configPath "config.yaml"
    $configExisted = [bool]$configSnapshot.Exists
    $configOriginalBytes = $configSnapshot.Bytes
    Assert-StateSnapshotUnchanged $previousConfig $configSnapshot "config.yaml"
    $vergeBytes = ConvertTo-Utf8Bytes $vergeOutput

    if ($resolvedUsageProfile -ne 3) {
        $scriptTarget = [pscustomobject]@{
            Path = $targetScript
            Bytes = $scriptBytes
            Existed = $scriptExisted
            OriginalBytes = $scriptOriginalBytes
            OriginalIdentity = $scriptSnapshot.Identity
        }
        $lightTargets = @(
            $scriptTarget,
            [pscustomobject]@{
                Path = $profilesIndexPath
                Bytes = $profilesIndexBytes
                Existed = $true
                OriginalBytes = $profilesIndexOriginalBytes
                OriginalIdentity = $profilesIndexSnapshot.Identity
            },
            [pscustomobject]@{
                Path = $vergePath
                Bytes = $vergeBytes
                Existed = $vergeExisted
                OriginalBytes = $vergeOriginalBytes
                OriginalIdentity = $vergeSnapshot.Identity
            }
        )
        if ($null -ne $autoUpdateStateTarget) { $lightTargets += $autoUpdateStateTarget }
        $lightStateObject = [ordered]@{
            Version = 1
            VergeYaml = (New-InstallStateEntry $previousVerge $vergePath $vergeBytes)
            ConfigYaml = (New-InstallStateEntry $previousConfig $configPath $configOriginalBytes)
        }
        $lightStateBytes = ConvertTo-Utf8Bytes (($lightStateObject | ConvertTo-Json -Depth 5) + "`r`n")
        $lightTargets += [pscustomobject]@{
            Path = $statePath
            Bytes = $lightStateBytes
            Existed = $stateExisted
            OriginalBytes = $stateOriginalBytes
            OriginalIdentity = $stateSnapshot.Identity
        }
        $lightTargets += $usageProfileTarget
        foreach ($target in $lightTargets) {
            if ($target.Path -in @($usageStatePath, $autoUpdateStatePath)) { continue }
            Backup-InitialOnce $target.Path $backupRoot | Out-Null
            Backup-Versioned $target.Path $backupRoot "prewrite" | Out-Null
        }
        $lightCommitted = Invoke-VerifiedFileTransaction $lightTargets $clientStoppedPreCommit
        if (-not $lightCommitted) {
            throw "检测到 Clash Verge Rev 在安装期间启动；已撤销本次文件修改。"
        }
        if ($profileSource -ne "saved") { Write-Info "已保存用途档位 $resolvedUsageProfile。" }
        Write-Info "已为全部订阅安装共享国内域名直连规则、自动重新加载入口，并关闭全部远程订阅的自动更新；未修改 TUN 或 IPv6。"
        Complete-InstallResult 0 "ok" "installed_common_baseline" "已安装全部订阅共用的国内域名直连规则、更新加载入口，并关闭订阅自动更新。" @("global_script", "subscription_reactivation", "cn_domain_baseline", "auto_update")
    }
    $vergeOutput = Set-YamlTopLevelScalar $vergeOutput "enable_tun_mode" "true"
    $vergeOutput = Set-YamlTopLevelScalar $vergeOutput "enable_dns_settings" "false"
    $configInput = if ($configExisted) { $strictUtf8.GetString($configOriginalBytes) } else { "" }
    $configOutput = Set-YamlTopLevelScalar $configInput "ipv6" "false"
    $configOutput = Set-YamlTunMapping $configOutput

    Test-GeneratedYaml $vergeOutput "verge.yaml" | Out-Null
    Test-GeneratedYaml $configOutput "config.yaml" | Out-Null
    Test-MihomoCandidate $corePath $configOutput $AppHome

    $vergeBytes = ConvertTo-Utf8Bytes $vergeOutput
    $configBytes = ConvertTo-Utf8Bytes $configOutput
    $stateObject = [ordered]@{
        Version = 1
        VergeYaml = (New-InstallStateEntry $previousVerge $vergePath $vergeBytes)
        ConfigYaml = (New-InstallStateEntry $previousConfig $configPath $configBytes)
    }
    $stateBytes = ConvertTo-Utf8Bytes (($stateObject | ConvertTo-Json -Depth 5) + "`r`n")

    $targets = @(
        [pscustomobject]@{ Path = $targetScript; Bytes = $scriptBytes; Existed = $scriptExisted; OriginalBytes = $scriptOriginalBytes; OriginalIdentity = $scriptSnapshot.Identity },
        [pscustomobject]@{ Path = $profilesIndexPath; Bytes = $profilesIndexBytes; Existed = $true; OriginalBytes = $profilesIndexOriginalBytes; OriginalIdentity = $profilesIndexSnapshot.Identity },
        [pscustomobject]@{ Path = $vergePath; Bytes = $vergeBytes; Existed = $vergeExisted; OriginalBytes = $vergeOriginalBytes; OriginalIdentity = $vergeSnapshot.Identity },
        [pscustomobject]@{ Path = $configPath; Bytes = $configBytes; Existed = $configExisted; OriginalBytes = $configOriginalBytes; OriginalIdentity = $configSnapshot.Identity },
        [pscustomobject]@{ Path = $statePath; Bytes = $stateBytes; Existed = $stateExisted; OriginalBytes = $stateOriginalBytes; OriginalIdentity = $stateSnapshot.Identity }
    )
    if ($null -ne $autoUpdateStateTarget) { $targets += $autoUpdateStateTarget }
    $targets += $usageProfileTarget
    foreach ($target in $targets) {
        if ($target.Path -in @($usageStatePath, $autoUpdateStatePath)) { continue }
        Backup-InitialOnce $target.Path $backupRoot | Out-Null
        Backup-Versioned $target.Path $backupRoot "prewrite" | Out-Null
    }

    if (Test-ClashVergeRunning) { throw "检测到 Clash Verge Rev 在安装期间启动；已撤销本次文件修改。" }
    $installCommitted = Invoke-VerifiedFileTransaction $targets $clientStoppedPreCommit
    if (-not $installCommitted) {
        throw "检测到 Clash Verge Rev 在安装期间启动；已撤销本次文件修改。"
    }

    if ($null -ne $usageProfileTarget) { Write-Info "已保存用途档位 $resolvedUsageProfile。" }
    Write-Info "已安装全局扩展脚本，之后每次加载或刷新订阅都会自动应用补丁。"
    Write-Info "已自动关闭全部远程订阅的自动更新，并回读确认 profiles.yaml。"
    Write-Info "已开启 TUN，并让全局脚本接管 DNS 配置。下次订阅刷新时应用补丁。"
    Write-Info "安装程序从未退出、停止或重启 Clash Verge Rev。"
    Write-Info "已有 AI 分组只补全规则；没有时创建包含全部可用节点和代理提供者的独立选择器。安装程序不会替你选择节点。"
    Complete-InstallResult 0 "ok" "installed" "Windows ClaudeEasy 已安装。" @("global_script", "subscription_reactivation", "auto_update", "tun", "dns", "ipv6")
    exit 0
} catch {
    Complete-InstallResult 1 $(if ($_.Exception.Message -match "已恢复") { "rolled_back" } else { "failed" }) "install_failed" ("安装失败：" + $_.Exception.Message)
}
} finally {
    Exit-AppHomeMutationLock $mutationLock
}
