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
    if ($configResponse.Status -ne 200 -or $proxyResponse.Status -ne 200) {
        throw "Clash Verge Rev 没有返回当前运行状态。"
    }
    $config = $configResponse.Content | ConvertFrom-Json
    $proxies = ($proxyResponse.Content | ConvertFrom-Json).proxies
    if ($null -eq $proxies) { throw "Clash Verge Rev 没有返回代理组。" }
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
        Selections = $selections
        TunEnabled = ($null -ne $config.tun -and [bool]$config.tun.enable)
    }
}

function Restore-ClashRuntimeSelections([object]$Context, [hashtable]$Selections) {
    $current = Get-ClashRuntimeState $Context
    foreach ($name in @($Selections.Keys)) {
        $property = $current.Proxies.PSObject.Properties[[string]$name]
        if ($null -eq $property -or [string]$property.Value.type -ne "Selector") { continue }
        $selected = [string]$Selections[$name]
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

function Assert-ClashRuntimePatch([string]$RuntimeText, [object]$Policy, [int]$UsageProfile) {
    foreach ($required in @([string]$Policy.cn_domain_provider.url, [string]$Policy.direct_resolvers[0])) {
        if (-not $RuntimeText.Contains($required)) { throw "Clash Verge Rev 运行配置没有应用当前补丁。" }
    }
    if ($UsageProfile -eq 3) {
        foreach ($required in @([string]$Policy.cn_ip_provider.url, [string]$Policy.ai_rules[0])) {
            $rendered = $required.Replace("{AI}", "")
            $prefix = $rendered.Substring(0, $rendered.LastIndexOf(",") + 1)
            if (-not $RuntimeText.Contains($prefix)) { throw "Clash Verge Rev 运行配置没有应用档位 3 补丁。" }
        }
    }
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

function Test-ClashRuntimeProxyPath([object]$Proxies, [string]$Name, [hashtable]$Seen = $null) {
    if ([string]::IsNullOrWhiteSpace($Name) -or
        $Name -in @("DIRECT", "DNS", "REJECT", "REJECT-DROP", "PASS", "PASS-RULE", "COMPATIBLE", "REMATCH")) {
        return $false
    }
    if ($null -eq $Seen) { $Seen = @{} }
    if ($Seen.ContainsKey($Name)) { return $false }
    $property = $Proxies.PSObject.Properties[$Name]
    if ($null -eq $property) { return $true }
    $proxy = $property.Value
    if ([string]$proxy.type -in @("Direct", "Dns", "Reject", "RejectDrop", "Pass", "PassRule", "Compatible", "Rematch")) {
        return $false
    }
    if ([string]$proxy.type -notin @("Selector", "URLTest", "Fallback", "LoadBalance")) { return $true }
    $visited = @{}
    foreach ($key in $Seen.Keys) { $visited[$key] = $true }
    $visited[$Name] = $true
    if ([string]$proxy.type -eq "LoadBalance") {
        $members = @($proxy.all)
        return $members.Count -gt 0 -and @($members | Where-Object {
            -not (Test-ClashRuntimeProxyPath $Proxies ([string]$_) $visited)
        }).Count -eq 0
    }
    return Test-ClashRuntimeProxyPath $Proxies ([string]$proxy.now) $visited
}

function Assert-ClashRuntimeAiGroup([object]$Proxies, [object]$Policy) {
    $candidates = @($Policy.ai_group_names)
    $candidates += @($Proxies.PSObject.Properties | Where-Object {
        [string]$_.Name -match '(?i)(^|[^A-Za-z])AI([^A-Za-z]|$)|OpenAI|人工智能|🤖'
    } | ForEach-Object { [string]$_.Name })
    foreach ($name in @($candidates | Select-Object -Unique)) {
        $property = $Proxies.PSObject.Properties[[string]$name]
        if ($null -eq $property -or [string]$property.Value.type -notin @("Selector", "URLTest", "Fallback", "LoadBalance")) { continue }
        if (Test-ClashRuntimeProxyPath $Proxies ([string]$name)) { return }
    }
    throw "档位 3 的 AI 分组当前没有可用代理路径。"
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
        if ($null -ne $property -and [string]$property.Value.type -eq "Selector" -and
            [string]$property.Value.now -cne [string]$Selections[$name]) {
            throw "Clash Verge Rev 没有保留原代理选择。"
        }
    }
    if ($state.TunEnabled -ne $ExpectedTunEnabled) { throw "Clash Verge Rev 没有保留原 TUN 状态。" }
    if ($UsageProfile -eq 3) { Assert-ClashRuntimeAiGroup $state.Proxies $Policy }
    $flush = Invoke-ClashControllerRequest $Context "POST" "/cache/dns/flush"
    if ($flush.Status -notin @(200, 204)) { throw "Clash Verge Rev DNS 缓存清理失败。" }
    $dns = Invoke-ClashControllerRequest $Context "GET" "/dns/query?name=www.baidu.com&type=A"
    if ($dns.Status -ne 200) { throw "Clash Verge Rev DNS 检查失败。" }
    $dnsPayload = $dns.Content | ConvertFrom-Json
    $answers = if ($null -ne $dnsPayload.Answer) { @($dnsPayload.Answer) } else { @($dnsPayload.answer) }
    $dnsStatus = if ($null -ne $dnsPayload.Status) { [int]$dnsPayload.Status } else { [int]$dnsPayload.status }
    if ($dnsStatus -ne 0 -or $answers.Count -eq 0) { throw "Clash Verge Rev DNS 检查失败。" }
    Assert-ClashRuntimePatch ([string]$Context.RuntimeText) $Policy $UsageProfile
    if (-not (Test-ClashRuntimeConnectivity $Context $state $CurlPath ($UsageProfile -eq 3))) {
        throw "更新后的配置无法连接 Google。"
    }
}
