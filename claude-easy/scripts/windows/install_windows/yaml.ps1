function Split-YamlLines([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    $lines = @($Text -split "`r?`n")
    if ($lines.Count -gt 0) { $lines[0] = $lines[0].TrimStart([char]0xFEFF) }
    return $lines
}
function Join-YamlLines([string[]]$Lines) {
    if ($Lines.Count -eq 0) { return "" }
    $text = $Lines -join "`r`n"
    if (-not $text.EndsWith("`r`n")) { $text += "`r`n" }
    return $text
}

function Get-YamlIndent([string]$Line) {
    if ($Line -match '^ *\t') { throw "YAML 使用了制表符缩进，无法安全修改。" }
    if ($Line -match '^( *)') { return $Matches[1].Length }
    return 0
}

function Get-YamlMappingEntry([string]$Line) {
    $pattern = '^\s*(?:"([A-Za-z0-9_-]+)"|''([A-Za-z0-9_-]+)''|([A-Za-z0-9_-]+))\s*:\s*(.*)$'
    if ($Line -notmatch $pattern) { return $null }
    $key = @($Matches[1], $Matches[2], $Matches[3]) | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -First 1
    return [pscustomobject]@{ Key = $key; Value = $Matches[4] }
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

function Get-YamlPathFingerprints([string]$Text) {
    $lines = @(Split-YamlLines $Text)
    $values = @{}
    $stack = New-Object System.Collections.ArrayList

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) { continue }
        if ($line -match "`t") { throw "YAML 使用了制表符缩进，无法安全比较。" }
        $indent = Get-YamlIndent $line
        $trimmed = $line.TrimStart()
        $sequenceItem = $trimmed.StartsWith("- ")
        while ($stack.Count -gt 0 -and
               [int]$stack[$stack.Count - 1].Indent -ge $indent -and
               -not ($sequenceItem -and [int]$stack[$stack.Count - 1].Indent -eq $indent)) {
            $stack.RemoveAt($stack.Count - 1)
        }
        if ($sequenceItem) {
            if ($stack.Count -eq 0) { continue }
            $path = [string]$stack[$stack.Count - 1].Path
            $values[$path].Add((($trimmed -replace '\s+#.*$', '').Trim()))
            [void]$stack.Add([pscustomobject]@{ Indent = $indent; Path = $path; Sequence = $true })
            continue
        }
        if ($stack.Count -gt 0 -and $stack[$stack.Count - 1].Sequence) {
            $values[[string]$stack[$stack.Count - 1].Path].Add((($trimmed -replace '\s+#.*$', '').Trim()))
            continue
        }
        $entry = Get-YamlMappingEntry $trimmed
        if ($null -eq $entry) {
            if ($stack.Count -eq 0) { continue }
            $path = [string]$stack[$stack.Count - 1].Path
            if (-not $values.ContainsKey($path)) { $values[$path] = New-Object System.Collections.Generic.List[string] }
            $values[$path].Add($trimmed)
            continue
        }
        $parent = if ($stack.Count -eq 0) { "" } else { [string]$stack[$stack.Count - 1].Path }
        $path = if ([string]::IsNullOrWhiteSpace($parent)) { [string]$entry.Key } else { "$parent.$($entry.Key)" }
        if ($values.ContainsKey($path)) { throw "YAML 中存在重复键：$path。无法安全比较。" }
        $values[$path] = New-Object System.Collections.Generic.List[string]
        $value = ($entry.Value -replace '\s+#.*$', '').Trim()
        if (-not [string]::IsNullOrWhiteSpace($value)) { $values[$path].Add($value) }
        [void]$stack.Add([pscustomobject]@{ Indent = $indent; Path = $path; Sequence = $false })
    }

    $fingerprints = @{}
    foreach ($path in $values.Keys) {
        $fingerprints[$path] = Get-BytesSha256 (ConvertTo-Utf8Bytes (($values[$path].ToArray()) -join "`n"))
    }
    return $fingerprints
}

function Get-RedactedYamlChangedPaths([string]$Before, [string]$After) {
    if ($Before -ceq $After) { return @() }
    $beforeSections = Get-YamlPathFingerprints $Before
    $afterSections = Get-YamlPathFingerprints $After
    $keys = @($beforeSections.Keys) + @($afterSections.Keys) | Sort-Object -Unique
    $changes = @($keys | Where-Object {
        -not $beforeSections.ContainsKey($_) -or
        -not $afterSections.ContainsKey($_) -or
        $beforeSections[$_] -ne $afterSections[$_]
    })
    if ($changes.Count -eq 0) { return @("无法安全识别的配置区域") }
    return @($changes | ForEach-Object {
        $parts = @([string]$_ -split '\.')
        if ($parts.Count -gt 1 -and $parts[0] -in @(
            "proxies", "proxy-groups", "proxy-providers", "rule-providers", "hosts"
        )) {
            $parts[1] = "[item]"
        } elseif ($parts.Count -gt 2 -and $parts[0] -eq "dns" -and
            $parts[1] -in @("hosts", "nameserver-policy")) {
            $parts[2] = "[item]"
        } elseif ($parts.Count -gt 2 -and $parts[0] -eq "script" -and $parts[1] -eq "shortcuts") {
            $parts[2] = "[item]"
        }
        $parts -join "."
    } | Sort-Object -Unique)
}

function Find-YamlMappingNode(
    [string[]]$Lines,
    [string]$Key,
    [int]$Indent,
    [int]$SearchStart,
    [int]$SearchEnd
) {
    $foundIndexes = @()
    for ($i = $SearchStart; $i -lt $SearchEnd; $i++) {
        $line = $Lines[$i]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) { continue }
        if ((Get-YamlIndent $line) -ne $Indent) { continue }
        $entry = Get-YamlMappingEntry $line
        if ($null -ne $entry -and $entry.Key -eq $Key) {
            $foundIndexes += $i
        }
    }
    if ($foundIndexes.Count -gt 1) { throw "YAML 中存在重复键：$Key。原文件没有被修改。" }
    if ($foundIndexes.Count -eq 0) { return $null }

    $start = [int]$foundIndexes[0]
    $finish = $SearchEnd
    $pendingSiblingComment = -1
    for ($i = $start + 1; $i -lt $SearchEnd; $i++) {
        $line = $Lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $lineIndent = Get-YamlIndent $line
        if ($line.TrimStart().StartsWith("#")) {
            if ($lineIndent -le $Indent -and $pendingSiblingComment -lt 0) {
                $pendingSiblingComment = $i
            }
            continue
        }
        if ($lineIndent -eq $Indent -and $line.TrimStart().StartsWith("- ")) {
            $pendingSiblingComment = -1
            continue
        }
        if ($lineIndent -lt $Indent -or
            $lineIndent -eq $Indent) {
            $finish = if ($pendingSiblingComment -ge 0) {
                $pendingSiblingComment
            } else {
                $i
            }
            break
        }
    }
    if ($pendingSiblingComment -ge 0 -and $finish -eq $SearchEnd) {
        $finish = $pendingSiblingComment
    }
    $entry = Get-YamlMappingEntry $Lines[$start]
    $value = if ($null -ne $entry) { $entry.Value } else { "" }
    return [pscustomobject]@{ Start = $start; End = $finish; Value = $value; Indent = $Indent }
}

function Replace-YamlRange([string[]]$Lines, [int]$Start, [int]$End, [string[]]$Replacement) {
    $before = @(if ($Start -gt 0) { $Lines[0..($Start - 1)] })
    $after = @(if ($End -lt $Lines.Count) { $Lines[$End..($Lines.Count - 1)] })
    return @($before + $Replacement + $after)
}

function Set-YamlTopLevelScalar([string]$Text, [string]$Key, [string]$Value) {
    $lines = @(Split-YamlLines $Text)
    $node = Find-YamlMappingNode $lines $Key 0 0 $lines.Count
    $comment = ""
    if ($null -ne $node) {
        $semanticValue = ($node.Value -replace '\s+#.*$', '').Trim()
        if ($semanticValue -match '(^|\s)[&*][A-Za-z0-9_-]+(?=\s|$)') {
            throw "$Key 使用了 YAML 锚点或别名，无法安全修改。原文件没有被修改。"
        }
        if ($node.Value -match '(\s+#.*)$') { $comment = $Matches[1] }
    }
    $replacement = @("$Key`: $Value$comment")
    if ($null -eq $node) {
        while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            $lines = if ($lines.Count -eq 1) { @() } else { @($lines[0..($lines.Count - 2)]) }
        }
        return (Join-YamlLines -Lines @($lines + $replacement))
    }
    $updated = Replace-YamlRange -Lines $lines -Start $node.Start -End $node.End -Replacement $replacement
    return (Join-YamlLines -Lines $updated)
}

function Get-ManagedTunLines([int]$Indent, [string]$Key) {
    $prefix = " " * $Indent
    switch ($Key) {
        "enable" { return @("${prefix}enable: true") }
        "stack" { return @("${prefix}stack: system") }
        "dns-hijack" { return @("${prefix}dns-hijack:", "${prefix}  - any:53", "${prefix}  - tcp://any:53") }
        "auto-route" { return @("${prefix}auto-route: true") }
        "auto-detect-interface" { return @("${prefix}auto-detect-interface: true") }
        "strict-route" { return @("${prefix}strict-route: true") }
        default { throw "未知的 TUN 设置：$Key" }
    }
}

function New-ManagedTunBlock {
    $lines = @("tun:")
    foreach ($key in @("enable", "stack", "dns-hijack", "auto-route", "auto-detect-interface", "strict-route")) {
        $lines += @(Get-ManagedTunLines 2 $key)
    }
    return $lines
}

function Set-YamlTunMapping([string]$Text) {
    $lines = @(Split-YamlLines $Text)
    $tun = Find-YamlMappingNode $lines "tun" 0 0 $lines.Count
    if ($null -eq $tun) {
        while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            $lines = if ($lines.Count -eq 1) { @() } else { @($lines[0..($lines.Count - 2)]) }
        }
        $updated = Replace-YamlRange -Lines $lines -Start $lines.Count -End $lines.Count -Replacement @(New-ManagedTunBlock)
        return (Join-YamlLines -Lines $updated)
    }

    $semanticValue = ($tun.Value -replace '\s+#.*$', '').Trim()
    if ($semanticValue -match '^[&*]') {
        throw "config.yaml 的 tun 节点使用了 YAML 锚点或别名，无法安全合并。原文件没有被修改。"
    }
    if ($semanticValue -match '^\{') {
        throw "config.yaml 使用了行内 tun 写法，无法安全合并。原文件没有被修改。"
    }
    if ($semanticValue -ne "" -and $semanticValue -notmatch '^(?:null|~)$') {
        $replacement = @(New-ManagedTunBlock)
        $updated = Replace-YamlRange -Lines $lines -Start $tun.Start -End $tun.End -Replacement $replacement
        return (Join-YamlLines -Lines $updated)
    }
    if ($semanticValue -match '^(?:null|~)$') {
        $replacement = @(New-ManagedTunBlock)
        $updated = Replace-YamlRange -Lines $lines -Start $tun.Start -End $tun.End -Replacement $replacement
        return (Join-YamlLines -Lines $updated)
    }

    $childIndent = 2
    for ($i = $tun.Start + 1; $i -lt $tun.End; $i++) {
        if ([string]::IsNullOrWhiteSpace($lines[$i]) -or $lines[$i].TrimStart().StartsWith("#")) { continue }
        $childIndent = Get-YamlIndent $lines[$i]
        if ($childIndent -le 0) { throw "tun 节点不是有效的 YAML 映射。原文件没有被修改。" }
        break
    }

    foreach ($key in @("enable", "stack", "dns-hijack", "auto-route", "auto-detect-interface", "strict-route")) {
        $tun = Find-YamlMappingNode $lines "tun" 0 0 $lines.Count
        $child = Find-YamlMappingNode $lines $key $childIndent ($tun.Start + 1) $tun.End
        $replacement = @(Get-ManagedTunLines $childIndent $key)
        if ($null -eq $child) {
            $lines = Replace-YamlRange -Lines $lines -Start $tun.End -End $tun.End -Replacement $replacement
        } else {
            $lines = Replace-YamlRange -Lines $lines -Start $child.Start -End $child.End -Replacement $replacement
        }
    }
    return (Join-YamlLines -Lines $lines)
}

function Test-GeneratedYaml([string]$Text, [string]$Label) {
    $lines = @(Split-YamlLines $Text)
    $topKeys = @{}
    $seenContent = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) { continue }
        $trimmed = $line.Trim()
        if ($trimmed -match '^---(?:\s+#.*)?$') {
            if ($seenContent) { throw "$Label 包含多个 YAML 文档，原文件没有被修改。" }
            $seenContent = $true
            continue
        }
        if ($trimmed -match '^\.\.\.(?:\s+#.*)?$') { throw "$Label 包含 YAML 文档结束标记，原文件没有被修改。" }
        $seenContent = $true
        if ((Get-YamlIndent $line) -ne 0) { continue }
        $entry = Get-YamlMappingEntry $line
        if ($null -ne $entry) {
            $key = $entry.Key
            if ($topKeys.ContainsKey($key)) { throw "$Label 生成了重复键：$key。" }
            $topKeys[$key] = $true
        }
    }

    if ($Label -eq "config.yaml") {
        foreach ($key in @("ipv6", "tun")) {
            if (-not $topKeys.ContainsKey($key)) { throw "$Label 缺少设置：$key。" }
        }
        $tun = Find-YamlMappingNode $lines "tun" 0 0 $lines.Count
        foreach ($key in @("enable", "stack", "dns-hijack", "auto-route", "auto-detect-interface", "strict-route")) {
            $found = $false
            for ($i = $tun.Start + 1; $i -lt $tun.End; $i++) {
                if ($lines[$i] -match ('^\s+' + [regex]::Escape($key) + '\s*:')) { $found = $true; break }
            }
            if (-not $found) { throw "$Label 缺少 TUN 设置：$key。" }
        }
    }
    return $true
}

function Get-ClaudeEasyReactivationHotkey([string]$Text) {
    $lines = @(Split-YamlLines $Text)
    $node = Find-YamlMappingNode $lines "hotkeys" 0 0 $lines.Count
    if ($null -eq $node) { return "" }
    $inline = ([string]$node.Value).Trim()
    if ($inline -eq "[]") { return "" }
    if (-not [string]::IsNullOrWhiteSpace($inline)) {
        throw "verge.yaml 的 hotkeys 不是受支持的块状清单。"
    }
    $reactivationMatches = @()
    for ($index = $node.Start + 1; $index -lt $node.End; $index++) {
        $line = [string]$lines[$index]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) { continue }
        if ($line -notmatch '^\s*-\s+(.+?)\s*$') {
            throw "verge.yaml 的 hotkeys 包含不受支持的项目。"
        }
        $entry = ([string]$Matches[1] -replace '\s+#.*$', '').Trim()
        if ($entry.StartsWith("'") -or $entry.StartsWith('"')) {
            $entry = ConvertFrom-SubscriptionScalar $entry "verge.yaml hotkey"
        } elseif ($entry -match '[\r\n\t\[\]\{\}]') {
            throw "verge.yaml hotkey 使用了不受支持的复杂标量。"
        }
        $parts = @($entry.Split(",", 2) | ForEach-Object { $_.Trim() })
        if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or
            [string]::IsNullOrWhiteSpace($parts[1])) {
            throw "verge.yaml 的 hotkeys 包含无效项目。"
        }
        if ($parts[0] -ceq "reactivate_profiles") { $reactivationMatches += $parts[1] }
    }
    if ($reactivationMatches.Count -gt 1) { throw "verge.yaml 存在重复的重新激活订阅快捷键。" }
    return $(if ($reactivationMatches.Count -eq 1) { [string]$reactivationMatches[0] } else { "" })
}

function Set-ClaudeEasyReactivationHotkey([string]$Text) {
    $shortcut = Get-ClaudeEasyReactivationHotkey $Text
    if (-not [string]::IsNullOrWhiteSpace($shortcut)) { return $Text }

    $managedShortcut = "CTRL+ALT+SHIFT+F24"
    $lines = @(Split-YamlLines $Text)
    $node = Find-YamlMappingNode $lines "hotkeys" 0 0 $lines.Count
    if ($null -eq $node) {
        while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            $lines = if ($lines.Count -eq 1) { @() } else { @($lines[0..($lines.Count - 2)]) }
        }
        $replacement = @("hotkeys:", "  - reactivate_profiles,$managedShortcut")
        return (Join-YamlLines -Lines (Replace-YamlRange -Lines $lines -Start $lines.Count -End $lines.Count -Replacement $replacement))
    }

    $inline = ([string]$node.Value).Trim()
    if ($inline -eq "[]") {
        $replacement = @("hotkeys:", "  - reactivate_profiles,$managedShortcut")
        return (Join-YamlLines -Lines (Replace-YamlRange -Lines $lines -Start $node.Start -End $node.End -Replacement $replacement))
    }
    if (-not [string]::IsNullOrWhiteSpace($inline)) {
        throw "verge.yaml 的 hotkeys 不是受支持的块状清单。"
    }

    $itemIndent = 2
    for ($index = $node.Start + 1; $index -lt $node.End; $index++) {
        $line = [string]$lines[$index]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) { continue }
        if ($line -notmatch '^(\s*)-\s+') { throw "verge.yaml 的 hotkeys 包含不受支持的项目。" }
        $itemIndent = $Matches[1].Length
        break
    }
    $replacement = @((" " * $itemIndent) + "- reactivate_profiles,$managedShortcut")
    return (Join-YamlLines -Lines (Replace-YamlRange -Lines $lines -Start $node.End -End $node.End -Replacement $replacement))
}

function Test-YamlTunEnabled([string]$Text) {
    $lines = @(Split-YamlLines $Text)
    $tun = Find-YamlMappingNode $lines "tun" 0 0 $lines.Count
    if ($null -eq $tun) { return $false }

    $enabledValue = $null
    $inline = (($tun.Value -replace '\s+#.*$', '').Trim())
    if ($inline -match '^\{' -and $inline.Contains('}')) {
        if ($inline -match '(?:^|[,{])\s*enable\s*:\s*(.+?)(?:\s*[,}]|$)') {
            $enabledValue = $Matches[1].Trim()
        }
    } else {
        $childIndents = @()
        if ($tun.End -gt ($tun.Start + 1)) {
            $childIndents = @($lines[($tun.Start + 1)..($tun.End - 1)] | Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and -not $_.TrimStart().StartsWith("#")
            } | ForEach-Object { Get-YamlIndent $_ })
        }
        $enabled = if ($childIndents.Count -gt 0) {
            Find-YamlMappingNode $lines "enable" (($childIndents | Measure-Object -Minimum).Minimum) ($tun.Start + 1) $tun.End
        } else { $null }
        if ($null -ne $enabled) { $enabledValue = [string]$enabled.Value }
    }
    if ($null -eq $enabledValue) { return $false }
    return ((ConvertFrom-SubscriptionScalar $enabledValue "tun.enable") -ieq "true")
}
