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
                $changed = -not (Test-RemoteSubscriptionSemanticEqual $local $remote)
                $item.status = if ($changed) { 'pending' } else { 'unchanged' }
                $item.update_available = [bool]$changed
            } catch {
                $item['code'] = 'subscription_check_failed'
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

function Get-RemoteSubscriptionUpdatePlan(
    [object[]]$Targets,
    [scriptblock]$RemoteContentProvider = $null,
    [DateTime]$AbsoluteDeadline = [DateTime]::MaxValue
) {
    if (@($Targets).Count -eq 0) { throw "没有可比较的远程订阅。" }
    $plan = @()
    foreach ($target in @($Targets)) {
        $remaining = if ($AbsoluteDeadline -eq [DateTime]::MaxValue) {
            30
        } else {
            [int][Math]::Ceiling(($AbsoluteDeadline - [DateTime]::UtcNow).TotalSeconds)
        }
        if ($remaining -lt 1) { throw "safe_update_timeout" }
        $url = [string]$target.Url
        $remoteBytes = if ($null -ne $RemoteContentProvider) {
            $providedContent = & $RemoteContentProvider $target
            ConvertTo-RemoteSubscriptionBytes $providedContent
        } else {
            Get-RemoteSubscriptionHttpBytes $url ([int][Math]::Min(30, $remaining))
        }
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        try {
            $remoteText = $strictUtf8.GetString($remoteBytes)
        } catch {
            throw "远程订阅返回的内容不是有效 UTF-8。"
        }
        if ($remoteText.Length -gt 0 -and $remoteText[0] -eq [char]0xFEFF) {
            $remoteText = $remoteText.Substring(1)
        }
        Test-GeneratedYaml $remoteText (Get-PublicSubscriptionLabel ([string]$target.Uid) ([string]$target.Name)) | Out-Null
        $localSnapshot = Get-OptionalFileSnapshot ([string]$target.Path) "远程订阅"
        $localFingerprint = $null
        $localText = ""
        if ($localSnapshot.Exists) {
            try {
                $localText = $strictUtf8.GetString($localSnapshot.Bytes)
                $localFingerprint = Get-YamlPathFingerprints $localText
            } catch {
                throw "本地远程订阅无效，无法安全比较。"
            }
        }
        $remoteFingerprint = Get-YamlPathFingerprints $remoteText
        $changed = -not $localSnapshot.Exists -or
            -not (Test-RemoteSubscriptionSemanticEqual $localFingerprint $remoteFingerprint)
        $plan += [pscustomobject]@{
            Uid = [string]$target.Uid
            Name = [string]$target.Name
            Path = [string]$target.Path
            Url = $url
            Changed = [bool]$changed
            RemoteBytes = [byte[]]$remoteBytes
            RemoteText = $remoteText
            LocalText = if ($localSnapshot.Exists) { $localText } else { "" }
            LocalBytes = if ($localSnapshot.Exists) { [byte[]]$localSnapshot.Bytes } else { [byte[]]@() }
            LocalIdentity = [string]$localSnapshot.Identity
            LocalSha256 = if ($localSnapshot.Exists) { Get-BytesSha256 $localSnapshot.Bytes } else { "" }
            RemoteSha256 = Get-BytesSha256 $remoteBytes
        }
    }
    return @($plan)
}
