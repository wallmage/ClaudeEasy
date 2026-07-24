param(
    [string]$ControllerUrl = "http://127.0.0.1:9097",
    [string]$Secret = "",
    [string]$MainGroup = "",
    [string]$AiGroup = "",
    [int]$ObservationSeconds = 15,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$resultContractPath = Join-Path $PSScriptRoot "result_contract.ps1"
if (-not (Test-Path -LiteralPath $resultContractPath -PathType Leaf)) {
    if ($Json) {
        [Console]::Out.WriteLine('{"schema":"claude-easy.result","version":1,"command":"verify_routes","platform":"windows","client":"clash-verge-rev","operation":"load","ok":false,"status":"failed","code":"incomplete_package","exit_code":6,"summary_zh":"安装包不完整。","profile":null,"changes":[],"checks":[],"items":[],"messages":[],"warnings":[]}')
    } else {
        [Console]::Error.WriteLine("[ClaudeEasy] 安装包不完整。")
    }
    exit 6
}
. $resultContractPath
$script:ClaudeEasyChecks = New-Object System.Collections.ArrayList

function Invoke-ControllerJson([string]$Endpoint) {
    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($Secret)) {
        $headers["Authorization"] = "Bearer $Secret"
    }
    $uri = $ControllerUrl.TrimEnd("/") + $Endpoint
    $response = Invoke-WebRequest -UseBasicParsing -Uri $uri -Headers $headers -Method Get -TimeoutSec 5
    if ([int]$response.StatusCode -ne 200) { throw "本地控制器请求失败。" }
    return ($response.Content | ConvertFrom-Json)
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
        if ($null -ne $Proxies.PSObject.Properties[$name]) { return $name }
    }
    if ($Label -eq "AI 分组") {
        foreach ($property in $Proxies.PSObject.Properties) {
            $type = [string]$property.Value.type
            if ($type -eq "Selector" -and [string]$property.Name -match '(?i)(^|[^A-Za-z])AI([^A-Za-z]|$)|OpenAI|人工智能|🤖') {
                return [string]$property.Name
            }
        }
    }
    throw "无法自动识别$Label；未进行分流验证。"
}

function Get-LiveMainGroup([object]$Proxies) {
    $rules = @((Invoke-ControllerJson "/rules").rules)
    for ($index = $rules.Count - 1; $index -ge 0; $index--) {
        $rule = $rules[$index]
        if ($null -eq $rule -or [string]$rule.type -notmatch '^(?i:match)$') { continue }
        $name = [string]$rule.proxy
        if ([string]::IsNullOrWhiteSpace($name)) { throw "当前 MATCH 规则没有代理目标。" }
        $property = $Proxies.PSObject.Properties[$name]
        if ($null -eq $property -or [string]$property.Value.type -ne "Selector") {
            throw "当前 MATCH 规则没有指向可选主代理组。"
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
    [bool]$AllowExplicitProxyGroup
) {
    if ($Chains -contains "DIRECT" -or $ExpectedSelection -eq "DIRECT") { return $false }
    $nonProxyTermini = @("REJECT", "REJECT-DROP", "PASS", "COMPATIBLE")
    if (@($Chains | Where-Object { $_ -in $nonProxyTermini }).Count -gt 0 -or
        $ExpectedSelection -in $nonProxyTermini) {
        return $false
    }
    if (-not $AllowExplicitProxyGroup) {
        return ($Chains -contains $ExpectedGroup) -and ($Chains -contains $ExpectedSelection)
    }
    if ($Chains -contains $AiGroup) { return $false }
    if (($Chains -contains $ExpectedGroup) -and ($Chains -contains $ExpectedSelection)) { return $true }
    foreach ($name in $Chains) {
        if ($name -notmatch '(?i)google') { continue }
        $property = $Proxies.PSObject.Properties[$name]
        if ($null -eq $property) { continue }
        $selection = [string]$property.Value.now
        if (-not [string]::IsNullOrWhiteSpace($selection) -and
            $selection -notin $nonProxyTermini -and
            $Chains -contains $selection) {
            return $true
        }
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
    [bool]$AllowExplicitProxyGroup
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
                $chains = @($connection.chains | ForEach-Object { [string]$_ })
                $passed = Test-RouteChains $Proxies $chains $ExpectedGroup $ExpectedSelection $AiGroup $AllowExplicitProxyGroup
                [void]$script:ClaudeEasyChecks.Add([ordered]@{ name = $Label.ToLowerInvariant(); ok = $passed; status = $(if ($passed) { "passed" } else { "failed" }) })
                if (-not $Json) { Write-Host ("{0}：{1}" -f $Label, $(if ($passed) { "通过" } else { "失败" })) }
                return $passed
            }
        }
        [void]$script:ClaudeEasyChecks.Add([ordered]@{ name = $Label.ToLowerInvariant(); ok = $false; status = "not_observed" })
        if (-not $Json) { Write-Host "$Label：失败（没有观察到对应连接）" }
        return $false
    } finally {
        if ($null -ne $process -and -not $process.HasExited) {
            try { $process.Kill() } catch { }
        }
        if ($null -ne $process) { $process.Dispose() }
    }
}

try {
    if ($ObservationSeconds -lt 1 -or $ObservationSeconds -gt 60) { throw "观察时间必须为 1 到 60 秒。" }
    $policy = Get-Policy
    $proxyResponse = Invoke-ControllerJson "/proxies"
    $proxies = $proxyResponse.proxies
    if ($null -eq $proxies) { throw "本地控制器没有返回代理组。" }

    if ([string]::IsNullOrWhiteSpace($MainGroup)) {
        $main = Get-LiveMainGroup $proxies
    } else {
        $main = Find-Group $proxies @() $MainGroup "主代理组"
    }
    $ai = Find-Group $proxies @($policy.ai_group_names) $AiGroup "AI 分组"
    $mainSelection = [string]$proxies.PSObject.Properties[$main].Value.now
    $aiSelection = [string]$proxies.PSObject.Properties[$ai].Value.now
    if ([string]::IsNullOrWhiteSpace($mainSelection) -or $mainSelection -eq "DIRECT") { throw "主代理组当前没有选择有效代理节点。" }
    if ([string]::IsNullOrWhiteSpace($aiSelection) -or $aiSelection -eq "DIRECT") { throw "AI 分组当前没有选择有效代理节点。" }

    if (-not $Json) {
        Write-Output "主代理组：已识别；当前选择已隐藏"
        Write-Output "AI 分组：已识别；当前选择已隐藏"
    }
    $checks = @(
        (Observe-Route "Google" "https://www.google.com/search?q=clash-route-verification" '(?i)(^|\.)google\.com$' $main $mainSelection $proxies $ai $true),
        (Observe-Route "OpenAI" "https://openai.com/" '(?i)(^|\.)openai\.com$' $ai $aiSelection $proxies $ai $false),
        (Observe-Route "Anthropic" "https://www.anthropic.com/" '(?i)(^|\.)anthropic\.com$' $ai $aiSelection $proxies $ai $false),
        (Observe-Route "Claude" "https://claude.ai/" '(?i)(^|\.)claude\.ai$' $ai $aiSelection $proxies $ai $false)
    )
    if (@($checks | Where-Object { -not $_ }).Count -gt 0) {
        if ($Json) { Write-ClaudeEasyResult (New-ClaudeEasyResult -Command "verify_routes" -Operation "verify_routes" -Ok $false -Status "failed" -Code "route_check_failed" -ExitCode 1 -SummaryZh "Windows 分流验证未通过。" -Checks @($script:ClaudeEasyChecks)) }
        exit 1
    }
    if ($Json) { Write-ClaudeEasyResult (New-ClaudeEasyResult -Command "verify_routes" -Operation "verify_routes" -Ok $true -Status "ok" -Code "routes_verified" -ExitCode 0 -SummaryZh "Windows 分流验证通过。" -Checks @($script:ClaudeEasyChecks)) }
    exit 0
} catch {
    if ($Json) {
        Write-ClaudeEasyResult (New-ClaudeEasyResult -Command "verify_routes" -Operation "verify_routes" -Ok $false -Status "failed" -Code "verification_failed" -ExitCode 1 -SummaryZh ("Windows 分流验证失败：" + $_.Exception.Message) -Checks @($script:ClaudeEasyChecks))
    } else {
        [Console]::Error.WriteLine("[ClaudeEasy] Windows 分流验证失败：$($_.Exception.Message)")
    }
    exit 1
}
