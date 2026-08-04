param(
    [string]$ControllerUrl = "http://127.0.0.1:9097",
    [string]$Secret = "",
    [switch]$SecretStdin,
    [string]$MainGroup = "",
    [string]$AiGroup = "",
    [string]$ObservationSeconds = "15",
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$resultContractPath = Join-Path $PSScriptRoot "result_contract.ps1"
$resultContractLoaded = $false
if (Test-Path -LiteralPath $resultContractPath -PathType Leaf) {
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
}
if (-not $resultContractLoaded) {
    if ($Json) {
        [Console]::Out.WriteLine('{"schema":"claude-easy.result","version":1,"command":"verify_routes","platform":"windows","client":"clash-verge-rev","operation":"load","ok":false,"status":"failed","code":"incomplete_package","exit_code":6,"summary_zh":"安装包不完整。","profile":null,"changes":[],"checks":[],"items":[],"messages":[],"warnings":[]}')
    } else {
        [Console]::Error.WriteLine("[ClaudeEasy] 安装包不完整。")
    }
    exit 6
}
$script:ClaudeEasyChecks = New-Object System.Collections.ArrayList
$script:ClaudeEasyControllerBaseUrl = ""
$script:ClaudeEasyControllerSecret = ""

function Write-ClaudeEasyVerificationText([string]$Message, [switch]$ErrorStream) {
    $safeMessage = Protect-ClaudeEasyResultText $Message
    if ($ErrorStream) {
        [Console]::Error.WriteLine($safeMessage)
    } else {
        [Console]::Out.WriteLine($safeMessage)
    }
}

$observationSecondsValue = 0
if (-not [int]::TryParse(
        $ObservationSeconds,
        [System.Globalization.NumberStyles]::Integer,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$observationSecondsValue
    ) -or $observationSecondsValue -lt 1 -or $observationSecondsValue -gt 60) {
    if ($Json) {
        Write-ClaudeEasyResult (New-ClaudeEasyResult -Command "verify_routes" -Operation "verify_routes" -Ok $false -Status "invalid_request" -Code "invalid_arguments" -ExitCode 64 -SummaryZh "观察时间必须为 1 到 60 秒。")
    } else {
        Write-ClaudeEasyVerificationText "[ClaudeEasy] 观察时间必须为 1 到 60 秒。" -ErrorStream
    }
    exit 64
}
$ObservationSeconds = $observationSecondsValue
$blankGroupOverride =
    ($PSBoundParameters.ContainsKey("MainGroup") -and
        [string]::IsNullOrWhiteSpace($MainGroup)) -or
    ($PSBoundParameters.ContainsKey("AiGroup") -and
        [string]::IsNullOrWhiteSpace($AiGroup))
if ($blankGroupOverride) {
    if ($Json) {
        Write-ClaudeEasyResult (New-ClaudeEasyResult -Command "verify_routes" -Operation "verify_routes" -Ok $false -Status "invalid_request" -Code "invalid_arguments" -ExitCode 64 -SummaryZh "代理组名称不能为空。")
    } else {
        Write-ClaudeEasyVerificationText "[ClaudeEasy] 代理组名称不能为空。" -ErrorStream
    }
    exit 64
}

function Read-ControllerSecretFromStandardInput {
    if (-not [string]::IsNullOrEmpty($Secret)) {
        throw "不能通过 -Secret 传入非空控制器密钥；请改用 -SecretStdin。"
    }
    if (-not $SecretStdin) { return "" }
    $inputStream = [Console]::OpenStandardInput()
    $inputReader = New-Object System.IO.StreamReader(
        $inputStream,
        [Console]::InputEncoding,
        $true,
        1024,
        $true
    )
    try {
        $value = $inputReader.ReadToEnd()
    } finally {
        $inputReader.Dispose()
    }
    if ($value.Length -gt 0 -and $value[0] -eq [char]0xFEFF) {
        $value = $value.Substring(1)
    }
    if ($value.EndsWith("`r`n", [StringComparison]::Ordinal)) {
        $value = $value.Substring(0, $value.Length - 2)
    } elseif ($value.EndsWith("`n", [StringComparison]::Ordinal)) {
        $value = $value.Substring(0, $value.Length - 1)
    }
    if ($value.Contains("`r") -or $value.Contains("`n")) {
        throw "标准输入中的控制器密钥必须是单行文本。"
    }
    return $value
}

function Test-StrictIpv4LoopbackHost([string]$HostName) {
    $parts = @($HostName.Split([char[]]@(".")))
    if ($parts.Count -ne 4 -or $parts[0] -cne "127") { return $false }
    foreach ($part in $parts) {
        if ($part -notmatch '^(?:0|[1-9][0-9]{0,2})$' -or
            [int]$part -gt 255) {
            return $false
        }
    }
    return $true
}

function Get-ValidatedControllerBaseUri([string]$Value) {
    [Uri]$parsed = $null
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Contains("\") -or
        -not [Uri]::TryCreate($Value, [System.UriKind]::Absolute, [ref]$parsed)) {
        throw "控制器地址无效；只允许本机回环 HTTP 或 HTTPS 地址。"
    }
    $authorityMatch = [regex]::Match(
        $Value,
        '^(?i:https?)://(?<authority>[^/?#]+)'
    )
    if (-not $authorityMatch.Success) {
        throw "控制器地址无效；只允许本机回环 HTTP 或 HTTPS 地址。"
    }
    $rawAuthority = $authorityMatch.Groups["authority"].Value
    $rawHost = ""
    if ($rawAuthority.StartsWith("[", [StringComparison]::Ordinal)) {
        $closingBracket = $rawAuthority.IndexOf("]")
        if ($closingBracket -lt 0) {
            throw "控制器地址无效；只允许本机回环 HTTP 或 HTTPS 地址。"
        }
        $rawHost = $rawAuthority.Substring(0, $closingBracket + 1)
        $rawPort = $rawAuthority.Substring($closingBracket + 1)
        if (-not [string]::IsNullOrEmpty($rawPort) -and
            $rawPort -notmatch '^:[0-9]+$') {
            throw "控制器地址无效；只允许本机回环 HTTP 或 HTTPS 地址。"
        }
    } else {
        $rawParts = @($rawAuthority.Split(":"))
        if ($rawParts.Count -gt 2 -or
            ($rawParts.Count -eq 2 -and $rawParts[1] -notmatch '^[0-9]+$')) {
            throw "控制器地址无效；只允许本机回环 HTTP 或 HTTPS 地址。"
        }
        $rawHost = $rawParts[0]
    }
    $rawHostIsLoopback = [string]::Equals(
        $rawHost,
        "localhost",
        [StringComparison]::OrdinalIgnoreCase
    ) -or $rawHost -ceq "[::1]" -or
        (Test-StrictIpv4LoopbackHost $rawHost)
    if (-not $rawHostIsLoopback) {
        throw "控制器地址必须使用本机回环地址。"
    }
    if ($parsed.Scheme -notin @("http", "https") -or
        -not [string]::IsNullOrEmpty($parsed.UserInfo) -or
        -not [string]::IsNullOrEmpty($parsed.Query) -or
        -not [string]::IsNullOrEmpty($parsed.Fragment)) {
        throw "控制器地址无效；只允许本机回环 HTTP 或 HTTPS 地址，且不能包含凭据、查询或片段。"
    }
    $hostName = [string]$parsed.DnsSafeHost
    $parsedHostMatchesRaw = [string]::Equals(
        $hostName,
        $rawHost,
        [System.StringComparison]::OrdinalIgnoreCase
    )
    if ($rawHost -ceq "[::1]") {
        [System.Net.IPAddress]$parsedAddress = $null
        $parsedHostMatchesRaw =
            [System.Net.IPAddress]::TryParse(
                $hostName.Trim([char[]]@("[", "]")),
                [ref]$parsedAddress
            ) -and [System.Net.IPAddress]::IsLoopback($parsedAddress)
    }
    if (-not $parsedHostMatchesRaw) {
        throw "控制器地址必须使用本机回环地址。"
    }
    return $parsed.GetLeftPart([System.UriPartial]::Path).TrimEnd([char[]]@("/"))
}

function Invoke-ControllerJson([string]$Endpoint) {
    $uri = $script:ClaudeEasyControllerBaseUrl + $Endpoint
    $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($uri)
    $request.Method = "GET"
    $request.AllowAutoRedirect = $false
    $request.Proxy = $null
    $request.Timeout = 5000
    $request.ReadWriteTimeout = 5000
    $request.KeepAlive = $false
    if (-not [string]::IsNullOrEmpty($script:ClaudeEasyControllerSecret)) {
        $request.Headers.Set(
            [System.Net.HttpRequestHeader]::Authorization,
            "Bearer " + $script:ClaudeEasyControllerSecret
        )
    }
    $response = $null
    $reader = $null
    try {
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        if ($response.StatusCode -ne [System.Net.HttpStatusCode]::OK) {
            throw "unexpected controller status"
        }
        $reader = New-Object System.IO.StreamReader(
            $response.GetResponseStream(),
            [System.Text.Encoding]::UTF8,
            $true
        )
        $content = $reader.ReadToEnd()
        return ($content | ConvertFrom-Json)
    } catch {
        $errorResponse = $_.Exception.Response
        if ($null -ne $errorResponse) {
            try { $errorResponse.Dispose() } catch { }
        }
        throw "本地控制器请求失败。"
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
    }
}

function Get-SafeVerificationFailureMessage([string]$Message) {
    $safe = $Message
    if (-not [string]::IsNullOrEmpty($script:ClaudeEasyControllerSecret)) {
        $safe = $safe.Replace(
            $script:ClaudeEasyControllerSecret,
            "[已隐藏]"
        )
    }
    return Protect-ClaudeEasyResultText $safe
}

function Get-Policy {
    $path = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "references\policy.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "找不到策略文件。" }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Find-Group([object]$Proxies, [object[]]$Candidates, [string]$Requested, [string]$Label) {
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        if ($null -eq $Proxies.PSObject.Properties[$Requested]) { throw "找不到$Label。" }
        return $Requested
    }
    foreach ($candidate in $Candidates) {
        $name = [string]$candidate
        $property = $Proxies.PSObject.Properties[$name]
        if ($null -ne $property -and
            (Test-SupportedRouteGroupType ([string]$property.Value.type))) {
            return $name
        }
    }
    if ($Label -eq "AI 分组") {
        foreach ($property in $Proxies.PSObject.Properties) {
            $type = [string]$property.Value.type
            if ((Test-SupportedRouteGroupType $type) -and
                [string]$property.Name -match '(?i)(^|[^A-Za-z])AI([^A-Za-z]|$)|OpenAI|人工智能|🤖') {
                return [string]$property.Name
            }
        }
    }
    throw "无法自动识别$Label；未进行分流验证。"
}

function Test-SupportedRouteGroupType([string]$GroupType) {
    return $GroupType -in @("Selector", "URLTest", "Fallback", "LoadBalance")
}

function Test-UsableRouteGroupSelection([object]$Group) {
    if ($null -eq $Group -or
        -not (Test-SupportedRouteGroupType ([string]$Group.type))) {
        return $false
    }
    $selection = [string]$Group.now
    if ([string]::IsNullOrWhiteSpace($selection)) {
        return [string]$Group.type -eq "LoadBalance"
    }
    return $selection -notin @(
        "DIRECT", "DNS", "REJECT", "REJECT-DROP",
        "PASS", "PASS-RULE", "COMPATIBLE", "REMATCH"
    )
}

function Get-LiveChainProxy(
    [object]$Proxies,
    [object]$Providers,
    [string]$Name,
    [string]$ProviderName
) {
    if (-not [string]::IsNullOrWhiteSpace($ProviderName)) {
        if ($null -eq $Providers) { return $null }
        $providerProperty = $Providers.PSObject.Properties[$ProviderName]
        if ($null -eq $providerProperty) { return $null }
        foreach ($proxy in @($providerProperty.Value.proxies)) {
            if ($null -ne $proxy -and [string]$proxy.name -eq $Name) { return $proxy }
        }
        return $null
    }
    $property = $Proxies.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-SafeLiveChain(
    [object]$Proxies,
    [object]$Providers,
    [string[]]$Chains,
    [string[]]$ProviderChains
) {
    $chainItems = @($Chains)
    $providerChainItems = @($ProviderChains)
    if ($chainItems.Count -eq 0) { return $false }
    $nonProxyNames = @("DIRECT", "REJECT", "REJECT-DROP", "PASS", "PASS-RULE", "COMPATIBLE", "REMATCH", "DNS")
    $nonProxyTypes = @("Direct", "Dns", "Reject", "RejectDrop", "Pass", "PassRule", "Compatible", "Rematch")
    for ($index = 0; $index -lt $chainItems.Count; $index++) {
        $name = [string]$chainItems[$index]
        if ([string]::IsNullOrWhiteSpace($name) -or $name -in $nonProxyNames) { return $false }
        $providerName = ""
        if ($index -lt $providerChainItems.Count) { $providerName = [string]$providerChainItems[$index] }
        $proxy = Get-LiveChainProxy $Proxies $Providers $name $providerName
        if ($null -eq $proxy) { return $false }
        $type = [string]$proxy.type
        if ([string]::IsNullOrWhiteSpace($type) -or $type -in $nonProxyTypes) { return $false }
        if ($index -eq 0 -and (Test-SupportedRouteGroupType $type)) { return $false }
    }
    return $true
}

function Get-LiveMainGroup([object]$Proxies) {
    $rules = @((Invoke-ControllerJson "/rules").rules)
    for ($index = $rules.Count - 1; $index -ge 0; $index--) {
        $rule = $rules[$index]
        if ($null -eq $rule -or [string]$rule.type -notmatch '^(?i:match)$') { continue }
        $name = [string]$rule.proxy
        if ([string]::IsNullOrWhiteSpace($name)) { throw "当前 MATCH 规则没有代理目标。" }
        $property = $Proxies.PSObject.Properties[$name]
        if ($null -eq $property -or -not (Test-SupportedRouteGroupType ([string]$property.Value.type))) {
            throw "当前 MATCH 规则没有指向受支持的主代理组。"
        }
        return $name
    }
    throw "当前运行配置没有 MATCH 主代理组；未进行分流验证。"
}

function Get-ConnectionIds {
    $connections = @((Invoke-ControllerJson "/connections").connections)
    $ids = @{}
    foreach ($connection in $connections) {
        if ($null -ne $connection -and -not [string]::IsNullOrWhiteSpace([string]$connection.id)) {
            $ids[[string]$connection.id] = $true
        }
    }
    return $ids
}

function Get-AvailableSourcePort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Start-TestTraffic([string]$Url) {
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($null -eq $curl) { throw "找不到 Windows 自带的 curl.exe。" }
    $sourcePort = Get-AvailableSourcePort
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $curl.Source
    $start.Arguments = '--http1.1 -L --max-time 15 --limit-rate 2k --local-port ' + $sourcePort + ' --output NUL --silent "' + $Url.Replace('"', '\"') + '"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    if (-not $process.Start()) { throw "无法启动分流测试请求。" }
    return [pscustomobject]@{ Process = $process; SourcePort = $sourcePort }
}

function Test-RouteChains(
    [object]$Proxies,
    [string[]]$Chains,
    [string]$ExpectedGroup,
    [string]$ExpectedSelection,
    [string]$AiGroup,
    [bool]$AllowExplicitProxyGroup,
    [object]$Providers = $null,
    [string[]]$ProviderChains = @()
) {
    $chainItems = @($Chains)
    $providerChainItems = @($ProviderChains)
    if (-not (Test-SafeLiveChain $Proxies $Providers $chainItems $providerChainItems)) { return $false }
    $expectedProperty = $Proxies.PSObject.Properties[$ExpectedGroup]
    if ($null -eq $expectedProperty) { return $false }
    $expectedType = [string]$expectedProperty.Value.type
    if (-not (Test-SupportedRouteGroupType $expectedType) -or
        ([string]::IsNullOrWhiteSpace($ExpectedSelection) -and
            $expectedType -ne "LoadBalance")) {
        return $false
    }
    if (-not $AllowExplicitProxyGroup) {
        return $chainItems -contains $ExpectedGroup
    }
    if ($ExpectedGroup -ne $AiGroup -and $chainItems -contains $AiGroup) { return $false }
    if ($chainItems -contains $ExpectedGroup) { return $true }
    for ($index = 0; $index -lt $chainItems.Count; $index++) {
        $name = [string]$chainItems[$index]
        if ($name -notmatch '(?i)google') { continue }
        $providerName = ""
        if ($index -lt $providerChainItems.Count) { $providerName = [string]$providerChainItems[$index] }
        $proxy = Get-LiveChainProxy $Proxies $Providers $name $providerName
        if ($null -ne $proxy -and (Test-SupportedRouteGroupType ([string]$proxy.type))) { return $true }
    }
    return $false
}

function Observe-Route(
    [string]$Label,
    [string]$Url,
    [string]$HostPattern,
    [string]$ExpectedGroup,
    [string]$ExpectedSelection,
    [object]$Proxies,
    [string]$AiGroup,
    [bool]$AllowExplicitProxyGroup,
    [object]$Providers = $null
) {
    $known = Get-ConnectionIds
    $traffic = Start-TestTraffic $Url
    $process = $traffic.Process
    $sourcePort = [int]$traffic.SourcePort
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds($ObservationSeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
            $connections = @((Invoke-ControllerJson "/connections").connections)
            foreach ($connection in $connections) {
                if ($null -eq $connection -or $known.ContainsKey([string]$connection.id)) { continue }
                $connectionHost = [string]$connection.metadata.host
                if ($connectionHost -notmatch $HostPattern) { continue }
                if ([string]$connection.metadata.network -notmatch '^(?i:tcp)$') { continue }
                $connectionSourcePort = 0
                if (-not [int]::TryParse([string]$connection.metadata.sourcePort, [ref]$connectionSourcePort)) { continue }
                if ($connectionSourcePort -ne $sourcePort) { continue }
                $chains = @(
                    @($connection.chains) |
                        Where-Object { $null -ne $_ } |
                        ForEach-Object { [string]$_ }
                )
                $providerChains = @()
                $providerChainsProperty =
                    $connection.PSObject.Properties["providerChains"]
                if ($null -ne $providerChainsProperty) {
                    $providerChains = @(
                        @($providerChainsProperty.Value) |
                            Where-Object { $null -ne $_ } |
                            ForEach-Object { [string]$_ }
                    )
                }
                $passed = Test-RouteChains $Proxies $chains $ExpectedGroup $ExpectedSelection $AiGroup $AllowExplicitProxyGroup $Providers $providerChains
                [void]$script:ClaudeEasyChecks.Add([ordered]@{ name = $Label.ToLowerInvariant(); ok = $passed; status = $(if ($passed) { "passed" } else { "failed" }) })
                if (-not $Json) { Write-ClaudeEasyVerificationText ("{0}：{1}" -f $Label, $(if ($passed) { "通过" } else { "失败" })) }
                return $passed
            }
        }
        [void]$script:ClaudeEasyChecks.Add([ordered]@{ name = $Label.ToLowerInvariant(); ok = $false; status = "not_observed" })
        if (-not $Json) { Write-ClaudeEasyVerificationText "$Label：失败（没有观察到对应连接）" }
        return $false
    } finally {
        if ($null -ne $process -and -not $process.HasExited) {
            try { $process.Kill() } catch { }
        }
        if ($null -ne $process) { $process.Dispose() }
    }
}

try {
    $script:ClaudeEasyControllerSecret =
        Read-ControllerSecretFromStandardInput
    $script:ClaudeEasyControllerBaseUrl =
        Get-ValidatedControllerBaseUri $ControllerUrl
    $policy = Get-Policy
    $proxyResponse = Invoke-ControllerJson "/proxies"
    $proxies = $proxyResponse.proxies
    if ($null -eq $proxies) { throw "本地控制器没有返回代理组。" }
    $providerResponse = Invoke-ControllerJson "/providers/proxies"
    $providers = $providerResponse.providers
    if ($null -eq $providers) { throw "本地控制器没有返回代理提供器。" }

    if ([string]::IsNullOrWhiteSpace($MainGroup)) {
        $main = Get-LiveMainGroup $proxies
    } else {
        $main = Find-Group $proxies @() $MainGroup "主代理组"
    }
    $ai = Find-Group $proxies @($policy.ai_group_names) $AiGroup "AI 分组"
    $mainSelection = [string]$proxies.PSObject.Properties[$main].Value.now
    $aiSelection = [string]$proxies.PSObject.Properties[$ai].Value.now
    if (-not (Test-UsableRouteGroupSelection $proxies.PSObject.Properties[$main].Value)) {
        throw "主代理组当前没有选择有效代理节点。"
    }
    if (-not (Test-UsableRouteGroupSelection $proxies.PSObject.Properties[$ai].Value)) {
        throw "AI 分组当前没有选择有效代理节点。"
    }

    if (-not $Json) {
        Write-ClaudeEasyVerificationText "主代理组：已识别；当前选择已隐藏"
        Write-ClaudeEasyVerificationText "AI 分组：已识别；当前选择已隐藏"
    }
    $checks = @(
        (Observe-Route "Google" "https://www.google.com/search?q=clash-route-verification" '(?i)(^|\.)google\.com$' $main $mainSelection $proxies $ai $true $providers),
        (Observe-Route "OpenAI" "https://openai.com/" '(?i)(^|\.)openai\.com$' $ai $aiSelection $proxies $ai $false $providers),
        (Observe-Route "Anthropic" "https://www.anthropic.com/" '(?i)(^|\.)anthropic\.com$' $ai $aiSelection $proxies $ai $false $providers),
        (Observe-Route "Claude" "https://claude.ai/" '(?i)(^|\.)claude\.ai$' $ai $aiSelection $proxies $ai $false $providers)
    )
    if (@($checks | Where-Object { -not $_ }).Count -gt 0) {
        if ($Json) { Write-ClaudeEasyResult (New-ClaudeEasyResult -Command "verify_routes" -Operation "verify_routes" -Ok $false -Status "failed" -Code "route_verification_failed" -ExitCode 1 -SummaryZh "Windows 分流验证未通过。" -Checks @($script:ClaudeEasyChecks)) }
        exit 1
    }
    if ($Json) { Write-ClaudeEasyResult (New-ClaudeEasyResult -Command "verify_routes" -Operation "verify_routes" -Ok $true -Status "ok" -Code "routes_verified" -ExitCode 0 -SummaryZh "Windows 分流验证通过。" -Checks @($script:ClaudeEasyChecks)) }
    exit 0
} catch {
    $failureMessage = Get-SafeVerificationFailureMessage $_.Exception.Message
    if ($Json) {
        Write-ClaudeEasyResult (New-ClaudeEasyResult -Command "verify_routes" -Operation "verify_routes" -Ok $false -Status "failed" -Code "route_verification_failed" -ExitCode 1 -SummaryZh ("Windows 分流验证失败：" + $failureMessage) -Checks @($script:ClaudeEasyChecks))
    } else {
        Write-ClaudeEasyVerificationText "[ClaudeEasy] Windows 分流验证失败：$failureMessage" -ErrorStream
    }
    exit 1
}
