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

function Get-PublicSubscriptionLabel([string]$Uid, [string]$Name) {
    $digest = Get-BytesSha256 ([System.Text.Encoding]::UTF8.GetBytes($Uid))
    $label = if ([string]::IsNullOrWhiteSpace($Name)) { "订阅 " + $digest.Substring(0, 8) } else { $Name }
    return Protect-ClaudeEasyResultText $label
}

function Get-PublicSubscriptionResult([string]$Uid, [string]$Name, [string]$Status) {
    $digest = Get-BytesSha256 ([System.Text.Encoding]::UTF8.GetBytes($Uid))
    return [pscustomobject][ordered]@{
        id = "ce-subscription-v1-$digest"
        label = (Get-PublicSubscriptionLabel $Uid $Name)
        status = $Status
    }
}

function Test-SafeUpdateRuntimeFingerprint([object]$Fingerprint) {
    if ($null -eq $Fingerprint) { return $false }
    $properties = @($Fingerprint.PSObject.Properties.Name | Sort-Object)
    return ($properties -join ",") -ceq "Identity,LastWriteTicks,Sha256" -and
        $Fingerprint.Identity -is [string] -and
        -not [string]::IsNullOrWhiteSpace([string]$Fingerprint.Identity) -and
        $Fingerprint.LastWriteTicks -is [long] -and
        [long]$Fingerprint.LastWriteTicks -gt 0 -and
        $Fingerprint.Sha256 -is [string] -and
        [string]$Fingerprint.Sha256 -cmatch '^[0-9a-f]{64}$'
}

function Test-SafeUpdateActivationRecord([object]$Record) {
    if ($null -eq $Record) { return $false }
    $properties = @($Record.PSObject.Properties.Name | Sort-Object)
    return ($properties -join ",") -ceq "Client,RuntimeBefore" -and
        (Test-ClashVergeProcessIdentity $Record.Client) -and
        (Test-SafeUpdateRuntimeFingerprint $Record.RuntimeBefore)
}

function Close-SafeUpdateVersionGuard([object]$Guard) {
    if ($null -eq $Guard) { return }
    $Guard.Stream.Dispose()
    foreach ($directoryGuard in @($Guard.DirectoryGuards)) {
        $directoryGuard.Dispose()
    }
}

function Set-SafeUpdateActivationAttempt(
    [string]$ManifestPath,
    [object]$ManifestSnapshot,
    [object]$Manifest,
    [string]$PropertyName,
    [object]$ClientIdentity,
    [object]$RuntimeContext
) {
    if (-not (Test-ClashVergeProcessIdentity $ClientIdentity) -or
        $PropertyName -notin @("UpdateDispatchCommittedFor", "RestoreDispatchCommittedFor") -or
        $null -eq $RuntimeContext -or $null -eq $RuntimeContext.Snapshot -or
        -not [bool]$RuntimeContext.Snapshot.Exists -or
        -not ($RuntimeContext.LastWriteTicks -is [long]) -or
        [long]$RuntimeContext.LastWriteTicks -lt 1) {
        throw "安全更新客户端激活记录无效。"
    }
    $property = $Manifest.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        $Manifest | Add-Member -NotePropertyName $PropertyName -NotePropertyValue $null
    } elseif ($null -ne $property.Value) {
        if (-not (Test-SafeUpdateActivationRecord $property.Value)) {
            throw "安全更新客户端激活记录无效。"
        }
        return [pscustomobject]@{
            Allowed = $false
            Snapshot = $ManifestSnapshot
            Manifest = $Manifest
            VersionGuard = $null
        }
    }
    $runtimeVersionGuard = $null
    try {
        $runtimeVersionGuard = Open-SafeUpdateVersionGuard `
            ([string]$RuntimeContext.Snapshot.Path) "Clash Verge Rev 运行配置"
        $runtimeBytes = Get-StreamBytes $runtimeVersionGuard.Stream
        $Manifest.$PropertyName = [pscustomobject][ordered]@{
            Client = $ClientIdentity
            RuntimeBefore = [pscustomobject][ordered]@{
                Identity = [ClaudeEasy.VerifiedDeleteNative]::GetIdentity(
                    $runtimeVersionGuard.Stream.SafeFileHandle
                )
                LastWriteTicks = [ClaudeEasy.VerifiedDeleteNative]::GetLastWriteTicks(
                    $runtimeVersionGuard.Stream.SafeFileHandle
                )
                Sha256 = Get-BytesSha256 $runtimeBytes
            }
        }
        $bytes = ConvertTo-Utf8Bytes (($Manifest | ConvertTo-Json -Depth 7) + "`r`n")
        Invoke-VerifiedFileTransaction @(
            [pscustomobject]@{
                Path = $ManifestPath
                Bytes = $bytes
                Existed = $true
                OriginalBytes = $ManifestSnapshot.Bytes
                OriginalIdentity = $ManifestSnapshot.Identity
            }
        ) -InterruptedRecoveryPolicy "safe_update_running_client"
        $snapshot = Get-OptionalFileSnapshot $ManifestPath "安全更新客户端激活记录"
        if (-not $snapshot.Exists -or (Get-BytesSha256 $snapshot.Bytes) -cne (Get-BytesSha256 $bytes)) {
            throw "安全更新客户端激活记录无法确认。"
        }
        $result = [pscustomobject]@{
            Allowed = $true
            Snapshot = $snapshot
            Manifest = ((New-Object System.Text.UTF8Encoding($false, $true)).GetString($snapshot.Bytes) | ConvertFrom-Json)
            VersionGuard = $runtimeVersionGuard
        }
        $runtimeVersionGuard = $null
        return $result
    } finally {
        Close-SafeUpdateVersionGuard $runtimeVersionGuard
    }
}

function Get-FlowProxyProtocolTypes([string]$Text) {
    $types = @()
    $squareDepth = 0
    $braceDepth = 0
    $quote = [char]0
    $escaped = $false
    $comment = $false
    $fieldStart = -1
    $typeValueStart = -1
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        if ($comment) {
            if ($character -eq "`r" -or $character -eq "`n") { $comment = $false }
            continue
        }
        if ($quote -ne [char]0) {
            if ($quote -eq '"') {
                if ($escaped) {
                    $escaped = $false
                } elseif ($character -eq '\') {
                    $escaped = $true
                } elseif ($character -eq $quote) {
                    $quote = [char]0
                }
            } elseif ($character -eq $quote) {
                if ($index + 1 -lt $Text.Length -and $Text[$index + 1] -eq "'") {
                    $index += 1
                } else {
                    $quote = [char]0
                }
            }
            continue
        }
        if ($character -eq "#") { $comment = $true; continue }
        if ($character -eq "'" -or $character -eq '"') { $quote = $character; continue }
        if ($character -eq "[") { $squareDepth += 1; continue }
        if ($character -eq "]") { $squareDepth -= 1; continue }
        if ($character -eq "{") {
            $braceDepth += 1
            if ($squareDepth -eq 1 -and $braceDepth -eq 1) { $fieldStart = $index + 1 }
            continue
        }
        if ($character -eq ":" -and $squareDepth -eq 1 -and $braceDepth -eq 1 -and $fieldStart -ge 0) {
            $key = ConvertFrom-SubscriptionScalar `
                $Text.Substring($fieldStart, $index - $fieldStart) "代理字段"
            if ($key -ieq "type") { $typeValueStart = $index + 1 }
            continue
        }
        if (($character -eq "," -or $character -eq "}") -and
            $squareDepth -eq 1 -and $braceDepth -eq 1) {
            if ($typeValueStart -ge 0) {
                $types += (ConvertFrom-SubscriptionScalar `
                    $Text.Substring($typeValueStart, $index - $typeValueStart) "代理类型").ToLowerInvariant()
            }
            $typeValueStart = -1
            $fieldStart = $index + 1
            if ($character -eq "}") { $braceDepth -= 1; $fieldStart = -1 }
            continue
        }
        if ($character -eq "}") { $braceDepth -= 1 }
    }
    return @($types)
}

function Get-YamlBlockSequenceEnd([string[]]$Lines, [int]$KeyIndex, [int]$KeyIndent, [int]$SearchEnd) {
    $finish = $KeyIndex + 1
    $itemIndent = $null
    for ($index = $KeyIndex + 1; $index -lt $SearchEnd; $index++) {
        $line = $Lines[$index]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $indent = Get-YamlIndent $line
        $trim = $line.TrimStart()
        if ($trim.StartsWith("#")) {
            if ($null -ne $itemIndent -and $indent -le $KeyIndent) { break }
            continue
        }
        if ($null -eq $itemIndent) {
            if ($indent -lt $KeyIndent -or -not ($trim -eq "-" -or $trim.StartsWith("- "))) { break }
            $itemIndent = $indent
            $finish = $index + 1
            continue
        }
        if ($indent -eq $itemIndent -and ($trim -eq "-" -or $trim.StartsWith("- "))) {
            $finish = $index + 1
            continue
        }
        if ($indent -le $KeyIndent) { break }
        if ($indent -lt $itemIndent) { break }
        $finish = $index + 1
    }
    return $finish
}

function ConvertFrom-ProxyProtocolType([string]$Value) {
    $type = (ConvertFrom-SubscriptionScalar $Value "代理类型").ToLowerInvariant()
    if ($type.StartsWith("*") -or $type.StartsWith("&")) {
        throw "proxies 清单无法解析，无法核对协议。"
    }
    return $type
}

function Get-ProxyProtocolTypes([string]$Text) {
    $lines = @(Split-YamlLines $Text)
    $node = Find-YamlMappingNode $lines "proxies" 0 0 $lines.Count
    if ($null -eq $node) { return @() }
    $inline = ([string]$node.Value).Trim()
    if ($inline -eq "[]") { return @() }
    if ($inline.StartsWith("[")) {
        $flowTypes = @(Get-FlowProxyProtocolTypes (($lines[$node.Start..($node.End - 1)]) -join "`n"))
        if ($flowTypes.Count -eq 0) { throw "proxies 清单无法解析，无法核对协议。" }
        return @($flowTypes | ForEach-Object { ConvertFrom-ProxyProtocolType $_ })
    }
    if (-not [string]::IsNullOrWhiteSpace($inline) -and -not $inline.StartsWith("#")) {
        throw "proxies 不是受支持的清单，无法核对协议。"
    }

    $end = Get-YamlBlockSequenceEnd $lines $node.Start $node.Indent $lines.Count
    if ($end -le ($node.Start + 1)) { throw "proxies 清单无法解析，无法核对协议。" }

    $children = @()
    for ($index = $node.Start + 1; $index -lt $end; $index++) {
        $line = $lines[$index]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) { continue }
        $children += [pscustomobject]@{ Index = $index; Indent = Get-YamlIndent $line; Text = $line.TrimStart() }
    }
    if ($children.Count -eq 0) { throw "proxies 清单无法解析，无法核对协议。" }
    $itemIndent = ($children | Measure-Object -Property Indent -Minimum).Minimum
    $itemStarts = @($children | Where-Object {
        $_.Indent -eq $itemIndent -and ($_.Text -eq "-" -or $_.Text.StartsWith("- "))
    })
    if ($itemStarts.Count -eq 0) { throw "proxies 清单无法解析，无法核对协议。" }
    $types = @()
    for ($itemIndex = 0; $itemIndex -lt $itemStarts.Count; $itemIndex++) {
        $item = $itemStarts[$itemIndex]
        $finish = if ($itemIndex + 1 -lt $itemStarts.Count) { $itemStarts[$itemIndex + 1].Index } else { $end }
        $entries = @()
        $tail = $item.Text.Substring(1).TrimStart()
        if (-not [string]::IsNullOrWhiteSpace($tail)) {
            if ($tail.StartsWith("{")) {
                $flow = $tail
                if ($finish -gt ($item.Index + 1)) {
                    $flow = $tail + "`n" + (($lines[($item.Index + 1)..($finish - 1)]) -join "`n")
                }
                $itemTypes = @(Get-FlowProxyProtocolTypes "[$flow]")
                if ($itemTypes.Count -eq 0) { throw "proxies 清单无法解析，无法核对协议。" }
                $types += @($itemTypes | ForEach-Object { ConvertFrom-ProxyProtocolType $_ })
                continue
            }
            $entries += Get-YamlMappingEntry $tail
        }
        $nested = @($children | Where-Object { $_.Index -gt $item.Index -and $_.Index -lt $finish })
        if ($nested.Count -gt 0) {
            $fieldIndent = ($nested | Measure-Object -Property Indent -Minimum).Minimum
            $entries += @($nested | Where-Object { $_.Indent -eq $fieldIndent } | ForEach-Object {
                Get-YamlMappingEntry $_.Text
            })
        }
        $typeEntries = @($entries | Where-Object { $null -ne $_ -and $_.Key -ieq "type" })
        if ($typeEntries.Count -eq 0) { throw "proxies 清单无法解析，无法核对协议。" }
        foreach ($entry in $typeEntries) {
            $types += (ConvertFrom-ProxyProtocolType ([string]$entry.Value))
        }
    }
    return @($types)
}

function Assert-SubscriptionProtocolPreserved([string]$BeforeText, [string]$CandidateText) {
    $beforeTypes = @(Get-ProxyProtocolTypes $BeforeText)
    $candidateTypes = @(Get-ProxyProtocolTypes $CandidateText)
    if ($beforeTypes -contains "anytls" -and $candidateTypes -notcontains "anytls" -and
        ($candidateTypes -contains "ss" -or $candidateTypes -contains "shadowsocks")) {
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

function Test-RestoreCandidate([string]$TargetPath, [byte[]]$Bytes, [int]$UsageProfile) {
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
    if ($UsageProfile -notin @(1, 2, 3)) { throw "没有可用于恢复备份的用途档位。" }
    if ($UsageProfile -lt 3 -and (Test-YamlTunEnabled $text)) {
        throw "备份与已保存用途档位不一致。"
    }
    $core = Find-MihomoCore $MihomoPath
    Test-MihomoCandidate $core $text (Split-Path -Parent $TargetPath)
}

function Open-SafeUpdateVersionGuard([string]$Path, [string]$Label) {
    Initialize-VerifiedFileNative
    $directoryGuards = @(Open-VerifiedDirectoryChain (Split-Path -Parent $Path))
    $handle = $null
    $stream = $null
    try {
        $handle = [ClaudeEasy.VerifiedDeleteNative]::OpenSharedRead($Path)
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
        if ($uid -notmatch '^[A-Za-z0-9._-]+$' -or $file -notmatch '^[A-Za-z0-9._-]+\.ya?ml$') {
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
        try {
            $resolved = Resolve-RemoteSubscriptionTargetPath -Item $item[0] -Directory $Directory -AllowMissing
        } catch {
            throw "远程订阅清单在更新期间发生变化。"
        }
        if ([string]::IsNullOrEmpty($resolved)) {
            $path = [string]$recovery.TargetPath
        } elseif (-not [string]::Equals(
            (Split-Path -Leaf $resolved),
            [string]$recovery.File,
            [StringComparison]::Ordinal
        )) {
            throw "远程订阅清单在更新期间发生变化。"
        } elseif (Test-Path -LiteralPath $resolved -PathType Leaf) {
            $path = (Resolve-Path -LiteralPath $resolved).Path
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
    [object]$ManifestSnapshot,
    [byte[]]$RuntimeRecoveryBytes
) {
    $failures = @()
    $conflicts = @()
    $targets = @()
    foreach ($recovery in $RecoveryItems) {
        try {
            if (-not $ObservedHashes.ContainsKey($recovery.TargetPath)) {
                $conflicts += (Get-PublicSubscriptionLabel ([string]$recovery.Uid) "")
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
                    $conflicts += (Get-PublicSubscriptionLabel ([string]$recovery.Uid) "")
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
                    $conflicts += (Get-PublicSubscriptionLabel ([string]$recovery.Uid) "")
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
            $failures += (Get-PublicSubscriptionLabel ([string]$recovery.Uid) "")
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
            if ($null -ne $RuntimeRecoveryBytes -and $RuntimeRecoveryBytes.Count -gt 0) {
                $manifestTarget | Add-Member -NotePropertyName Bytes -NotePropertyValue $RuntimeRecoveryBytes
                Invoke-VerifiedWriteDeleteTransaction (@($targets) + @($manifestTarget)) @() `
                    -InterruptedRecoveryPolicy "safe_update_running_client"
            } else {
                Invoke-VerifiedWriteDeleteTransaction $targets @($manifestTarget) `
                    -InterruptedRecoveryPolicy "safe_update_running_client"
            }
        } catch {
            $failures = @($RecoveryItems | ForEach-Object {
                Get-PublicSubscriptionLabel ([string]$_.Uid) ""
            })
        }
    }
    return [pscustomobject]@{ Failures = @($failures); Conflicts = @($conflicts) }
}
