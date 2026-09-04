param(
    [Parameter(Mandatory = $true)]
    [string]$PowerShellPath,
    [Parameter(Mandatory = $true)]
    [ValidateSet("Desktop", "Core")]
    [string]$ExpectedPSEdition,
    [Parameter(Mandatory = $true)]
    [ValidateSet(5, 7)]
    [int]$ExpectedPSMajor
)

$ErrorActionPreference = "Stop"

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

Assert-True (
    $PSVersionTable.PSEdition -eq $ExpectedPSEdition -and
    $PSVersionTable.PSVersion.Major -eq $ExpectedPSMajor
) "test host runtime mismatch"

$childVersionOutput = & $PowerShellPath -NoLogo -NoProfile -Command `
    '[pscustomobject]@{ Edition = $PSVersionTable.PSEdition; Major = $PSVersionTable.PSVersion.Major } | ConvertTo-Json -Compress'
Assert-True ($LASTEXITCODE -eq 0) "PowerShellPath version probe failed"
$childVersion = $childVersionOutput | ConvertFrom-Json
Assert-True (
    [string]$childVersion.Edition -eq $ExpectedPSEdition -and
    [int]$childVersion.Major -eq $ExpectedPSMajor
) "PowerShellPath runtime mismatch"

$root = Split-Path -Parent $PSScriptRoot
$routeVerifier = Join-Path $root "claude-easy/scripts/windows/verify_routes.ps1"
$windowsScripts = Join-Path $root "claude-easy/scripts/windows"
. (Join-Path $windowsScripts "result_contract.ps1")
foreach ($moduleName in @("transaction.ps1", "common.ps1", "yaml.ps1", "runtime.ps1")) {
    . (Join-Path $windowsScripts "install_windows/$moduleName")
}
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $routeVerifier,
    [ref]$tokens,
    [ref]$parseErrors
)
Assert-True ($parseErrors.Count -eq 0) ($parseErrors | Out-String)
$functionAsts = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true))
Assert-True ($functionAsts.Count -gt 0) "route verifier has no functions"
$functionAsts | ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }

foreach ($acceptedControllerUrl in @(
    "http://127.0.0.1:9097",
    "http://[::1]:9097",
    "https://localhost:9443/base"
)) {
    [void](Get-ValidatedControllerBaseUri $acceptedControllerUrl)
}
foreach ($rejectedControllerUrl in @(
    "ftp://127.0.0.1/",
    "http://example.com/",
    "http://127.0.0.1.example.com/",
    "http://friend@127.0.0.1/"
)) {
    $rejected = $false
    try { [void](Get-ValidatedControllerBaseUri $rejectedControllerUrl) } catch { $rejected = $true }
    Assert-True $rejected "controller URL escaped the loopback-only validator"
}

$proxies = [pscustomobject]@{
    Main = [pscustomobject]@{ type = "Selector"; now = "Main Node" }
    AI = [pscustomobject]@{ type = "Selector"; now = "AI Node" }
    "Main Node" = [pscustomobject]@{ type = "Shadowsocks" }
    "AI Node" = [pscustomobject]@{ type = "Vmess" }
    DIRECT = [pscustomobject]@{ type = "Direct" }
}
Assert-True (
    Test-RouteChains $proxies @("AI Node", "AI") "AI" "AI Node" "AI" $false
) "AI route chain was rejected"
Assert-True (-not (
    Test-RouteChains $proxies @("DIRECT", "AI") "AI" "AI Node" "AI" $false
)) "direct route chain was accepted"

$siblingSequenceRuntime = @'
dns:
  direct-nameserver:
  - 1.1.1.1
  - 8.8.8.8
  nameserver:
  - 9.9.9.9
'@
Assert-True (
    (@(Get-ClashRuntimeYamlSequence $siblingSequenceRuntime @("dns", "direct-nameserver")) -join ",") -ceq
        "1.1.1.1,8.8.8.8"
) "runtime parser did not retain same-indent direct-nameserver entries"

$ipv6AiPolicy = [pscustomobject]@{
    ai_rules = @("IP-CIDR6,2606:4700::/32,{AI}")
}
$ipv6AiRules = @([pscustomobject]@{
    type = "IPCIDR"
    payload = "2606:4700::/32"
    proxy = "AI"
})
Assert-True (
    (Get-ClashRuntimeAiGroupName $ipv6AiRules $ipv6AiPolicy) -ceq "AI"
) "IPv6 IPCIDR runtime rule was rejected for an IPCIDR6 policy rule"
$ipv4TypeMismatchRejected = $false
try {
    Get-ClashRuntimeAiGroupName @([pscustomobject]@{
        type = "IPCIDR"
        payload = "198.51.100.0/24"
        proxy = "AI"
    }) ([pscustomobject]@{ ai_rules = @("IP-CIDR6,198.51.100.0/24,{AI}") }) | Out-Null
} catch {
    $ipv4TypeMismatchRejected = $true
}
Assert-True $ipv4TypeMismatchRejected "IPv4 IPCIDR rule was accepted as IPCIDR6"

if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $probeCommand = Join-Path ([System.IO.Path]::GetTempPath()) (
        "claude-easy-route-policy-" + [Guid]::NewGuid().ToString("N") + ".cmd"
    )
    [System.IO.File]::WriteAllText($probeCommand, @'
@echo off
echo %* | findstr /C:"-ExecutionPolicy Bypass" >nul
if errorlevel 1 exit /b 1
echo {"checks":[{"ok":true,"status":"ok"}]}
'@, [System.Text.Encoding]::ASCII)
    function global:Join-Path {
        param([string]$Path, [string]$ChildPath)
        if ($Path -ceq $PSHOME -and $ChildPath -eq "powershell.exe") { return $probeCommand }
        return Microsoft.PowerShell.Management\Join-Path @PSBoundParameters
    }
    try {
        $policyProbe = @(Invoke-ParallelRouteProbes @([pscustomobject]@{ Label = "ChatGPT" }) "http://127.0.0.1:9097" "" 1)
        Assert-True ($policyProbe.Count -eq 1 -and [bool]$policyProbe[0].Passed) "parallel route probe did not pass ExecutionPolicy Bypass to its child PowerShell"
    } finally {
        Remove-Item -LiteralPath Function:\global:Join-Path -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $probeCommand -Force -ErrorAction SilentlyContinue
    }
}

$invalidOutput = & $PowerShellPath -NoLogo -NoProfile -File $routeVerifier `
    -ObservationSeconds 0 -Json 2>&1
Assert-True ($LASTEXITCODE -eq 64) "invalid observation window returned the wrong exit code"
$invalidResult = ($invalidOutput -join "`n") | ConvertFrom-Json
Assert-True ($invalidResult.code -eq "invalid_arguments") "invalid observation window lost its JSON contract"

$profileHome = Join-Path ([System.IO.Path]::GetTempPath()) (
    "claude-easy-route-profile-" + [Guid]::NewGuid().ToString("N")
)
try {
    [void](New-Item -ItemType Directory -Path $profileHome -Force)
    [System.IO.File]::WriteAllText(
        (Join-Path $profileHome "claude-easy-usage-profile.json"),
        '{"Version":1,"Profile":1}'
    )
    $profileOutput = & $PowerShellPath -NoLogo -NoProfile -File $routeVerifier `
        -AppHome $profileHome -ObservationSeconds 1 -Json 2>&1
    Assert-True ($LASTEXITCODE -eq 10) "profile gate returned the wrong exit code"
    $profileResult = ($profileOutput -join "`n") | ConvertFrom-Json
    Assert-True ($profileResult.code -eq "usage_profile_mismatch") "profile gate lost its JSON contract"
} finally {
    Remove-Item -LiteralPath $profileHome -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "Windows route regressions passed."
