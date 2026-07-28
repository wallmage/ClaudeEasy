param(
    [string]$AppHome = "",
    [string]$MihomoPath = "",
    [int]$UsageProfile = 0,
    [switch]$ShowUsageProfile,
    [switch]$SnapshotProfiles,
    [switch]$VerifySafeUpdate,
    [switch]$ListBackups,
    [string]$CompareBackup = "",
    [string]$RestoreBackup = "",
    [string]$ExpectedCurrentSha256 = "",
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$resultContractPath = Join-Path (Join-Path $PSScriptRoot "windows") "result_contract.ps1"
if (-not (Test-Path -LiteralPath $resultContractPath -PathType Leaf)) {
    if ($Json) {
        [Console]::Out.WriteLine('{"schema":"claude-easy.result","version":1,"command":"install","platform":"windows","client":"clash-verge-rev","operation":"load","ok":false,"status":"failed","code":"incomplete_package","exit_code":6,"summary_zh":"安装包不完整。","profile":null,"changes":[],"checks":[],"items":[],"messages":[],"warnings":[]}')
    } else {
        [Console]::Error.WriteLine("[ClaudeEasy] 安装包不完整。")
    }
    exit 6
}
. $resultContractPath
$script:ClaudeEasyMessages = New-Object System.Collections.ArrayList
$script:ClaudeEasyOperation = if ($SnapshotProfiles) { "snapshot_profiles" } elseif ($VerifySafeUpdate) { "verify_safe_update" } elseif ($ListBackups) { "list_backups" } elseif (-not [string]::IsNullOrWhiteSpace($CompareBackup)) { "compare_backup" } elseif (-not [string]::IsNullOrWhiteSpace($RestoreBackup)) { "restore_backup" } elseif ($ShowUsageProfile) { "show_usage_profile" } else { "install" }
$script:ClaudeEasyProfile = $null

$installerModuleRoot = Join-Path (Join-Path $PSScriptRoot "windows") "install_windows"
$installerModules = @(
    "common.ps1",
    "yaml.ps1",
    "profiles.ps1",
    "mihomo.ps1",
    "transaction.ps1",
    "script_js.ps1",
    "safe_update.ps1"
)
try {
    foreach ($installerModule in $installerModules) {
        $installerModulePath = Join-Path $installerModuleRoot $installerModule
        if (-not (Test-Path -LiteralPath $installerModulePath -PathType Leaf)) {
            throw "安装包不完整：缺少 Windows 安装模块。"
        }
        . $installerModulePath
    }
} catch {
    if ($Json) {
        Write-ClaudeEasyResult (New-ClaudeEasyResult -Command "install" -Operation "load" -Ok $false -Status "failed" -Code "incomplete_package" -ExitCode 6 -SummaryZh "安装包不完整。")
    } else {
        [Console]::Error.WriteLine("[ClaudeEasy] 安装包不完整。")
    }
    exit 6
}

if ([string]::IsNullOrWhiteSpace($AppHome)) {
    try {
        $AppHome = Resolve-ClashVergeAppHome
    } catch {
        if (-not $Json) { [Console]::Error.WriteLine("[ClaudeEasy] $($_.Exception.Message)") }
        Complete-InstallResult 2 "invalid_request" "ambiguous_app_home" "检测到多个 Clash Verge Rev 配置目录；未执行任何操作。"
    }
}
if (-not [string]::IsNullOrWhiteSpace($AppHome)) {
    $AppHome = ConvertTo-NormalizedWindowsPath $AppHome
}

if ([string]::IsNullOrWhiteSpace($AppHome) -or -not (Test-Path -LiteralPath $AppHome -PathType Container)) {
    if (-not $Json) { [Console]::Error.WriteLine("[ClaudeEasy] 没有找到受支持的 Clash Verge Rev。请安装最新版 Clash Verge Rev，打开一次后再运行 ClaudeEasy。") }
    Complete-InstallResult 2 "unsupported" "client_not_found" "没有找到受支持的 Clash Verge Rev。"
    exit 2
}

$requestedOperations = @(
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

# Clash Verge Rev 的全局扩展脚本位置：profiles/Script.js。
$profilesDirectory = Join-Path $AppHome "profiles"
$backupRoot = Join-Path $AppHome "claude-easy-backups"
$profilesIndexPath = Join-Path $AppHome "profiles.yaml"
$vergePath = Join-Path $AppHome "verge.yaml"
$configPath = Join-Path $AppHome "config.yaml"
$statePath = Join-Path $AppHome "claude-easy-install-state.json"
$autoUpdateStatePath = Join-Path $AppHome "claude-easy-auto-update-state.json"
$usageStatePath = Join-Path $AppHome "claude-easy-usage-profile.json"
$safeUpdateStatePath = Join-Path $AppHome "claude-easy-safe-update.json"
$targetScript = Join-Path $profilesDirectory "Script.js"
$enginePath = Join-Path (Join-Path $PSScriptRoot "windows") "clash_verge_global.js"

$mutationLock = $null
try {
    $mutationLock = Enter-AppHomeMutationLock $AppHome
} catch {
    $lockMessage = $_.Exception.Message
    if ($lockMessage -eq "客户端保持运行；中断的当前配置事务等待恢复。") {
        Complete-InstallResult 1 "partial" "transaction_recovery_pending" "客户端保持运行；中断的当前配置事务仍在等待安全恢复，请稍后重试。"
    }
    if ($lockMessage -eq "同一配置目录已有 ClaudeEasy 操作正在进行，请稍后重试。") {
        Complete-InstallResult 1 "failed" "operation_in_progress" $lockMessage
    }
    Complete-InstallResult 1 "failed" "state_recovery_failed" $lockMessage
}
$clientStoppedPreCommit = {
    return (-not (Test-ClashVergeRunning))
}

try {
try {
if ($SnapshotProfiles) {
    $newManifestSnapshot = Get-OptionalFileSnapshot $safeUpdateStatePath "安全更新准备记录"
    if ($newManifestSnapshot.Exists) {
        throw "发现尚未验收的安全更新；请先运行 -VerifySafeUpdate，不能覆盖更新前清单。"
    }
    if (-not (Test-Path -LiteralPath $profilesIndexPath -PathType Leaf)) { throw "找不到远程订阅清单。" }
    $snapshotContext = $null
    try {
        $core = Find-MihomoCore $MihomoPath
        $snapshotContext = New-SafeUpdateSnapshotContext `
            $profilesIndexPath `
            $profilesDirectory `
            $core
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
        $manifest = [ordered]@{ Version = 2; CreatedAt = [DateTimeOffset]::Now.ToString("o"); Profiles = $manifestItems }
        $manifestBytes = ConvertTo-Utf8Bytes (($manifest | ConvertTo-Json -Depth 5) + "`r`n")
        Invoke-VerifiedFileTransaction @(
            [pscustomobject]@{
                Path = $safeUpdateStatePath
                Bytes = $manifestBytes
                Existed = $false
                OriginalBytes = $null
                OriginalIdentity = $null
            }
        )
    } finally {
        if ($null -ne $snapshotContext) {
            foreach ($guard in @($snapshotContext.Guards)) { $guard.Dispose() }
        }
    }
    Write-Info "已核对远程清单，并为 $($profiles.Count) 份订阅创建安全更新前备份。"
    foreach ($profile in $profiles) { Write-Info ("待更新：" + $(if ([string]::IsNullOrWhiteSpace($profile.Name)) { $profile.Uid } else { $profile.Name })) }
    Complete-InstallResult 0 "ok" "snapshot_created" "已创建全部远程订阅的安全更新前备份。" @("profile_backups")
}

if ($VerifySafeUpdate) {
    $manifestSnapshot = Get-OptionalFileSnapshot $safeUpdateStatePath "安全更新准备记录"
    if (-not $manifestSnapshot.Exists) { throw "没有找到本次安全更新的准备记录。" }
    $manifestText = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($manifestSnapshot.Bytes)
    $manifest = $manifestText | ConvertFrom-Json
    $manifestProperties = @($manifest.PSObject.Properties.Name | Sort-Object)
    $createdAtIsJsonString = [regex]::Matches(
        $manifestText,
        '(?i)"CreatedAt"\s*:\s*"(?:[^"\\]|\\.)*"'
    ).Count -eq 1
    if (($manifestProperties -join ",") -cne "CreatedAt,Profiles,Version" -or
        -not ($manifest.Version -is [int] -or $manifest.Version -is [long]) -or
        [long]$manifest.Version -notin @(1, 2) -or
        -not $createdAtIsJsonString -or
        @($manifest.Profiles).Count -eq 0) {
        throw "安全更新准备记录无效。"
    }
    $recoveryItems = @(Get-SafeUpdateRecoveryItems $manifest $profilesDirectory $backupRoot)
    $validated = @()
    $observedCurrentHashes = @{}
    $legacySnapshotRetirement = $false
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
        $refreshPending = @()
        foreach ($recovery in $recoveryItems) {
            $target = @($currentTargets | Where-Object {
                [string]::Equals(
                    [string]$_.Uid,
                    [string]$recovery.Uid,
                    [StringComparison]::Ordinal
                )
            })
            if ($target.Count -ne 1 -or
                -not (Test-SafeUpdateRefreshEvidence `
                    ([string]$recovery.BeforeSha256) `
                    ([string]$observedCurrentHashes[$recovery.TargetPath]) `
                    ([string]$recovery.BeforeUpdated) `
                    ([string]$target[0].Updated) `
                    ([bool]$recovery.UseUpdatedEvidence))) {
                $refreshPending += $recovery.Uid
            }
        }
        if ($refreshPending.Count -gt 0) {
            if (@($recoveryItems | Where-Object { $_.CanAutoRestore }).Count -eq 0) {
                $legacySnapshotRetirement = $true
            } else {
                Complete-InstallResult 1 "partial" "safe_update_refresh_pending" "仍有远程订阅缺少本轮刷新凭据；安全更新清单和订阅文件保持不变，请在客户端完成全部更新后重试验收。" @() @("refresh_evidence")
            }
        }
        $savedProfile = Get-SavedUsageProfile $usageStatePath
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
                $validatedBytes = [System.IO.File]::ReadAllBytes($target[0].Path)
                $validatedHash = Get-BytesSha256 $validatedBytes
                $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($validatedBytes)
                Test-GeneratedYaml $text ([string]$item.File) | Out-Null
                Assert-ClaudeEasyProxyGroupCollection $text ([string]$item.File)
                Test-MihomoCandidate $core $text $profilesDirectory
                if ((Get-FileSha256 $target[0].Path) -ne $validatedHash) {
                    throw "订阅在验收期间再次发生变化。"
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
        $versionGuards = @()
        try {
            foreach ($entry in @($validated | Sort-Object { $_.Target.Path })) {
                $guard = [System.IO.File]::Open(
                    $entry.Target.Path,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::Read
                )
                $versionGuards += $guard
                if ((Get-BytesSha256 (Get-StreamBytes $guard)) -ne $entry.ValidatedSha256) {
                    throw "订阅在验收期间再次发生变化。"
                }
            }
            $indexGuard = [System.IO.File]::Open(
                $profilesIndexPath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::Read
            )
            $versionGuards += $indexGuard
            if ((Get-BytesSha256 (Get-StreamBytes $indexGuard)) -ne (Get-BytesSha256 $indexSnapshot.Bytes)) {
                throw "远程订阅清单在验收期间发生变化。"
            }
            $scriptGuard = [System.IO.File]::Open(
                $targetScript,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::Read
            )
            $versionGuards += $scriptGuard
            if ((Get-BytesSha256 (Get-StreamBytes $scriptGuard)) -ne (Get-BytesSha256 $scriptSnapshot.Bytes)) {
                throw "全局扩展脚本在验收期间发生变化。"
            }
            Remove-VerifiedOwnedFile $safeUpdateStatePath $manifestSnapshot.Bytes $manifestSnapshot.Identity
        } finally {
            foreach ($guard in $versionGuards) { $guard.Dispose() }
        }
    } catch {
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
                [pscustomobject]@{ Path = $profilesIndexPath; Snapshot = $indexSnapshot },
                [pscustomobject]@{ Path = $targetScript; Snapshot = $scriptSnapshot }
            )) {
                $controlGuard = [System.IO.File]::Open(
                    $control.Path,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::Read
                )
                $controlGuards += $controlGuard
                if ((Get-BytesSha256 (Get-StreamBytes $controlGuard)) -ne
                    (Get-BytesSha256 $control.Snapshot.Bytes)) {
                    throw "安全更新恢复所需的控制文件在验收期间变化。"
                }
            }
        } catch {
            $controlStateStable = $false
        }
        if (-not $controlStateStable) {
            foreach ($controlGuard in $controlGuards) { $controlGuard.Dispose() }
            Complete-InstallResult 1 "partial" "safe_update_verification_retry_pending" "验收依赖的清单、脚本或状态在检查期间变化；已保留当前订阅和安全更新清单，请待客户端写入完成后重试。" @() @("verification_state")
        }
        try {
            $restoreResult = Restore-SafeUpdateFiles $recoveryItems $observedCurrentHashes $safeUpdateStatePath $manifestSnapshot
        } finally {
            foreach ($controlGuard in $controlGuards) { $controlGuard.Dispose() }
        }
        if ($restoreResult.Conflicts.Count -gt 0) {
            throw "更新验收失败；检测到订阅同时发生变化，未覆盖新内容：$($restoreResult.Conflicts -join '、')。安全更新记录已保留。"
        }
        if ($restoreResult.Failures.Count -gt 0) { throw "更新验收失败，且部分订阅未能恢复：$($restoreResult.Failures -join '、')。安全更新记录已保留。" }
        throw "更新验收失败，全部订阅文件已恢复到更新前版本。"
    }
    foreach ($entry in $validated) {
        $changed = (Get-FileSha256 $entry.Target.Path) -ne [string]$entry.Manifest.BeforeSha256
        Write-Info ($(if ($changed) { "已更新并通过检查：" } else { "内容未变化并通过检查：" }) + $(if ([string]::IsNullOrWhiteSpace($entry.Target.Name)) { $entry.Target.Uid } else { $entry.Target.Name }))
    }
    Write-Info "全部远程订阅已逐份通过全局脚本、代理组、YAML 与 Mihomo 检查。"
    if ($legacySnapshotRetirement) {
        Complete-InstallResult 1 "partial" "safe_update_legacy_snapshot_required" "当前订阅已通过检查，旧版安全更新记录已安全结束；请重新创建 v2 快照后再更新。" @() @("legacy_manifest_retired")
    }
    Complete-InstallResult 0 "ok" "safe_update_verified" "全部远程订阅已逐份通过检查。" @() @("global_script", "yaml", "mihomo", "auto_update")
}

if ($ListBackups) {
    $backupItems = @()
    if (Test-Path -LiteralPath $backupRoot -PathType Container) {
        Get-ChildItem -LiteralPath $backupRoot -File -Filter "*.backup" | Sort-Object Name -Descending | ForEach-Object {
            if ($Json) { $backupItems += $_.Name } else { $_.Name }
        }
    }
    $backupStatus = if ($backupItems.Count -eq 0) { "no_change" } else { "ok" }
    Complete-InstallResult 0 $backupStatus "backups_listed" "备份清单已读取。" @() @() $backupItems
}

if (-not [string]::IsNullOrWhiteSpace($CompareBackup)) {
    $resolved = Get-BackupTarget $CompareBackup
    $backupHash = (Get-FileHash -LiteralPath $resolved.BackupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $currentHash = (Get-FileHash -LiteralPath $resolved.TargetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $same = ($backupHash -eq $currentHash)
    $changedFields = @()
    if (-not $same) {
        if ([System.IO.Path]::GetExtension($resolved.TargetPath) -match '^\.ya?ml$') {
            $backupText = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($resolved.BackupPath))
            $currentText = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($resolved.TargetPath))
            $changedFields = @(Get-RedactedYamlChangedPaths $backupText $currentText)
        } else {
            $changedFields = @("文件内容")
        }
    }
    $comparison = [pscustomobject]@{
        Backup = $CompareBackup
        Profile = (Split-Path -Leaf $resolved.TargetPath)
        Same = $same
        BackupSha256 = $backupHash
        CurrentSha256 = $currentHash
        ChangedFields = $changedFields
        ConfigurationDifference = $(if ($same) { "无配置差异" } else { "存在配置差异；为保护隐私只输出发生变化的字段名" })
    }
    if (-not $Json) { $comparison | ConvertTo-Json }
    Complete-InstallResult 0 $(if ($same) { "no_change" } else { "ok" }) "backup_compared" "备份比较已完成。" @($changedFields) @($comparison)
}

if (-not [string]::IsNullOrWhiteSpace($RestoreBackup)) {
    if (Test-ClashVergeRunning) { throw "Clash Verge Rev 正在运行，不能安全恢复配置；未修改任何文件。" }
    if ($ExpectedCurrentSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "恢复时必须提供预期 SHA-256。" }
    $resolved = Get-BackupTarget $RestoreBackup
    $currentSnapshot = Get-OptionalFileSnapshot $resolved.TargetPath "当前配置"
    if (-not $currentSnapshot.Exists) { throw "当前配置不存在，拒绝恢复。" }
    $currentHash = Get-BytesSha256 $currentSnapshot.Bytes
    if ($currentHash -ne $ExpectedCurrentSha256.ToLowerInvariant()) { throw "当前配置已变化，拒绝覆盖。" }
    $restoreBytes = [System.IO.File]::ReadAllBytes($resolved.BackupPath)
    Test-RestoreCandidate $resolved.TargetPath $restoreBytes
    $validatedCurrentSnapshot = Get-OptionalFileSnapshot $resolved.TargetPath "当前配置"
    if (-not $validatedCurrentSnapshot.Exists -or
        $validatedCurrentSnapshot.Identity -cne $currentSnapshot.Identity -or
        (Get-BytesSha256 $validatedCurrentSnapshot.Bytes) -ne $currentHash) {
        throw "当前配置在检查期间发生变化，拒绝覆盖。"
    }
    Backup-Versioned $resolved.TargetPath $backupRoot "pre-restore" | Out-Null
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
    if ($Json) {
        $operationStatus = if ($_.Exception.Message -match "已恢复") { "rolled_back" } else { "failed" }
        Complete-InstallResult 1 $operationStatus "operation_failed" ("操作失败：" + $_.Exception.Message)
    }
    throw
}
try {
    $savedUsageProfile = Get-SavedUsageProfile $usageStatePath
} catch {
    if (-not $Json) { [Console]::Error.WriteLine("[ClaudeEasy] $($_.Exception.Message)") }
    Complete-InstallResult 1 "failed" "usage_profile_read_failed" ("读取用途档位失败：" + $_.Exception.Message)
}

if ($ShowUsageProfile) {
    if ($savedUsageProfile -ne 0) { $script:ClaudeEasyProfile = $savedUsageProfile }
    if (-not $Json) { if ($savedUsageProfile -eq 0) { Write-Output "unset" } else { Write-Output $savedUsageProfile } }
    Complete-InstallResult 0 "ok" "usage_profile_shown" "用途档位已读取。"
}

$profileSource = "saved"
$resolvedUsageProfile = $UsageProfile
if ($resolvedUsageProfile -eq 0 -and -not [string]::IsNullOrWhiteSpace($env:CLAUDE_EASY_USAGE_PROFILE)) {
    $parsedUsageProfile = 0
    if (-not [int]::TryParse($env:CLAUDE_EASY_USAGE_PROFILE, [ref]$parsedUsageProfile)) {
        if (-not $Json) { [Console]::Error.WriteLine("[ClaudeEasy] 用途档位无效，只能是 1、2 或 3。") }
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
    if (-not $Json) { [Console]::Error.WriteLine("[ClaudeEasy] 还没有选择用途档位。请先在 skill 中选择：1 普通浏览、2 海外 AI、3 Claude/Claude Code。") }
    Complete-InstallResult 10 "invalid_request" "usage_profile_required" "还没有选择用途档位。"
}
if ($resolvedUsageProfile -notin @(1, 2, 3)) {
    if (-not $Json) { [Console]::Error.WriteLine("[ClaudeEasy] 用途档位无效，只能是 1、2 或 3。") }
    Complete-InstallResult 64 "invalid_request" "invalid_usage_profile" "用途档位无效，只能是 1、2 或 3。"
}
$script:ClaudeEasyProfile = $resolvedUsageProfile

if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
    if (-not $Json) { [Console]::Error.WriteLine("[ClaudeEasy] 安装包不完整：缺少 Windows 全局扩展脚本。") }
    Complete-InstallResult 3 "failed" "package_incomplete" "安装包不完整：缺少 Windows 全局扩展脚本。"
    exit 3
}

try {
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $clientRunning = Test-ClashVergeRunning
    $corePath = Find-MihomoCore $MihomoPath
    Test-MihomoVersion $corePath | Out-Null
    if ($savedUsageProfile -eq 3 -and $resolvedUsageProfile -ne 3 -and $profileSource -ne "saved") {
        throw "从档位 3 改为轻量档位前，必须先运行安全卸载。"
    }
    if ($clientRunning) {
        $runningCode = if ($resolvedUsageProfile -eq 3) {
            "client_running_profile_three_deferred"
        } else {
            "client_running_auto_update_deferred"
        }
        if (-not $Json) {
            [Console]::Error.WriteLine(
                "[ClaudeEasy] Clash Verge Rev 正在运行；为避免客户端内存状态覆盖 profiles.yaml，本次未修改用途档位、自动更新所有权、脚本或客户端配置。请在客户端未运行时按当前档位重试。"
            )
        }
        Complete-InstallResult 1 "partial" $runningCode "客户端正在运行；本次未修改用途档位、自动更新所有权、脚本或客户端配置，请在客户端未运行时按当前档位重试。"
    }
    $usageProfileTarget = $null
    if ($profileSource -ne "saved") {
        $usageProfileSnapshot = Get-OptionalFileSnapshot $usageStatePath "用途档位状态"
        $usageProfileBytes = ConvertTo-Utf8Bytes ((([ordered]@{
            Version = 1
            Profile = $resolvedUsageProfile
        }) | ConvertTo-Json -Compress) + "`r`n")
        $usageProfileTarget = [pscustomobject]@{
            Path = $usageStatePath
            Bytes = $usageProfileBytes
            Existed = [bool]$usageProfileSnapshot.Exists
            OriginalBytes = $usageProfileSnapshot.Bytes
            OriginalIdentity = $usageProfileSnapshot.Identity
        }
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

    if ($resolvedUsageProfile -ne 3) {
        $scriptSnapshot = Get-OptionalFileSnapshot $targetScript "Script.js"
        $scriptExisted = [bool]$scriptSnapshot.Exists
        $scriptOriginalBytes = $scriptSnapshot.Bytes
        $scriptCurrentText = if ($scriptExisted) { $strictUtf8.GetString($scriptOriginalBytes) } else { $null }
        $scriptOutput = Build-GlobalScript $enginePath $targetScript $resolvedUsageProfile $scriptCurrentText
        $scriptBytes = ConvertTo-Utf8Bytes $scriptOutput
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
            }
        )
        if ($null -ne $autoUpdateStateTarget) { $lightTargets += $autoUpdateStateTarget }
        if ($null -ne $usageProfileTarget) { $lightTargets += $usageProfileTarget }
        foreach ($target in $lightTargets) {
            if ($target.Path -in @($usageStatePath, $autoUpdateStatePath)) { continue }
            Backup-InitialOnce $target.Path $backupRoot | Out-Null
            Backup-Versioned $target.Path $backupRoot "prewrite" | Out-Null
        }
        $lightCommitted = Invoke-VerifiedFileTransaction $lightTargets $clientStoppedPreCommit
        if (-not $lightCommitted) {
            throw "检测到 Clash Verge Rev 在安装期间启动；已撤销本次文件修改。"
        }
        if ($null -ne $usageProfileTarget) { Write-Info "已保存用途档位 $resolvedUsageProfile。" }
        Write-Info "已为全部订阅安装共享国内域名直连规则，并关闭全部远程订阅的自动更新；未修改 TUN 或 IPv6。"
        Complete-InstallResult 0 "ok" "installed_common_baseline" "已安装全部订阅共用的国内域名直连规则，并关闭订阅自动更新。" @("global_script", "cn_domain_baseline", "auto_update")
    }

    $installState = $null
    $stateSnapshot = Get-OptionalFileSnapshot $statePath "安装状态"
    $stateExisted = [bool]$stateSnapshot.Exists
    $stateOriginalBytes = $stateSnapshot.Bytes
    if ($stateExisted) {
        $installState = $strictUtf8.GetString($stateOriginalBytes) | ConvertFrom-Json
        Assert-InstallState $installState
    }
    $previousVerge = Get-InstallStateEntry $installState "VergeYaml"
    $previousConfig = Get-InstallStateEntry $installState "ConfigYaml"

    $scriptSnapshot = Get-OptionalFileSnapshot $targetScript "Script.js"
    $scriptExisted = [bool]$scriptSnapshot.Exists
    $scriptOriginalBytes = $scriptSnapshot.Bytes
    $scriptCurrentText = if ($scriptExisted) { $strictUtf8.GetString($scriptOriginalBytes) } else { $null }
    $scriptOutput = Build-GlobalScript $enginePath $targetScript $resolvedUsageProfile $scriptCurrentText
    $vergeSnapshot = Get-OptionalFileSnapshot $vergePath "verge.yaml"
    $vergeExisted = [bool]$vergeSnapshot.Exists
    $vergeOriginalBytes = $vergeSnapshot.Bytes
    Assert-StateSnapshotUnchanged $previousVerge $vergeSnapshot "verge.yaml"
    $vergeInput = if ($vergeExisted) { $strictUtf8.GetString($vergeOriginalBytes) } else { "" }
    $vergeOutput = Set-YamlTopLevelScalar $vergeInput "enable_tun_mode" "true"
    $vergeOutput = Set-YamlTopLevelScalar $vergeOutput "enable_dns_settings" "false"
    $configSnapshot = Get-OptionalFileSnapshot $configPath "config.yaml"
    $configExisted = [bool]$configSnapshot.Exists
    $configOriginalBytes = $configSnapshot.Bytes
    Assert-StateSnapshotUnchanged $previousConfig $configSnapshot "config.yaml"
    $configInput = if ($configExisted) { $strictUtf8.GetString($configOriginalBytes) } else { "" }
    $configOutput = Set-YamlTopLevelScalar $configInput "ipv6" "false"
    $configOutput = Set-YamlTunMapping $configOutput

    Test-GeneratedYaml $vergeOutput "verge.yaml" | Out-Null
    Test-GeneratedYaml $configOutput "config.yaml" | Out-Null
    Test-MihomoCandidate $corePath $configOutput $AppHome

    $scriptBytes = ConvertTo-Utf8Bytes $scriptOutput
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
    if ($null -ne $usageProfileTarget) { $targets += $usageProfileTarget }
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
    Complete-InstallResult 0 "ok" "installed" "Windows ClaudeEasy 已安装。" @("global_script", "auto_update", "tun", "dns", "ipv6")
    exit 0
} catch {
    if (-not $Json) { [Console]::Error.WriteLine("[ClaudeEasy] 安装失败：$($_.Exception.Message)") }
    Complete-InstallResult 1 $(if ($_.Exception.Message -match "已撤销|恢复") { "rolled_back" } else { "failed" }) "install_failed" ("安装失败：" + $_.Exception.Message)
    exit 1
}
} finally {
    Exit-AppHomeMutationLock $mutationLock
}
