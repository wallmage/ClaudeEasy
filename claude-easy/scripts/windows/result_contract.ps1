$script:ClaudeEasyResultSchema = "claude-easy.result"
$script:ClaudeEasyResultVersion = 1
$script:ClaudeEasyResultCommands = @("install", "uninstall", "patch", "verify_routes")
$script:ClaudeEasyResultItemStatuses = @("updated", "unchanged", "skipped", "failed", "rolled_back", "pending")
$script:ClaudeEasyResultTextLimit = 240

function Protect-ClaudeEasyResultText([object]$Value) {
    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    $text = [regex]::Replace($text, '\x1B\][^\x07]*(?:\x07|\x1B\\)', '')
    $text = [regex]::Replace($text, '\x1B\[[0-?]*[ -/]*[@-~]', '')
    $text = [regex]::Replace($text, '[\p{Cc}\p{Cf}]', '')
    $text = [regex]::Replace($text, '(?i)(?<![A-Za-z0-9])[A-Za-z][A-Za-z0-9+.-]*://\S+', '[已隐藏地址]')
    $text = [regex]::Replace($text, '(?i)(?<![A-Za-z0-9])Bearer\s+\S+', '[已隐藏]')
    $text = [regex]::Replace($text, '(?i)(?<![A-Za-z0-9])(password|passwd|secret|token|uuid|private[-_ ]?key|controller[-_ ]?key)\s*[:=]\s*\S+', '[已隐藏]')
    $text = [regex]::Replace($text, '(?i)[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', '[已隐藏]')
    $text = [regex]::Replace($text, '(?i)(?:[A-Z]:[\\/]|\\\\|//)[^\r\n；，。]+', '[已隐藏路径]')
    $text = [regex]::Replace($text, '(?<![A-Za-z0-9])/(?!/)[^\r\n；，。]+', '[已隐藏路径]')
    $text = $text.Trim()
    if ($text.Length -gt $script:ClaudeEasyResultTextLimit) {
        $text = $text.Substring(0, $script:ClaudeEasyResultTextLimit)
        if ($text.Length -gt 0 -and [char]::IsHighSurrogate($text[$text.Length - 1])) {
            $text = $text.Substring(0, $text.Length - 1)
        }
    }
    return $text
}

function ConvertTo-ClaudeEasyResultArray([object[]]$Values) {
    $result = @()
    foreach ($value in @($Values)) {
        if ($null -eq $value) { continue }
        $result += (Protect-ClaudeEasyResultValue $value)
    }
    return @($result)
}

function Protect-ClaudeEasyResultValue([object]$Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return (Protect-ClaudeEasyResultText $Value) }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $result[(Protect-ClaudeEasyResultText $key)] = Protect-ClaudeEasyResultValue $Value[$key]
        }
        return $result
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[(Protect-ClaudeEasyResultText $property.Name)] = Protect-ClaudeEasyResultValue $property.Value
        }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $result = @()
        foreach ($entry in $Value) { $result += ,(Protect-ClaudeEasyResultValue $entry) }
        return ,$result
    }
    if ($Value -is [bool] -or
        $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        return $Value
    }
    return (Protect-ClaudeEasyResultText $Value)
}

function New-ClaudeEasyResult(
    [Parameter(Mandatory = $true)][string]$Command,
    [Parameter(Mandatory = $true)][string]$Operation,
    [Parameter(Mandatory = $true)][bool]$Ok,
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$Code,
    [Parameter(Mandatory = $true)][int]$ExitCode,
    [Parameter(Mandatory = $true)][string]$SummaryZh,
    [object]$Profile = $null,
    [object[]]$Changes = @(),
    [object[]]$Checks = @(),
    [object[]]$Items = @(),
    [object[]]$Messages = @(),
    [object[]]$Warnings = @()
) {
    if ($Command -notin $script:ClaudeEasyResultCommands) { throw "结果命令无效。" }
    if ($Status -notin @("ok", "no_change", "skipped", "failed", "rolled_back", "partial", "invalid_request", "unsupported")) { throw "结果状态无效。" }
    $protectedItems = @(ConvertTo-ClaudeEasyResultArray $Items)
    foreach ($item in $protectedItems) {
        if ($item -is [System.Collections.IDictionary] -and
            $item.Contains("status") -and
            [string]$item["status"] -notin $script:ClaudeEasyResultItemStatuses) {
            throw "结果项目状态无效。"
        }
    }
    return [pscustomobject][ordered]@{
        schema = $script:ClaudeEasyResultSchema
        version = $script:ClaudeEasyResultVersion
        command = $Command
        platform = "windows"
        client = "clash-verge-rev"
        operation = $Operation
        ok = $Ok
        status = $Status
        code = $Code
        exit_code = $ExitCode
        summary_zh = (Protect-ClaudeEasyResultText $SummaryZh)
        profile = Protect-ClaudeEasyResultValue $Profile
        changes = @(ConvertTo-ClaudeEasyResultArray $Changes)
        checks = @(ConvertTo-ClaudeEasyResultArray $Checks)
        items = $protectedItems
        messages = @(ConvertTo-ClaudeEasyResultArray $Messages)
        warnings = @(ConvertTo-ClaudeEasyResultArray $Warnings)
    }
}

function Write-ClaudeEasyResult([object]$Result) {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $protected = Protect-ClaudeEasyResultValue $Result
    [Console]::Out.WriteLine(($protected | ConvertTo-Json -Depth 8 -Compress))
}
