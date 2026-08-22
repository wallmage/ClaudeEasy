param(
    [string]$AppHome = "",
    [switch]$Json
)

$unboundArguments = @($args)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$ErrorActionPreference = "Stop"
$resultContractPath = Join-Path (Join-Path $PSScriptRoot "windows") "result_contract.ps1"
$uninstallerModuleRoot = Join-Path (Join-Path $PSScriptRoot "windows") "install_windows"
$enginePath = Join-Path (Join-Path $PSScriptRoot "windows") "clash_verge_global.js"
$uninstallerModules = @("yaml.ps1", "profiles.ps1", "transaction.ps1", "script_js.ps1", "safe_update.ps1")
$packageComplete = (Test-Path -LiteralPath $resultContractPath -PathType Leaf) -and
    (Test-Path -LiteralPath $enginePath -PathType Leaf)
foreach ($uninstallerModule in $uninstallerModules) {
    if (-not (Test-Path -LiteralPath (Join-Path $uninstallerModuleRoot $uninstallerModule) -PathType Leaf)) {
        $packageComplete = $false
    }
}
if (-not $packageComplete) {
    if ($Json) {
        [Console]::Out.WriteLine('{"schema":"claude-easy.result","version":1,"command":"uninstall","platform":"windows","client":"clash-verge-rev","operation":"load","ok":false,"status":"failed","code":"incomplete_package","exit_code":6,"summary_zh":"安装包不完整。","profile":null,"changes":[],"checks":[],"items":[],"messages":[],"warnings":[]}')
    } else {
        [Console]::Error.WriteLine("[ClaudeEasy] 安装包不完整。")
    }
    exit 6
}
$resultContractLoaded = $false
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
if (-not $resultContractLoaded) {
    if ($Json) {
        [Console]::Out.WriteLine('{"schema":"claude-easy.result","version":1,"command":"uninstall","platform":"windows","client":"clash-verge-rev","operation":"load","ok":false,"status":"failed","code":"incomplete_package","exit_code":6,"summary_zh":"安装包不完整。","profile":null,"changes":[],"checks":[],"items":[],"messages":[],"warnings":[]}')
    } else {
        [Console]::Error.WriteLine("[ClaudeEasy] 安装包不完整。")
    }
    exit 6
}
try {
    foreach ($uninstallerModule in $uninstallerModules) {
        $null = . (Join-Path $uninstallerModuleRoot $uninstallerModule)
    }
    foreach ($requiredUninstallerFunction in @(
        "Resolve-ClashVergeAppHome", "ConvertTo-NormalizedWindowsPath", "Enter-AppHomeMutationLock", "Exit-AppHomeMutationLock",
        "Get-OptionalFileSnapshot", "ConvertTo-Utf8Bytes", "Get-BytesSha256", "Backup-Versioned", "Invoke-VerifiedWriteDeleteTransaction",
        "Assert-InstallState", "Get-JavaScriptAnalysis", "Rename-JavaScriptMain", "Assert-JavaScriptCanCompose",
        "Get-ClaudeEasyManagedScriptEnvelope", "Assert-ClaudeEasyManagedScriptCurrent",
        "Assert-RemoteSubscriptionAutoUpdateOwnershipState", "Restore-RemoteSubscriptionAutoUpdate"
    )) {
        if ($null -eq (Get-Command $requiredUninstallerFunction -CommandType Function -ErrorAction SilentlyContinue)) {
            throw "安装包不完整：卸载模块缺少必要接口。"
        }
    }
} catch {
    if ($Json) {
        [Console]::Out.WriteLine('{"schema":"claude-easy.result","version":1,"command":"uninstall","platform":"windows","client":"clash-verge-rev","operation":"load","ok":false,"status":"failed","code":"incomplete_package","exit_code":6,"summary_zh":"安装包不完整。","profile":null,"changes":[],"checks":[],"items":[],"messages":[],"warnings":[]}')
    } else {
        [Console]::Error.WriteLine("[ClaudeEasy] 安装包不完整。")
    }
    exit 6
}
$script:ClaudeEasyMessages = New-Object System.Collections.ArrayList

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

function Complete-UninstallResult(
    [int]$ExitCode,
    [string]$Status,
    [string]$Code,
    [string]$SummaryZh,
    [object[]]$Changes = @(),
    [object[]]$Warnings = @()
) {
    if ($Json) {
        $result = New-ClaudeEasyResult -Command "uninstall" -Operation "uninstall" -Ok ($ExitCode -eq 0) -Status $Status -Code $Code -ExitCode $ExitCode -SummaryZh $SummaryZh -Changes $Changes -Messages @($script:ClaudeEasyMessages) -Warnings $Warnings
        Write-ClaudeEasyResult $result
    } elseif ($ExitCode -eq 0) {
        Write-ClaudeEasyHumanText "[ClaudeEasy] $SummaryZh"
    } else {
        Write-ClaudeEasyHumanText "[ClaudeEasy] $SummaryZh" -ErrorStream
    }
    exit $ExitCode
}

if ($unboundArguments.Count -gt 0) {
    Complete-UninstallResult 64 "invalid_request" "invalid_arguments" "参数错误；未执行任何修改。"
}

function Complete-RunningClientUninstall {
    Write-Info "客户端保持运行；安全卸载按安全边界延期，本次没有修改任何受保护文件或状态，已生成的安全备份继续保留。"
    Complete-UninstallResult 1 "partial" "client_running" "客户端保持运行；安全卸载按安全边界延期，本次未修改受保护文件或状态。"
}

function Complete-PendingSafeUpdateUninstall {
    Write-Info "发现尚未验收的安全更新；本次没有修改任何文件。请先完成安全更新验收或恢复，再重试卸载。"
    Complete-UninstallResult 1 "partial" "safe_update_pending" "发现尚未验收的安全更新，本次卸载未修改任何文件。" @() @("请先运行安全更新验收，完成或恢复整批订阅后再重试卸载。")
}

function New-UninstallBackup([string]$Path) {
    $backupRoot = $script:ClaudeEasyUninstallBackupRoot
    if ([string]::IsNullOrWhiteSpace([string]$backupRoot)) {
        $backupRoot = Join-Path (Split-Path -Parent $Path) "claude-easy-backups"
    }
    return (Backup-Versioned $Path $backupRoot "pre-uninstall")
}

function Get-InstalledSettingRestorePlan([object]$Entry, [string]$Path, [string]$Label) {
    if ($null -eq $Entry) { return $null }
    $snapshot = Get-OptionalFileSnapshot $Path $Label
    $existed = [bool]$snapshot.Exists
    $currentBytes = $snapshot.Bytes
    $current = Get-BytesSha256 $currentBytes
    $expected = [string]$Entry.InstalledSha256
    if ([bool]$Entry.Existed) {
        $originalBytes = [Convert]::FromBase64String([string]$Entry.OriginalBase64)
        if ($existed -and $current -eq (Get-BytesSha256 $originalBytes)) {
            return [pscustomobject]@{ Changed = $false; Path = $Path; Label = $Label }
        }
    } elseif (-not $existed) {
        return [pscustomobject]@{ Changed = $false; Path = $Path; Label = $Label }
    }
    if ($current -ne $expected) {
        throw "$Label 在安装后有新改动，未自动覆盖。"
    }
    $replacement = if ([bool]$Entry.Existed) { $originalBytes } else { [byte[]]@() }
    return [pscustomobject]@{
        Changed = $true
        Path = $Path
        Label = $Label
        Bytes = $replacement
        Existed = $existed
        OriginalBytes = $currentBytes
        OriginalIdentity = $snapshot.Identity
        Delete = (-not [bool]$Entry.Existed)
    }
}

function Assert-UsageProfileState([object]$State) {
    if ($null -eq $State) { throw "用途档位状态文件无效。" }
    $version = $State.Version
    $profile = $State.Profile
    $numericVersion = $version -is [int] -or $version -is [long]
    $numericProfile = $profile -is [int] -or $profile -is [long]
    $propertyNames = @($State.PSObject.Properties.Name | Sort-Object)
    $expectedProperties = if ($numericVersion -and [long]$version -eq 1) {
        "Profile,Version"
    } elseif ($numericVersion -and [long]$version -eq 2) {
        "ManagedScriptSha256,Profile,Version"
    } else {
        ""
    }
    if (($propertyNames -join ",") -cne $expectedProperties -or
        -not $numericProfile -or [long]$profile -notin @(1, 2, 3) -or
        ([long]$version -eq 2 -and (
            -not ($State.ManagedScriptSha256 -is [string]) -or
            [string]$State.ManagedScriptSha256 -notmatch '^[0-9a-f]{64}$'
        ))) {
        throw "用途档位状态文件内容无效。"
    }
}

function Test-ClashVergeRunning {
    foreach ($name in @("clash-verge", "clash-verge-rev", "Clash Verge", "Clash Verge Rev")) {
        if ($null -ne (Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1)) { return $true }
    }
    return $false
}

if ([string]::IsNullOrWhiteSpace($AppHome)) {
    try {
        $AppHome = Resolve-ClashVergeAppHome
    } catch {
        Complete-UninstallResult 2 "invalid_request" "ambiguous_app_home" "检测到多个 Clash Verge Rev 配置目录；未执行任何操作。"
    }
}
if (-not [string]::IsNullOrWhiteSpace($AppHome)) {
    try {
        $AppHome = ConvertTo-NormalizedWindowsPath $AppHome
    } catch {
        Complete-UninstallResult 64 "invalid_request" "invalid_app_home" "Clash Verge Rev 配置目录参数无效。"
    }
}

if ([string]::IsNullOrWhiteSpace($AppHome)) {
    Complete-UninstallResult 2 "unsupported" "client_not_found" "没有找到 Clash Verge Rev 配置目录。"
}

$target = Join-Path (Join-Path $AppHome "profiles") "Script.js"
$profilesIndexPath = Join-Path $AppHome "profiles.yaml"
$vergePath = Join-Path $AppHome "verge.yaml"
$configPath = Join-Path $AppHome "config.yaml"
$statePath = Join-Path $AppHome "claude-easy-install-state.json"
$autoUpdateStatePath = Join-Path $AppHome "claude-easy-auto-update-state.json"
$usageStatePath = Join-Path $AppHome "claude-easy-usage-profile.json"
$safeUpdateStatePath = Join-Path $AppHome "claude-easy-safe-update.json"
$script:ClaudeEasyUninstallBackupRoot = Join-Path $AppHome "claude-easy-backups"
$state = $null

$mutationLock = $null
try {
    $mutationLock = Enter-AppHomeMutationLock $AppHome
} catch {
    $lockMessage = $_.Exception.Message
    if ($lockMessage -eq "客户端保持运行；中断的客户端敏感事务等待恢复。") {
        Complete-UninstallResult 1 "partial" "transaction_recovery_pending" "客户端保持运行；中断的客户端敏感事务仍在等待安全恢复，请稍后重试。"
    }
    if ($lockMessage -eq "同一配置目录已有 ClaudeEasy 操作正在进行，请稍后重试。") {
        Complete-UninstallResult 1 "failed" "operation_in_progress" $lockMessage
    }
    Complete-UninstallResult 1 "failed" "state_recovery_failed" $lockMessage
}

try {
try {
    $safeUpdateStateSnapshot = Get-OptionalFileSnapshot $safeUpdateStatePath "安全更新准备记录"
    if ($safeUpdateStateSnapshot.Exists) {
        Complete-PendingSafeUpdateUninstall
    }
    $clientRunning = Test-ClashVergeRunning
    $stateSnapshot = Get-OptionalFileSnapshot $statePath "安装状态"
    $autoUpdateStateSnapshot = Get-OptionalFileSnapshot $autoUpdateStatePath "订阅自动更新所有权状态"
    $usageStateSnapshot = Get-OptionalFileSnapshot $usageStatePath "用途档位状态"
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)

    if ($stateSnapshot.Exists) {
        try {
            $state = $strictUtf8.GetString($stateSnapshot.Bytes) | ConvertFrom-Json
        } catch {
            throw "安装状态文件无效。"
        }
        Assert-InstallState $state
    }
    $autoUpdateStateExists = [bool]$autoUpdateStateSnapshot.Exists
    $autoUpdatePlan = $null
    $autoUpdateStateBytes = $autoUpdateStateSnapshot.Bytes
    if ($autoUpdateStateExists) {
        try {
            $autoUpdateState = $strictUtf8.GetString($autoUpdateStateBytes) | ConvertFrom-Json
        } catch {
            throw "订阅自动更新所有权状态文件无效。"
        }
        $autoUpdateOwnership = @(Assert-RemoteSubscriptionAutoUpdateOwnershipState $autoUpdateState)
    }
    if ($usageStateSnapshot.Exists) {
        try {
            $usageStateText = $strictUtf8.GetString($usageStateSnapshot.Bytes)
            if ([regex]::Matches($usageStateText, '(?i)"Version"\s*:').Count -ne 1 -or
                [regex]::Matches($usageStateText, '(?i)"Profile"\s*:').Count -ne 1) {
                throw "用途档位状态文件字段重复或缺失。"
            }
            $usageState = $usageStateText | ConvertFrom-Json
            if (($usageState.Version -is [int] -or $usageState.Version -is [long]) -and
                [long]$usageState.Version -eq 2 -and
                [regex]::Matches($usageStateText, '(?i)"ManagedScriptSha256"\s*:').Count -ne 1) {
                throw "用途档位状态文件字段重复或缺失。"
            }
        } catch {
            throw "用途档位状态文件无效。"
        }
        Assert-UsageProfileState $usageState
    }
    if ($clientRunning -and (
        $null -ne $state -or
        $autoUpdateStateExists -or
        [bool]$usageStateSnapshot.Exists
    )) {
        Complete-RunningClientUninstall
    }

    if ($autoUpdateStateExists) {
        $profilesIndexSnapshot = Get-OptionalFileSnapshot $profilesIndexPath "profiles.yaml"
        if (-not $profilesIndexSnapshot.Exists) {
            throw "找不到 profiles.yaml，无法安全恢复订阅自动更新设置。"
        }
        $profilesIndexOriginalBytes = $profilesIndexSnapshot.Bytes
        try {
            $profilesIndexInput = $strictUtf8.GetString($profilesIndexOriginalBytes)
        } catch {
            throw "profiles.yaml 不是有效的 UTF-8 文件。"
        }
        $profilesIndexOutput = Restore-RemoteSubscriptionAutoUpdate $profilesIndexInput $autoUpdateOwnership
        $profilesIndexBytes = ConvertTo-Utf8Bytes $profilesIndexOutput
        if ((Get-BytesSha256 $profilesIndexBytes) -ne (Get-BytesSha256 $profilesIndexOriginalBytes)) {
            $autoUpdatePlan = [pscustomobject]@{
                Changed = $true
                Path = $profilesIndexPath
                Label = "profiles.yaml"
                Bytes = $profilesIndexBytes
                Existed = $true
                OriginalBytes = $profilesIndexOriginalBytes
                OriginalIdentity = $profilesIndexSnapshot.Identity
                Delete = $false
            }
        }
    }

    $scriptPlan = $null
    $scriptSnapshot = Get-OptionalFileSnapshot $target "Script.js"
    if ($scriptSnapshot.Exists) {
        $begin = "// CLAUDEEASY BEGIN"
        $end = "// CLAUDEEASY END"
        $scriptOriginalBytes = $scriptSnapshot.Bytes
        try {
            $current = $strictUtf8.GetString($scriptOriginalBytes)
        } catch {
            throw "Script.js 不是有效的 UTF-8 文件。"
        }
        $analysis = Get-JavaScriptAnalysis $current
        $beginMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "begin" })
        $endMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "end" })
        $originalBeginMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "original-begin" })
        $originalEndMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "original-end" })
        if ($beginMarkers.Count -gt 0 -or $endMarkers.Count -gt 0) {
            if ($beginMarkers.Count -ne 1 -or $endMarkers.Count -ne 1 -or $endMarkers[0].Start -lt $beginMarkers[0].Start) {
                throw "Script.js 标记不完整或重复，原文件未修改。"
            }
            $managedBlock = $current.Substring($beginMarkers[0].Start, $endMarkers[0].End - $beginMarkers[0].Start)
            if (-not $managedBlock.Contains("CLAUDEEASY POLICY BEGIN") -or -not $managedBlock.Contains("function claudeEasyTransform")) {
                throw "Script.js 中的同名标记不是本工具创建的，原文件未修改。"
            }
            $managedProfileMatches = [regex]::Matches(
                $managedBlock,
                'const\s+CLAUDE_EASY_USAGE_PROFILE\s*=\s*([123])\s*;'
            )
            if ($managedProfileMatches.Count -ne 1) {
                throw "Script.js 中的用途档位标记无效，原文件未修改。"
            }
            $managedProfile = [int]$managedProfileMatches[0].Groups[1].Value
            if ($null -ne $usageState -and $managedProfile -ne [int]$usageState.Profile) {
                throw "Script.js 中的用途档位与已保存状态不一致，原文件未修改。"
            }
            if ($null -ne $usageState -and [long]$usageState.Version -eq 2) {
                $managedEnvelope = Get-ClaudeEasyManagedScriptEnvelope $current $managedProfile
                $managedEnvelopeHash = Get-BytesSha256 (ConvertTo-Utf8Bytes $managedEnvelope)
                if ($managedEnvelopeHash -cne [string]$usageState.ManagedScriptSha256) {
                    throw "Script.js 中的 ClaudeEasy 区块在安装后有新改动，原文件未修改。"
                }
            } else {
                Assert-ClaudeEasyManagedScriptCurrent $current $managedProfile $enginePath $target -AllowOutsideCode
            }

            $outsidePrefix = $current.Substring(0, $beginMarkers[0].Start).Trim()
            $outsideSuffix = $current.Substring($endMarkers[0].End).Trim()
            $previous = ""
            if ($originalBeginMarkers.Count -gt 0 -or $originalEndMarkers.Count -gt 0) {
                if ($originalBeginMarkers.Count -ne 1 -or $originalEndMarkers.Count -ne 1 -or
                    $originalEndMarkers[0].Start -lt $originalBeginMarkers[0].End -or
                    $originalBeginMarkers[0].Start -lt $beginMarkers[0].Start -or
                    $originalEndMarkers[0].End -gt $endMarkers[0].End) {
                    throw "Script.js 原脚本标记不完整、重复或越界，原文件未修改。"
                }
                $previous = $current.Substring(
                    $originalBeginMarkers[0].End,
                    $originalEndMarkers[0].Start - $originalBeginMarkers[0].End
                ).Trim()
            } else {
                $previous = $outsidePrefix
                $outsidePrefix = ""
            }
            if (-not [string]::IsNullOrWhiteSpace($previous)) {
                $previous = (Rename-JavaScriptMain $previous "claudeEasyPreviousMain" "main").Trim()
            }
            $remaining = @($outsidePrefix, $previous, $outsideSuffix) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $remainingText = ($remaining -join "`r`n`r`n")
            if (-not [string]::IsNullOrWhiteSpace($previous)) {
                Assert-JavaScriptCanCompose $remainingText
            }
            $scriptBytes = if ($remaining.Count -eq 0) {
                [byte[]]@()
            } else {
                (New-Object System.Text.UTF8Encoding($false)).GetBytes(($remainingText + "`r`n"))
            }
            $scriptPlan = [pscustomobject]@{
                Changed = $true
                Path = $target
                Label = "Script.js"
                Bytes = $scriptBytes
                Existed = $true
                OriginalBytes = $scriptOriginalBytes
                OriginalIdentity = $scriptSnapshot.Identity
                Delete = ($remaining.Count -eq 0)
            }
        }
    }

    $settingPlans = @()
    if ($null -ne $state -and -not $clientRunning) {
        $settingEntries = @(
            [pscustomobject]@{ Entry = $state.ConfigYaml; Path = $configPath; Label = "config.yaml" },
            [pscustomobject]@{ Entry = $state.VergeYaml; Path = $vergePath; Label = "verge.yaml" }
        )
        foreach ($settingEntry in $settingEntries) {
            $settingPlans += Get-InstalledSettingRestorePlan $settingEntry.Entry $settingEntry.Path $settingEntry.Label
        }
    } elseif ($null -ne $state) {
        Write-Info "Clash Verge Rev 保持运行；config.yaml 与 verge.yaml 未改动，安装状态文件继续保留。"
    }

    $usageStateExists = [bool]$usageStateSnapshot.Exists
    if ($null -eq $scriptPlan -and $null -eq $state -and -not $autoUpdateStateExists -and -not $usageStateExists) {
        if ([bool]$mutationLock.RecoveredTransaction) {
            Write-Info "已恢复被中断的文件事务；没有遗留安装内容。"
            Complete-UninstallResult 0 "ok" "uninstalled" "ClaudeEasy 已安全移除。" @("interrupted_transaction")
        }
        Write-Info "没有发现已安装的自动补丁，无需移除。"
        Complete-UninstallResult 0 "no_change" "not_installed" "没有发现已安装的自动补丁，无需移除。"
    }

    $filePlans = @()
    if ($null -ne $autoUpdatePlan) { $filePlans += $autoUpdatePlan }
    if ($null -ne $scriptPlan) { $filePlans += $scriptPlan }
    $filePlans += @($settingPlans | Where-Object { $_.Changed })
    $uninstallHasProtectedChanges = ($filePlans.Count -gt 0 -or $null -ne $state -or $autoUpdateStateExists -or $usageStateExists)
    if ($uninstallHasProtectedChanges -and (Test-ClashVergeRunning)) {
        Complete-RunningClientUninstall
    }
    foreach ($filePlan in $filePlans) {
        if ([bool]$filePlan.Existed) { New-UninstallBackup $filePlan.Path | Out-Null }
    }
    $writePlans = @($filePlans | Where-Object { -not [bool]$_.Delete })
    $deletePlans = @($filePlans | Where-Object { [bool]$_.Delete } | ForEach-Object {
        [pscustomobject]@{
            Path = $_.Path
            Existed = $_.Existed
            OriginalBytes = $_.OriginalBytes
            OriginalIdentity = $_.OriginalIdentity
        }
    })
    if ($null -ne $state -and -not $clientRunning) {
        $deletePlans += [pscustomobject]@{
            Path = $statePath
            Existed = $true
            OriginalBytes = $stateSnapshot.Bytes
            OriginalIdentity = $stateSnapshot.Identity
        }
    }
    if ($autoUpdateStateExists) {
        $deletePlans += [pscustomobject]@{
            Path = $autoUpdateStatePath
            Existed = $true
            OriginalBytes = $autoUpdateStateBytes
            OriginalIdentity = $autoUpdateStateSnapshot.Identity
        }
    }
    if ($usageStateExists) {
        $deletePlans += [pscustomobject]@{
            Path = $usageStatePath
            Existed = $true
            OriginalBytes = $usageStateSnapshot.Bytes
            OriginalIdentity = $usageStateSnapshot.Identity
        }
    }

    $writeTargets = @($writePlans | ForEach-Object {
        [pscustomobject]@{
            Path = $_.Path
            Bytes = $_.Bytes
            Existed = $_.Existed
            OriginalBytes = $_.OriginalBytes
            OriginalIdentity = $_.OriginalIdentity
        }
    })
    $clientStoppedPreCommit = $null
    if ($uninstallHasProtectedChanges) {
        $clientStoppedPreCommit = {
            return (-not (Test-ClashVergeRunning))
        }
    }
    $transactionCommitted = Invoke-VerifiedWriteDeleteTransaction `
        $writeTargets $deletePlans $clientStoppedPreCommit
    if ($null -ne $clientStoppedPreCommit -and -not $transactionCommitted) {
        Complete-RunningClientUninstall
    }

    $changes = @()
    if ($null -ne $scriptPlan) { $changes += "global_script" }
    if ($autoUpdateStateExists) { $changes += "subscription_auto_update" }
    $settingsRestored = @($settingPlans | Where-Object { $_.Changed }).Count -gt 0
    if ($settingsRestored) { $changes += "application_settings" }
    if ($usageStateExists) { $changes += "usage_profile" }
    $settingsMessage = if ($settingsRestored) {
        "config.yaml 与 verge.yaml 已恢复到安装前状态。"
    } else {
        "config.yaml 与 verge.yaml 无需恢复。"
    }
    Write-Info "全局自动补丁已移除，$settingsMessage 现有备份没有删除。"
    Complete-UninstallResult 0 "ok" "uninstalled" "ClaudeEasy 已安全移除。" $changes
} catch {
    Complete-UninstallResult 1 "failed" "uninstall_failed" ("卸载失败：" + $_.Exception.Message)
}
} finally {
    Exit-AppHomeMutationLock $mutationLock
}
