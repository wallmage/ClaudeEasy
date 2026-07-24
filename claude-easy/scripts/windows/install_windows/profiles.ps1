function Get-RemoteSubscriptionProfileItems([string[]]$Lines) {
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "`t") { throw "profiles.yaml 使用了制表符缩进，无法安全修改。" }
        if ($Lines[$i].Trim() -match '^(?:---|\.\.\.)(?:\s+#.*)?$') {
            throw "profiles.yaml 包含 YAML 文档标记，无法安全修改。"
        }
    }
    $itemsIndexes = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ((Get-YamlIndent $Lines[$i]) -ne 0) { continue }
        $entry = Get-YamlMappingEntry $Lines[$i]
        if ($null -ne $entry -and $entry.Key -eq "items") { $itemsIndexes += $i }
    }
    if ($itemsIndexes.Count -eq 0) { throw "profiles.yaml 缺少 items 清单。" }
    if ($itemsIndexes.Count -gt 1) { throw "profiles.yaml 存在重复 items 清单。" }
    $itemsStart = [int]$itemsIndexes[0]
    $itemsEntry = Get-YamlMappingEntry $Lines[$itemsStart]
    $itemsValue = ($itemsEntry.Value -replace '\s+#.*$', '').Trim()
    if ($itemsValue -ne "") { throw "profiles.yaml 的 items 不是受支持的块状清单。" }
    $itemsEnd = $Lines.Count
    for ($i = $itemsStart + 1; $i -lt $Lines.Count; $i++) {
        if ([string]::IsNullOrWhiteSpace($Lines[$i]) -or $Lines[$i].TrimStart().StartsWith("#")) { continue }
        if ((Get-YamlIndent $Lines[$i]) -ne 0 -or $Lines[$i] -match '^\s*-\s+') { continue }
        if ($null -ne (Get-YamlMappingEntry $Lines[$i])) { $itemsEnd = $i; break }
    }

    $candidateStarts = @()
    for ($i = $itemsStart + 1; $i -lt $itemsEnd; $i++) {
        if ($Lines[$i] -match '^( *)-\s+(.+)$') {
            $candidateStarts += [pscustomobject]@{ Index = $i; Indent = $Matches[1].Length; Inline = $Matches[2] }
        }
    }
    if ($candidateStarts.Count -eq 0) { return @() }
    $itemIndent = ($candidateStarts | Measure-Object -Property Indent -Minimum).Minimum
    $starts = @($candidateStarts | Where-Object { $_.Indent -eq $itemIndent })
    $items = @()
    for ($position = 0; $position -lt $starts.Count; $position++) {
        $start = $starts[$position]
        $finish = if ($position + 1 -lt $starts.Count) { $starts[$position + 1].Index } else { $itemsEnd }
        $fieldIndent = $start.Indent + 2
        $fieldValues = @{}
        $inlineEntry = Get-YamlMappingEntry $start.Inline
        if ($null -ne $inlineEntry) { $fieldValues[[string]$inlineEntry.Key] = @([string]$inlineEntry.Value) }
        $optionIndexes = @()
        for ($i = $start.Index + 1; $i -lt $finish; $i++) {
            if ([string]::IsNullOrWhiteSpace($Lines[$i]) -or $Lines[$i].TrimStart().StartsWith("#")) { continue }
            if ((Get-YamlIndent $Lines[$i]) -ne $fieldIndent) { continue }
            $entry = Get-YamlMappingEntry $Lines[$i]
            if ($null -eq $entry) { continue }
            if (-not $fieldValues.ContainsKey([string]$entry.Key)) { $fieldValues[[string]$entry.Key] = @() }
            $fieldValues[[string]$entry.Key] += [string]$entry.Value
            if ($entry.Key -eq "option") { $optionIndexes += $i }
        }
        $typeValues = @($fieldValues["type"])
        if ($typeValues.Count -ne 1) { throw "profiles.yaml 的订阅项目缺少唯一 type。" }
        if ($optionIndexes.Count -gt 1) { throw "profiles.yaml 的订阅项目存在重复 option。" }
        $typeValue = (($typeValues[0] -replace '\s+#.*$', '').Trim()).Trim("'`"")
        $uidValues = @($fieldValues["uid"])
        $nameValues = @($fieldValues["name"])
        $uidValue = if ($uidValues.Count -eq 1) { (($uidValues[0] -replace '\s+#.*$', '').Trim()).Trim("'`"") } else { "" }
        $nameValue = if ($nameValues.Count -eq 1) { (($nameValues[0] -replace '\s+#.*$', '').Trim()).Trim("'`"") } else { "" }
        if ($typeValue -eq "remote" -and ($uidValues.Count -ne 1 -or $uidValue -notmatch '^[A-Za-z0-9._-]+$')) {
            throw "profiles.yaml 的远程订阅缺少安全且唯一的 uid。"
        }
        $items += [pscustomobject]@{
            Start = $start.Index
            End = $finish
            ItemIndent = $start.Indent
            FieldIndent = $fieldIndent
            Type = $typeValue
            Uid = $uidValue
            Name = $nameValue
            OptionIndex = $(if ($optionIndexes.Count -eq 1) { [int]$optionIndexes[0] } else { -1 })
        }
    }
    $remoteUids = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($items | Where-Object { $_.Type -eq "remote" })) {
        if (-not $remoteUids.Add([string]$item.Uid)) {
            throw "profiles.yaml 存在重复或仅大小写不同的远程订阅 uid。"
        }
    }
    return @($items)
}

function Get-RemoteSubscriptionAutoUpdateStateRecords([string]$Text) {
    $lines = @(Split-YamlLines $Text)
    $items = @(Get-RemoteSubscriptionProfileItems $lines)
    $records = @()
    foreach ($item in $items) {
        $state = "missing"
        $allowIndex = -1
        $optionStyle = "absent"
        $optionLine = ""
        $optionEnd = -1
        if ($item.OptionIndex -ge 0) {
            $optionLine = [string]$lines[$item.OptionIndex]
            $optionEntry = Get-YamlMappingEntry $lines[$item.OptionIndex]
            $optionValue = (($optionEntry.Value -replace '^\s*#.*$', '') -replace '\s+#.*$', '').Trim()
            if ($optionValue -match '^[&*]' -or ($optionValue -match '^\{' -and $optionValue -ne '{}')) {
                throw "profiles.yaml 的 option 使用了无法安全修改的写法。"
            }
            if ($optionValue -notmatch '^(?:null|~|\{\})?$') {
                throw "profiles.yaml 的 option 不是受支持的块状映射。"
            }
            if ($optionValue -eq "") {
                $optionStyle = "block"
                $optionEnd = [int]$item.End
                for ($i = $item.OptionIndex + 1; $i -lt $item.End; $i++) {
                    if ([string]::IsNullOrWhiteSpace($lines[$i])) { continue }
                    $indent = Get-YamlIndent $lines[$i]
                    if (-not $lines[$i].TrimStart().StartsWith("#") -and $indent -le $item.FieldIndent) {
                        $optionEnd = $i
                        break
                    }
                }
                $childIndent = -1
                $allowIndexes = @()
                for ($i = $item.OptionIndex + 1; $i -lt $optionEnd; $i++) {
                    if ([string]::IsNullOrWhiteSpace($lines[$i]) -or $lines[$i].TrimStart().StartsWith("#")) { continue }
                    $indent = Get-YamlIndent $lines[$i]
                    if ($indent -le $item.FieldIndent) { continue }
                    if ($childIndent -lt 0) { $childIndent = $indent }
                    if ($indent -ne $childIndent) { continue }
                    $entry = Get-YamlMappingEntry $lines[$i]
                    if ($null -ne $entry -and $entry.Key -eq "allow_auto_update") { $allowIndexes += $i }
                }
                if ($allowIndexes.Count -gt 1) { throw "profiles.yaml 的 option 存在重复 allow_auto_update。" }
                if ($allowIndexes.Count -eq 1) {
                    $allowIndex = [int]$allowIndexes[0]
                    $allowEntry = Get-YamlMappingEntry $lines[$allowIndex]
                    $allowValue = ($allowEntry.Value -replace '\s+#.*$', '').Trim()
                    if ($allowValue -notin @("true", "false")) {
                        throw "profiles.yaml 的 allow_auto_update 不是布尔值。"
                    }
                    $state = $allowValue
                }
            } elseif ($optionValue -eq "null") {
                $optionStyle = "null"
            } elseif ($optionValue -eq "~") {
                $optionStyle = "tilde"
            } elseif ($optionValue -eq "{}") {
                $optionStyle = "empty_map"
            }
        }
        $records += [pscustomobject]@{
            Uid = $item.Uid
            Type = $item.Type
            State = $state
            AllowIndex = $allowIndex
            OptionIndex = [int]$item.OptionIndex
            OptionEnd = $optionEnd
            FieldIndent = [int]$item.FieldIndent
            OptionStyle = $optionStyle
            OptionLine = $optionLine
        }
    }
    return @($records)
}

function Get-RemoteSubscriptionAutoUpdateOwnership([string]$Text) {
    return @(Get-RemoteSubscriptionAutoUpdateStateRecords $Text | Where-Object {
        $_.Type -eq "remote" -and $_.State -ne "false"
    } | ForEach-Object {
        $optionBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$_.OptionLine)
        [pscustomobject]@{
            Uid = $_.Uid
            OriginalState = $_.State
            OriginalOptionBase64 = [Convert]::ToBase64String($optionBytes)
        }
    })
}

function Restore-RemoteSubscriptionAutoUpdate([string]$Text, [object[]]$Ownership) {
    $lines = @(Split-YamlLines $Text)
    $records = @(Get-RemoteSubscriptionAutoUpdateStateRecords $Text)
    $validatedOwnership = @(Assert-RemoteSubscriptionAutoUpdateOwnershipState ([pscustomobject]@{
        Version = 1
        Profiles = @($Ownership)
    }))
    $plans = @()
    foreach ($owned in $validatedOwnership) {
        $uid = [string]$owned.Uid
        $originalState = [string]$owned.OriginalState
        $matches = @($records | Where-Object {
            [string]::Equals([string]$_.Uid, $uid, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($matches.Count -gt 1) { throw "profiles.yaml 存在重复远程订阅 uid。" }
        if ($matches.Count -eq 0 -or $matches[0].Type -ne "remote") { continue }
        $current = $matches[0]
        if ($current.State -ne "false") { continue }
        $plans += [pscustomobject]@{
            Uid = $uid
            AllowIndex = [int]$current.AllowIndex
            OptionIndex = [int]$current.OptionIndex
            OptionEnd = [int]$current.OptionEnd
            FieldIndent = [int]$current.FieldIndent
            OriginalState = $originalState
            OriginalOptionBase64 = [string]$owned.OriginalOptionBase64
        }
    }
    foreach ($plan in @($plans | Sort-Object AllowIndex -Descending)) {
        if ($plan.AllowIndex -lt 0 -or $plan.OptionIndex -lt 0) {
            throw "订阅自动更新所有权状态与 profiles.yaml 不一致。"
        }
        $originalOptionBytes = [Convert]::FromBase64String($plan.OriginalOptionBase64)
        try {
            $originalOptionLine = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($originalOptionBytes)
        } catch {
            throw "订阅自动更新所有权状态包含无效 UTF-8。"
        }
        if (-not [string]::IsNullOrEmpty($originalOptionLine)) {
            $originalOptionMatch = [regex]::Match($originalOptionLine, '^( *)option\s*:')
            if (-not $originalOptionMatch.Success) {
                throw "订阅自动更新所有权状态中的 option 行无效。"
            }
            if ($originalOptionMatch.Groups[1].Value.Length -ne $plan.FieldIndent) {
                throw "订阅自动更新所有权状态与当前订阅缩进不一致。"
            }
        }
        if ($plan.OriginalState -eq "true") {
            $entry = Get-YamlMappingEntry $lines[$plan.AllowIndex]
            $prefix = " " * (Get-YamlIndent $lines[$plan.AllowIndex])
            $comment = if ($entry.Value -match '(\s+#.*)$') { $Matches[1] } else { "" }
            $lines[$plan.AllowIndex] = "${prefix}allow_auto_update: true$comment"
            continue
        }
        $hasOtherOptionContent = $false
        for ($i = $plan.OptionIndex + 1; $i -lt $plan.OptionEnd; $i++) {
            if ($i -eq $plan.AllowIndex -or [string]::IsNullOrWhiteSpace($lines[$i])) { continue }
            $hasOtherOptionContent = $true
            break
        }
        if (-not $hasOtherOptionContent -and [string]::IsNullOrEmpty($originalOptionLine)) {
            $lines = Replace-YamlRange -Lines $lines -Start $plan.OptionIndex -End ($plan.AllowIndex + 1) -Replacement @()
            continue
        }
        if (-not $hasOtherOptionContent) {
            $originalEntry = Get-YamlMappingEntry $originalOptionLine
            $originalValue = ($originalEntry.Value -replace '\s+#.*$', '').Trim()
            if ($originalValue -in @("null", "~", "{}")) {
                $originalComment = if ($originalEntry.Value -match '(\s+#.*)$') { $Matches[1] } else { "" }
                $normalizedOptionLine = (" " * $plan.FieldIndent) + "option: $originalValue$originalComment"
                $lines = Replace-YamlRange -Lines $lines -Start $plan.OptionIndex -End ($plan.AllowIndex + 1) -Replacement @($normalizedOptionLine)
                continue
            }
        }
        $lines = Replace-YamlRange -Lines $lines -Start $plan.AllowIndex -End ($plan.AllowIndex + 1) -Replacement @()
    }
    $output = Join-YamlLines -Lines $lines
    $restoredRecords = @(Get-RemoteSubscriptionAutoUpdateStateRecords $output)
    foreach ($plan in $plans) {
        $restored = @($restoredRecords | Where-Object {
            [string]::Equals([string]$_.Uid, [string]$plan.Uid, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($restored.Count -ne 1 -or [string]$restored[0].State -ne [string]$plan.OriginalState) {
            throw "订阅自动更新设置恢复后的语义验证失败。"
        }
    }
    return $output
}

function Assert-RemoteSubscriptionAutoUpdateOwnershipState([object]$State) {
    if ($null -eq $State) { throw "订阅自动更新所有权状态无效。" }
    $statePropertyNames = @($State.PSObject.Properties.Name | Sort-Object)
    if (($statePropertyNames -join ",") -cne "Profiles,Version") {
        throw "订阅自动更新所有权状态字段无效。"
    }
    $version = $State.Version
    if (-not (($version -is [int] -or $version -is [long]) -and [long]$version -eq 1)) {
        throw "订阅自动更新所有权状态版本无效。"
    }
    $profilesProperty = $State.PSObject.Properties["Profiles"]
    if ($null -eq $profilesProperty) { throw "订阅自动更新所有权状态缺少 Profiles。" }
    $profiles = @($profilesProperty.Value)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $validated = @()
    foreach ($profile in $profiles) {
        if ($null -eq $profile) { throw "订阅自动更新所有权状态包含空项目。" }
        $propertyNames = @($profile.PSObject.Properties.Name | Sort-Object)
        if (($propertyNames -join ",") -cne "OriginalOptionBase64,OriginalState,Uid") {
            throw "订阅自动更新所有权状态项目字段无效。"
        }
        $uid = [string]$profile.Uid
        $originalState = [string]$profile.OriginalState
        if ($uid -notmatch '^[A-Za-z0-9._-]+$' -or $originalState -notin @("true", "missing") -or -not $seen.Add($uid)) {
            throw "订阅自动更新所有权状态项目无效。"
        }
        if (-not ($profile.OriginalOptionBase64 -is [string])) {
            throw "订阅自动更新所有权状态项目无效。"
        }
        $encodedOption = [string]$profile.OriginalOptionBase64
        try {
            $optionBytes = [Convert]::FromBase64String($encodedOption)
        } catch {
            throw "订阅自动更新所有权状态项目无效。"
        }
        if ([Convert]::ToBase64String($optionBytes) -cne $encodedOption) {
            throw "订阅自动更新所有权状态项目无效。"
        }
        try {
            $optionLine = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($optionBytes)
        } catch {
            throw "订阅自动更新所有权状态项目无效。"
        }
        if ($optionLine -match "[`r`n`t\0-\x08\x0B\x0C\x0E-\x1F]" -or
            (-not [string]::IsNullOrEmpty($optionLine) -and $optionLine -notmatch '^ +option\s*:')) {
            throw "订阅自动更新所有权状态项目无效。"
        }
        if ([string]::IsNullOrEmpty($optionLine)) {
            if ($originalState -ne "missing") { throw "订阅自动更新所有权状态项目无效。" }
        } else {
            $optionEntry = Get-YamlMappingEntry $optionLine
            if ($null -eq $optionEntry -or $optionEntry.Key -ne "option") {
                throw "订阅自动更新所有权状态项目无效。"
            }
            $optionValue = (($optionEntry.Value -replace '^\s*#.*$', '') -replace '\s+#.*$', '').Trim()
            if ($originalState -eq "true" -and $optionValue -ne "") {
                throw "订阅自动更新所有权状态项目无效。"
            }
            if ($originalState -eq "missing" -and $optionValue -notin @("", "null", "~", "{}")) {
                throw "订阅自动更新所有权状态项目无效。"
            }
        }
        $validated += [pscustomobject]@{
            Uid = $uid
            OriginalState = $originalState
            OriginalOptionBase64 = $encodedOption
        }
    }
    return @($validated)
}

function Merge-RemoteSubscriptionAutoUpdateOwnership([object[]]$Existing, [object[]]$Current) {
    $validatedExisting = @(Assert-RemoteSubscriptionAutoUpdateOwnershipState ([pscustomobject]@{
        Version = 1
        Profiles = @($Existing)
    }))
    $validatedCurrent = @(Assert-RemoteSubscriptionAutoUpdateOwnershipState ([pscustomobject]@{
        Version = 1
        Profiles = @($Current)
    }))
    $merged = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($validatedExisting + $validatedCurrent)) {
        $uid = [string]$entry.Uid
        if ($merged.ContainsKey($uid) -and
            -not [string]::Equals([string]$merged[$uid].Uid, $uid, [StringComparison]::Ordinal)) {
            throw "订阅自动更新所有权状态包含仅大小写不同的 uid。"
        }
        $merged[$uid] = [pscustomobject]@{
            Uid = $uid
            OriginalState = [string]$entry.OriginalState
            OriginalOptionBase64 = [string]$entry.OriginalOptionBase64
        }
    }
    return @($merged.Values | Sort-Object Uid | ForEach-Object {
        [ordered]@{
            Uid = $_.Uid
            OriginalState = $_.OriginalState
            OriginalOptionBase64 = $_.OriginalOptionBase64
        }
    })
}

function Get-RemoteSubscriptionTargets([string]$ProfilesIndexText, [string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { throw "找不到订阅目录。" }
    $items = @(Get-RemoteSubscriptionProfileItems @(Split-YamlLines $ProfilesIndexText) | Where-Object { $_.Type -eq "remote" })
    if ($items.Count -eq 0) { throw "没有可更新的远程订阅。" }
    $targets = @()
    $targetPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $items) {
        $candidates = @(
            (Join-Path $Directory ($item.Uid + ".yaml")),
            (Join-Path $Directory ($item.Uid + ".yml"))
        )
        $matches = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
        if ($matches.Count -ne 1) { throw "远程订阅无法对应到唯一配置文件：$($item.Uid)。" }
        $path = (Resolve-Path -LiteralPath $matches[0]).Path
        if (-not $targetPaths.Add($path)) { throw "多个远程订阅对应到同一配置文件。" }
        $targets += [pscustomobject]@{ Uid = $item.Uid; Name = $item.Name; Path = $path }
    }
    return @($targets)
}

function Set-RemoteSubscriptionAutoUpdateDisabled([string]$Text) {
    $lines = @(Split-YamlLines $Text)
    $items = @(Get-RemoteSubscriptionProfileItems $lines)
    for ($position = $items.Count - 1; $position -ge 0; $position--) {
        $item = $items[$position]
        if ($item.Type -ne "remote") { continue }
        $fieldPrefix = " " * $item.FieldIndent
        if ($item.OptionIndex -lt 0) {
            $lines = Replace-YamlRange -Lines $lines -Start $item.End -End $item.End -Replacement @(
                "${fieldPrefix}option:",
                "${fieldPrefix}  allow_auto_update: false"
            )
            continue
        }

        $optionEntry = Get-YamlMappingEntry $lines[$item.OptionIndex]
        $optionValue = (($optionEntry.Value -replace '^\s*#.*$', '') -replace '\s+#.*$', '').Trim()
        if ($optionValue -match '^[&*]' -or ($optionValue -match '^\{' -and $optionValue -ne '{}')) {
            throw "profiles.yaml 的 option 使用了无法安全修改的写法。"
        }
        if ($optionValue -match '^(?:null|~|\{\})$') {
            $lines = Replace-YamlRange -Lines $lines -Start $item.OptionIndex -End ($item.OptionIndex + 1) -Replacement @(
                "${fieldPrefix}option:",
                "${fieldPrefix}  allow_auto_update: false"
            )
            continue
        }
        if ($optionValue -ne "") { throw "profiles.yaml 的 option 不是受支持的块状映射。" }

        $optionEnd = $item.End
        for ($i = $item.OptionIndex + 1; $i -lt $item.End; $i++) {
            if ([string]::IsNullOrWhiteSpace($lines[$i])) { continue }
            $indent = Get-YamlIndent $lines[$i]
            if (-not $lines[$i].TrimStart().StartsWith("#") -and $indent -le $item.FieldIndent) {
                $optionEnd = $i
                break
            }
        }
        $childIndent = $item.FieldIndent + 2
        $childIndentFound = $false
        $allowIndexes = @()
        for ($i = $item.OptionIndex + 1; $i -lt $optionEnd; $i++) {
            if ([string]::IsNullOrWhiteSpace($lines[$i]) -or $lines[$i].TrimStart().StartsWith("#")) { continue }
            $indent = Get-YamlIndent $lines[$i]
            if ($indent -le $item.FieldIndent) { continue }
            if (-not $childIndentFound) {
                $childIndent = $indent
                $childIndentFound = $true
            }
            if ($indent -ne $childIndent) { continue }
            $entry = Get-YamlMappingEntry $lines[$i]
            if ($null -ne $entry -and $entry.Key -eq "allow_auto_update") { $allowIndexes += $i }
        }
        if ($allowIndexes.Count -gt 1) { throw "profiles.yaml 的 option 存在重复 allow_auto_update。" }
        $childPrefix = " " * $childIndent
        if ($allowIndexes.Count -eq 0) {
            $lines = Replace-YamlRange -Lines $lines -Start $optionEnd -End $optionEnd -Replacement @("${childPrefix}allow_auto_update: false")
        } else {
            $allowIndex = [int]$allowIndexes[0]
            $allowEntry = Get-YamlMappingEntry $lines[$allowIndex]
            $allowValue = ($allowEntry.Value -replace '\s+#.*$', '').Trim()
            if ($allowValue -match '(^|\s)[&*][A-Za-z0-9_-]+(?=\s|$)') {
                throw "profiles.yaml 的 allow_auto_update 使用了 YAML 锚点或别名。"
            }
            $comment = if ($allowEntry.Value -match '(\s+#.*)$') { $Matches[1] } else { "" }
            $lines[$allowIndex] = "${childPrefix}allow_auto_update: false$comment"
        }
    }
    $output = Join-YamlLines -Lines $lines
    Assert-RemoteSubscriptionAutoUpdateDisabled $output | Out-Null
    return $output
}

function Assert-RemoteSubscriptionAutoUpdateDisabled([string]$Text) {
    $lines = @(Split-YamlLines $Text)
    $items = @(Get-RemoteSubscriptionProfileItems $lines)
    foreach ($item in $items) {
        if ($item.Type -ne "remote") { continue }
        if ($item.OptionIndex -lt 0) { throw "远程订阅仍允许自动更新。" }
        $childIndent = -1
        $found = 0
        for ($i = $item.OptionIndex + 1; $i -lt $item.End; $i++) {
            if ([string]::IsNullOrWhiteSpace($lines[$i]) -or $lines[$i].TrimStart().StartsWith("#")) { continue }
            $indent = Get-YamlIndent $lines[$i]
            if ($indent -le $item.FieldIndent) { break }
            if ($childIndent -lt 0) { $childIndent = $indent }
            if ($indent -ne $childIndent) { continue }
            $entry = Get-YamlMappingEntry $lines[$i]
            if ($null -ne $entry -and $entry.Key -eq "allow_auto_update") {
                $value = ($entry.Value -replace '\s+#.*$', '').Trim()
                if ($value -ne "false") { throw "远程订阅仍允许自动更新。" }
                $found++
            }
        }
        if ($found -ne 1) { throw "无法确认远程订阅已经关闭自动更新。" }
    }
    return $true
}
