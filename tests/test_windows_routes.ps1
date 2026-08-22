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

$source = Get-Content -LiteralPath $routeVerifier -Raw
$expectedTargets = @(
    '(Observe-Route "ChatGPT" "https://chatgpt.com/"',
    '(Observe-Route "Gemini" "https://gemini.google.com/"',
    '(Observe-Route "Grok" "https://grok.com/"'
)
foreach ($target in $expectedTargets) {
    Assert-True ($source.Contains($target)) "missing approved route target"
}
$targetCalls = [regex]::Matches($source, '(?m)^\s*\(Observe-Route "').Count
Assert-True ($targetCalls -eq 3) "route verifier target set changed"

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
