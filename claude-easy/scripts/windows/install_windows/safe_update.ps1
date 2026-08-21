function Get-PublicBackupDescriptor([string]$BackupName) {
    if ([string]::IsNullOrWhiteSpace($BackupName) -or $BackupName -ne (Split-Path -Leaf $BackupName)) {
        throw "备份编号无效。"
    }
    $pattern = '^(?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})_(?<hour>\d{2})-(?<minute>\d{2})-(?<second>\d{2})\.(?<fraction>\d{7})(?<offset_sign>[+-])(?<offset_hour>\d{2})(?<offset_minute>\d{2})--[a-z][a-z0-9-]{0,31}--[0-9a-f]{16}--.+\.backup$'
    if ($BackupName -cnotmatch $pattern) { throw "备份编号无效。" }
    $createdAtCandidate = (
        "{0}-{1}-{2}T{3}:{4}:{5}.{6}{7}{8}:{9}" -f
            $Matches.year, $Matches.month, $Matches.day,
            $Matches.hour, $Matches.minute, $Matches.second,
            $Matches.fraction, $Matches.offset_sign,
            $Matches.offset_hour, $Matches.offset_minute
    )
    $createdAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact(
            $createdAtCandidate,
            "yyyy-MM-dd'T'HH:mm:ss.fffffffzzz",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$createdAt
        )) {
        throw "备份编号无效。"
    }
    $digest = Get-BytesSha256 ([System.Text.Encoding]::UTF8.GetBytes($BackupName))
    return [pscustomobject][ordered]@{
        id = "ce-backup-v1-$digest"
        created_at = $createdAt.ToString(
            "yyyy-MM-dd'T'HH:mm:ss.fffffffzzz",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }
}

function Get-PublicSubscriptionResult([string]$Uid, [string]$Name, [string]$Status) {
    $digest = Get-BytesSha256 ([System.Text.Encoding]::UTF8.GetBytes($Uid))
    $label = if ([string]::IsNullOrWhiteSpace($Name)) { "订阅 " + $digest.Substring(0, 8) } else { $Name }
    return [pscustomobject][ordered]@{
        id = "ce-subscription-v1-$digest"
        label = (Protect-ClaudeEasyResultText $label)
        status = $Status
    }
}

function ConvertFrom-SubscriptionScalar([string]$Raw, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Raw)) { throw "$Label 为空。" }
    $value = ($Raw -replace '\s+#.*$', '').Trim()
    if ($value.StartsWith("'") -and $value.EndsWith("'") -and $value.Length -ge 2) {
        return $value.Substring(1, $value.Length - 2).Replace("''", "'")
    }
    if ($value.StartsWith('"') -and $value.EndsWith('"')) {
        try {
            $decoded = $value | ConvertFrom-Json
        } catch {
            throw "$Label 使用了无效的双引号字符串。"
        }
        if (-not ($decoded -is [string])) { throw "$Label 不是字符串。" }
        return [string]$decoded
    }
    if ($value -match '[\r\n\t\[\]\{\},]') { throw "$Label 使用了不受支持的复杂标量。" }
    return $value
}

function Assert-SubscriptionProtocolPreserved([string]$BeforeText, [string]$CandidateText) {
    $anyTls = '(?im)\btype\s*:\s*["'']?anytls\b'
    $shadowsocks = '(?im)\btype\s*:\s*["'']?ss\b'
    if ($BeforeText -match $anyTls -and $CandidateText -notmatch $anyTls -and $CandidateText -match $shadowsocks) {
        throw "远程订阅把 AnyTLS 替换为 Shadowsocks。"
    }
}

function Get-PublicBackupId([string]$BackupName) {
    return [string]((Get-PublicBackupDescriptor $BackupName).id)
}

function Get-BackupTarget([string]$BackupId) {
    if ([string]::IsNullOrWhiteSpace($BackupId) -or $BackupId -ne (Split-Path -Leaf $BackupId)) {
        throw "备份编号无效。"
    }
    Assert-NoReparsePointPath $backupRoot "备份目录"
    $storageItems = @()
    if (Test-Path -LiteralPath $backupRoot -PathType Container) {
        $storageItems = @(Get-ChildItem -LiteralPath $backupRoot -File -Filter "*.backup")
    }
    $storageName = $BackupId
    if ($BackupId -cmatch '^ce-backup-v1-[0-9a-f]{64}$') {
        $storageMatches = @($storageItems | Where-Object {
            try {
                (Get-PublicBackupId $_.Name) -ceq $BackupId
            } catch {
                $false
            }
        })
        if ($storageMatches.Count -eq 0) { throw "找不到指定备份。" }
        if ($storageMatches.Count -ne 1) { throw "备份无法对应到唯一的存储文件。" }
        $storageName = [string]$storageMatches[0].Name
    } elseif ($BackupId -notlike "*.backup") {
        throw "备份编号无效。"
    } else {
        $storageMatches = @($storageItems | Where-Object {
            [string]::Equals([string]$_.Name, $BackupId, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($storageMatches.Count -eq 0) { throw "找不到指定备份。" }
        if ($storageMatches.Count -ne 1) { throw "备份无法对应到唯一的存储文件。" }
        $storageName = [string]$storageMatches[0].Name
    }
    $backupPath = Join-Path $backupRoot $storageName
    $backupSnapshot = Get-OptionalFileSnapshot $backupPath "备份"
    if (-not $backupSnapshot.Exists) { throw "找不到指定备份。" }
    $publicDescriptor = Get-PublicBackupDescriptor $storageName
    if ($storageName -notmatch '--([0-9a-f]{16})--(.+)\.backup$') { throw "备份编号无效。" }
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
    return [pscustomobject]@{
        BackupPath = $backupPath
        BackupSnapshot = $backupSnapshot
        TargetPath = $matches[0]
        PublicId = ([string]$publicDescriptor.id)
    }
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
    [string]$TargetPath,
    [switch]$AllowOutsideCode
) {
    $managed = Get-ClaudeEasyManagedScriptEnvelope $ScriptText $UsageProfile
    if (-not $AllowOutsideCode) {
        Assert-ClaudeEasyScriptOutsideManagedBlockIsPassive $ScriptText
    }
    $expectedScript = Build-GlobalScript $EnginePath $TargetPath $UsageProfile $ScriptText
    $expectedManaged = Get-ClaudeEasyManagedScriptEnvelope $expectedScript $UsageProfile
    if ($managed -cne $expectedManaged) {
        throw "已安装的全局扩展脚本与当前安装包不一致。"
    }
}

function Test-ClaudeEasyFlowSequenceHasItem([string]$Text) {
    $depth = 0
    $hasItem = $false
    $comment = $false
    $quote = ""
    $escaped = $false
    foreach ($character in $Text.ToCharArray()) {
        if ($comment) {
            if ($character -eq "`r" -or $character -eq "`n") { $comment = $false }
            continue
        }
        if (-not [string]::IsNullOrEmpty($quote)) {
            if ($escaped) {
                $escaped = $false
            } elseif ($quote -eq '"' -and $character -eq '\') {
                $escaped = $true
            } elseif ($character -eq $quote) {
                $quote = ""
            }
            continue
        }
        if ($depth -eq 0) {
            if ($character -eq "[") { $depth = 1 }
            continue
        }
        if ($character -eq "#") {
            $comment = $true
            continue
        }
        if ($character -eq "'" -or $character -eq '"') {
            $quote = [string]$character
            $hasItem = $true
            continue
        }
        if ($character -eq "[") {
            $depth += 1
            $hasItem = $true
            continue
        }
        if ($character -eq "]") {
            $depth -= 1
            if ($depth -eq 0) { return $hasItem }
            continue
        }
        if (-not [char]::IsWhiteSpace($character) -and $character -ne ",") {
            $hasItem = $true
        }
    }
    return $false
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
    if ($TargetPath -in @($targetScript, $profilesIndexPath, $vergePath)) {
        throw "受保护的客户端控制文件不能通过单文件备份恢复。"
    }
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

function Open-SafeUpdateVersionGuard([string]$Path, [string]$Label) {
    Initialize-VerifiedFileNative
    $directoryGuards = @(Open-VerifiedDirectoryChain (Split-Path -Parent $Path))
    $handle = $null
    $stream = $null
    try {
        $handle = [ClaudeEasy.VerifiedDeleteNative]::Open($Path, $false, $false)
        if ([ClaudeEasy.VerifiedDeleteNative]::IsReparsePoint($handle)) {
            throw "$Label 不能是符号链接或其他重解析点。"
        }
        if ([ClaudeEasy.VerifiedDeleteNative]::GetLinkCount($handle) -ne 1) {
            throw "$Label 不能有硬链接别名。"
        }
        $stream = New-Object System.IO.FileStream($handle, [System.IO.FileAccess]::Read)
        $handle = $null
        return [pscustomobject]@{
            Stream = $stream
            DirectoryGuards = $directoryGuards
        }
    } catch {
        if ($null -ne $stream) {
            $stream.Dispose()
        } elseif ($null -ne $handle) {
            $handle.Dispose()
        }
        for ($index = $directoryGuards.Count - 1; $index -ge 0; $index--) {
            $directoryGuards[$index].Dispose()
        }
        throw
    }
}

function New-SafeUpdateSnapshotContext(
    [string]$ProfilesIndex,
    [string]$ProfileDirectory
) {
    $fileGuards = @()
    $directoryGuards = @()
    try {
        $indexVersionGuard = Open-SafeUpdateVersionGuard $ProfilesIndex "远程订阅清单"
        $indexGuard = $indexVersionGuard.Stream
        $fileGuards += $indexGuard
        $directoryGuards += @($indexVersionGuard.DirectoryGuards)
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $indexText = $strictUtf8.GetString((Get-StreamBytes $indexGuard))
        if ($indexText.Length -gt 0 -and $indexText[0] -eq [char]0xFEFF) {
            $indexText = $indexText.Substring(1)
        }
        $profiles = @(Get-RemoteSubscriptionTargets $indexText $ProfileDirectory)
        $snapshotProfiles = @()
        foreach ($profile in @($profiles | Sort-Object Path)) {
            $profileVersionGuard = Open-SafeUpdateVersionGuard $profile.Path "远程订阅"
            $profileGuard = $profileVersionGuard.Stream
            $fileGuards += $profileGuard
            $directoryGuards += @($profileVersionGuard.DirectoryGuards)
            $profileBytes = Get-StreamBytes $profileGuard
            $snapshotProfiles += [pscustomobject]@{
                Uid = $profile.Uid
                Name = $profile.Name
                Path = $profile.Path
                Updated = $profile.Updated
                SnapshotSha256 = Get-BytesSha256 $profileBytes
                SnapshotBytes = $profileBytes
            }
        }
        $guards = @($fileGuards)
        for ($index = $directoryGuards.Count - 1; $index -ge 0; $index--) {
            $guards += $directoryGuards[$index]
        }
        return [pscustomobject]@{
            Profiles = $snapshotProfiles
            Guards = $guards
        }
    } catch {
        foreach ($guard in $fileGuards) { $guard.Dispose() }
        for ($index = $directoryGuards.Count - 1; $index -ge 0; $index--) {
            $directoryGuards[$index].Dispose()
        }
        throw
    }
}

function Get-SafeUpdateRecoveryItems([object]$Manifest, [string]$Directory, [string]$BackupDirectory) {
    $items = @()
    $manifestVersion = [long]$Manifest.Version
    foreach ($item in @($Manifest.Profiles)) {
        $properties = @($item.PSObject.Properties.Name | Sort-Object)
        $expectedProperties = if ($manifestVersion -eq 1) {
            "Backup,BeforeSha256,File,Uid"
        } else {
            "Backup,BeforeSha256,BeforeUpdated,File,Uid"
        }
        if (($properties -join ",") -cne $expectedProperties -or
            -not ($item.Uid -is [string]) -or
            -not ($item.File -is [string]) -or
            -not ($item.Backup -is [string]) -or
            -not ($item.BeforeSha256 -is [string]) -or
            ($manifestVersion -ge 2 -and -not ($item.BeforeUpdated -is [string]))) {
            throw "安全更新准备记录包含无效订阅项。"
        }
        $uid = [string]$item.Uid
        $file = [string]$item.File
        $backup = [string]$item.Backup
        $beforeSha = ([string]$item.BeforeSha256).ToLowerInvariant()
        $beforeUpdated = if ($manifestVersion -ge 2) { [string]$item.BeforeUpdated } else { "" }
        if ($uid -notmatch '^[A-Za-z0-9._-]+$' -or $file -notin @("$uid.yaml", "$uid.yml")) {
            throw "安全更新准备记录包含无效订阅标识。"
        }
        $beforeUpdatedTimestamp = 0L
        if (-not [string]::IsNullOrEmpty($beforeUpdated) -and
            (-not [long]::TryParse($beforeUpdated, [ref]$beforeUpdatedTimestamp) -or
             $beforeUpdatedTimestamp -lt 0)) {
            throw "安全更新准备记录包含无效更新时间。"
        }
        if ($backup -ne (Split-Path -Leaf $backup) -or $backup -notlike "*.backup" -or $beforeSha -notmatch '^[0-9a-f]{64}$') {
            throw "安全更新准备记录包含无效备份信息。"
        }
        $targetPath = Join-Path $Directory $file
        $expectedSuffix = "--$(Get-PathKey $targetPath)--$file.backup"
        if (-not $backup.EndsWith($expectedSuffix)) { throw "安全更新准备记录中的备份与订阅不匹配。" }
        $backupPath = Join-Path $BackupDirectory $backup
        if ($manifestVersion -ge 2 -and (
            -not (Test-Path -LiteralPath $backupPath -PathType Leaf) -or
            (Get-FileSha256 $backupPath) -ne $beforeSha
        )) {
            throw "安全更新前备份缺失或哈希不匹配。"
        }
        $items += [pscustomobject]@{
            Uid = $uid
            File = $file
            TargetPath = $targetPath
            BackupPath = $backupPath
            BeforeSha256 = $beforeSha
            BeforeUpdated = $beforeUpdated
            CanAutoRestore = ($manifestVersion -ge 2)
        }
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
            Updated = [string]$item[0].Updated
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
            Invoke-VerifiedWriteDeleteTransaction $targets @($manifestTarget) `
                -InterruptedRecoveryPolicy "safe_update_running_client"
        } catch {
            $failures = @($RecoveryItems | ForEach-Object { $_.File })
        }
    }
    return [pscustomobject]@{ Failures = @($failures); Conflicts = @($conflicts) }
}
