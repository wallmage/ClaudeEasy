function Get-ClaudeEasyTopLevelScalar([string]$Text, [string]$Key) {
    $lines = @(Split-YamlLines $Text)
    $node = Find-YamlMappingNode $lines $Key 0 0 $lines.Count
    if ($null -eq $node) { return $null }
    for ($i = $node.Start + 1; $i -lt $node.End; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) { continue }
        throw "$Key 不是单值设置。"
    }
    return ConvertFrom-SubscriptionScalar ([string]$node.Value) $Key
}

function Get-ClashVergeReactivationShortcut([string]$VergeText) {
    $enabled = Get-ClaudeEasyTopLevelScalar $VergeText "enable_global_hotkey"
    if ($null -ne $enabled -and $enabled -cne "true") {
        throw "Clash Verge Rev 的全局快捷键没有开启。"
    }
    $shortcut = Get-ClaudeEasyReactivationHotkey $VergeText
    if ([string]::IsNullOrWhiteSpace($shortcut)) {
        throw "没有找到重新激活订阅快捷键；请在客户端未运行时重新安装 ClaudeEasy。"
    }
    return $shortcut
}

function Initialize-ClaudeEasySendInput {
    if ($null -ne ("ClaudeEasy.SendInputNative" -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace ClaudeEasy {
    public static class SendInputNative {
        [StructLayout(LayoutKind.Sequential)]
        public struct INPUT {
            public UInt32 type;
            public InputUnion data;
        }

        [StructLayout(LayoutKind.Explicit)]
        public struct InputUnion {
            [FieldOffset(0)] public KEYBDINPUT keyboard;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct KEYBDINPUT {
            public UInt16 virtualKey;
            public UInt16 scanCode;
            public UInt32 flags;
            public UInt32 time;
            public UIntPtr extraInfo;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern UInt32 SendInput(UInt32 count, INPUT[] inputs, Int32 size);

        public static bool Send(UInt16[] keys) {
            INPUT[] inputs = new INPUT[keys.Length * 2];
            for (int index = 0; index < keys.Length; index++) {
                inputs[index].type = 1;
                inputs[index].data.keyboard.virtualKey = keys[index];
            }
            for (int index = 0; index < keys.Length; index++) {
                int target = keys.Length + index;
                inputs[target].type = 1;
                inputs[target].data.keyboard.virtualKey = keys[keys.Length - index - 1];
                inputs[target].data.keyboard.flags = 2;
            }
            return SendInput((UInt32)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))) == inputs.Length;
        }
    }
}
'@
}

function Invoke-ClashVergeReactivationShortcut([string]$Shortcut) {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw "重新激活订阅只能在 Windows 上执行。"
    }
    $virtualKeys = @()
    $mainKeyCount = 0
    foreach ($part in @($Shortcut.Split("+") | ForEach-Object { $_.Trim().ToUpperInvariant() })) {
        switch -Regex ($part) {
            '^CTRL$' { $virtualKeys += [uint16]0x11; continue }
            '^ALT$' { $virtualKeys += [uint16]0x12; continue }
            '^SHIFT$' { $virtualKeys += [uint16]0x10; continue }
            '^(?:WIN|SUPER|META)$' { $virtualKeys += [uint16]0x5B; continue }
            '^F(?:[1-9]|1[0-9]|2[0-4])$' {
                $virtualKeys += [uint16](0x70 + [int]$part.Substring(1) - 1)
                $mainKeyCount += 1
                continue
            }
            '^[A-Z]$' {
                $virtualKeys += [uint16][char]$part
                $mainKeyCount += 1
                continue
            }
            '^[0-9]$' {
                $virtualKeys += [uint16][char]$part
                $mainKeyCount += 1
                continue
            }
            default { throw "重新激活订阅快捷键包含不受支持的按键。" }
        }
    }
    if ($mainKeyCount -ne 1 -or $virtualKeys.Count -lt 1) {
        throw "重新激活订阅快捷键无效。"
    }
    Initialize-ClaudeEasySendInput
    if (-not [ClaudeEasy.SendInputNative]::Send([uint16[]]$virtualKeys)) {
        throw "无法触发 Clash Verge Rev 重新激活订阅。"
    }
}

function Get-ClashControllerContext([string]$RuntimePath) {
    $snapshot = Get-OptionalFileSnapshot $RuntimePath "Clash Verge Rev 运行配置"
    if (-not $snapshot.Exists) { throw "找不到 Clash Verge Rev 运行配置。" }
    $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($snapshot.Bytes)
    $controller = [string](Get-ClaudeEasyTopLevelScalar $text "external-controller")
    $secret = [string](Get-ClaudeEasyTopLevelScalar $text "secret")
    if ($controller -notmatch '^(?:127\.0\.0\.1|localhost|\[::1\]):([0-9]{1,5})$') {
        throw "Clash Verge Rev 本地控制器不是受支持的回环地址。"
    }
    $controllerPort = [int]$Matches[1]
    if ($controllerPort -lt 1 -or $controllerPort -gt 65535) { throw "Clash Verge Rev 本地控制器端口无效。" }
    $controllerHost = if ($controller.StartsWith("[::1]", [StringComparison]::OrdinalIgnoreCase)) { "[::1]" } else { "127.0.0.1" }
    return [pscustomobject]@{
        BaseUrl = "http://${controllerHost}:$controllerPort"
        Secret = $secret
        RuntimeText = $text
        Snapshot = $snapshot
        LastWriteTicks = [System.IO.File]::GetLastWriteTimeUtc($RuntimePath).Ticks
    }
}

function Invoke-ClashControllerRequest(
    [object]$Context,
    [string]$Method,
    [string]$Endpoint,
    [string]$Body = ""
) {
    $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create(([string]$Context.BaseUrl + $Endpoint))
    $request.Method = $Method
    $request.AllowAutoRedirect = $false
    $request.Proxy = $null
    $request.Timeout = 5000
    $request.ReadWriteTimeout = 5000
    $request.KeepAlive = $false
    if (-not [string]::IsNullOrEmpty([string]$Context.Secret)) {
        $request.Headers.Set([System.Net.HttpRequestHeader]::Authorization, "Bearer " + [string]$Context.Secret)
    }
    if (-not [string]::IsNullOrEmpty($Body)) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $request.ContentType = "application/json"
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    } else {
        $request.ContentLength = 0
    }
    $response = $null
    $reader = $null
    try {
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        $content = ""
        if ($null -ne $response.GetResponseStream()) {
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8, $true)
            $content = $reader.ReadToEnd()
        }
        return [pscustomobject]@{ Status = [int]$response.StatusCode; Content = $content }
    } catch {
        $failedResponse = $_.Exception.Response
        if ($null -ne $failedResponse) { try { $failedResponse.Dispose() } catch { } }
        throw "Clash Verge Rev 本地控制器请求失败。"
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
    }
}

function Get-ClashRuntimeState([object]$Context) {
    $configResponse = Invoke-ClashControllerRequest $Context "GET" "/configs"
    $proxyResponse = Invoke-ClashControllerRequest $Context "GET" "/proxies"
    $ruleResponse = Invoke-ClashControllerRequest $Context "GET" "/rules"
    $providerResponse = Invoke-ClashControllerRequest $Context "GET" "/providers/proxies"
    if ($configResponse.Status -ne 200 -or $proxyResponse.Status -ne 200 -or
        $ruleResponse.Status -ne 200 -or $providerResponse.Status -ne 200) {
        throw "Clash Verge Rev 没有返回当前运行状态。"
    }
    $config = $configResponse.Content | ConvertFrom-Json
    $proxies = ($proxyResponse.Content | ConvertFrom-Json).proxies
    $rules = @((($ruleResponse.Content | ConvertFrom-Json).rules))
    $providers = ($providerResponse.Content | ConvertFrom-Json).providers
    if ($null -eq $proxies -or $null -eq $providers) { throw "Clash Verge Rev 没有返回代理组。" }
    $selections = @{}
    foreach ($property in @($proxies.PSObject.Properties)) {
        if ([string]$property.Value.type -eq "Selector" -and
            -not [string]::IsNullOrWhiteSpace([string]$property.Value.now)) {
            $selections[[string]$property.Name] = [string]$property.Value.now
        }
    }
    return [pscustomobject]@{
        Config = $config
        Proxies = $proxies
        Rules = $rules
        Providers = $providers
        Selections = $selections
        TunEnabled = ($null -ne $config.tun -and [bool]$config.tun.enable)
    }
}

function Restore-ClashRuntimeSelections([object]$Context, [hashtable]$Selections) {
    $current = Get-ClashRuntimeState $Context
    foreach ($name in @($Selections.Keys)) {
        $property = $current.Proxies.PSObject.Properties[[string]$name]
        if ($null -eq $property -or [string]$property.Value.type -ne "Selector") {
            throw "Clash Verge Rev 无法保留原代理选择。"
        }
        $selected = [string]$Selections[$name]
        $members = @($property.Value.all)
        if ($members -cnotcontains $selected) { throw "Clash Verge Rev 无法保留原代理选择。" }
        if ([string]$property.Value.now -eq $selected) { continue }
        $endpoint = "/proxies/" + [Uri]::EscapeDataString([string]$name)
        $body = @{ name = $selected } | ConvertTo-Json -Compress
        $response = Invoke-ClashControllerRequest $Context "PUT" $endpoint $body
        if ($response.Status -notin @(200, 204)) { throw "Clash Verge Rev 没有恢复原代理选择。" }
    }
}

function Wait-ClashVergeRuntimeRefresh([string]$RuntimePath, [object]$PreviousContext) {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        if (Test-Path -LiteralPath $RuntimePath -PathType Leaf) {
            $current = Get-OptionalFileSnapshot $RuntimePath "Clash Verge Rev 运行配置"
            $ticks = [System.IO.File]::GetLastWriteTimeUtc($RuntimePath).Ticks
            if ($current.Exists -and (
                $ticks -ne [long]$PreviousContext.LastWriteTicks -or
                $current.Identity -cne $PreviousContext.Snapshot.Identity -or
                (Get-BytesSha256 $current.Bytes) -cne (Get-BytesSha256 $PreviousContext.Snapshot.Bytes)
            )) {
                return
            }
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Clash Verge Rev 没有重新生成运行配置。"
}

function Wait-ClashVergeRuntimeHealthy(
    [string]$RuntimePath,
    [object]$PreviousContext,
    [hashtable]$Selections,
    [bool]$TunEnabled,
    [int]$Profile,
    [string]$CurlPath,
    [object]$Policy
) {
    Wait-ClashVergeRuntimeRefresh $RuntimePath $PreviousContext
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        try {
            $context = Get-ClashControllerContext $RuntimePath
            Assert-ClashRuntimeHealthy `
                $context $Selections $TunEnabled $Profile $CurlPath $Policy
            return $context
        } catch {
            $lastFailure = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Clash Verge Rev 热加载后没有恢复完整运行状态：$lastFailure"
}

function ConvertFrom-ClashRuntimeYamlScalar([string]$Value) {
    $scalar = ($Value -replace '\s+#.*$', '').Trim()
    if ($scalar.Length -ge 2 -and $scalar[0] -eq "'" -and $scalar[$scalar.Length - 1] -eq "'") {
        return $scalar.Substring(1, $scalar.Length - 2).Replace("''", "'")
    }
    if ($scalar.Length -ge 2 -and $scalar[0] -eq '"' -and $scalar[$scalar.Length - 1] -eq '"') {
        try { return [string]($scalar | ConvertFrom-Json) } catch { throw "运行配置包含无法读取的 YAML 标量。" }
    }
    return $scalar
}

function Get-ClashRuntimeYamlMappingEntry([string]$Line) {
    $trimmed = $Line.TrimStart()
    if ($trimmed -match '^("(?:\\.|[^"\\])*")\s*:\s*(.*)$') {
        try { $key = [string]($Matches[1] | ConvertFrom-Json) } catch {
            throw "运行配置包含无法读取的 YAML 键。"
        }
        return [pscustomobject]@{ Key = $key; Value = [string]$Matches[2] }
    }
    if ($trimmed -match "^('(?:''|[^'])*')\s*:\s*(.*)$") {
        $key = $Matches[1].Substring(1, $Matches[1].Length - 2).Replace("''", "'")
        return [pscustomobject]@{ Key = $key; Value = [string]$Matches[2] }
    }
    if ($trimmed -notmatch '^(.+?):(?=\s|$)\s*(.*)$') { return $null }
    $key = [string]$Matches[1]
    if ([string]::IsNullOrWhiteSpace($key) -or $key.Contains("#")) { return $null }
    return [pscustomobject]@{ Key = $key.Trim(); Value = [string]$Matches[2] }
}

function Get-ClashRuntimeYamlNode([string]$Text, [string[]]$Path) {
    $lines = @(Split-YamlLines $Text)
    $searchStart = 0
    $searchEnd = $lines.Count
    $indent = 0
    $node = $null
    foreach ($key in $Path) {
        $matchingIndexes = @()
        for ($index = $searchStart; $index -lt $searchEnd; $index++) {
            $line = [string]$lines[$index]
            if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#") -or
                (Get-YamlIndent $line) -ne $indent) { continue }
            $entry = Get-ClashRuntimeYamlMappingEntry $line
            if ($null -ne $entry -and [string]$entry.Key -ceq $key) { $matchingIndexes += $index }
        }
        if ($matchingIndexes.Count -ne 1) { throw "Clash Verge Rev 运行配置缺少唯一的受管设置。" }
        $start = [int]$matchingIndexes[0]
        $finish = $searchEnd
        for ($index = $start + 1; $index -lt $searchEnd; $index++) {
            $line = [string]$lines[$index]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ((Get-YamlIndent $line) -le $indent -and -not $line.TrimStart().StartsWith("#")) {
                $finish = $index
                break
            }
        }
        $node = [pscustomobject]@{ Start = $start; End = $finish; Indent = $indent }
        $searchStart = $node.Start + 1
        $searchEnd = $node.End
        $indent = -1
        for ($index = $searchStart; $index -lt $searchEnd; $index++) {
            $line = [string]$lines[$index]
            if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) { continue }
            $indent = Get-YamlIndent $line
            break
        }
        if ($key -ne $Path[$Path.Count - 1] -and $indent -le $node.Indent) {
            throw "Clash Verge Rev 运行配置缺少受管设置。"
        }
    }
    return [pscustomobject]@{ Lines = $lines; Node = $node }
}

function Get-ClashRuntimeYamlMapping([string]$Text, [string[]]$Path) {
    $located = Get-ClashRuntimeYamlNode $Text $Path
    $values = @{}
    $childIndent = -1
    for ($index = $located.Node.Start + 1; $index -lt $located.Node.End; $index++) {
        $line = [string]$located.Lines[$index]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) { continue }
        if ($childIndent -lt 0) { $childIndent = Get-YamlIndent $line }
        if ((Get-YamlIndent $line) -ne $childIndent) { continue }
        $entry = Get-ClashRuntimeYamlMappingEntry $line
        if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.Value)) { continue }
        if ($values.ContainsKey([string]$entry.Key)) { throw "运行配置包含重复的受管设置。" }
        $values[[string]$entry.Key] = ConvertFrom-ClashRuntimeYamlScalar ([string]$entry.Value)
    }
    return $values
}

function Get-ClashRuntimeYamlSequence([string]$Text, [string[]]$Path) {
    $located = Get-ClashRuntimeYamlNode $Text $Path
    $items = @()
    for ($index = $located.Node.Start + 1; $index -lt $located.Node.End; $index++) {
        $line = [string]$located.Lines[$index]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) { continue }
        if ($line -notmatch '^\s*-\s+(.+?)\s*$') { throw "运行配置包含无法读取的受管清单。" }
        $items += ConvertFrom-ClashRuntimeYamlScalar ([string]$Matches[1])
    }
    return @($items)
}

function Get-ClashRuntimeManagedProvider(
    [string]$RuntimeText,
    [object]$Expected,
    [string]$ExpectedProxy = ""
) {
    $located = Get-ClashRuntimeYamlNode $RuntimeText @("rule-providers")
    $providerMatches = @()
    $providerIndent = -1
    for ($index = $located.Node.Start + 1; $index -lt $located.Node.End; $index++) {
        $line = [string]$located.Lines[$index]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) { continue }
        if ($providerIndent -lt 0) { $providerIndent = Get-YamlIndent $line }
        if ((Get-YamlIndent $line) -ne $providerIndent) { continue }
        $entry = Get-ClashRuntimeYamlMappingEntry $line
        if ($null -eq $entry -or -not [string]::IsNullOrWhiteSpace([string]$entry.Value)) { continue }
        $name = [string]$entry.Key
        if ($name -notmatch ('^' + [regex]::Escape([string]$Expected.name) + '(?:-(?:[2-9]|[1-9][0-9]+))?$')) { continue }
        $values = Get-ClashRuntimeYamlMapping $RuntimeText @("rule-providers", $name)
        $suffix = $name.Substring(([string]$Expected.name).Length)
        $expectedPath = [string]$Expected.path
        if (-not [string]::IsNullOrEmpty($suffix)) {
            $dot = $expectedPath.LastIndexOf(".")
            $expectedPath = if ($dot -lt 0) {
                $expectedPath + $suffix
            } else {
                $expectedPath.Substring(0, $dot) + $suffix + $expectedPath.Substring($dot)
            }
        }
        $expectedValues = [ordered]@{
            type = [string]$Expected.type
            behavior = [string]$Expected.behavior
            format = [string]$Expected.format
            url = [string]$Expected.url
            path = $expectedPath
            interval = [string]$Expected.interval
            proxy = if ([string]::IsNullOrWhiteSpace($ExpectedProxy)) { [string]$values.proxy } else { $ExpectedProxy }
            "size-limit" = [string]$Expected.size_limit
        }
        $complete = -not [string]::IsNullOrWhiteSpace([string]$values.proxy) -and
            @($values.Keys).Count -eq @($expectedValues.Keys).Count
        foreach ($key in $expectedValues.Keys) {
            if (-not $values.ContainsKey($key) -or
                [string]$values[$key] -cne [string]$expectedValues[$key]) { $complete = $false }
        }
        if ($complete) {
            $providerMatches += [pscustomobject]@{ Name = $name; Proxy = [string]$values.proxy }
        }
    }
    if ($providerMatches.Count -ne 1) { throw "Clash Verge Rev 运行配置缺少唯一的受管规则提供器。" }
    return $providerMatches[0]
}

function Assert-ClashRuntimePatch(
    [string]$RuntimeText,
    [object]$State,
    [object]$Policy,
    [int]$UsageProfile
) {
    $profile = Get-ClashRuntimeYamlMapping $RuntimeText @("profile")
    if ([string]$profile["store-selected"] -cne "true") {
        throw "Clash Verge Rev 运行配置没有保存代理组选择。"
    }
    $dns = Get-ClashRuntimeYamlMapping $RuntimeText @("dns")
    if ([string]$dns.enable -cne "true" -or [string]$dns["respect-rules"] -cne "true" -or
        [string]$dns["direct-nameserver-follow-policy"] -cne "false") {
        throw "Clash Verge Rev 运行配置没有应用共同 DNS 设置。"
    }
    $directResolvers = @(Get-ClashRuntimeYamlSequence $RuntimeText @("dns", "direct-nameserver"))
    if ($directResolvers.Count -ne @($Policy.direct_resolvers).Count) {
        throw "Clash Verge Rev 运行配置没有应用直连 DNS。"
    }
    for ($index = 0; $index -lt $directResolvers.Count; $index++) {
        if ([string]$directResolvers[$index] -cne [string]$Policy.direct_resolvers[$index]) {
            throw "Clash Verge Rev 运行配置没有应用直连 DNS。"
        }
    }
    $rules = @($State.Rules)
    $domainProviderInfo = Get-ClashRuntimeManagedProvider $RuntimeText $Policy.cn_domain_provider
    $domainProvider = [string]$domainProviderInfo.Name
    $mainGroup = [string]$domainProviderInfo.Proxy
    $mainProperty = $State.Proxies.PSObject.Properties[$mainGroup]
    if ($null -eq $mainProperty -or
        [string]$mainProperty.Value.type -notin @("Selector", "URLTest", "Fallback", "LoadBalance")) {
        throw "Clash Verge Rev 运行配置中的受管规则提供器没有指向主代理组。"
    }
    $liveMainGroup = ""
    for ($index = $rules.Count - 1; $index -ge 0; $index--) {
        if (([string]$rules[$index].type).Replace("-", "") -ieq "Match") {
            $candidate = [string]$rules[$index].proxy
            $candidateProperty = $State.Proxies.PSObject.Properties[$candidate]
            if ($null -ne $candidateProperty -and
                [string]$candidateProperty.Value.type -in @("Selector", "URLTest", "Fallback", "LoadBalance")) {
                $liveMainGroup = $candidate
                break
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($liveMainGroup) -and $liveMainGroup -cne $mainGroup) {
        throw "Clash Verge Rev 运行配置中的主代理组不一致。"
    }
    $policyResolvers = @(Get-ClashRuntimeYamlSequence $RuntimeText @(
        "dns", "nameserver-policy", "rule-set:$domainProvider"
    ))
    if ($policyResolvers.Count -ne @($Policy.direct_resolvers).Count) {
        throw "Clash Verge Rev 运行配置没有应用国内 DNS 分流。"
    }
    for ($index = 0; $index -lt $policyResolvers.Count; $index++) {
        if ([string]$policyResolvers[$index] -cne [string]$Policy.direct_resolvers[$index]) {
            throw "Clash Verge Rev 运行配置没有应用国内 DNS 分流。"
        }
    }
    $runtimeRules = @(Get-ClashRuntimeYamlSequence $RuntimeText @("rules"))
    $domainRule = "RULE-SET,$domainProvider,DIRECT"
    $firstBroadRule = @($runtimeRules | Where-Object {
        ([string]$_).Split(",", 2)[0].ToUpperInvariant() -in @("MATCH", "GEOSITE", "GEOIP", "RULE-SET")
    } | Select-Object -First 1)
    if ($firstBroadRule.Count -ne 1 -or [string]$firstBroadRule[0] -cne $domainRule) {
        throw "Clash Verge Rev 运行配置没有按顺序应用共同规则。"
    }
    if ($UsageProfile -lt 3) {
        return
    }
    $aiGroup = Get-ClashRuntimeAiGroupName $rules $Policy
    $ipProviderInfo = Get-ClashRuntimeManagedProvider $RuntimeText $Policy.cn_ip_provider $mainGroup
    $ipProvider = [string]$ipProviderInfo.Name
    $managed = @($Policy.ai_rules | ForEach-Object { ([string]$_).Replace("{AI}", $aiGroup) })
    $expectedPrefix = @(
        $managed +
        @($Policy.ai_rules | ForEach-Object { ([string]$_).Replace("{AI}", "REJECT") }) +
        @($Policy.lan_udp_direct_rules) +
        @("RULE-SET,$domainProvider,DIRECT") +
        @(([string]$Policy.cn_udp_direct_rule).Replace("{CN_IP}", $ipProvider)) +
        @("NETWORK,UDP,$aiGroup", "NETWORK,UDP,REJECT")
    )
    if ($runtimeRules.Count -lt $expectedPrefix.Count) { throw "Clash Verge Rev 运行配置没有应用档位 3 补丁。" }
    for ($index = 0; $index -lt $expectedPrefix.Count; $index++) {
        if ([string]$runtimeRules[$index] -cne [string]$expectedPrefix[$index]) {
            throw "Clash Verge Rev 运行配置没有应用档位 3 补丁。"
        }
    }
}

function Test-ClashRuntimeRequiresTun([int]$UsageProfile) {
    return $UsageProfile -ge 2
}

function Test-ClashRuntimeConnectivity([object]$Context, [object]$State, [string]$CurlPath, [bool]$UseTun) {
    $proxy = ""
    if (-not $UseTun) {
        foreach ($field in @("mixed-port", "port", "socks-port")) {
            $property = $State.Config.PSObject.Properties[$field]
            if ($null -ne $property -and [int]$property.Value -ge 1 -and [int]$property.Value -le 65535) {
                $scheme = if ($field -eq "socks-port") { "socks5h" } else { "http" }
                $proxy = "${scheme}://127.0.0.1:$([int]$property.Value)"
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($proxy)) { return $false }
    }
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $arguments = @('-q', '--silent', '--show-error', '--fail', '--max-time', '8', '--output', 'NUL')
        if ($UseTun) { $arguments += @('--proxy', '', '--noproxy', '*') } else { $arguments += @('--proxy', $proxy) }
        $arguments += 'https://www.google.com/generate_204'
        $start = New-Object System.Diagnostics.ProcessStartInfo
        $start.FileName = $CurlPath
        $start.Arguments = ($arguments | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }) -join ' '
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        foreach ($name in @('http_proxy', 'https_proxy', 'all_proxy', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'no_proxy', 'NO_PROXY')) {
            $start.EnvironmentVariables[$name] = ""
        }
        $process = [System.Diagnostics.Process]::Start($start)
        $finished = $process.WaitForExit(12000)
        if (-not $finished) { try { $process.Kill() } catch { } }
        $ok = $finished -and $process.ExitCode -eq 0
        $process.Dispose()
        if ($ok) { return $true }
        if ($attempt -lt 2) { Start-Sleep -Seconds 1 }
    }
    return $false
}

function Test-ClashRuntimeProxyPath(
    [object]$Proxies,
    [string]$Name,
    [hashtable]$Seen = $null,
    [object]$Providers = $null
) {
    if ([string]::IsNullOrWhiteSpace($Name) -or
        $Name -in @("DIRECT", "DNS", "REJECT", "REJECT-DROP", "PASS", "PASS-RULE", "COMPATIBLE", "REMATCH", "RELAY")) {
        return $false
    }
    if ($null -eq $Seen) { $Seen = @{} }
    if ($Seen.ContainsKey($Name)) { return $false }
    $candidates = @()
    $property = $Proxies.PSObject.Properties[$Name]
    if ($null -ne $property) { $candidates += $property.Value }
    if ($null -ne $Providers) {
        foreach ($provider in @($Providers.PSObject.Properties)) {
            $candidates += @($provider.Value.proxies | Where-Object {
                $null -ne $_ -and [string]$_.name -ceq $Name
            })
        }
    }
    if ($candidates.Count -eq 0) { return $false }
    foreach ($proxy in $candidates) {
        if ([string]$proxy.type -in @("Direct", "Dns", "Reject", "RejectDrop", "Pass", "PassRule", "Compatible", "Rematch", "Relay")) {
            return $false
        }
        if ([string]$proxy.type -notin @("Selector", "URLTest", "Fallback", "LoadBalance")) { continue }
        $visited = @{}
        foreach ($key in $Seen.Keys) { $visited[$key] = $true }
        $visited[$Name] = $true
        if ([string]$proxy.type -eq "LoadBalance") {
            $members = @($proxy.all)
            if ($members.Count -eq 0 -or @($members | Where-Object {
                -not (Test-ClashRuntimeProxyPath $Proxies ([string]$_) $visited $Providers)
            }).Count -ne 0) { return $false }
        } elseif (-not (Test-ClashRuntimeProxyPath $Proxies ([string]$proxy.now) $visited $Providers)) {
            return $false
        }
    }
    return $true
}

function Get-ClashRuntimeAiGroupName([object[]]$Rules, [object]$Policy) {
    $templates = @($Policy.ai_rules)
    if ($templates.Count -eq 0 -or $Rules.Count -lt $templates.Count) {
        throw "档位 3 的受管 AI 规则不完整。"
    }
    $aiGroup = ""
    for ($index = 0; $index -lt $templates.Count; $index++) {
        $parts = @(([string]$templates[$index]).Split(","))
        if ($parts.Count -lt 3) { throw "档位 3 的 AI 策略无效。" }
        $expectedType = ([string]$parts[0]).Replace("-", "")
        $actual = $Rules[$index]
        $actualType = ([string]$actual.type).Replace("-", "")
        if ($actualType -ine $expectedType -or [string]$actual.payload -ine [string]$parts[1]) {
            throw "档位 3 的受管 AI 规则不完整。"
        }
        $target = [string]$actual.proxy
        if ([string]::IsNullOrWhiteSpace($target) -or $target -in @("DIRECT", "REJECT")) {
            throw "档位 3 的受管 AI 规则目标无效。"
        }
        if ([string]::IsNullOrWhiteSpace($aiGroup)) { $aiGroup = $target }
        elseif ($target -cne $aiGroup) { throw "档位 3 的受管 AI 规则目标不一致。" }
    }
    return $aiGroup
}

function Assert-ClashRuntimeAiGroup(
    [object]$Proxies,
    [object[]]$Rules,
    [object]$Providers,
    [object]$Policy
) {
    $name = Get-ClashRuntimeAiGroupName $Rules $Policy
    $property = $Proxies.PSObject.Properties[$name]
    if ($null -eq $property -or
        [string]$property.Value.type -notin @("Selector", "URLTest", "Fallback", "LoadBalance") -or
        -not (Test-ClashRuntimeProxyPath $Proxies $name $null $Providers)) {
        throw "档位 3 的 AI 分组当前没有可用代理路径。"
    }
}

function Assert-ClashRuntimeHealthy(
    [object]$Context,
    [hashtable]$Selections,
    [bool]$ExpectedTunEnabled,
    [int]$UsageProfile,
    [string]$CurlPath,
    [object]$Policy
) {
    Restore-ClashRuntimeSelections $Context $Selections
    $state = Get-ClashRuntimeState $Context
    foreach ($name in @($Selections.Keys)) {
        $property = $state.Proxies.PSObject.Properties[[string]$name]
        if ($null -eq $property -or [string]$property.Value.type -ne "Selector" -or
            [string]$property.Value.now -cne [string]$Selections[$name]) {
            throw "Clash Verge Rev 没有保留原代理选择。"
        }
    }
    if ($state.TunEnabled -ne $ExpectedTunEnabled) { throw "Clash Verge Rev 没有保留原 TUN 状态。" }
    if ($UsageProfile -eq 3) {
        Assert-ClashRuntimeAiGroup $state.Proxies $state.Rules $state.Providers $Policy
    }
    $flush = Invoke-ClashControllerRequest $Context "POST" "/cache/dns/flush"
    if ($flush.Status -notin @(200, 204)) { throw "Clash Verge Rev DNS 缓存清理失败。" }
    $dns = Invoke-ClashControllerRequest $Context "GET" "/dns/query?name=www.baidu.com&type=A"
    if ($dns.Status -ne 200) { throw "Clash Verge Rev DNS 检查失败。" }
    $dnsPayload = $dns.Content | ConvertFrom-Json
    $answers = if ($null -ne $dnsPayload.Answer) { @($dnsPayload.Answer) } else { @($dnsPayload.answer) }
    $dnsStatus = if ($null -ne $dnsPayload.Status) { [int]$dnsPayload.Status } else { [int]$dnsPayload.status }
    if ($dnsStatus -ne 0 -or $answers.Count -eq 0) { throw "Clash Verge Rev DNS 检查失败。" }
    Assert-ClashRuntimePatch ([string]$Context.RuntimeText) $state $Policy $UsageProfile
    if (-not (Test-ClashRuntimeConnectivity $Context $state $CurlPath $ExpectedTunEnabled)) {
        throw "更新后的配置无法连接 Google。"
    }
}
