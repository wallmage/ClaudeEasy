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
