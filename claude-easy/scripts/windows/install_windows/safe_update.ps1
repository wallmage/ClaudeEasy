function Get-BackupTarget([string]$BackupId) {
    if ([string]::IsNullOrWhiteSpace($BackupId) -or $BackupId -ne (Split-Path -Leaf $BackupId) -or $BackupId -notlike "*.backup") {
        throw "备份编号无效。"
    }
    $backupPath = Join-Path $backupRoot $BackupId
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { throw "找不到指定备份。" }
    if ($BackupId -notmatch '--([0-9a-f]{16})--(.+)\.backup$') { throw "备份编号无效。" }
    $key = $Matches[1]
    $basename = $Matches[2]
    $candidates = @($targetScript, $profilesIndexPath, $vergePath, $configPath)
    if (Test-Path -LiteralPath $profilesDirectory -PathType Container) {
        $candidates += @(Get-ChildItem -LiteralPath $profilesDirectory -File | ForEach-Object { $_.FullName })
    }
    $matches = @($candidates | Select-Object -Unique | Where-Object {
        (Test-Path -LiteralPath $_ -PathType Leaf) -and
        (Split-Path -Leaf $_) -eq $basename -and
        (Get-PathKey $_) -eq $key
    })
    if ($matches.Count -ne 1) { throw "备份无法对应到唯一的当前配置。" }
    return [pscustomobject]@{ BackupPath = $backupPath; TargetPath = $matches[0] }
}

function Get-ClaudeEasyManagedScriptBlock([string]$ScriptText, [int]$UsageProfile) {
    $analysis = Get-JavaScriptAnalysis $ScriptText
    $beginMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "begin" })
    $endMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "end" })
    if ($beginMarkers.Count -ne 1 -or $endMarkers.Count -ne 1 -or $endMarkers[0].Start -lt $beginMarkers[0].Start) {
        throw "已安装的全局扩展脚本缺少唯一完整的 ClaudeEasy 区块。"
    }
    $managed = $ScriptText.Substring(
        $beginMarkers[0].Start,
        $endMarkers[0].End - $beginMarkers[0].Start
    )
    if (-not $managed.Contains("function claudeEasyTransform") -or
        -not $managed.Contains("function claudeEasyDetectMain")) {
        throw "已安装的全局扩展脚本缺少转换入口。"
    }
    $profileMatches = [regex]::Matches($managed, 'const\s+CLAUDE_EASY_USAGE_PROFILE\s*=\s*([123])\s*;')
    if ($profileMatches.Count -ne 1 -or [int]$profileMatches[0].Groups[1].Value -ne $UsageProfile) {
        throw "已安装的全局扩展脚本与当前用途档位不一致。"
    }
    return $managed
}

function Get-ClaudeEasyManagedScriptEnvelope([string]$ScriptText, [int]$UsageProfile) {
    $managed = Get-ClaudeEasyManagedScriptBlock $ScriptText $UsageProfile
    $analysis = Get-JavaScriptAnalysis $ScriptText
    $beginMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "begin" })
    $endMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "end" })
    $originalBeginMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "original-begin" })
    $originalEndMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "original-end" })
    if ($originalBeginMarkers.Count -eq 0 -and $originalEndMarkers.Count -eq 0) {
        return $managed
    }
    if ($beginMarkers.Count -ne 1 -or $endMarkers.Count -ne 1 -or
        $originalBeginMarkers.Count -ne 1 -or $originalEndMarkers.Count -ne 1 -or
        $originalBeginMarkers[0].Start -lt $beginMarkers[0].Start -or
        $originalEndMarkers[0].Start -lt $originalBeginMarkers[0].End -or
        $originalEndMarkers[0].End -gt $endMarkers[0].End) {
        throw "已安装的全局扩展脚本缺少唯一完整的原脚本边界。"
    }
    $prefix = $ScriptText.Substring(
        $beginMarkers[0].Start,
        $originalBeginMarkers[0].End - $beginMarkers[0].Start
    )
    $suffix = $ScriptText.Substring(
        $originalEndMarkers[0].Start,
        $endMarkers[0].End - $originalEndMarkers[0].Start
    )
    return $prefix + "`r`n// CLAUDEEASY ORIGINAL CONTENT`r`n" + $suffix
}

function Assert-ClaudeEasyScriptOutsideManagedBlockIsPassive([string]$ScriptText) {
    $analysis = Get-JavaScriptAnalysis $ScriptText
    $beginMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "begin" })
    $endMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "end" })
    if ($beginMarkers.Count -ne 1 -or $endMarkers.Count -ne 1 -or
        $endMarkers[0].Start -lt $beginMarkers[0].Start) {
        throw "已安装的全局扩展脚本缺少唯一完整的 ClaudeEasy 区块。"
    }
    $outsidePrefix = $ScriptText.Substring(0, $beginMarkers[0].Start)
    $outsideSuffix = $ScriptText.Substring($endMarkers[0].End)
    $outsidePrefixAnalysis = Get-JavaScriptAnalysis $outsidePrefix
    $outsideSuffixAnalysis = Get-JavaScriptAnalysis $outsideSuffix
    if ($outsidePrefixAnalysis.HasLiteral -or
        $outsideSuffixAnalysis.HasLiteral -or
        -not [string]::IsNullOrWhiteSpace([string]$outsidePrefixAnalysis.Code) -or
        -not [string]::IsNullOrWhiteSpace([string]$outsideSuffixAnalysis.Code)) {
        throw "已安装的全局扩展脚本在 ClaudeEasy 区块外包含可执行代码。"
    }
}

function Assert-ClaudeEasyManagedScriptCurrent(
    [string]$ScriptText,
    [int]$UsageProfile,
    [string]$EnginePath,
    [string]$TargetPath
) {
    $managed = Get-ClaudeEasyManagedScriptEnvelope $ScriptText $UsageProfile
    Assert-ClaudeEasyScriptOutsideManagedBlockIsPassive $ScriptText
    $expectedScript = Build-GlobalScript $EnginePath $TargetPath $UsageProfile $ScriptText
    $expectedManaged = Get-ClaudeEasyManagedScriptEnvelope $expectedScript $UsageProfile
    if ($managed -cne $expectedManaged) {
        throw "已安装的全局扩展脚本与当前安装包不一致。"
    }
}

function Test-ClaudeEasyFlowSequenceHasItem([string]$Text) {
    $inside = $false
    $comment = $false
    foreach ($character in $Text.ToCharArray()) {
        if ($comment) {
            if ($character -eq "`r" -or $character -eq "`n") { $comment = $false }
            continue
        }
        if (-not $inside) {
            if ($character -eq "[") { $inside = $true }
            continue
        }
        if ($character -eq "#") {
            $comment = $true
            continue
        }
        if ($character -eq "]") { return $false }
        if (-not [char]::IsWhiteSpace($character) -and $character -ne ",") { return $true }
    }
    return $true
}

function Assert-ClaudeEasyProxyGroupCollection([string]$Text, [string]$Label) {
    $lines = @(Split-YamlLines $Text)
    $groupsNode = Find-YamlMappingNode $lines "proxy-groups" 0 0 $lines.Count
    if ($null -eq $groupsNode) {
        throw "$Label 缺少代理组，无法应用全局扩展脚本。"
    }

    $inline = ([string]$groupsNode.Value).Trim()
    if ($inline -match '^\[') {
        $flowLines = @([string]$groupsNode.Value)
        if ($groupsNode.Start + 1 -lt $lines.Count) {
            $flowLines += @($lines[($groupsNode.Start + 1)..($lines.Count - 1)])
        }
        if (-not (Test-ClaudeEasyFlowSequenceHasItem ($flowLines -join "`n"))) {
            throw "$Label 的代理组为空，无法应用全局扩展脚本。"
        }
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($inline) -and -not $inline.StartsWith("#")) {
        throw "$Label 的代理组结构无法安全确认。"
    }

    $children = @()
    for ($lineIndex = $groupsNode.Start + 1; $lineIndex -lt $groupsNode.End; $lineIndex++) {
        $line = $lines[$lineIndex]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) { continue }
        $children += [pscustomobject]@{
            Indent = Get-YamlIndent $line
            Text = $line.TrimStart()
        }
    }
    if ($children.Count -eq 0) {
        throw "$Label 的代理组为空，无法应用全局扩展脚本。"
    }
    $itemIndent = ($children | Measure-Object -Property Indent -Minimum).Minimum
    $items = @($children | Where-Object {
        $_.Indent -eq $itemIndent -and ($_.Text -eq "-" -or $_.Text.StartsWith("- "))
    })
    if ($items.Count -eq 0) {
        throw "$Label 的代理组结构无法安全确认。"
    }
}

function Test-RestoreCandidate([string]$TargetPath, [byte[]]$Bytes) {
    $leaf = Split-Path -Leaf $TargetPath
    $extension = [System.IO.Path]::GetExtension($TargetPath).ToLowerInvariant()
    $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($Bytes)
    if ($extension -eq ".json") {
        throw "内部状态文件不能通过单文件备份恢复。"
    }
    if ($extension -notin @(".yaml", ".yml")) { return }

    Test-GeneratedYaml $text $leaf | Out-Null
    if ($TargetPath -eq $profilesIndexPath -or $TargetPath -eq $vergePath) { return }
    $core = Find-MihomoCore $MihomoPath
    Test-MihomoCandidate $core $text (Split-Path -Parent $TargetPath)
}

function Get-SafeUpdateRecoveryItems([object]$Manifest, [string]$Directory, [string]$BackupDirectory) {
    $items = @()
    foreach ($item in @($Manifest.Profiles)) {
        $properties = @($item.PSObject.Properties.Name | Sort-Object)
        if (($properties -join ",") -cne "Backup,BeforeSha256,File,Uid" -or
            -not ($item.Uid -is [string]) -or
            -not ($item.File -is [string]) -or
            -not ($item.Backup -is [string]) -or
            -not ($item.BeforeSha256 -is [string])) {
            throw "安全更新准备记录包含无效订阅项。"
        }
        $uid = [string]$item.Uid
        $file = [string]$item.File
        $backup = [string]$item.Backup
        $beforeSha = ([string]$item.BeforeSha256).ToLowerInvariant()
        if ($uid -notmatch '^[A-Za-z0-9._-]+$' -or $file -notin @("$uid.yaml", "$uid.yml")) {
            throw "安全更新准备记录包含无效订阅标识。"
        }
        if ($backup -ne (Split-Path -Leaf $backup) -or $backup -notlike "*.backup" -or $beforeSha -notmatch '^[0-9a-f]{64}$') {
            throw "安全更新准备记录包含无效备份信息。"
        }
        $targetPath = Join-Path $Directory $file
        $expectedSuffix = "--$(Get-PathKey $targetPath)--$file.backup"
        if (-not $backup.EndsWith($expectedSuffix)) { throw "安全更新准备记录中的备份与订阅不匹配。" }
        $backupPath = Join-Path $BackupDirectory $backup
        if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf) -or (Get-FileSha256 $backupPath) -ne $beforeSha) {
            throw "安全更新前备份缺失或哈希不匹配。"
        }
        $items += [pscustomobject]@{ Uid = $uid; File = $file; TargetPath = $targetPath; BackupPath = $backupPath; BeforeSha256 = $beforeSha }
    }
    if ($items.Count -eq 0 -or @($items.TargetPath | Sort-Object -Unique).Count -ne $items.Count) {
        throw "安全更新准备记录中的订阅清单无效。"
    }
    return @($items)
}

function Get-SafeUpdateVerificationTargets(
    [string]$ProfilesIndexText,
    [string]$Directory,
    [object[]]$RecoveryItems
) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "找不到订阅目录。"
    }
    $items = @(Get-RemoteSubscriptionProfileItems @(Split-YamlLines $ProfilesIndexText))
    $items = @($items | Where-Object { $_.Type -eq "remote" })
    if ($items.Count -eq 0 -or $items.Count -ne $RecoveryItems.Count) {
        throw "远程订阅清单在更新期间发生变化。"
    }
    $targets = @()
    foreach ($recovery in $RecoveryItems) {
        $item = @($items | Where-Object {
            [string]::Equals(
                [string]$_.Uid,
                [string]$recovery.Uid,
                [StringComparison]::Ordinal
            )
        })
        if ($item.Count -ne 1) { throw "远程订阅清单在更新期间发生变化。" }
        $candidates = @(
            (Join-Path $Directory ($item[0].Uid + ".yaml")),
            (Join-Path $Directory ($item[0].Uid + ".yml"))
        )
        $matches = @($candidates | Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf
        })
        if ($matches.Count -gt 1) { throw "远程订阅清单在更新期间发生变化。" }
        if ($matches.Count -eq 1) {
            $path = (Resolve-Path -LiteralPath $matches[0]).Path
            if (-not [string]::Equals(
                (Split-Path -Leaf $path),
                [string]$recovery.File,
                [StringComparison]::Ordinal
            )) {
                throw "远程订阅清单在更新期间发生变化。"
            }
        } else {
            $path = [string]$recovery.TargetPath
        }
        $targets += [pscustomobject]@{
            Uid = [string]$item[0].Uid
            Name = [string]$item[0].Name
            Path = $path
        }
    }
    return @($targets)
}

function Restore-SafeUpdateFiles(
    [object[]]$RecoveryItems,
    [hashtable]$ObservedHashes,
    [string]$ManifestPath,
    [object]$ManifestSnapshot
) {
    $failures = @()
    $conflicts = @()
    $targets = @()
    foreach ($recovery in $RecoveryItems) {
        try {
            if (-not $ObservedHashes.ContainsKey($recovery.TargetPath)) {
                $conflicts += $recovery.File
                continue
            }
            $backupSnapshot = Get-OptionalFileSnapshot $recovery.BackupPath "安全更新备份"
            if (-not $backupSnapshot.Exists -or
                (Get-BytesSha256 $backupSnapshot.Bytes) -ne [string]$recovery.BeforeSha256) {
                throw "安全更新备份在恢复前发生变化。"
            }
            $observedHash = [string]$ObservedHashes[$recovery.TargetPath]
            $targetSnapshot = Get-OptionalFileSnapshot $recovery.TargetPath "更新后的订阅"
            if ([string]::IsNullOrWhiteSpace($observedHash)) {
                if ($targetSnapshot.Exists) {
                    $conflicts += $recovery.File
                    continue
                }
                $targets += [pscustomobject]@{
                    Path = $recovery.TargetPath
                    Bytes = $backupSnapshot.Bytes
                    Existed = $false
                    OriginalBytes = $null
                    OriginalIdentity = $null
                }
            } else {
                if ($observedHash -notmatch '^[0-9a-f]{64}$' -or
                    -not $targetSnapshot.Exists -or
                    (Get-BytesSha256 $targetSnapshot.Bytes) -ne $observedHash) {
                    $conflicts += $recovery.File
                    continue
                }
                $targets += [pscustomobject]@{
                    Path = $recovery.TargetPath
                    Bytes = $backupSnapshot.Bytes
                    Existed = $true
                    OriginalBytes = $targetSnapshot.Bytes
                    OriginalIdentity = $targetSnapshot.Identity
                }
            }
        } catch {
            $failures += $recovery.File
        }
    }
    if ($failures.Count -eq 0 -and $conflicts.Count -eq 0) {
        try {
            if ([string]::IsNullOrWhiteSpace($ManifestPath) -or
                $null -eq $ManifestSnapshot -or
                -not [bool]$ManifestSnapshot.Exists) {
                throw "安全更新准备记录快照无效。"
            }
            $manifestTarget = [pscustomobject]@{
                Path = $ManifestPath
                Existed = $true
                OriginalBytes = $ManifestSnapshot.Bytes
                OriginalIdentity = $ManifestSnapshot.Identity
            }
            Invoke-VerifiedWriteDeleteTransaction $targets @($manifestTarget)
        } catch {
            $failures = @($RecoveryItems | ForEach-Object { $_.File })
        }
    }
    return [pscustomobject]@{ Failures = @($failures); Conflicts = @($conflicts) }
}
