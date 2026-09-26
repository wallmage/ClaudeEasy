function Get-RemoteSubscriptionHttpBytes([string]$Url, [int]$TimeoutSeconds = 30) {
    if ([string]::IsNullOrWhiteSpace($Url)) { throw "远程订阅缺少 url。" }
    try {
        $uri = [Uri]$Url
    } catch {
        throw "远程订阅 url 无效。"
    }
    if ($uri.Scheme -notin @("http", "https") -or
        [string]::IsNullOrWhiteSpace($uri.Host)) {
        throw "远程订阅 url 只支持 HTTP 或 HTTPS。"
    }
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $handler.UseProxy = $true
    $handler.Proxy = [System.Net.WebRequest]::DefaultWebProxy
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $client = New-Object System.Net.Http.HttpClient($handler)
    if ($TimeoutSeconds -lt 1) { throw "远程订阅读取超时。" }
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $request = New-Object System.Net.Http.HttpRequestMessage(
        [System.Net.Http.HttpMethod]::Get,
        $uri
    )
    $response = $null
    try {
        $request.Headers.AcceptLanguage.ParseAdd("zh-CN,zh;q=0.9")
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "远程订阅请求失败（HTTP $([int]$response.StatusCode)）。"
        }
        $bytes = [byte[]]$response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        if ($bytes.Length -eq 0 -or $bytes.Length -gt 52428800) {
            throw "远程订阅内容大小不受支持。"
        }
        return $bytes
    } catch {
        if ($_.Exception.Message -like "远程订阅请求失败*" -or
            $_.Exception.Message -eq "远程订阅内容大小不受支持。") {
            throw $_
        }
        throw "读取远程订阅失败。"
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
        $client.Dispose()
        $handler.Dispose()
    }
}

function ConvertTo-RemoteSubscriptionBytes([object]$Content) {
    if ($Content -is [byte[]]) { return $Content }
    if ($Content -is [System.Array] -and @($Content | Where-Object { $_ -isnot [byte] }).Count -eq 0) {
        return [byte[]]$Content
    }
    if ($Content -is [string]) { return ConvertTo-Utf8Bytes ([string]$Content) }
    throw "远程订阅读取结果不是文本或字节。"
}

function Test-RemoteSubscriptionSemanticEqual([hashtable]$Before, [hashtable]$After) {
    $keys = @($Before.Keys) + @($After.Keys) | Sort-Object -Unique
    foreach ($key in $keys) {
        if (-not $Before.ContainsKey($key) -or
            -not $After.ContainsKey($key) -or
            [string]$Before[$key] -cne [string]$After[$key]) {
            return $false
        }
    }
    return $true
}

function Protect-SubscriptionDetailName([string]$Name, [string[]]$Servers = @()) {
    if ($Servers -contains $Name) { return '[redacted]' }
    $safe = Protect-ClaudeEasyResultText $Name
    $safe = $safe -replace '(?i)(?<![\w])(?:[0-9a-f]{0,4}:){2,}[0-9a-f:.]*', '[redacted]'
    $safe = $safe -replace '(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)', '[redacted]'
    return $safe
}

# Bounded block extraction; existing YAML readers own scalar, mapping and sequence syntax.
function Get-SubscriptionDetailBlocks([string]$Text, [string]$Section) {
    $located = Get-ClashRuntimeYamlNode $Text @($Section)
    $entry = Get-ClashRuntimeYamlMappingEntry $located.Lines[$located.Node.Start]
    $quote = ''; $flow = 0
    $value = (Remove-YamlComment $entry.Value ([ref]$quote) ([ref]$flow)).Trim()
    if ($value -in @('[]', '{}')) { return ,([ordered]@{}) }
    if ($value) { throw 'detail unconfirmed' }
    $blocks = [ordered]@{}
    $starts = @(); $indent = -1
    for ($i = $located.Node.Start + 1; $i -lt $located.Node.End; $i++) {
        $line = $located.Lines[$i]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
        if ($indent -lt 0) { $indent = Get-YamlIndent $line }
        if ((Get-YamlIndent $line) -eq $indent) { $starts += $i }
    }
    for ($n = 0; $n -lt $starts.Count; $n++) {
        $start = $starts[$n]
        $end = if ($n + 1 -lt $starts.Count) { $starts[$n + 1] } else { $located.Node.End }
        $line = $located.Lines[$start].TrimStart()
        if ($Section -eq 'rules') {
            if ($line -notmatch '^-\s+(.+)$') { throw 'detail unconfirmed' }
            $raw = $Matches[1]
            for ($i = $start + 1; $i -lt $end; $i++) {
                $extra = $located.Lines[$i]
                if (-not [string]::IsNullOrWhiteSpace($extra) -and -not $extra.TrimStart().StartsWith('#')) { throw 'detail unconfirmed' }
            }
            $quote = ''; $flow = 0
            $name = (Remove-YamlComment $raw ([ref]$quote) ([ref]$flow)).Trim()
            if ($name -match '^[''"]') { $name = ConvertFrom-SubscriptionScalar $name 'rule' -YamlEscapes }
            elseif ($name -match '[\[\]{}&*!|>]' -or $quote -or $flow) { throw 'detail unconfirmed' }
            $body = ''
        } elseif ($Section -in @('proxies', 'proxy-groups')) {
            if ($line -notmatch '^-\s+(.+)$') { throw 'detail unconfirmed' }
            $bodyLines = @($Matches[1])
            for ($i = $start + 1; $i -lt $end; $i++) {
                $child = $located.Lines[$i]
                if ([string]::IsNullOrWhiteSpace($child) -or $child.TrimStart().StartsWith('#')) { continue }
                if ((Get-YamlIndent $child) -lt $indent + 2) { throw 'detail unconfirmed' }
                $bodyLines += $child.Substring($indent + 2)
            }
            if ($Section -eq 'proxy-groups') {
                $bodyLines = @($bodyLines | ForEach-Object {
                    # Only flat, plain member names; normalize for the existing block sequence reader.
                    if ($_ -match '^(proxies|use):\s*\[([^\[\]{}"'':#&*!|>\r\n]*)\]\s*(?:#.*)?$') {
                        $key = $Matches[1]; $members = $Matches[2]
                        "${key}:"
                        if ($members.Trim()) {
                            foreach ($member in $members.Split(',')) {
                                '  - ' + (ConvertFrom-SubscriptionScalar $member 'member')
                            }
                        }
                    } else { $_ }
                })
            }
            $body = $bodyLines -join "`n"
            $named = Get-ClashRuntimeYamlNode $body @('name')
            $nameEntry = Get-ClashRuntimeYamlMappingEntry $named.Lines[$named.Node.Start]
            $name = ConvertFrom-SubscriptionScalar $nameEntry.Value 'name' -YamlEscapes
        } else {
            $provider = Get-ClashRuntimeYamlMappingEntry $line
            if ($null -eq $provider -or $provider.Value -or $end -le $start + 1) { throw 'detail unconfirmed' }
            $name = $provider.Key
            $body = (@($located.Lines[($start + 1)..($end - 1)]) -join "`n")
        }
        if ($blocks.Contains($name)) { throw 'detail unconfirmed' }
        # Aliases, tags, flow maps and multiline scalars need a full YAML parser.
        if ($body -match '(?m)(?:^|:\s*|-\s+)[&*!|>{\[]' -or $name -match '^[&*!|>\[{]') { throw 'detail unconfirmed' }
        foreach ($bodyLine in @(Split-YamlLines $body)) {
            if ([string]::IsNullOrWhiteSpace($bodyLine) -or $bodyLine.TrimStart().StartsWith('#')) { continue }
            if (-not $bodyLine.TrimStart().StartsWith('- ') -and $null -eq (Get-YamlMappingEntry $bodyLine)) { throw 'detail unconfirmed' }
        }
        $blocks.Add($name, $body)
    }
    return ,$blocks
}

function Get-SubscriptionCheckDetails([string]$Before, [string]$After, [hashtable]$Local, [hashtable]$Remote) {
    $details = @()
    $servers = @(@(Split-YamlLines $Before) + @(Split-YamlLines $After) | ForEach-Object {
        $entry = Get-YamlMappingEntry ($_ -replace '^\s*-\s+', '')
        if ($null -ne $entry -and $entry.Key -ceq 'server') {
            try { ConvertFrom-SubscriptionScalar $entry.Value 'server' -YamlEscapes } catch { }
        }
    })
    $paths = @(@($Local.Keys) + @($Remote.Keys) | Sort-Object -Unique | Where-Object {
        -not $Local.ContainsKey($_) -or -not $Remote.ContainsKey($_) -or $Local[$_] -cne $Remote[$_]
    })
    foreach ($section in @($paths | ForEach-Object { ($_ -split '\.')[0] } | Sort-Object -Unique)) {
        $action = if (-not $Local.ContainsKey($section)) { 'added' } elseif (-not $Remote.ContainsKey($section)) { 'removed' } else { 'modified' }
        $sectionAction = $action
        if ($section -notin @('proxies', 'proxy-groups', 'rules', 'proxy-providers', 'rule-providers')) {
            $details += @{ section = Protect-SubscriptionDetailName $section; action = $action; fields = @($paths | Where-Object { ($_ -split '\.')[0] -ceq $section } | ForEach-Object { Protect-SubscriptionDetailName $_ }) }
            continue
        }
        try {
            $old = [ordered]@{}; $new = [ordered]@{}
            if ($Local.ContainsKey($section)) { $old = Get-SubscriptionDetailBlocks $Before $section }
            if ($Remote.ContainsKey($section)) { $new = Get-SubscriptionDetailBlocks $After $section }
            $sectionDetails = @()
            foreach ($name in @(@($old.Keys) + @($new.Keys) | Sort-Object -Unique -CaseSensitive)) {
                $fields = @(); $added = @(); $removed = @()
                $action = if (-not $old.Contains($name)) { 'added' } elseif (-not $new.Contains($name)) { 'removed' } else { 'modified' }
                $left = @{}; $right = @{}
                if ($old.Contains($name)) { $left = Get-YamlPathFingerprints $old[$name] -RequireComplete }
                if ($new.Contains($name)) { $right = Get-YamlPathFingerprints $new[$name] -RequireComplete }
                $fields = @(@($left.Keys) + @($right.Keys) | Sort-Object -Unique | Where-Object {
                    -not $left.ContainsKey($_) -or -not $right.ContainsKey($_) -or $left[$_] -cne $right[$_]
                })
                if ($action -eq 'modified' -and $fields.Count -eq 0) { continue }
                $detail = @{ section = $section; action = $action; name = Protect-SubscriptionDetailName $name $servers; fields = @($fields | ForEach-Object { Protect-SubscriptionDetailName $_ }) }
                if ($section -eq 'rules') {
                    $detail.name = Protect-SubscriptionDetailName ($name -replace '(?i)(\b(?:SRC-PORT|DST-PORT|IN-PORT)\s*,)[^,()]+', '${1}[redacted]') $servers
                }
                if ($section -eq 'proxy-groups') {
                    foreach ($field in @('proxies', 'use')) {
                        $a = @(); $b = @()
                        if ($left.ContainsKey($field)) { $a = @(Get-ClashRuntimeYamlSequence $old[$name] @($field)) }
                        if ($right.ContainsKey($field)) { $b = @(Get-ClashRuntimeYamlSequence $new[$name] @($field)) }
                        $added += @($b | Where-Object { $a -cnotcontains $_ } | ForEach-Object { Protect-SubscriptionDetailName $_ $servers })
                        $removed += @($a | Where-Object { $b -cnotcontains $_ } | ForEach-Object { Protect-SubscriptionDetailName $_ $servers })
                    }
                    $detail['added'] = @($added); $detail['removed'] = @($removed)
                    if ($action -eq 'modified' -and $added.Count -eq 0 -and $removed.Count -eq 0 -and
                        @($fields | Where-Object { $_ -notin @('proxies', 'use') }).Count -eq 0) { $detail.action = 'reordered' }
                }
                $sectionDetails += $detail
            }
            $oldOrder = @($old.Keys | Where-Object { $new.Contains($_) })
            $newOrder = @($new.Keys | Where-Object { $old.Contains($_) })
            if ($section -in @('proxies', 'proxy-groups', 'rules') -and
                ($oldOrder | ConvertTo-Json -Compress) -cne ($newOrder | ConvertTo-Json -Compress)) {
                $sectionDetails += @{ section = $section; action = 'reordered'; fields = @() }
            }
            $details += $sectionDetails
        } catch {
            $details += @{
                section = $section; action = $sectionAction; status = 'unconfirmed'
                fields = @($paths | Where-Object { ($_ -split '\.')[0] -ceq $section } | ForEach-Object { Protect-SubscriptionDetailName $_ })
                reason_zh = '该部分未能完整解析；只能确认列出的配置位置有差异，具体节点或成员尚未确认。'
            }
        }
    }
    return @($details)
}

function Get-SubscriptionCheckResult([string]$AppHome, [string]$SubscriptionName) {
    $results = @()
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $indexPath = Join-Path $AppHome 'profiles.yaml'
        $index = Get-OptionalFileSnapshot $indexPath '订阅索引'
        if (-not $index.Exists) { throw 'missing index' }
        $records = @(Get-RemoteSubscriptionProfileItems @(Split-YamlLines ($utf8.GetString($index.Bytes))) | Where-Object { $_.Type -eq 'remote' })
        foreach ($record in $records) {
            if ($record.NameRaw -match '^\s*[''"]') { $record.Name = ConvertFrom-SubscriptionScalar ([string]$record.NameRaw) 'name' -YamlEscapes }
        }
        if ($SubscriptionName) {
            $records = @($records | Where-Object { $_.Name -ceq $SubscriptionName })
            if ($records.Count -ne 1) { throw 'ambiguous subscription' }
        }
        if ($records.Count -eq 0) { throw 'no remote subscriptions' }
        $resolvedPaths = @{}
        $uniquePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($record in $records) {
            try {
                $path = Resolve-RemoteSubscriptionTargetPath -Item $record -Directory (Join-Path $AppHome 'profiles')
            } catch {
                $path = $null
            }
            if ($path -and -not $uniquePaths.Add($path)) { throw 'ambiguous subscription file' }
            $resolvedPaths[[string]$record.Uid] = $path
        }
        foreach ($record in $records) {
            $item = [ordered]@{
                id = 'ce-subscription-v1-' + (Get-BytesSha256 (ConvertTo-Utf8Bytes ([string]$record.Uid)))
                name = Protect-ClaudeEasyResultText ([string]$record.Name)
                status = 'failed'
                update_available = $null
                comparison_basis = 'local_subscription'
                details = @()
                detail_status = 'unconfirmed'
            }
            try {
                $path = $resolvedPaths[[string]$record.Uid]
                if (-not $path) { throw 'missing subscription file' }
                $before = Get-OptionalFileSnapshot $path '本地订阅'
                if (-not $before.Exists -or $record.UrlCount -ne 1) { throw 'invalid subscription' }
                $url = ConvertFrom-SubscriptionScalar ([string]$record.UrlRaw) 'url'
                $remoteBytes = Get-RemoteSubscriptionHttpBytes $url
                $localText = $utf8.GetString($before.Bytes).TrimStart([char]0xFEFF)
                $remoteText = $utf8.GetString([byte[]]$remoteBytes).TrimStart([char]0xFEFF)
                Test-GeneratedYaml $localText '本地订阅' | Out-Null
                Test-GeneratedYaml $remoteText '远程订阅' | Out-Null
                $local = Get-YamlPathFingerprints $localText -RequireComplete
                $remote = Get-YamlPathFingerprints $remoteText -RequireComplete
                if ($local.Count -eq 0 -or $remote.Count -eq 0) { throw 'invalid subscription body' }
                $after = Get-OptionalFileSnapshot $path '本地订阅'
                $indexAfter = Get-OptionalFileSnapshot $indexPath '订阅索引'
                if (-not $after.Exists -or $before.Identity -cne $after.Identity -or
                    (Get-BytesSha256 $before.Bytes) -cne (Get-BytesSha256 $after.Bytes) -or
                    -not $indexAfter.Exists -or $index.Identity -cne $indexAfter.Identity -or
                    (Get-BytesSha256 $index.Bytes) -cne (Get-BytesSha256 $indexAfter.Bytes)) { throw 'local snapshot changed' }
                $item.details = @(Get-SubscriptionCheckDetails $localText $remoteText $local $remote)
                $item.detail_status = if (@($item.details | Where-Object { $_.status -eq 'unconfirmed' }).Count) { 'unconfirmed' } else { 'confirmed' }
                if ($item.detail_status -eq 'unconfirmed') { throw 'subscription_details_incomplete' }
                $changed = $item.details.Count -gt 0
                $item.status = if ($changed) { 'pending' } else { 'unchanged' }
                $item.update_available = [bool]$changed
            } catch {
                $item['code'] = if ($_.Exception.Message -ceq 'subscription_details_incomplete') { 'subscription_details_incomplete' } else { 'subscription_check_failed' }
                if ($_.Exception.Message -match '^远程订阅请求失败（HTTP ([1-5][0-9]{2})）。$') {
                    $item['code'] = 'subscription_http_' + $Matches[1]
                }
            }
            $results += [pscustomobject]$item
        }
    } catch {
        $results = @()
    }
    $failed = @($results | Where-Object { $_.status -eq 'failed' }).Count
    $status = 'failed'; $code = 'subscription_check_failed'; $summary = '订阅检查失败；本次未修改配置。'; $exitCode = 1
    if ($results.Count -gt 0 -and $failed -eq 0) {
        $exitCode = 0
        if (@($results | Where-Object { $_.update_available }).Count -gt 0) {
            $status = 'ok'; $code = 'subscription_updates_available'; $summary = '订阅与本地配置有变化；本次未修改配置。'
        } else {
            $status = 'no_change'; $code = 'subscriptions_unchanged'; $summary = '订阅与本地配置无变化；本次未修改配置。'
        }
    } elseif ($failed -gt 0 -and $failed -lt $results.Count) {
        $status = 'partial'; $code = 'subscription_check_partial'; $summary = '部分订阅检查失败；本次未修改配置。'
    }
    return [pscustomobject]@{ status = $status; code = $code; summary_zh = $summary; exit_code = $exitCode; changes = @(); items = @($results) }
}
