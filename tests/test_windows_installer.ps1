param(
    [Parameter(Mandatory = $true)]
    [string]$PowerShellPath,
    [Parameter(Mandatory = $true)]
    [ValidateSet("Desktop", "Core")]
    [string]$ExpectedPSEdition,
    [Parameter(Mandatory = $true)]
    [ValidateSet(5, 7)]
    [int]$ExpectedPSMajor,
    [string[]]$RealMihomoPaths = @(),
    [string]$RealMihomoGeoSitePath,
    [switch]$RealMihomoOnly,
    [string]$CompletionReceiptPath,
    [string]$CompletionReceiptNonce
)

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSEdition -ne $ExpectedPSEdition -or
    $PSVersionTable.PSVersion.Major -ne $ExpectedPSMajor) {
    throw "test host runtime mismatch: expected $ExpectedPSEdition $ExpectedPSMajor, got $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
}
$childVersionOutput = & $PowerShellPath -NoLogo -NoProfile -Command '[pscustomobject]@{ PSEdition = $PSVersionTable.PSEdition; Major = $PSVersionTable.PSVersion.Major } | ConvertTo-Json -Compress'
if ($LASTEXITCODE -ne 0) { throw "PowerShellPath version probe failed" }
$childVersion = $childVersionOutput | ConvertFrom-Json
if ([string]$childVersion.PSEdition -ne $ExpectedPSEdition -or
    [int]$childVersion.Major -ne $ExpectedPSMajor) {
    throw "PowerShellPath runtime mismatch: expected $ExpectedPSEdition $ExpectedPSMajor"
}
$root = Split-Path -Parent $PSScriptRoot
$installer = Join-Path (Join-Path $root "claude-easy/scripts") "install_windows.ps1"
$uninstaller = Join-Path (Join-Path $root "claude-easy/scripts") "uninstall_windows.ps1"
$installWrapper = Join-Path (Join-Path $root "claude-easy/scripts") "install_windows.cmd"
$uninstallWrapper = Join-Path (Join-Path $root "claude-easy/scripts") "uninstall_windows.cmd"
$routeVerifier = Join-Path (Join-Path $root "claude-easy/scripts/windows") "verify_routes.ps1"
$resultContract = Join-Path (Join-Path $root "claude-easy/scripts/windows") "result_contract.ps1"
$installerModuleRoot = Join-Path (Join-Path $root "claude-easy/scripts/windows") "install_windows"
$installerModules = @(
    "common.ps1", "yaml.ps1", "profiles.ps1", "mihomo.ps1",
    "transaction.ps1", "script_js.ps1", "runtime.ps1", "safe_update.ps1"
) | ForEach-Object { Join-Path $installerModuleRoot $_ }
$uninstallerModules = @(
    "yaml.ps1", "profiles.ps1", "transaction.ps1", "script_js.ps1", "safe_update.ps1"
) | ForEach-Object { Join-Path $installerModuleRoot $_ }
$resultItemStatuses = @((Get-Content -LiteralPath (Join-Path (Join-Path $root "claude-easy/references") "result-contract.json") -Raw | ConvertFrom-Json).item_statuses)
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-easy-windows-test-" + [System.Guid]::NewGuid().ToString("N"))
$onWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$script:safeUpdateControllerPort = 0
$script:safeUpdateClientPath = ""
$safeUpdateControllerJob = $null
$previousUsageProfile = $env:CLAUDE_EASY_USAGE_PROFILE
$env:CLAUDE_EASY_USAGE_PROFILE = "3"
$script:deferredProbeFailures = New-Object System.Collections.ArrayList
$fakeCore = Join-Path $sandbox $(if ($onWindows) { "mihomo-test.cmd" } else { "mihomo-test.sh" })
$hangingCore = Join-Path $sandbox $(if ($onWindows) { "mihomo-hang.cmd" } else { "mihomo-hang.sh" })
$mutatingCore = Join-Path $sandbox "mihomo-mutate.cmd"
$identityMutatingCore = Join-Path $sandbox "mihomo-identity-mutate.cmd"
$candidateHangingCore = Join-Path $sandbox "mihomo-candidate-hang.cmd"

function Get-ProtectedAutomaticVariableNames {
    $automaticCandidates = @(
        "ConsoleFileName", "EnabledExperimentalFeatures", "ExecutionContext",
        "HOME", "Host", "IsCoreCLR", "IsLinux", "IsMacOS", "IsWindows",
        "MyInvocation", "NestedPromptLevel", "PID", "PROFILE",
        "PSBoundParameters", "PSCmdlet", "PSCommandPath", "PSCulture",
        "PSDebugContext", "PSEdition", "PSHOME", "PSScriptRoot",
        "PSSenderInfo", "PSUICulture", "PSVersionTable", "PWD",
        "ShellId", "StackTrace"
    )
    $names = @{}
    foreach ($variable in @(Get-Variable)) {
        if ($variable.Name -in @("null", "true", "false")) { continue }
        if (($variable.Options -band [System.Management.Automation.ScopedItemOptions]::ReadOnly) -or
            ($variable.Options -band [System.Management.Automation.ScopedItemOptions]::Constant)) {
            $names[$variable.Name] = $true
        }
    }
    foreach ($name in $automaticCandidates) {
        $variable = Get-Variable -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $variable) { continue }
        if (($variable.Options -band [System.Management.Automation.ScopedItemOptions]::ReadOnly) -or
            ($variable.Options -band [System.Management.Automation.ScopedItemOptions]::Constant)) {
            $names[$name] = $true
        }
    }
    return $names
}

function Get-AutomaticVariableBaseName([System.Management.Automation.Language.VariableExpressionAst]$Variable) {
    $parts = $Variable.VariablePath.UserPath.Split(":")
    return $parts[$parts.Count - 1]
}

function Test-IsDirectVariableTarget(
    [System.Management.Automation.Language.VariableExpressionAst]$Variable,
    [System.Management.Automation.Language.Ast]$Target
) {
    if ($Variable -eq $Target) { return $true }
    $current = $Variable.Parent
    while ($null -ne $current -and $current -ne $Target) {
        if ($current -is [System.Management.Automation.Language.MemberExpressionAst] -or
            $current -is [System.Management.Automation.Language.IndexExpressionAst]) {
            return $false
        }
        $current = $current.Parent
    }
    return $current -eq $Target
}

function Assert-NoReadOnlyAutomaticVariableWrites(
    [System.Management.Automation.Language.ScriptBlockAst]$Ast,
    [string]$DisplayName
) {
    $protectedNames = Get-ProtectedAutomaticVariableNames
    $violations = New-Object System.Collections.ArrayList
    $recordName = {
        param([string]$Name, [System.Management.Automation.Language.Ast]$Write)
        $parts = $Name.Split(":")
        $baseName = $parts[$parts.Count - 1]
        if ($protectedNames.ContainsKey($baseName)) {
            [void]$violations.Add(("{0}:{1}: ${2} is read-only or constant" -f $DisplayName, $Write.Extent.StartLineNumber, $baseName))
        }
    }
    $record = {
        param(
            [System.Management.Automation.Language.VariableExpressionAst]$Variable,
            [System.Management.Automation.Language.Ast]$Write
        )
        & $recordName (Get-AutomaticVariableBaseName $Variable) $Write
    }

    foreach ($assignment in @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst]
    }, $true))) {
        foreach ($variable in @($assignment.Left.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.VariableExpressionAst]
        }, $true))) {
            if (Test-IsDirectVariableTarget $variable $assignment.Left) {
                & $record $variable $assignment
            }
        }
    }

    foreach ($parameter in @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.ParameterAst]
    }, $true))) {
        & $record $parameter.Name $parameter
    }

    foreach ($loop in @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.ForEachStatementAst]
    }, $true))) {
        & $record $loop.Variable $loop
    }

    $mutationTokens = @("PlusPlus", "MinusMinus", "PostfixPlusPlus", "PostfixMinusMinus")
    foreach ($unary in @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.UnaryExpressionAst]
    }, $true))) {
        if ($unary.TokenKind.ToString() -notin $mutationTokens) { continue }
        if ($unary.Child -is [System.Management.Automation.Language.VariableExpressionAst]) {
            & $record $unary.Child $unary
        }
    }

    $variableMutationCommands = @("Set-Variable", "New-Variable", "Clear-Variable", "Remove-Variable")
    foreach ($command in @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true))) {
        $commandName = $command.GetCommandName()
        if ($commandName -notin $variableMutationCommands) { continue }
        $expectName = $false
        $sawPositionalName = $false
        for ($index = 1; $index -lt $command.CommandElements.Count; $index++) {
            $element = $command.CommandElements[$index]
            if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                $expectName = $element.ParameterName -eq "Name"
                if ($expectName -and $null -ne $element.Argument -and
                    $element.Argument -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    & $recordName $element.Argument.Value $command
                    $expectName = $false
                }
                continue
            }
            if ($element -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
                if ($expectName) { $expectName = $false }
                continue
            }
            if ($expectName -or -not $sawPositionalName) {
                & $recordName $element.Value $command
                $sawPositionalName = $true
                $expectName = $false
            }
        }
    }

    if ($violations.Count -gt 0) { throw ($violations -join "`n") }
}

$automaticVariableGuardCases = @(
    '$host = "blocked"',
    'param([string]$HOST)',
    'foreach ($Host in @("blocked")) { }',
    '++$global:Host',
    '${script:HOST}--',
    '$safe, $Host = @("safe", "blocked")',
    'Set-Variable -Name Host -Value "blocked"'
)
foreach ($guardCase in $automaticVariableGuardCases) {
    $guardTokens = $null
    $guardErrors = $null
    $guardAst = [System.Management.Automation.Language.Parser]::ParseInput($guardCase, [ref]$guardTokens, [ref]$guardErrors)
    if ($guardErrors.Count -gt 0) { throw ($guardErrors | Out-String) }
    $guardRejected = $false
    try { Assert-NoReadOnlyAutomaticVariableWrites $guardAst "automatic-variable-guard-fixture" } catch { $guardRejected = $true }
    if (-not $guardRejected) { throw "automatic-variable guard accepted: $guardCase" }
}
$safeGuardTokens = $null
$safeGuardErrors = $null
$safeGuardAst = [System.Management.Automation.Language.Parser]::ParseInput(
    '$connectionHost = "safe"; $Host.UI.RawUI.BackgroundColor = "Red"',
    [ref]$safeGuardTokens,
    [ref]$safeGuardErrors
)
if ($safeGuardErrors.Count -gt 0) { throw ($safeGuardErrors | Out-String) }
Assert-NoReadOnlyAutomaticVariableWrites $safeGuardAst "automatic-variable-safe-fixture"

$productionPowerShellFiles = @(Get-ChildItem -LiteralPath (Join-Path $root "claude-easy/scripts") -Filter "*.ps1" -File -Recurse)
foreach ($productionPowerShellFile in $productionPowerShellFiles) {
    $productionTokens = $null
    $productionParseErrors = $null
    $productionAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $productionPowerShellFile.FullName,
        [ref]$productionTokens,
        [ref]$productionParseErrors
    )
    if ($productionParseErrors.Count -gt 0) { throw ($productionParseErrors | Out-String) }
    Assert-NoReadOnlyAutomaticVariableWrites $productionAst $productionPowerShellFile.FullName
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
$entryFunctions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
if ($entryFunctions.Count -ne 0) { throw "install_windows.ps1 still contains library functions" }
$loadedFunctions = @{}
foreach ($modulePath in $installerModules) {
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw "missing installer module: $modulePath" }
    $moduleTokens = $null
    $moduleParseErrors = $null
    $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$moduleTokens, [ref]$moduleParseErrors)
    if ($moduleParseErrors.Count -gt 0) { throw ($moduleParseErrors | Out-String) }
    foreach ($statement in @($moduleAst.EndBlock.Statements)) {
        if (-not ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst])) {
            throw "installer module has a load-time side effect: $modulePath"
        }
    }
    foreach ($functionAst in @($moduleAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
        if ($loadedFunctions.ContainsKey($functionAst.Name)) { throw "duplicate installer function: $($functionAst.Name)" }
        $loadedFunctions[$functionAst.Name] = $true
    }
    . $modulePath
}
$routeTokens = $null
$routeParseErrors = $null
$routeAst = [System.Management.Automation.Language.Parser]::ParseFile($routeVerifier, [ref]$routeTokens, [ref]$routeParseErrors)
if ($routeParseErrors.Count -gt 0) { throw ($routeParseErrors | Out-String) }
$routeFunctionAsts = @($routeAst.FindAll({
    param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true))
if ($routeFunctionAsts.Count -eq 0) { throw "route verifier has no functions" }
$routeFunctionAsts | ForEach-Object {
    . ([scriptblock]::Create($_.Extent.Text))
}
$uninstallTokens = $null
$uninstallParseErrors = $null
$uninstallAst = [System.Management.Automation.Language.Parser]::ParseFile($uninstaller, [ref]$uninstallTokens, [ref]$uninstallParseErrors)
if ($uninstallParseErrors.Count -gt 0) { throw ($uninstallParseErrors | Out-String) }
$uninstallerSource = Get-Content -LiteralPath $uninstaller -Raw
foreach ($stateBinding in @(
    [pscustomobject]@{ Variable = "statePath"; Label = "install state" },
    [pscustomobject]@{ Variable = "autoUpdateStatePath"; Label = "auto-update state" },
    [pscustomobject]@{ Variable = "usageStatePath"; Label = "usage state" },
    [pscustomobject]@{ Variable = "safeUpdateStatePath"; Label = "safe-update state" }
)) {
    $escapedVariable = [regex]::Escape($stateBinding.Variable)
    if ([regex]::Matches($uninstallerSource, "Get-OptionalFileSnapshot\s+\`$$escapedVariable\b").Count -ne 1) {
        throw "uninstaller does not bind $($stateBinding.Label) parsing and deletion to one snapshot"
    }
    if ($uninstallerSource -match "(?m)Get-Content[^\r\n]*\`$$escapedVariable\b|ReadAllBytes\(\`$$escapedVariable\)") {
        throw "uninstaller reads $($stateBinding.Label) again after taking its snapshot"
    }
}
$uninstallerEntryFunctionNames = @($uninstallAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true) | ForEach-Object { $_.Name })
foreach ($uninstallerModule in $uninstallerModules) {
    $uninstallerModuleTokens = $null
    $uninstallerModuleErrors = $null
    $uninstallerModuleAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $uninstallerModule,
        [ref]$uninstallerModuleTokens,
        [ref]$uninstallerModuleErrors
    )
    if ($uninstallerModuleErrors.Count -gt 0) { throw ($uninstallerModuleErrors | Out-String) }
    foreach ($moduleFunction in @($uninstallerModuleAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true))) {
        if ($uninstallerEntryFunctionNames -contains $moduleFunction.Name) {
            throw "uninstaller duplicates imported module function: $($moduleFunction.Name)"
        }
    }
}
$uninstallAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "New-UninstallBackup"
}, $true) | ForEach-Object {
    . ([scriptblock]::Create($_.Extent.Text))
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

if ($onWindows) {
    Initialize-ClaudeEasySendInput | Out-Null
    $productionSendInputType = "ClaudeEasy.SendInputNative" -as [type]
    Assert-True ($null -ne $productionSendInputType) "production SendInput type did not compile"
    Assert-True (
        @($productionSendInputType.GetMethods() | Where-Object {
            $_.Name -eq "Send" -and $_.IsStatic -and $_.ReturnType -eq [bool]
        }).Count -eq 1
    ) "production SendInput method was unavailable"
    $originalRunningCheck = (Get-Command Test-ClashVergeRunning -CommandType Function).ScriptBlock
    $originalSendInputInitializer = (Get-Command Initialize-ClaudeEasySendInput -CommandType Function).ScriptBlock
    try {
        Set-Item Function:\Test-ClashVergeRunning { return $false }
        Set-Item Function:\Initialize-ClaudeEasySendInput { throw "SendInput initialized after client exit" }
        $stoppedClientRejected = $false
        try { Invoke-ClashVergeReactivationShortcut "CTRL+ALT+SHIFT+F24" } catch {
            $stoppedClientRejected = $_.Exception.Message.Contains("已退出")
        }
        Assert-True $stoppedClientRejected "rollback shortcut was sent after Clash Verge Rev exited"
    } finally {
        Set-Item Function:\Test-ClashVergeRunning $originalRunningCheck
        Set-Item Function:\Initialize-ClaudeEasySendInput $originalSendInputInitializer
    }
}

$safeUpdateFollowupCases = @(
    [pscustomobject]@{
        Profile = 1
        Expected = @("client_switch_verification", "site_verification", "final_state_audit")
    },
    [pscustomobject]@{
        Profile = 2
        Expected = @("client_switch_verification", "site_verification", "agent_connectivity_verification", "final_state_audit")
    },
    [pscustomobject]@{
        Profile = 3
        Expected = @(
            "client_switch_verification", "site_verification", "agent_connectivity_verification",
            "route_verification", "dns_deep_test",
            "webrtc_test_1", "webrtc_test_2", "region_fingerprint_test", "final_state_audit"
        )
    }
)
foreach ($followupCase in $safeUpdateFollowupCases) {
    $actualFollowups = @(Get-SafeUpdateRequiredFollowups ([int]$followupCase.Profile))
    Assert-True (
        ($actualFollowups -join ",") -ceq (@($followupCase.Expected) -join ",")
    ) "Windows safe-update follow-ups differ from the shared profile workflow for profile $($followupCase.Profile)"
}

function Get-TreeContentSnapshot([string]$Path) {
    $rootPath = [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    return (@(Get-ChildItem -LiteralPath $rootPath -Force -Recurse | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($rootPath.Length).TrimStart(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
        if ($_.PSIsContainer) {
            "D:$relative"
        } elseif ($_.Name -eq ".claude-easy.lock") {
            "F:${relative}:<locked>"
        } else {
            "F:${relative}:" + [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($_.FullName))
        }
    })) -join "`n"
}

function Get-TestOutputDiagnostic([object]$Output) {
    $text = [string]$Output
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
    } finally {
        $sha.Dispose()
    }
    return "output_length=$($text.Length) output_sha256=$digest"
}

function Test-PrivateWindowsFileAcl([string]$Path) {
    $security = Get-Acl -LiteralPath $Path
    $allowedSids = @(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
        "S-1-5-18",
        "S-1-5-32-544"
    )
    $unsafeRules = @(
        foreach ($accessRule in @($security.Access)) {
            if ($accessRule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
                continue
            }
            try {
                $accessRuleSid = $accessRule.IdentityReference.Translate(
                    [System.Security.Principal.SecurityIdentifier]
                ).Value
            } catch {
                $accessRuleSid = $accessRule.IdentityReference.Value
            }
            if ($accessRuleSid -notin $allowedSids) { $accessRule }
        }
    )
    return $security.AreAccessRulesProtected -and $unsafeRules.Count -eq 0
}

function Get-WindowsShortPath([string]$Path) {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return "" }
    $command = 'for %I in ("' + $Path.Replace('"', '""') + '") do @echo %~sI'
    $output = @(& $env:ComSpec /d /c $command 2>$null)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) { return "" }
    return ([string]$output[0]).Trim()
}

function Assert-JsonResult([object]$Invocation, [string]$Command, [int]$ExitCode) {
    $text = $Invocation.Output.Trim()
    $diagnostic = Get-TestOutputDiagnostic $text
    Assert-True ($text.StartsWith("{") -and $text.EndsWith("}")) "JSON mode did not emit exactly one object: $diagnostic"
    try {
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey("DateKind")) {
            $result = $text | ConvertFrom-Json -DateKind String
        } else {
            $result = $text | ConvertFrom-Json
        }
    } catch { throw "JSON mode emitted invalid JSON: $diagnostic" }
    foreach ($field in @("schema", "version", "command", "platform", "client", "operation", "ok", "status", "code", "exit_code", "summary_zh", "profile", "changes", "checks", "items", "messages", "warnings")) {
        Assert-True ($null -ne $result.PSObject.Properties[$field]) "JSON result omitted $field"
    }
    Assert-True ($result.schema -eq "claude-easy.result") "JSON result schema mismatch"
    Assert-True ([int]$result.version -eq 1) "JSON result version mismatch"
    Assert-True ($result.command -eq $Command) "JSON result command mismatch"
    Assert-True ($result.platform -eq "windows") "JSON result platform mismatch"
    Assert-True ($result.client -eq "clash-verge-rev") "JSON result client mismatch"
    foreach ($item in @($result.items)) {
        if ($null -ne $item.PSObject.Properties["status"]) {
            Assert-True ([string]$item.status -in $resultItemStatuses) "JSON item status violates the result contract: $($item.status)"
        }
    }
    Assert-True (
        $text -notmatch '(?i)\b[A-Za-z][A-Za-z0-9+.-]*://|Bearer\s+|password\s*[:=]|secret\s*[:=]|token\s*[:=]|uuid\s*[:=]|private[_-]?key\s*[:=]|[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
    ) "JSON result leaked a secret, credential, identifier, or URL"
    Assert-True ([int]$result.exit_code -eq $ExitCode) (
        "JSON result exit_code mismatch for ${Command}: expected $ExitCode, JSON reported $($result.exit_code), process exited $($Invocation.ExitCode), status=$($result.status), code=$($result.code), summary=$($result.summary_zh)"
    )
    Assert-True ($Invocation.ExitCode -eq $ExitCode) (
        "process exit mismatch for ${Command}: expected $ExitCode, process exited $($Invocation.ExitCode), JSON reported $($result.exit_code), status=$($result.status), code=$($result.code), summary=$($result.summary_zh)"
    )
    return $result
}

function Invoke-DeferredProbe([string]$Name, [scriptblock]$Probe) {
    try {
        & $Probe
    } catch {
        [void]$script:deferredProbeFailures.Add(("{0}: {1}" -f $Name, $_.Exception.Message))
    }
}

function Invoke-TestPowerShell(
    [string]$ScriptPath,
    [string[]]$ScriptArguments,
    [switch]$SimulateRuntimeRefresh
) {
    $temporarySafeUpdateClient = $null
    $simulatedRuntimeBootstrap = $null
    $previousSafeUpdatePath = $null
    $previousImmediateCurl = $null
    $usesSafeUpdateRuntime = $onWindows -and $script:safeUpdateControllerPort -gt 0 -and
        (Split-Path -Leaf $ScriptPath) -eq "install_windows.ps1" -and
        ($ScriptArguments -contains "-SnapshotProfiles" -or $ScriptArguments -contains "-VerifySafeUpdate")
    if ($usesSafeUpdateRuntime) {
        $appHomeIndex = [Array]::IndexOf($ScriptArguments, "-AppHome")
        if ($appHomeIndex -ge 0 -and $appHomeIndex + 1 -lt $ScriptArguments.Count) {
            $runtimeHome = [string]$ScriptArguments[$appHomeIndex + 1]
            if (Test-Path -LiteralPath $runtimeHome -PathType Container) {
                $runtimePath = Join-Path $runtimeHome "clash-verge.yaml"
                [System.IO.File]::WriteAllText($runtimePath, $script:safeUpdateRuntimeText)
            }
        }
        $temporarySafeUpdateClient = Start-Process `
            -FilePath $script:safeUpdateClientPath `
            -ArgumentList @("-t", "127.0.0.1") `
            -PassThru
        $previousSafeUpdatePath = $env:PATH
        $previousImmediateCurl = $env:CLAUDE_EASY_TEST_CURL_IMMEDIATE_SUCCESS
        $env:PATH = $fakeCurlDirectory + [System.IO.Path]::PathSeparator + $env:PATH
        $env:CLAUDE_EASY_TEST_CURL_IMMEDIATE_SUCCESS = "1"
    }
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        if ($SimulateRuntimeRefresh) {
            $mihomoPathIndex = [Array]::IndexOf($ScriptArguments, "-MihomoPath")
            $payload = [pscustomobject]@{
                ScriptPath = $ScriptPath
                AppHome = [string]$ScriptArguments[$appHomeIndex + 1]
                MihomoPath = [string]$ScriptArguments[$mihomoPathIndex + 1]
                Json = $ScriptArguments -contains "-Json"
                RuntimePath = $runtimePath
            } | ConvertTo-Json -Compress -Depth 3
            $payloadBase64 = [Convert]::ToBase64String(
                [System.Text.Encoding]::UTF8.GetBytes($payload)
            )
            $bootstrap = @'
$payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__')) | ConvertFrom-Json
Add-Type -TypeDefinition 'namespace ClaudeEasy { public static class SendInputNative { public static string RuntimePath; public static bool Send(System.UInt16[] keys) { if (keys == null || keys.Length != 4 || keys[0] != 0x11 || keys[1] != 0x12 || keys[2] != 0x10 || keys[3] != 0x87) { return false; } System.IO.File.AppendAllText(RuntimePath, "\n# simulated refresh\n"); return true; } } }' -ErrorAction Stop | Out-Null
[ClaudeEasy.SendInputNative]::RuntimePath = [string]$payload.RuntimePath
$arguments = @{
    AppHome = [string]$payload.AppHome
    MihomoPath = [string]$payload.MihomoPath
    VerifySafeUpdate = $true
    RefreshConfirmed = $true
    Json = [bool]$payload.Json
}
& ([string]$payload.ScriptPath) @arguments
exit $LASTEXITCODE
'@
            $bootstrap = $bootstrap.Replace('__PAYLOAD__', $payloadBase64)
            $simulatedRuntimeBootstrap = Join-Path $sandbox "safe-update-runtime-bootstrap.ps1"
            [System.IO.File]::WriteAllText(
                $simulatedRuntimeBootstrap,
                $bootstrap,
                [System.Text.Encoding]::ASCII
            )
            $output = & $PowerShellPath -NoLogo -NoProfile -File $simulatedRuntimeBootstrap 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        } else {
            $output = & $PowerShellPath -NoLogo -NoProfile -File $ScriptPath @ScriptArguments 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        }
        return [pscustomobject]@{
            Output = $output
            ExitCode = $exitCode
        }
    } finally {
        if ($null -ne $simulatedRuntimeBootstrap) {
            Remove-Item -LiteralPath $simulatedRuntimeBootstrap -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $temporarySafeUpdateClient) {
            if (-not $temporarySafeUpdateClient.HasExited) {
                Stop-Process -Id $temporarySafeUpdateClient.Id -Force -ErrorAction SilentlyContinue
            }
            $temporarySafeUpdateClient.Dispose()
        }
        if ($null -ne $previousSafeUpdatePath) {
            $env:PATH = $previousSafeUpdatePath
            $env:CLAUDE_EASY_TEST_CURL_IMMEDIATE_SUCCESS = $previousImmediateCurl
        }
        $ErrorActionPreference = $previousPreference
    }
}

function ConvertTo-TestProcessArgument([string]$Value) {
    if ($null -eq $Value) { return '""' }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function New-TestPowerShellProcess(
    [string]$ScriptPath,
    [string[]]$ScriptArguments
) {
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $PowerShellPath
    $arguments = @("-NoLogo", "-NoProfile", "-File", $ScriptPath) +
        @($ScriptArguments)
    $start.Arguments = (@(
        $arguments | ForEach-Object {
            ConvertTo-TestProcessArgument ([string]$_)
        }
    ) -join " ")
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    return $process
}

function Invoke-TestPowerShellWithStandardInput(
    [string]$ScriptPath,
    [string[]]$ScriptArguments,
    [string]$StandardInput
) {
    $process = New-TestPowerShellProcess $ScriptPath $ScriptArguments
    try {
        if (-not $process.Start()) { throw "PowerShell test process did not start" }
        $process.StandardInput.Write($StandardInput)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(30000)) {
            try { $process.Kill() } catch { }
            throw "PowerShell test process timed out"
        }
        $output = $process.StandardOutput.ReadToEnd() +
            $process.StandardError.ReadToEnd()
        return [pscustomobject]@{
            Output = $output
            ExitCode = $process.ExitCode
        }
    } finally {
        $process.Dispose()
    }
}

function Invoke-TestPowerShellWithSeparatedStreams(
    [string]$ScriptPath,
    [string[]]$ScriptArguments
) {
    $process = New-TestPowerShellProcess $ScriptPath $ScriptArguments
    try {
        if (-not $process.Start()) { throw "PowerShell test process did not start" }
        $process.StandardInput.Close()
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            try { $process.Kill() } catch { }
            throw "PowerShell test process timed out"
        }
        return [pscustomobject]@{
            StandardOutput = $standardOutput.Result
            StandardError = $standardError.Result
            ExitCode = $process.ExitCode
        }
    } finally {
        $process.Dispose()
    }
}

function Get-WindowsProcessCommandLine([int]$ProcessId) {
    $cimCommand = Get-Command Get-CimInstance -ErrorAction SilentlyContinue
    if ($null -ne $cimCommand) {
        $record = Get-CimInstance -ClassName Win32_Process `
            -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
    } else {
        $record = Get-WmiObject -Class Win32_Process `
            -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
    }
    if ($null -eq $record) { return "" }
    return [string]$record.CommandLine
}

function Invoke-Installer([string]$AppHome) {
    $result = Invoke-TestPowerShell $installer @("-AppHome", $AppHome, "-MihomoPath", $fakeCore, "-Json")
    if ($result.ExitCode -ne 0) {
        $detail = Get-TestOutputDiagnostic $result.Output
        try {
            $failure = $result.Output.Trim() | ConvertFrom-Json
            $detail = "code=$($failure.code) summary=$($failure.summary_zh)"
        } catch {}
        throw "Windows installer failed for $(Split-Path -Leaf $AppHome): exit=$($result.ExitCode); $detail"
    }
}

function Invoke-Uninstaller([string]$AppHome) {
    $result = Invoke-TestPowerShell $uninstaller @("-AppHome", $AppHome)
    if ($result.ExitCode -ne 0) {
        throw "Windows uninstaller returned $($result.ExitCode); $(Get-TestOutputDiagnostic $result.Output)"
    }
}

function Read-TestUtf8Text([string]$Path) {
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    return $encoding.GetString([System.IO.File]::ReadAllBytes($Path))
}

function Write-TestUtf8Text([string]$Path, [string]$Text) {
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    [System.IO.File]::WriteAllBytes($Path, $encoding.GetBytes($Text))
}

function Assert-InstallerRejectsScript([string]$Name, [string]$Script, [string]$MessageFragment) {
    $case = Join-Path $sandbox $Name
    $profiles = Join-Path $case "profiles"
    New-Item -ItemType Directory -Path $profiles -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $case "config.yaml"), "ipv6: true`ntun: null`n")
    [System.IO.File]::WriteAllText((Join-Path $case "verge.yaml"), "enable_tun_mode: false`n")
    [System.IO.File]::WriteAllText((Join-Path $case "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
    $scriptPath = Join-Path $profiles "Script.js"
    Write-TestUtf8Text $scriptPath $Script
    $result = Invoke-TestPowerShell $installer @("-AppHome", $case, "-MihomoPath", $fakeCore)
    Assert-True ($result.ExitCode -eq 1) "$Name was accepted"
    Assert-True ($result.Output.Contains($MessageFragment)) "$Name rejection did not explain the problem; $(Get-TestOutputDiagnostic $result.Output)"
    Assert-True ((Read-TestUtf8Text $scriptPath) -eq $Script) "$Name rejection changed Script.js"
}

try {
    $installerSource = [System.IO.File]::ReadAllText($installer)
    $runtimeSource = [System.IO.File]::ReadAllText((Join-Path $installerModuleRoot "runtime.ps1"))
    Assert-True (
        -not $installerSource.Contains('[switch]$SafeUpdate') -and
        -not $installerSource.Contains('Invoke-SubscriptionCurlDownload')
    ) "Windows still exposed the cancelled direct-download update path"
    Assert-True (
        -not $installerSource.Contains('-SkipRecovery:$BackupSubscriptions')
    ) "subscription backup still skipped interrupted transaction recovery"
    Assert-True (-not (Test-ClashRuntimeRequiresTun 1)) "profile 1 unexpectedly required TUN"
    Assert-True (Test-ClashRuntimeRequiresTun 2) "profile 2 did not require TUN"
    Assert-True (Test-ClashRuntimeRequiresTun 3) "profile 3 did not require TUN"
    Assert-True (
        $runtimeSource.Contains('Test-ClashRuntimeConnectivity $Context $state $CurlPath $ExpectedTunEnabled')
    ) "safe update runtime validation did not preserve the pre-update TUN state"
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    $sameContentRuntime = Join-Path $sandbox "same-content-runtime.yaml"
    [System.IO.File]::WriteAllText($sameContentRuntime, "runtime")
    $sameContentSnapshot = Get-OptionalFileSnapshot $sameContentRuntime "runtime"
    $sameContentPrevious = [pscustomobject]@{
        Snapshot = $sameContentSnapshot
        LastWriteTicks = [System.IO.File]::GetLastWriteTimeUtc($sameContentRuntime).Ticks
    }
    $delayedRefreshSignal = Join-Path $sandbox "delayed-refresh-signal"
    $delayedRefreshJob = Start-Job -ArgumentList @(
        $sameContentRuntime,
        [DateTime]::UtcNow.AddSeconds(2).ToFileTimeUtc(),
        $delayedRefreshSignal
    ) -ScriptBlock {
        param([string]$RuntimePath, [long]$FutureFileTime, [string]$SignalPath)
        while (-not (Test-Path -LiteralPath $SignalPath -PathType Leaf)) {
            Start-Sleep -Milliseconds 20
        }
        Start-Sleep -Milliseconds 700
        [System.IO.File]::SetLastWriteTimeUtc($RuntimePath, [DateTime]::FromFileTimeUtc($FutureFileTime))
    }
    $refreshWait = [System.Diagnostics.Stopwatch]::StartNew()
    [System.IO.File]::WriteAllText($delayedRefreshSignal, "go")
    try {
        Wait-ClashVergeRuntimeRefresh $sameContentRuntime $sameContentPrevious
    } finally {
        $refreshWait.Stop()
        Stop-Job $delayedRefreshJob -ErrorAction SilentlyContinue
        Remove-Job $delayedRefreshJob -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $delayedRefreshSignal -Force -ErrorAction SilentlyContinue
    }
    Assert-True ($refreshWait.ElapsedMilliseconds -ge 400) "runtime refresh wait returned before the file changed"

    $hashOnlyRuntime = Join-Path $sandbox "hash-only-runtime.yaml"
    [System.IO.File]::WriteAllText($hashOnlyRuntime, "runtime-a")
    $hashOnlySnapshot = Get-OptionalFileSnapshot $hashOnlyRuntime "runtime"
    $hashOnlyTimestamp = [System.IO.File]::GetLastWriteTimeUtc($hashOnlyRuntime)
    $hashOnlyPrevious = [pscustomobject][ordered]@{
        Identity = [string]$hashOnlySnapshot.Identity
        LastWriteTicks = $hashOnlyTimestamp.Ticks
        Sha256 = Get-BytesSha256 $hashOnlySnapshot.Bytes
    }
    [System.IO.File]::WriteAllText($hashOnlyRuntime, "runtime-b")
    [System.IO.File]::SetLastWriteTimeUtc($hashOnlyRuntime, $hashOnlyTimestamp)
    $hashOnlyCurrent = Get-OptionalFileSnapshot $hashOnlyRuntime "runtime"
    Assert-True ($hashOnlyCurrent.Identity -ceq $hashOnlySnapshot.Identity) "hash-only refresh changed file identity"
    Assert-True (
        [System.IO.File]::GetLastWriteTimeUtc($hashOnlyRuntime).Ticks -le $hashOnlyPrevious.LastWriteTicks
    ) "hash-only refresh advanced the timestamp"
    Assert-True (
        (Get-BytesSha256 $hashOnlyCurrent.Bytes) -cne (Get-BytesSha256 $hashOnlySnapshot.Bytes)
    ) "hash-only refresh did not change content"
    Wait-ClashVergeRuntimeRefresh $hashOnlyRuntime $hashOnlyPrevious
    Assert-True (
        (Get-ClashRuntimeYamlMappingEntry "'rule-set:managed':").Key -ceq "rule-set:managed"
    ) "runtime YAML parser rejected a single-quoted policy key"
    Assert-True (
        (Get-ClashRuntimeYamlMappingEntry "rule-set:managed:").Key -ceq "rule-set:managed"
    ) "runtime YAML parser rejected a plain policy key"
    $missingRuntimeProxy = [pscustomobject]@{
        AI = [pscustomobject]@{ type = "Selector"; now = "Missing Node" }
    }
    Assert-True (-not (
        Test-ClashRuntimeProxyPath $missingRuntimeProxy "AI"
    )) "runtime AI path accepted a missing target"
    $providerRuntimeProxies = [pscustomobject]@{
        AI = [pscustomobject]@{ type = "Selector"; now = "Provider Node" }
    }
    $runtimeProviders = [pscustomobject]@{
        remote = [pscustomobject]@{
            proxies = @(
                [pscustomobject]@{ name = "Provider Node"; type = "Shadowsocks" },
                [pscustomobject]@{ name = "Provider Direct"; type = "Direct" }
            )
        }
    }
    Assert-True (
        Test-ClashRuntimeProxyPath $providerRuntimeProxies "AI" $null $runtimeProviders
    ) "runtime AI path rejected a provider-backed proxy"
    $providerRuntimeProxies.AI.now = "Provider Direct"
    Assert-True (-not (
        Test-ClashRuntimeProxyPath $providerRuntimeProxies "AI" $null $runtimeProviders
    )) "runtime AI path accepted a provider-backed Direct target"
    $runtimeProviders.remote.proxies += [pscustomobject]@{ name = "Provider Relay"; type = "Relay" }
    $providerRuntimeProxies.AI.now = "Provider Relay"
    Assert-True (-not (
        Test-ClashRuntimeProxyPath $providerRuntimeProxies "AI" $null $runtimeProviders
    )) "runtime AI path accepted a provider-backed Relay target"
    $runtimeAiPolicy = [pscustomobject]@{
        ai_rules = @(
            "DOMAIN-SUFFIX,anthropic.com,{AI}",
            "DOMAIN,ai.example,{AI}"
        )
    }
    $runtimeAiRules = @(
        [pscustomobject]@{ type = "DomainSuffix"; payload = "anthropic.com"; proxy = "Custom AI" },
        [pscustomobject]@{ type = "Domain"; payload = "ai.example"; proxy = "Custom AI" }
    )
    Assert-True (
        (Get-ClashRuntimeAiGroupName $runtimeAiRules $runtimeAiPolicy) -ceq "Custom AI"
    ) "runtime checks did not bind to the AI group used by managed rules"
    $runtimeAiRules[1].proxy = "Decoy AI"
    $inconsistentRuntimeAiRejected = $false
    try { Get-ClashRuntimeAiGroupName $runtimeAiRules $runtimeAiPolicy | Out-Null } catch {
        $inconsistentRuntimeAiRejected = $true
    }
    Assert-True $inconsistentRuntimeAiRejected "runtime checks accepted inconsistent managed AI targets"
    $runtimeAiRules[1].proxy = "Actual Group"
    $runtimeAiRules[0].proxy = "Actual Group"
    $ordinalSelections = New-OrdinalStringDictionary
    $ordinalSelections["AI"] = "Upper"
    $ordinalSelections["ai"] = "Lower"
    Assert-True (
        $ordinalSelections.Count -eq 2 -and
        [string]$ordinalSelections["AI"] -ceq "Upper" -and
        [string]$ordinalSelections["ai"] -ceq "Lower"
    ) "runtime selection map collapsed case-only group names"
    $exactRuntimeProxies = [pscustomobject][ordered]@{
        "Decoy AI" = [pscustomobject]@{ type = "Selector"; now = "Safe Node" }
        "Actual Group" = [pscustomobject]@{ type = "Selector"; now = "Missing Node" }
        "Safe Node" = [pscustomobject]@{ type = "Shadowsocks" }
    }
    $wrongRuntimeAiRejected = $false
    try {
        Assert-ClashRuntimeAiGroup $exactRuntimeProxies $runtimeAiRules $null $runtimeAiPolicy
    } catch { $wrongRuntimeAiRejected = $true }
    Assert-True $wrongRuntimeAiRejected "runtime checks accepted a healthy decoy AI group"
    $exactRuntimeProxies."Actual Group".now = "Provider Node"
    Assert-ClashRuntimeAiGroup $exactRuntimeProxies $runtimeAiRules $runtimeProviders $runtimeAiPolicy
    $script:runtimeProxyContent = '{"proxies":{"Main":{"type":"Selector","now":"Node"},"Node":{"type":"Shadowsocks"}}}'
    $originalRuntimeRequest = (Get-Item Function:Invoke-ClashControllerRequest).ScriptBlock
    function Invoke-ClashControllerRequest(
        [object]$Context,
        [string]$Method,
        [string]$Endpoint,
        [string]$Body = ""
    ) {
        $content = switch ($Endpoint) {
            "/configs" { '{"tun":{"enable":true}}' }
            "/proxies" { $script:runtimeProxyContent }
            "/rules" { '{"rules":[{"type":"Match","payload":"","proxy":"Main"}]}' }
            "/providers/proxies" { '{"providers":{"remote":{"proxies":[{"name":"Provider Node","type":"Shadowsocks"}]}}}' }
            default { throw "unexpected runtime endpoint" }
        }
        return [pscustomobject]@{ Status = 200; Content = $content }
    }
    try {
        $completeRuntimeState = Get-ClashRuntimeState ([pscustomobject]@{})
        Assert-True (
            $null -ne $completeRuntimeState.Rules -and @($completeRuntimeState.Rules).Count -eq 1
        ) "runtime state omitted rules"
        Assert-True (
            $null -ne $completeRuntimeState.Providers -and
            @($completeRuntimeState.Providers.remote.proxies).Count -eq 1
        ) "runtime state omitted provider proxies"

        $script:runtimeProxyContent = '{"proxies":{"A\u0049":{"type":"Selector","now":"Node"},"ai":{"type":"Selector","now":"Node"}}}'
        $caseCollisionRejected = $false
        try { Get-ClashRuntimeState ([pscustomobject]@{}) | Out-Null } catch {
            $caseCollisionRejected = $_.Exception.Message.Contains("大小写冲突")
        }
        Assert-True $caseCollisionRejected "runtime state collapsed case-only controller groups"
        $script:runtimeProxyContent = '{"proxies":{"Main":{"type":"Selector","now":"Node"},"Node":{"type":"Shadowsocks"}}}'

        $missingSelectionRejected = $false
        try {
            Restore-ClashRuntimeSelections ([pscustomobject]@{}) @{ "Missing Group" = "Old Node" }
        } catch {
            $missingSelectionRejected = $_.Exception.Message.Contains("无法保留原代理选择")
        }
        Assert-True $missingSelectionRejected "runtime restoration accepted a missing previous selection"
    } finally {
        Set-Item Function:Invoke-ClashControllerRequest $originalRuntimeRequest
    }
    $exactRuntimePolicy = [pscustomobject]@{
        ai_rules = @(
            "DOMAIN-SUFFIX,anthropic.com,{AI}",
            "DOMAIN,ai.example,{AI}"
        )
        lan_udp_direct_rules = @("AND,((NETWORK,UDP),(IP-CIDR,10.0.0.0/8,no-resolve)),DIRECT")
        cn_udp_direct_rule = "AND,((NETWORK,UDP),(RULE-SET,{CN_IP})),DIRECT"
        direct_resolvers = @("https://223.5.5.5/dns-query#DIRECT")
        cn_domain_provider = [pscustomobject]@{
            name = "ce-cn-domain"; type = "http"; behavior = "domain"; format = "mrs"
            url = "https://example.invalid/cn-domain.mrs"; path = "./ruleset/ce-cn-domain.mrs"
            interval = 86400; size_limit = 2097152
        }
        cn_ip_provider = [pscustomobject]@{
            name = "ce-cn-ip"; type = "http"; behavior = "ipcidr"; format = "mrs"
            url = "https://example.invalid/cn-ip.mrs"; path = "./ruleset/ce-cn-ip.mrs"
            interval = 86400; size_limit = 2097152
        }
    }
    $exactRuntimeText = @'
profile:
  store-selected: true
dns:
  enable: true
  respect-rules: true
  direct-nameserver:
    - https://223.5.5.5/dns-query#DIRECT
  direct-nameserver-follow-policy: false
  nameserver-policy:
    "rule-set:ce-cn-domain":
      - https://223.5.5.5/dns-query#DIRECT
rule-providers:
  ce-cn-domain:
    type: http
    behavior: domain
    format: mrs
    url: https://example.invalid/cn-domain.mrs
    path: ./ruleset/ce-cn-domain.mrs
    interval: 86400
    proxy: Main
    size-limit: 2097152
  ce-cn-ip:
    type: http
    behavior: ipcidr
    format: mrs
    url: https://example.invalid/cn-ip.mrs
    path: ./ruleset/ce-cn-ip.mrs
    interval: 86400
    proxy: Main
    size-limit: 2097152
rules:
  - DOMAIN-SUFFIX,anthropic.com,Actual AI
  - DOMAIN,ai.example,Actual AI
  - DOMAIN-SUFFIX,anthropic.com,REJECT
  - DOMAIN,ai.example,REJECT
  - AND,((NETWORK,UDP),(IP-CIDR,10.0.0.0/8,no-resolve)),DIRECT
  - RULE-SET,ce-cn-domain,DIRECT
  - AND,((NETWORK,UDP),(RULE-SET,ce-cn-ip)),DIRECT
  - NETWORK,UDP,Actual AI
  - NETWORK,UDP,REJECT
  - MATCH,Main
'@
    $exactRuntimeState = [pscustomobject]@{
        Proxies = [pscustomobject]@{
            Main = [pscustomobject]@{ type = "Selector"; now = "Node" }
            Node = [pscustomobject]@{ type = "Shadowsocks" }
        }
        Rules = @(
            [pscustomobject]@{ type = "DomainSuffix"; payload = "anthropic.com"; proxy = "Actual AI" },
            [pscustomobject]@{ type = "Domain"; payload = "ai.example"; proxy = "Actual AI" },
            [pscustomobject]@{ type = "DomainSuffix"; payload = "anthropic.com"; proxy = "REJECT" },
            [pscustomobject]@{ type = "Domain"; payload = "ai.example"; proxy = "REJECT" },
            [pscustomobject]@{ type = "RuleSet"; payload = "ce-cn-domain"; proxy = "DIRECT" },
            [pscustomobject]@{ type = "Match"; payload = ""; proxy = "Main" }
        )
    }
    Assert-ClashRuntimePatch $exactRuntimeText $exactRuntimeState $exactRuntimePolicy 3
    foreach ($invalidRuntimeText in @(
        $exactRuntimeText.Replace("store-selected: true", "store-selected: false"),
        $exactRuntimeText.Replace("behavior: ipcidr", "behavior: domain"),
        $exactRuntimeText.Replace("direct-nameserver-follow-policy: false", "direct-nameserver-follow-policy: true"),
        $exactRuntimeText.Replace(
            '"rule-set:ce-cn-domain":',
            '"rule-set:wrong-provider":'
        ),
        ($exactRuntimeText -replace
            '(?m)^  - DOMAIN-SUFFIX,anthropic\.com,Actual AI\r?\n  - DOMAIN,ai\.example,Actual AI\r?$',
            "  - DOMAIN,ai.example,Actual AI`n  - DOMAIN-SUFFIX,anthropic.com,Actual AI")
    )) {
        $invalidRuntimePatchRejected = $false
        try {
            Assert-ClashRuntimePatch $invalidRuntimeText $exactRuntimeState $exactRuntimePolicy 3
        } catch { $invalidRuntimePatchRejected = $true }
        Assert-True $invalidRuntimePatchRejected "runtime checks accepted an incomplete managed patch"
    }

    $profileTwoRuntimeText = @'
profile:
  store-selected: true
dns:
  enable: true
  respect-rules: true
  direct-nameserver:
    - https://223.5.5.5/dns-query#DIRECT
  direct-nameserver-follow-policy: false
  nameserver-policy:
    "rule-set:ce-cn-domain":
      - https://223.5.5.5/dns-query#DIRECT
rule-providers:
  ce-cn-domain:
    type: http
    behavior: domain
    format: mrs
    url: https://example.invalid/cn-domain.mrs
    path: ./ruleset/ce-cn-domain.mrs
    interval: 86400
    proxy: Main
    size-limit: 2097152
rules:
  - DOMAIN,example.com,Main
  - RULE-SET,ce-cn-domain,DIRECT
  - MATCH,Main
'@
    $profileTwoRuntimeState = [pscustomobject]@{
        Proxies = [pscustomobject]@{
            Main = [pscustomobject]@{ type = "Selector"; now = "Node" }
            Other = [pscustomobject]@{ type = "Selector"; now = "Node" }
            Node = [pscustomobject]@{ type = "Shadowsocks" }
        }
        Rules = @()
    }
    Assert-ClashRuntimePatch $profileTwoRuntimeText $profileTwoRuntimeState $exactRuntimePolicy 2
    foreach ($unusableMatchTarget in @("DIRECT", "Missing Group")) {
        $profileTwoRuntimeState.Rules = @(
            [pscustomobject]@{ type = "Match"; payload = ""; proxy = $unusableMatchTarget }
        )
        Assert-ClashRuntimePatch $profileTwoRuntimeText $profileTwoRuntimeState $exactRuntimePolicy 2
    }
    $profileTwoRuntimeState.Rules = @()
    $profileTwoRuntimeState.Rules = @(
        [pscustomobject]@{ type = "Match"; payload = ""; proxy = "Other" }
    )
    $mismatchedRuntimeMainRejected = $false
    try {
        Assert-ClashRuntimePatch $profileTwoRuntimeText $profileTwoRuntimeState $exactRuntimePolicy 2
    } catch { $mismatchedRuntimeMainRejected = $true }
    Assert-True $mismatchedRuntimeMainRejected "runtime checks accepted a different usable MATCH group"
    $profileTwoRuntimeState.Rules = @()
    foreach ($invalidProfileTwoRuntimeText in @(
        ($profileTwoRuntimeText -replace
            '(?m)^  - RULE-SET,ce-cn-domain,DIRECT\r?\n  - MATCH,Main\r?$',
            "  - MATCH,Main`n  - RULE-SET,ce-cn-domain,DIRECT"),
        $profileTwoRuntimeText.Replace("respect-rules: true", "respect-rules: false"),
        $profileTwoRuntimeText.Replace(
            "      - https://223.5.5.5/dns-query#DIRECT",
            "      - https://1.1.1.1/dns-query#DIRECT"
        )
    )) {
        $invalidProfileTwoPatchRejected = $false
        try {
            Assert-ClashRuntimePatch $invalidProfileTwoRuntimeText $profileTwoRuntimeState $exactRuntimePolicy 2
        } catch { $invalidProfileTwoPatchRejected = $true }
        Assert-True $invalidProfileTwoPatchRejected "profile 2 runtime checks accepted broken common policy"
    }

    $providerCollisionRuntimeText = $profileTwoRuntimeText -replace
        'rule-providers:\r?\n  ce-cn-domain:',
        @'
rule-providers:
  ce-cn-domain:
    type: http
    behavior: domain
    format: mrs
    url: https://example.invalid/cn-domain.mrs
    path: ./user-cache/cn-domain.mrs
    interval: 86400
    proxy: Main
    size-limit: 2097152
  ce-cn-domain-10:
'@
    $providerCollisionRuntimeText = $providerCollisionRuntimeText.Replace(
        "path: ./ruleset/ce-cn-domain.mrs",
        "path: ./ruleset/ce-cn-domain-10.mrs"
    ).Replace(
        '"rule-set:ce-cn-domain":',
        '"rule-set:ce-cn-domain-10":'
    ).Replace(
        "RULE-SET,ce-cn-domain,DIRECT",
        "RULE-SET,ce-cn-domain-10,DIRECT"
    )
    Assert-ClashRuntimePatch $providerCollisionRuntimeText $profileTwoRuntimeState $exactRuntimePolicy 2

    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    $failureDiagnosticCanary = "https://subscription.invalid/private?token=fixture-secret password=fixture-password 11111111-2222-3333-4444-555555555555"
    $failureDiagnostic = Get-TestOutputDiagnostic $failureDiagnosticCanary
    Assert-True ($failureDiagnostic -notmatch 'subscription|token|secret|password|11111111') "test failure diagnostics exposed captured command output"
    Assert-True ($failureDiagnostic -match '^output_length=\d+ output_sha256=[0-9a-f]{64}$') "test failure diagnostics omitted safe debugging metadata"
    if ($onWindows) {
        $fakeCoreText = "@echo off`r`necho %*>>`"%~dp0mihomo-arguments.log`"`r`nif `"%1`"==`"-v`" (`r`n  echo Mihomo Meta v1.19.27 windows amd64`r`n  exit /b 0`r`n)`r`nexit /b 0`r`n"
    } else {
        $fakeCoreText = "#!/bin/sh`nif [ `"`${1:-}`" = `"-v`" ]; then`n  echo 'Mihomo Meta v1.19.27 test arm64'`nfi`nexit 0`n"
    }
    [System.IO.File]::WriteAllText($fakeCore, $fakeCoreText, [System.Text.Encoding]::ASCII)
    if (-not $onWindows) { & /bin/chmod 700 $fakeCore }
    if ($onWindows) {
        foreach ($wrapperCase in @(
            @{ Source = $installWrapper; Command = "install"; Name = "install_windows.cmd" },
            @{ Source = $uninstallWrapper; Command = "uninstall"; Name = "uninstall_windows.cmd" }
        )) {
            $missingEntrypointRoot = Join-Path $sandbox ("missing-entrypoint-" + $wrapperCase.Command)
            New-Item -ItemType Directory -Path $missingEntrypointRoot -Force | Out-Null
            $missingEntrypointWrapper = Join-Path $missingEntrypointRoot $wrapperCase.Name
            Copy-Item -LiteralPath $wrapperCase.Source -Destination $missingEntrypointWrapper
            $missingEntrypointOutput = & $env:ComSpec /d /c $missingEntrypointWrapper -Json 2>&1 | Out-String
            $missingEntrypointInvocation = [pscustomobject]@{
                Output = $missingEntrypointOutput
                ExitCode = $LASTEXITCODE
            }
            $missingEntrypointResult = Assert-JsonResult `
                $missingEntrypointInvocation $wrapperCase.Command 6
            Assert-True ($missingEntrypointResult.code -eq "incomplete_package") (
                "$($wrapperCase.Name) did not report a missing PowerShell entrypoint"
            )
        }

        $mutatingCoreText = "@echo off`r`nif `"%1`"==`"-v`" (`r`n  echo Mihomo Meta v1.19.27 windows amd64`r`n  exit /b 0`r`n)`r`nif not `"%CLAUDE_EASY_MUTATE_TARGET%`"==`"`" (`r`n  >`"%CLAUDE_EASY_MUTATE_TARGET%`" echo friend_concurrent: true`r`n)`r`nexit /b 0`r`n"
        [System.IO.File]::WriteAllText($mutatingCore, $mutatingCoreText, [System.Text.Encoding]::ASCII)
        $identityMutatingCoreText = "@echo off`r`nif `"%1`"==`"-v`" (`r`n  echo Mihomo Meta v1.19.27 windows amd64`r`n  exit /b 0`r`n)`r`nif not `"%CLAUDE_EASY_MUTATE_TARGET%`"==`"`" (`r`n  copy /b `"%CLAUDE_EASY_MUTATE_TARGET%`" `"%CLAUDE_EASY_MUTATE_TARGET%.replacement`" >nul`r`n  del /f /q `"%CLAUDE_EASY_MUTATE_TARGET%`"`r`n  move /y `"%CLAUDE_EASY_MUTATE_TARGET%.replacement`" `"%CLAUDE_EASY_MUTATE_TARGET%`" >nul`r`n)`r`nexit /b 0`r`n"
        [System.IO.File]::WriteAllText(
            $identityMutatingCore,
            $identityMutatingCoreText,
            [System.Text.Encoding]::ASCII
        )
        $candidateHangingCoreText = "@echo off`r`nif `"%1`"==`"-v`" (`r`n  echo Mihomo Meta v1.19.27 windows amd64`r`n  exit /b 0`r`n)`r`nping 127.0.0.1 -n 3 >nul`r`nexit /b 0`r`n"
        [System.IO.File]::WriteAllText(
            $candidateHangingCore,
            $candidateHangingCoreText,
            [System.Text.Encoding]::ASCII
        )

        if ($RealMihomoOnly) {
            Assert-True ($RealMihomoPaths.Count -gt 0) "real Mihomo mode requires at least one core"
            Assert-True (
                Test-Path -LiteralPath $RealMihomoGeoSitePath -PathType Leaf
            ) "real Mihomo mode requires a pinned GeoSite.dat"
            $realNode = Get-Command node.exe -ErrorAction SilentlyContinue
            Assert-True ($null -ne $realNode) "real Mihomo mode requires Node.js"
            $realTransformHarness = Join-Path $sandbox "run-global-script.js"
            [System.IO.File]::WriteAllText(
                $realTransformHarness,
                @'
const fs = require("node:fs");
const script = fs.readFileSync(process.argv[2], "utf8");
const input = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const transform = new Function(`${script}
return main;`)();
const output = transform(input);
fs.writeFileSync(process.argv[4], JSON.stringify(output));
'@,
                (New-Object System.Text.UTF8Encoding($false))
            )
            $realSubscriptionJson = @'
{
  "mixed-port": 7890,
  "mode": "rule",
  "ipv6": true,
  "tun": { "enable": false },
  "proxies": [
    {
      "name": "US Home",
      "type": "socks5",
      "server": "127.0.0.1",
      "port": 1080
    }
  ],
  "proxy-groups": [
    {
      "name": "Main",
      "type": "select",
      "proxies": ["US Home"]
    }
  ],
  "dns": {
    "enable": true,
    "nameserver": ["8.8.8.8"]
  },
  "rules": ["MATCH,Main"]
}
'@
            $realCoreIndex = 0
            $realCompletedCases = New-Object System.Collections.ArrayList
            foreach ($realMihomoPath in $RealMihomoPaths) {
                $realCoreIndex++
                Assert-True (Test-Path -LiteralPath $realMihomoPath -PathType Leaf) "real Mihomo path is missing"
                Assert-True (Test-MihomoVersion $realMihomoPath) "real Mihomo version gate failed"
                foreach ($realUsageProfile in @(1, 2, 3)) {
                    try {
                    $realCase = Join-Path $sandbox (
                        "real-mihomo-" + $realUsageProfile + "-" + [Guid]::NewGuid().ToString("N")
                    )
                    $realProfiles = Join-Path $realCase "profiles"
                    New-Item -ItemType Directory -Path $realProfiles -Force | Out-Null
                    [System.IO.File]::Copy(
                        $RealMihomoGeoSitePath,
                        (Join-Path $realCase "GeoSite.dat")
                    )
                    [System.IO.File]::WriteAllText(
                        (Join-Path $realCase "config.yaml"),
                        "mixed-port: 7890`nmode: rule`nipv6: true`ntun:`n  enable: false`nproxies: []`nproxy-groups:`n  - name: Main`n    type: select`n    proxies:`n      - DIRECT`nrules:`n  - MATCH,Main`n"
                    )
                    [System.IO.File]::WriteAllText(
                        (Join-Path $realCase "verge.yaml"),
                        "enable_tun_mode: false`n"
                    )
                    [System.IO.File]::WriteAllText(
                        (Join-Path $realCase "profiles.yaml"),
                        "items:`n- uid: R-real`n  type: remote`n  option:`n    allow_auto_update: true`n"
                    )
                    $realInstall = Invoke-TestPowerShell $installer @(
                        "-AppHome", $realCase,
                        "-UsageProfile", $realUsageProfile.ToString(),
                        "-MihomoPath", $realMihomoPath,
                        "-Json"
                    )
                    $realInstallJson = Assert-JsonResult $realInstall "install" 0
                    Assert-True $realInstallJson.ok "real Mihomo public install did not succeed"
                    $realValidation = Invoke-Mihomo $realMihomoPath @(
                        "-d", $realCase,
                        "-t",
                        "-f", (Join-Path $realCase "config.yaml")
                    )
                    Assert-True ($realValidation.ExitCode -eq 0) "real Mihomo rejected an installed profile"
                    $realSubscriptionPath = Join-Path $realCase "subscription.json"
                    $realTransformedPath = Join-Path $realCase "transformed.yaml"
                    [System.IO.File]::WriteAllText(
                        $realSubscriptionPath,
                        $realSubscriptionJson,
                        (New-Object System.Text.UTF8Encoding($false))
                    )
                    $realScriptPath = Join-Path $realProfiles "Script.js"
                    Assert-True (Test-Path -LiteralPath $realScriptPath -PathType Leaf) "public install omitted Script.js"
                    & $realNode.Source $realTransformHarness $realScriptPath $realSubscriptionPath $realTransformedPath 2>&1 | Out-Null
                    $realNodeExitCode = $LASTEXITCODE
                    Assert-True ($realNodeExitCode -eq 0) "installed Script.js could not transform a full subscription"
                    $realTransformedValidation = Invoke-Mihomo $realMihomoPath @(
                        "-d", $realCase,
                        "-t",
                        "-f", $realTransformedPath
                    )
                    Assert-True (
                        $realTransformedValidation.ExitCode -eq 0
                    ) "real Mihomo rejected the installed Script.js output"
                    [void]$realCompletedCases.Add([ordered]@{ Core = $realCoreIndex; Profile = $realUsageProfile })
                    } catch {
                        [void]$script:deferredProbeFailures.Add((
                            "real Mihomo core #{0} profile {1}: {2}" -f
                                $realCoreIndex,
                                $realUsageProfile,
                                $_.Exception.Message
                        ))
                    }
                }
            }
            if ($script:deferredProbeFailures.Count -gt 0) {
                throw ("deferred production probes failed:`n- " + ($script:deferredProbeFailures -join "`n- "))
            }
            if (-not [string]::IsNullOrWhiteSpace($CompletionReceiptPath)) {
                Assert-True (
                    -not [string]::IsNullOrWhiteSpace($CompletionReceiptNonce)
                ) "real Mihomo completion receipt nonce is required"
                $realCompletionReceipt = [ordered]@{
                    Mode = "RealMihomo"
                    PSEdition = $ExpectedPSEdition
                    PSMajor = $ExpectedPSMajor
                    Nonce = $CompletionReceiptNonce
                    CoreCount = $RealMihomoPaths.Count
                    Cases = @($realCompletedCases)
                } | ConvertTo-Json -Compress -Depth 4
                [System.IO.File]::WriteAllText(
                    $CompletionReceiptPath,
                    $realCompletionReceipt,
                    (New-Object System.Text.UTF8Encoding($false))
                )
            }
            Write-Host "Windows real Mihomo public-entry cases passed"
            return
        }

        $ambiguousRoaming = Join-Path $sandbox "ambiguous-roaming"
        $ambiguousLocal = Join-Path $sandbox "ambiguous-local"
        $ambiguousName = "io.github.clash-verge-rev.clash-verge-rev"
        New-Item -ItemType Directory -Path (Join-Path $ambiguousRoaming $ambiguousName) -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $ambiguousLocal $ambiguousName) -Force | Out-Null
        $previousAppData = $env:APPDATA
        $previousLocalAppData = $env:LOCALAPPDATA
        try {
            $env:APPDATA = $ambiguousRoaming
            $env:LOCALAPPDATA = $ambiguousLocal
            $ambiguousInstall = Invoke-TestPowerShell $installer @("-ShowUsageProfile", "-Json")
            $ambiguousInstallJson = Assert-JsonResult $ambiguousInstall "install" 2
            Assert-True ($ambiguousInstallJson.code -eq "ambiguous_app_home") "installer silently selected one of two AppHome candidates"
            $ambiguousUninstall = Invoke-TestPowerShell $uninstaller @("-Json")
            $ambiguousUninstallJson = Assert-JsonResult $ambiguousUninstall "uninstall" 2
            Assert-True ($ambiguousUninstallJson.code -eq "ambiguous_app_home") "uninstaller silently selected one of two AppHome candidates"
        } finally {
            $env:APPDATA = $previousAppData
            $env:LOCALAPPDATA = $previousLocalAppData
        }

        $invalidTransactionJournals = @(
            '{"Version":"1","Actions":[{"Action":"write","Path":"target.txt","Existed":true,"OriginalBase64":"b2xk","ReplacementBase64":"bmV3"}]}',
            '{"Version":1,"Actions":[]}',
            '{"Version":1,"Actions":[{"Action":"rename","Path":"target.txt","Existed":true,"OriginalBase64":"b2xk","ReplacementBase64":"bmV3"}]}',
            '{"Version":1,"Extra":true,"Actions":[{"Action":"write","Path":"target.txt","Existed":true,"OriginalBase64":"b2xk","ReplacementBase64":"bmV3"}]}',
            '{"Version":1,"Actions":[{"Action":"write","Path":"target.txt","Existed":true,"OriginalBase64":"b2xk","ReplacementBase64":"bmV3","Extra":true}]}',
            '{"Version":1,"Actions":[{"Action":"write","Path":"C:\\target.txt","Existed":true,"OriginalBase64":"b2xk","ReplacementBase64":"bmV3"}]}',
            '{"Version":1,"Actions":[{"Action":"write","Path":"..\\target.txt","Existed":true,"OriginalBase64":"b2xk","ReplacementBase64":"bmV3"}]}',
            '{"Version":1,"Actions":[{"Action":"write","Path":"target.txt","Existed":true,"OriginalBase64":"not-base64","ReplacementBase64":"bmV3"}]}',
            '{"Version":1,"Actions":[{"Action":"delete","Path":"target.txt","Existed":false,"OriginalBase64":"","ReplacementBase64":""}]}',
            '{"Version":1,"Actions":[{"Action":"delete","Path":"target.txt","Existed":true,"OriginalBase64":"b2xk","ReplacementBase64":"bmV3"}]}',
            '{"Version":1,"Actions":[{"Action":"write","Path":"target.txt","Existed":false,"OriginalBase64":"b2xk","ReplacementBase64":"bmV3"}]}',
            '{"Version":1,"Actions":[{"Action":"write","Path":"target.txt","Existed":true,"OriginalBase64":"b2xk","ReplacementBase64":"bmV3"},{"Action":"delete","Path":"TARGET.txt","Existed":true,"OriginalBase64":"b2xk","ReplacementBase64":""}]}'
        )
        $journalValidationHome = Join-Path $sandbox "transaction-journal-validation"
        New-Item -ItemType Directory -Path $journalValidationHome -Force | Out-Null
        $journalValidationLock = Enter-AppHomeMutationLock $journalValidationHome
        try {
            foreach ($invalidTransactionJournalText in $invalidTransactionJournals) {
                $invalidTransactionJournal = $invalidTransactionJournalText | ConvertFrom-Json
                $invalidTransactionJournalRejected = $false
                try {
                    Get-ValidatedFileTransactionJournal $invalidTransactionJournal | Out-Null
                } catch {
                    $invalidTransactionJournalRejected = $true
                }
                Assert-True $invalidTransactionJournalRejected "transaction journal validator accepted a malformed state"
            }
        } finally {
            Exit-AppHomeMutationLock $journalValidationLock
        }

        Invoke-DeferredProbe "duplicate transaction action field" {
            $duplicateJournalHome = Join-Path $sandbox "duplicate-transaction-field"
            New-Item -ItemType Directory -Path $duplicateJournalHome -Force | Out-Null
            $duplicateJournalTarget = Join-Path $duplicateJournalHome "target.txt"
            [System.IO.File]::WriteAllText($duplicateJournalTarget, "old")
            $duplicateJournalLock = Enter-AppHomeMutationLock $duplicateJournalHome
            try {
                $duplicateJournalPath = Join-Path $duplicateJournalHome ".claude-easy-transaction.json"
                $duplicateJournalText = '{"Version":1,"Actions":[{"Action":"delete","Action":"write","Path":"target.txt","Existed":true,"OriginalBase64":"b2xk","ReplacementBase64":"bmV3"}]}'
                [System.IO.File]::WriteAllText(
                    $duplicateJournalPath,
                    $duplicateJournalText,
                    (New-Object System.Text.UTF8Encoding($false))
                )
                $duplicateJournalRejected = $false
                try {
                    Repair-InterruptedFileTransaction
                } catch {
                    $duplicateJournalRejected = $true
                }
                $duplicateJournalSafe = $duplicateJournalRejected -and
                    (Test-Path -LiteralPath $duplicateJournalPath -PathType Leaf) -and
                    (Get-Content -LiteralPath $duplicateJournalTarget -Raw) -eq "old"
                Assert-True $duplicateJournalSafe "transaction recovery accepted a duplicate action field"
            } finally {
                Exit-AppHomeMutationLock $duplicateJournalLock
            }
        }

        Invoke-DeferredProbe "strict transaction journal byte schema" {
            $validJournalPrefix = '{"Version":1,"Actions":[{"Action":"write","Path":"target.txt","Existed":false,"OriginalBase64":"","ReplacementBase64":"bmV3"}]}'
            $transactionJournalCases = @(
                [pscustomobject]@{
                    Name = "invalid-utf8"
                    Bytes = [byte[]](
                        [System.Text.Encoding]::UTF8.GetBytes($validJournalPrefix) +
                        @(0xff)
                    )
                },
                [pscustomobject]@{
                    Name = "duplicate-version"
                    Text = '{"Version":1,"Version":1,"Actions":[{"Action":"write","Path":"target.txt","Existed":false,"OriginalBase64":"","ReplacementBase64":"bmV3"}]}'
                },
                [pscustomobject]@{
                    Name = "duplicate-actions"
                    Text = '{"Version":1,"Actions":[],"Actions":[{"Action":"write","Path":"target.txt","Existed":false,"OriginalBase64":"","ReplacementBase64":"bmV3"}]}'
                },
                [pscustomobject]@{
                    Name = "duplicate-action"
                    Text = '{"Version":1,"Actions":[{"Action":"delete","Action":"write","Path":"target.txt","Existed":false,"OriginalBase64":"","ReplacementBase64":"bmV3"}]}'
                },
                [pscustomobject]@{
                    Name = "duplicate-path"
                    Text = '{"Version":1,"Actions":[{"Action":"write","Path":"other.txt","Path":"target.txt","Existed":false,"OriginalBase64":"","ReplacementBase64":"bmV3"}]}'
                },
                [pscustomobject]@{
                    Name = "duplicate-existed"
                    Text = '{"Version":1,"Actions":[{"Action":"write","Path":"target.txt","Existed":true,"Existed":false,"OriginalBase64":"","ReplacementBase64":"bmV3"}]}'
                },
                [pscustomobject]@{
                    Name = "duplicate-original-base64"
                    Text = '{"Version":1,"Actions":[{"Action":"write","Path":"target.txt","Existed":false,"OriginalBase64":"b2xk","OriginalBase64":"","ReplacementBase64":"bmV3"}]}'
                },
                [pscustomobject]@{
                    Name = "duplicate-replacement-base64"
                    Text = '{"Version":1,"Actions":[{"Action":"write","Path":"target.txt","Existed":false,"OriginalBase64":"","ReplacementBase64":"b2xk","ReplacementBase64":"bmV3"}]}'
                },
                [pscustomobject]@{
                    Name = "alternate-data-stream"
                    Text = '{"Version":1,"Actions":[{"Action":"write","Path":"target.txt:stream","Existed":false,"OriginalBase64":"","ReplacementBase64":"bmV3"}]}'
                },
                [pscustomobject]@{
                    Name = "reserved-device"
                    Text = '{"Version":1,"Actions":[{"Action":"write","Path":"CON","Existed":false,"OriginalBase64":"","ReplacementBase64":"bmV3"}]}'
                },
                [pscustomobject]@{
                    Name = "trailing-dot"
                    Text = '{"Version":1,"Actions":[{"Action":"write","Path":"target.txt.","Existed":false,"OriginalBase64":"","ReplacementBase64":"bmV3"}]}'
                },
                [pscustomobject]@{
                    Name = "trailing-space"
                    Text = '{"Version":1,"Actions":[{"Action":"write","Path":"target.txt ","Existed":false,"OriginalBase64":"","ReplacementBase64":"bmV3"}]}'
                }
            )
            $unsafeTransactionJournals = New-Object System.Collections.ArrayList
            foreach ($transactionJournalCase in $transactionJournalCases) {
                $transactionJournalHome = Join-Path $sandbox (
                    "transaction-journal-" + $transactionJournalCase.Name
                )
                New-Item -ItemType Directory -Path $transactionJournalHome -Force | Out-Null
                $transactionJournalSentinel = Join-Path $transactionJournalHome "sentinel.txt"
                [System.IO.File]::WriteAllText($transactionJournalSentinel, "sentinel")
                $transactionJournalLock = Enter-AppHomeMutationLock $transactionJournalHome
                Exit-AppHomeMutationLock $transactionJournalLock
                $transactionJournalPath = Join-Path $transactionJournalHome ".claude-easy-transaction.json"
                $transactionJournalBytes = if ($null -ne $transactionJournalCase.Bytes) {
                    [byte[]]$transactionJournalCase.Bytes
                } else {
                    [System.Text.Encoding]::UTF8.GetBytes([string]$transactionJournalCase.Text)
                }
                [System.IO.File]::WriteAllBytes($transactionJournalPath, $transactionJournalBytes)
                $transactionJournalBefore = Get-TreeContentSnapshot $transactionJournalHome
                $transactionJournalResult = Invoke-TestPowerShell $installer @(
                    "-AppHome", $transactionJournalHome,
                    "-ShowUsageProfile",
                    "-Json"
                )
                $transactionJournalAfter = Get-TreeContentSnapshot $transactionJournalHome
                if ($transactionJournalResult.ExitCode -ne 1 -or
                    -not (Test-Path -LiteralPath $transactionJournalPath -PathType Leaf) -or
                    $transactionJournalAfter -cne $transactionJournalBefore -or
                    (Get-Content -LiteralPath $transactionJournalSentinel -Raw) -cne "sentinel") {
                    [void]$unsafeTransactionJournals.Add($transactionJournalCase.Name)
                }
            }
            Assert-True (
                $unsafeTransactionJournals.Count -eq 0
            ) "public entry accepted or changed malformed transaction journals: $($unsafeTransactionJournals -join ', ')"
        }

        Invoke-DeferredProbe "new-file transaction journal empty original bytes" {
            $newFileTransactionHome = Join-Path $sandbox "new-file-transaction-home"
            $newFileTransactionTarget = Join-Path $newFileTransactionHome "created.txt"
            New-Item -ItemType Directory -Path $newFileTransactionHome -Force | Out-Null
            $newFileTransactionLock = Enter-AppHomeMutationLock $newFileTransactionHome
            try {
                Invoke-VerifiedFileTransaction @(
                    [pscustomobject]@{
                        Path = $newFileTransactionTarget
                        Bytes = [System.Text.Encoding]::UTF8.GetBytes("created")
                        Existed = $false
                        OriginalBytes = $null
                        OriginalIdentity = $null
                    }
                )
            } finally {
                Exit-AppHomeMutationLock $newFileTransactionLock
            }
            Assert-True (
                (Test-Path -LiteralPath $newFileTransactionTarget -PathType Leaf) -and
                (Get-Content -LiteralPath $newFileTransactionTarget -Raw) -ceq "created"
            ) "new-file transaction could not journal an empty original byte sequence"
            Assert-True (
                -not (Test-Path -LiteralPath (Join-Path $newFileTransactionHome ".claude-easy-transaction.json"))
            ) "new-file transaction left a stale journal"
        }

        Invoke-DeferredProbe "interrupted new-file transaction preserves later content" {
            $newFileRecoveryHome = Join-Path $sandbox "new-file-recovery-home"
            $newFileRecoveryTarget = Join-Path $newFileRecoveryHome "Script.js"
            New-Item -ItemType Directory -Path $newFileRecoveryHome -Force | Out-Null
            $newFileRecoveryLock = Enter-AppHomeMutationLock $newFileRecoveryHome
            try {
                $replacementBytes = [System.Text.Encoding]::UTF8.GetBytes("managed replacement")
                [System.IO.File]::WriteAllBytes($newFileRecoveryTarget, $replacementBytes)
                $createdSnapshot = Get-OptionalFileSnapshot $newFileRecoveryTarget "new-file recovery created target"
                $action = [pscustomobject]@{
                    Action = "write"
                    Path = $newFileRecoveryTarget
                    Existed = $false
                    Identity = $createdSnapshot.Identity
                    Original = [byte[]]@()
                    Replacement = $replacementBytes
                }
                $laterBytes = [System.Text.Encoding]::UTF8.GetBytes("user content written after interruption")
                [System.IO.File]::WriteAllBytes($newFileRecoveryTarget, $laterBytes)
                $laterSnapshot = Get-OptionalFileSnapshot $newFileRecoveryTarget "new-file recovery later target"
                Assert-True (
                    $laterSnapshot.Identity -ceq $createdSnapshot.Identity
                ) "new-file recovery fixture replaced the target identity"

                $recoveryRejected = $false
                try {
                    $plan = @(Get-InterruptedTransactionRecoveryPlan @($action))
                    Invoke-InterruptedTransactionRecovery $plan
                } catch {
                    $recoveryRejected = $true
                }
                $preservedSnapshot = Get-OptionalFileSnapshot $newFileRecoveryTarget "new-file recovery preserved target"
                Assert-True (
                    $recoveryRejected -and
                    $preservedSnapshot.Exists -and
                    $preservedSnapshot.Identity -ceq $createdSnapshot.Identity -and
                    (Get-BytesSha256 $preservedSnapshot.Bytes) -eq (Get-BytesSha256 $laterBytes)
                ) "interrupted recovery deleted later content written into a new transaction target"
            } finally {
                Exit-AppHomeMutationLock $newFileRecoveryLock
            }
        }
    }
    if ($onWindows) {
        $hangingCoreText = "@echo off`r`nping 127.0.0.1 -n 6 >nul`r`nexit /b 0`r`n"
    } else {
        $hangingCoreText = "#!/bin/sh`nsleep 5`nexit 0`n"
    }

    if ($onWindows) {
        $wrapperCase = Join-Path $sandbox "cmd-wrapper-case"
        New-Item -ItemType Directory -Path $wrapperCase -Force | Out-Null
        $wrapperOutput = & $installWrapper -ShowUsageProfile -AppHome $wrapperCase 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0) "install_windows.cmd did not propagate a successful exit; $(Get-TestOutputDiagnostic $wrapperOutput)"
        Assert-True ($wrapperOutput.Contains("unset")) "install_windows.cmd did not forward PowerShell output"

        $wrapperJsonOutput = & $installWrapper -ShowUsageProfile -AppHome $wrapperCase -Json 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0) "install_windows.cmd did not propagate JSON-mode success; $(Get-TestOutputDiagnostic $wrapperJsonOutput)"
        $wrapperJson = $wrapperJsonOutput.Trim() | ConvertFrom-Json
        Assert-True ($wrapperJson.schema -eq "claude-easy.result") "install_windows.cmd did not pass -Json through"

        $invalidWrapperOutput = & $installWrapper -UsageProfile 9 -AppHome $wrapperCase -Json 2>&1 | Out-String
        $invalidWrapperExit = $LASTEXITCODE
        Assert-True ($invalidWrapperExit -eq 64) "install_windows.cmd swallowed an installer failure; $(Get-TestOutputDiagnostic $invalidWrapperOutput)"
        $invalidWrapperJson = $invalidWrapperOutput.Trim() | ConvertFrom-Json
        Assert-True ([int]$invalidWrapperJson.exit_code -eq $invalidWrapperExit) "install_windows.cmd changed the JSON failure exit code"
        foreach ($invalidProfile in @("abc", "999999999999999999999")) {
            $invalidProfileOutput = & $installWrapper -UsageProfile $invalidProfile -AppHome $wrapperCase -Json 2>&1 | Out-String
            $invalidProfileExit = $LASTEXITCODE
            Assert-True ($invalidProfileExit -eq 64) "install_windows.cmd let PowerShell binding bypass an invalid profile result"
            $invalidProfileJson = $invalidProfileOutput.Trim() | ConvertFrom-Json
            Assert-True (
                $invalidProfileJson.code -eq "invalid_usage_profile" -and
                [int]$invalidProfileJson.exit_code -eq 64
            ) "install_windows.cmd did not structure a non-numeric or overflowing profile"
        }

        $invalidWrapperHome = 'C:\bad?name'
        foreach ($entry in @(
            @{ Wrapper = $installWrapper; Command = "install" },
            @{ Wrapper = $uninstallWrapper; Command = "uninstall" }
        )) {
            $invalidHomeOutput = & $entry.Wrapper -AppHome $invalidWrapperHome -Json 2>&1 | Out-String
            $invalidHomeExit = $LASTEXITCODE
            Assert-True ($invalidHomeExit -eq 64) "$($entry.Command) wrapper accepted an invalid AppHome"
            $invalidHomeJson = $invalidHomeOutput.Trim() | ConvertFrom-Json
            Assert-True (
                $invalidHomeJson.code -eq "invalid_app_home" -and
                [int]$invalidHomeJson.exit_code -eq 64
            ) "$($entry.Command) wrapper did not structure an invalid AppHome"
            Assert-True ($invalidHomeOutput -notlike "*$invalidWrapperHome*") "$($entry.Command) wrapper leaked an invalid AppHome"
        }

        $wrapperDiscoveryRoot = Join-Path $sandbox "cmd-wrapper-discovery"
        $wrapperRealHome = Join-Path $wrapperDiscoveryRoot "io.github.clash-verge-rev"
        $wrapperTypoTarget = Join-Path $sandbox "cmd-wrapper-typo-target"
        New-Item -ItemType Directory -Path $wrapperRealHome -Force | Out-Null
        New-Item -ItemType Directory -Path $wrapperTypoTarget -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $wrapperRealHome "keep.txt"), "real")
        [System.IO.File]::WriteAllText((Join-Path $wrapperTypoTarget "keep.txt"), "typo")
        $wrapperRealBefore = Get-TreeContentSnapshot $wrapperRealHome
        $wrapperTypoBefore = Get-TreeContentSnapshot $wrapperTypoTarget
        $savedAppData = $env:APPDATA
        $savedLocalAppData = $env:LOCALAPPDATA
        try {
            $env:APPDATA = $wrapperDiscoveryRoot
            $env:LOCALAPPDATA = Join-Path $sandbox "cmd-wrapper-empty-local"
            $typoInstallOutput = & $installWrapper -AppHme $wrapperTypoTarget -UsageProfile 1 -Json 2>&1 | Out-String
            Assert-True ($LASTEXITCODE -eq 64) "install_windows.cmd did not reject a misspelled AppHome"
            $typoInstallJson = $typoInstallOutput.Trim() | ConvertFrom-Json
            Assert-True ($typoInstallJson.code -eq "invalid_arguments") "install_windows.cmd changed a typo into installation"
            $typoUninstallOutput = & $uninstallWrapper -AppHme $wrapperTypoTarget -Json 2>&1 | Out-String
            Assert-True ($LASTEXITCODE -eq 64) "uninstall_windows.cmd did not reject a misspelled AppHome"
            $typoUninstallJson = $typoUninstallOutput.Trim() | ConvertFrom-Json
            Assert-True ($typoUninstallJson.code -eq "invalid_arguments") "uninstall_windows.cmd changed a typo into uninstallation"
        } finally {
            $env:APPDATA = $savedAppData
            $env:LOCALAPPDATA = $savedLocalAppData
        }
        Assert-True ((Get-TreeContentSnapshot $wrapperRealHome) -ceq $wrapperRealBefore) "wrapper typo changed the discovered AppHome"
        Assert-True ((Get-TreeContentSnapshot $wrapperTypoTarget) -ceq $wrapperTypoBefore) "wrapper typo changed the intended sandbox"

        $wrapperBackup = Join-Path (Join-Path $wrapperCase "claude-easy-backups") "keep.backup"
        New-Item -ItemType Directory -Path (Split-Path -Parent $wrapperBackup) -Force | Out-Null
        [System.IO.File]::WriteAllText($wrapperBackup, "keep")
        $uninstallWrapperOutput = & $uninstallWrapper -AppHome $wrapperCase 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0) "uninstall_windows.cmd did not propagate a successful exit; $(Get-TestOutputDiagnostic $uninstallWrapperOutput)"
        Assert-True (Test-Path -LiteralPath $wrapperBackup -PathType Leaf) "uninstall_windows.cmd deleted configuration history"

        $mutexCase = Join-Path $sandbox "app-home-mutex-case"
        $mutexReadyPath = Join-Path $sandbox "app-home-mutex.ready"
        $mutexReleasePath = Join-Path $sandbox "app-home-mutex.release"
        $mutexHolderPath = Join-Path $sandbox "app-home-mutex-holder.ps1"
        New-Item -ItemType Directory -Path $mutexCase -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $mutexCase "profiles.yaml"),
            "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n"
        )
        $mutexHolderSource = @'
param(
    [string]$ModulePath,
    [string]$AppHome,
    [string]$ReadyPath,
    [string]$ReleasePath
)
. $ModulePath
$held = Enter-AppHomeMutationLock $AppHome
try {
    [System.IO.File]::WriteAllText($ReadyPath, "ready")
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (-not (Test-Path -LiteralPath $ReleasePath -PathType Leaf) -and
        [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 25
    }
} finally {
    Exit-AppHomeMutationLock $held
}
'@
        [System.IO.File]::WriteAllText($mutexHolderPath, $mutexHolderSource, [System.Text.Encoding]::ASCII)
        $mutexHolder = Start-Process -FilePath $PowerShellPath -ArgumentList @(
            "-NoLogo", "-NoProfile", "-File", $mutexHolderPath,
            "-ModulePath", (Join-Path $installerModuleRoot "transaction.ps1"),
            "-AppHome", $mutexCase,
            "-ReadyPath", $mutexReadyPath,
            "-ReleasePath", $mutexReleasePath
        ) -PassThru
        try {
            $mutexDeadline = [DateTime]::UtcNow.AddSeconds(5)
            while (-not (Test-Path -LiteralPath $mutexReadyPath -PathType Leaf) -and
                [DateTime]::UtcNow -lt $mutexDeadline) {
                Start-Sleep -Milliseconds 25
            }
            Assert-True (Test-Path -LiteralPath $mutexReadyPath -PathType Leaf) "mutex holder did not acquire the AppHome lock"
            $mutexBefore = Get-TreeContentSnapshot $mutexCase
            $mutexInstall = Invoke-TestPowerShell $installer @(
                "-AppHome", $mutexCase,
                "-UsageProfile", "1",
                "-MihomoPath", $fakeCore,
                "-Json"
            )
            $mutexInstallJson = Assert-JsonResult $mutexInstall "install" 1
            Assert-True ($mutexInstallJson.code -eq "operation_in_progress") "parallel install did not report the shared AppHome lock"
            Assert-True ((Get-TreeContentSnapshot $mutexCase) -ceq $mutexBefore) "rejected parallel install changed AppHome"

            Invoke-DeferredProbe "extended-path AppHome lock alias" {
                $extendedMutexCase = "\\?\$mutexCase"
                $aliasInstall = Invoke-TestPowerShell $installer @(
                    "-AppHome", $extendedMutexCase,
                    "-UsageProfile", "1",
                    "-MihomoPath", $fakeCore,
                    "-Json"
                )
                $aliasInstallJson = Assert-JsonResult $aliasInstall "install" 1
                Assert-True ($aliasInstallJson.code -eq "operation_in_progress") "extended-path alias bypassed the shared AppHome lock"
            }

            Invoke-DeferredProbe "SUBST AppHome lock alias" {
                $substDriveName = @("Z", "Y", "X", "W", "V", "U", "T") |
                    Where-Object { -not (Test-Path -LiteralPath ("${_}:\")) } |
                    Select-Object -First 1
                Assert-True (-not [string]::IsNullOrWhiteSpace($substDriveName)) "no free drive letter was available for the SUBST alias fixture"
                $substRoot = Split-Path -Parent $mutexCase
                & (Join-Path $env:SystemRoot "System32\subst.exe") "${substDriveName}:" $substRoot
                Assert-True ($LASTEXITCODE -eq 0) "SUBST alias fixture could not map its drive"
                try {
                    $substMutexCase = Join-Path "${substDriveName}:\" (Split-Path -Leaf $mutexCase)
                    $substInstall = Invoke-TestPowerShell $installer @(
                        "-AppHome", $substMutexCase,
                        "-UsageProfile", "1",
                        "-MihomoPath", $fakeCore,
                        "-Json"
                    )
                    $substInstallJson = Assert-JsonResult $substInstall "install" 1
                    Assert-True ($substInstallJson.code -eq "operation_in_progress") "SUBST alias bypassed the shared AppHome lock"
                    Assert-True ((Get-TreeContentSnapshot $mutexCase) -ceq $mutexBefore) "rejected SUBST alias install changed AppHome"
                } finally {
                    & (Join-Path $env:SystemRoot "System32\subst.exe") "${substDriveName}:" /d
                }
            }

            $renamedMutexCase = Join-Path $sandbox "app-home-mutex-renamed"
            $renameBlocked = $false
            try { [System.IO.Directory]::Move($mutexCase, $renamedMutexCase) } catch { $renameBlocked = $true }
            Assert-True $renameBlocked "AppHome could be renamed while its mutation lock was held"
            Assert-True (-not (Test-Path -LiteralPath $renamedMutexCase)) "AppHome rename created a second mutation-lock identity"

            Invoke-DeferredProbe "installer and uninstaller shared AppHome lock" {
                $mutexUninstall = Invoke-TestPowerShell $uninstaller @("-AppHome", $mutexCase, "-Json")
                $mutexUninstallJson = Assert-JsonResult $mutexUninstall "uninstall" 1
                Assert-True ($mutexUninstallJson.code -eq "operation_in_progress") "parallel uninstall did not share the installer AppHome lock"
                Assert-True ((Get-TreeContentSnapshot $mutexCase) -ceq $mutexBefore) "rejected parallel uninstall changed AppHome"
                $mutexUninstallText = Invoke-TestPowerShellWithSeparatedStreams $uninstaller @("-AppHome", $mutexCase)
                Assert-True ($mutexUninstallText.ExitCode -eq 1) "non-JSON parallel uninstall returned the wrong exit code"
                Assert-True ($mutexUninstallText.StandardError.Contains("已有 ClaudeEasy 操作正在进行")) "failed non-JSON uninstall omitted its Chinese summary from stderr"
                Assert-True ([string]::IsNullOrWhiteSpace($mutexUninstallText.StandardOutput)) "failed non-JSON uninstall wrote its summary to stdout"
            }
        } finally {
            [System.IO.File]::WriteAllText($mutexReleasePath, "release")
            if (-not $mutexHolder.WaitForExit(5000)) {
                Stop-Process -Id $mutexHolder.Id -Force
            }
        }
    }
    [System.IO.File]::WriteAllText($hangingCore, $hangingCoreText, [System.Text.Encoding]::ASCII)
    if (-not $onWindows) { & /bin/chmod 700 $hangingCore }

    if ($onWindows) {
        $releaseZip = Join-Path $sandbox "claude-easy-release.zip"
        $releaseExtracted = Join-Path $sandbox "发布 包"
        Compress-Archive -Path (Join-Path $root "claude-easy") -DestinationPath $releaseZip
        Expand-Archive -LiteralPath $releaseZip -DestinationPath $releaseExtracted
        $releasePackage = Join-Path $releaseExtracted "claude-easy"
        $releaseInstaller = Join-Path (Join-Path $releasePackage "scripts") "install_windows.ps1"
        Assert-True (Test-Path -LiteralPath $releaseInstaller -PathType Leaf) "release archive omitted the Windows installer"

        $releaseAppHome = Join-Path $sandbox "用户 配置"
        $releaseProfiles = Join-Path $releaseAppHome "profiles"
        New-Item -ItemType Directory -Path $releaseProfiles -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $releaseAppHome "config.yaml"), "ipv6: true`ntun: null`n")
        [System.IO.File]::WriteAllText((Join-Path $releaseAppHome "verge.yaml"), "enable_tun_mode: false`n")
        [System.IO.File]::WriteAllText(
            (Join-Path $releaseAppHome "profiles.yaml"),
            "items:`n- uid: R-release`n  type: remote`n  option:`n    allow_auto_update: true`n"
        )
        Invoke-DeferredProbe "release archive public install" {
            $releaseInstallResult = Invoke-TestPowerShell $releaseInstaller @(
                "-AppHome", $releaseAppHome,
                "-UsageProfile", "1",
                "-MihomoPath", $fakeCore,
                "-Json"
            )
            $releaseInstallJson = Assert-JsonResult $releaseInstallResult "install" 0
            Assert-True ($releaseInstallJson.code -eq "installed_common_baseline") "relocated release did not complete a real install"
            Assert-True (Test-Path -LiteralPath (Join-Path $releaseProfiles "Script.js") -PathType Leaf) "relocated release omitted Script.js"
        }

        $incompleteReleaseHome = Join-Path $sandbox "incomplete-release-home"
        New-Item -ItemType Directory -Path $incompleteReleaseHome -Force | Out-Null
        $incompleteBefore = Get-TreeContentSnapshot $incompleteReleaseHome
        Remove-Item -LiteralPath (Join-Path (Join-Path $releasePackage "scripts/windows/install_windows") "transaction.ps1") -Force
        $incompleteResult = Invoke-TestPowerShell $releaseInstaller @(
            "-AppHome", $incompleteReleaseHome,
            "-UsageProfile", "1",
            "-MihomoPath", $fakeCore,
            "-Json"
        )
        $incompleteJson = Assert-JsonResult $incompleteResult "install" 6
        Assert-True ($incompleteJson.code -eq "incomplete_package") "release with a missing module did not report incomplete_package"
        Assert-True ((Get-TreeContentSnapshot $incompleteReleaseHome) -ceq $incompleteBefore) "incomplete release changed AppHome"
    }

    . $resultContract
    $contractResult = New-ClaudeEasyResult -Command "install" -Operation "test" -Ok $true -Status "ok" -Code "ok" -ExitCode 0 -SummaryZh "完成"
    foreach ($field in @("schema", "version", "command", "platform", "client", "operation", "ok", "status", "code", "exit_code", "summary_zh", "profile", "changes", "checks", "items", "messages", "warnings")) {
        Assert-True ($null -ne $contractResult.PSObject.Properties[$field]) "result contract omitted $field"
    }
    $workflowContractResult = New-ClaudeEasyResult -Command "install" -Operation "safe_update" -Ok $true -Status "ok" -Code "safe_update_verified" -ExitCode 0 -SummaryZh "订阅事务完成" -WorkflowComplete $false -CompletedScope "subscription_update" -RequiredFollowups @("route_verification", "final_state_audit")
    Assert-True ($workflowContractResult.workflow_complete -eq $false) "result contract changed incomplete workflow state"
    Assert-True ($workflowContractResult.completed_scope -eq "subscription_update") "result contract omitted completed workflow scope"
    Assert-True ((@($workflowContractResult.required_followups) -join ",") -eq "route_verification,final_state_audit") "result contract changed required follow-ups"
    $partialWorkflowMetadataRejected = $false
    try {
        New-ClaudeEasyResult -Command "install" -Operation "safe_update" -Ok $true -Status "ok" -Code "safe_update_verified" -ExitCode 0 -SummaryZh "订阅事务完成" -WorkflowComplete $false | Out-Null
    } catch {
        $partialWorkflowMetadataRejected = $true
    }
    Assert-True $partialWorkflowMetadataRejected "result contract accepted partial workflow metadata"
    foreach ($safeUpdateCode in @("safe_update_completed", "safe_update_verified")) {
        $missingWorkflowMetadataRejected = $false
        try {
            New-ClaudeEasyResult -Command "install" -Operation "safe_update" -Ok $true -Status "ok" -Code $safeUpdateCode -ExitCode 0 -SummaryZh "订阅事务完成" | Out-Null
        } catch {
            $missingWorkflowMetadataRejected = $true
        }
        Assert-True $missingWorkflowMetadataRejected "result contract accepted $safeUpdateCode without workflow metadata"
    }
    foreach ($invalidSafeUpdateWorkflow in @(
        @{ WorkflowComplete = $true; CompletedScope = "subscription_update"; RequiredFollowups = @("final_state_audit") },
        @{ WorkflowComplete = $false; CompletedScope = "wrong_scope"; RequiredFollowups = @("final_state_audit") },
        @{ WorkflowComplete = $false; CompletedScope = "subscription_update"; RequiredFollowups = @() }
    )) {
        $invalidSafeUpdateWorkflowRejected = $false
        try {
            New-ClaudeEasyResult -Command "install" -Operation "safe_update" -Ok $true -Status "ok" -Code "safe_update_verified" -ExitCode 0 -SummaryZh "订阅事务完成" -WorkflowComplete $invalidSafeUpdateWorkflow.WorkflowComplete -CompletedScope $invalidSafeUpdateWorkflow.CompletedScope -RequiredFollowups $invalidSafeUpdateWorkflow.RequiredFollowups | Out-Null
        } catch {
            $invalidSafeUpdateWorkflowRejected = $true
        }
        Assert-True $invalidSafeUpdateWorkflowRejected "result contract accepted invalid safe-update workflow metadata"
    }
    $snapshotWorkflowMetadataRejected = $false
    try {
        New-ClaudeEasyResult -Command "install" -Operation "snapshot_profiles" -Ok $true -Status "ok" -Code "snapshot_created" -ExitCode 0 -SummaryZh "已创建快照" | Out-Null
    } catch {
        $snapshotWorkflowMetadataRejected = $true
    }
    Assert-True $snapshotWorkflowMetadataRejected "result contract accepted snapshot success without workflow metadata"
    $snapshotWorkflowContractResult = New-ClaudeEasyResult -Command "install" -Operation "snapshot_profiles" -Ok $true -Status "ok" -Code "snapshot_created" -ExitCode 0 -SummaryZh "已创建快照" -WorkflowComplete $false -CompletedScope "subscription_snapshot" -RequiredFollowups @("region_fingerprint_baseline", "subscription_refresh")
    Assert-True ($snapshotWorkflowContractResult.completed_scope -eq "subscription_snapshot") "result contract changed snapshot workflow metadata"
    $invalidWorkflowFollowupRejected = $false
    try {
        New-ClaudeEasyResult -Command "install" -Operation "safe_update" -Ok $true -Status "ok" -Code "safe_update_verified" -ExitCode 0 -SummaryZh "订阅事务完成" -WorkflowComplete $false -CompletedScope "subscription_update" -RequiredFollowups @("route_verification", 7) | Out-Null
    } catch {
        $invalidWorkflowFollowupRejected = $true
    }
    Assert-True $invalidWorkflowFollowupRejected "result contract accepted a non-string workflow follow-up"
    $scalarWorkflowFollowupsRejected = $false
    try {
        New-ClaudeEasyResult -Command "install" -Operation "safe_update" -Ok $true -Status "ok" -Code "safe_update_verified" -ExitCode 0 -SummaryZh "订阅事务完成" -WorkflowComplete $false -CompletedScope "subscription_update" -RequiredFollowups "final_state_audit" | Out-Null
    } catch {
        $scalarWorkflowFollowupsRejected = $true
    }
    Assert-True $scalarWorkflowFollowupsRejected "result contract accepted a scalar string instead of a workflow follow-up array"
    $incompleteWhitespaceScopeRejected = $false
    try {
        New-ClaudeEasyResult -Command "install" -Operation "safe_update" -Ok $true -Status "ok" -Code "safe_update_verified" -ExitCode 0 -SummaryZh "订阅事务完成" -CompletedScope "   " | Out-Null
    } catch {
        $incompleteWhitespaceScopeRejected = $true
    }
    Assert-True $incompleteWhitespaceScopeRejected "result contract ignored an explicitly supplied blank workflow scope"
    $emptySanitizedWorkflowScopeRejected = $false
    try {
        New-ClaudeEasyResult -Command "install" -Operation "safe_update" -Ok $true -Status "ok" -Code "safe_update_verified" -ExitCode 0 -SummaryZh "订阅事务完成" -WorkflowComplete $false -CompletedScope (" " + [char]27 + "[31m ") -RequiredFollowups @("final_state_audit") | Out-Null
    } catch {
        $emptySanitizedWorkflowScopeRejected = $true
    }
    Assert-True $emptySanitizedWorkflowScopeRejected "result contract accepted a workflow scope that sanitizes to empty"
    $emptySanitizedWorkflowFollowupRejected = $false
    try {
        New-ClaudeEasyResult -Command "install" -Operation "safe_update" -Ok $true -Status "ok" -Code "safe_update_verified" -ExitCode 0 -SummaryZh "订阅事务完成" -WorkflowComplete $false -CompletedScope "subscription_update" -RequiredFollowups @((" " + [char]0x202E + " ")) | Out-Null
    } catch {
        $emptySanitizedWorkflowFollowupRejected = $true
    }
    Assert-True $emptySanitizedWorkflowFollowupRejected "result contract accepted a workflow follow-up that sanitizes to empty"
    $invalidContractCommandRejected = $false
    try { New-ClaudeEasyResult -Command "contract-test" -Operation "test" -Ok $true -Status "ok" -Code "ok" -ExitCode 0 -SummaryZh "完成" | Out-Null } catch { $invalidContractCommandRejected = $true }
    Assert-True $invalidContractCommandRejected "result contract accepted an unstable command name"
    $nestedSecretResult = New-ClaudeEasyResult -Command "install" -Operation "test" -Ok $true -Status "ok" -Code "ok" -ExitCode 0 -SummaryZh "完成" -Checks @([pscustomobject]@{ nested = [ordered]@{ url = "https://secret.invalid/path"; node = "ss://cipher:password@secret.invalid:443"; path = "C:\Users\friend\secret.yaml"; forward_path = "D:/Work/ordinary/file.yaml"; forward_unc = "//server/share/ordinary/file.yaml"; posix_path = "/opt/ordinary/file.yaml"; token = "token=private"; uuid = "11111111-2222-3333-4444-555555555555" } })
    $nestedSecretJson = $nestedSecretResult | ConvertTo-Json -Depth 8 -Compress
    Assert-True ($nestedSecretJson -notmatch 'secret\.invalid|ss://|C:\\Users\\friend|D:/Work|//server/share|/opt/ordinary|token=private|11111111-2222-3333-4444-555555555555') "result contract leaked nested sensitive text"
    $profileSecretResult = New-ClaudeEasyResult -Command "install" -Operation "test" -Ok $true -Status "ok" -Code "ok" -ExitCode 0 -SummaryZh "完成" -Profile ([pscustomobject]@{ name = ""; uid = "11111111-2222-4333-8444-555555555555" })
    $profileSecretJson = $profileSecretResult | ConvertTo-Json -Depth 8 -Compress
    Assert-True ($profileSecretJson -notmatch '11111111-2222-4333-8444-555555555555') "result contract leaked a UUID from an unnamed profile"
    $unsafeResultText = "前缀$([char]27)[31m$([char]0x202E)`r`n伪造" + ("长" * 300)
    $protectedResultText = Protect-ClaudeEasyResultText $unsafeResultText
    Assert-True ($protectedResultText -notmatch '\x1B|\[31m|[\p{Cc}\p{Cf}]') "result contract retained terminal or format controls"
    Assert-True ($protectedResultText.Length -le 240) "result contract did not limit dynamic text length"
    $surrogateBoundaryText = Protect-ClaudeEasyResultText (("a" * 239) + [char]0xD83D + [char]0xDE00)
    Assert-True ($surrogateBoundaryText.Length -eq 239) "result contract split a Unicode surrogate pair at the text limit"
    $unknownScalarResult = New-ClaudeEasyResult -Command "install" -Operation "test" -Ok $true -Status "ok" -Code "ok" -ExitCode 0 -SummaryZh "完成" -Items @([Guid]"11111111-2222-4333-8444-555555555555")
    $unknownScalarJson = $unknownScalarResult | ConvertTo-Json -Depth 8 -Compress
    Assert-True ($unknownScalarJson -notmatch '11111111-2222-4333-8444-555555555555') "result contract left an unknown scalar unsanitized"
    $invalidItemStatusRejected = $false
    try {
        New-ClaudeEasyResult -Command "install" -Operation "test" -Ok $true -Status "ok" -Code "ok" -ExitCode 0 -SummaryZh "完成" -Items @([pscustomobject]@{ status = "verified" }) | Out-Null
    } catch {
        $invalidItemStatusRejected = $true
    }
    Assert-True $invalidItemStatusRejected "result contract accepted an unknown item status"
    $privateSubscriptionUid = "account_private_42"
    $privateSubscriptionLabel = Get-PublicSubscriptionLabel $privateSubscriptionUid ""
    Assert-True (
        -not $privateSubscriptionLabel.Contains($privateSubscriptionUid) -and
        $privateSubscriptionLabel -match '^订阅 [0-9a-f]{8}$'
    ) "unnamed subscription label exposed a non-UUID uid"
    $privateSubscriptionResult = Get-PublicSubscriptionResult $privateSubscriptionUid "" "pending"
    Assert-True (
        -not ([string]$privateSubscriptionResult.id).Contains($privateSubscriptionUid) -and
        -not ([string]$privateSubscriptionResult.label).Contains($privateSubscriptionUid)
    ) "public subscription result exposed a non-UUID uid"

    $activationAttemptHome = Join-Path $sandbox "safe-update-activation-attempt"
    New-Item -ItemType Directory -Path $activationAttemptHome -Force | Out-Null
    $activationAttemptPath = Join-Path $activationAttemptHome "claude-easy-safe-update.json"
    $activationAttemptManifest = [pscustomobject][ordered]@{
        Version = 4
        CreatedAt = "2026-08-22T00:00:00+00:00"
        Profiles = @()
        Runtime = [pscustomobject][ordered]@{ TunEnabled = $false; Selections = @() }
        UpdateDispatchCommittedFor = $null
    }
    [System.IO.File]::WriteAllText(
        $activationAttemptPath,
        (($activationAttemptManifest | ConvertTo-Json -Depth 5) + "`r`n")
    )
    $activationRuntimePath = Join-Path $activationAttemptHome "clash-verge.yaml"
    [System.IO.File]::WriteAllText($activationRuntimePath, "runtime-before")
    $activationRuntimeSnapshot = Get-OptionalFileSnapshot $activationRuntimePath "runtime"
    $activationRuntimeContext = [pscustomobject]@{
        Snapshot = $activationRuntimeSnapshot
        LastWriteTicks = [System.IO.File]::GetLastWriteTimeUtc($activationRuntimePath).Ticks
    }
    [System.IO.File]::WriteAllText($activationRuntimePath, "runtime-before-stage-commit")
    $activationAttemptLock = Enter-AppHomeMutationLock $activationAttemptHome
    try {
        $activationIdentityA = [pscustomobject][ordered]@{
            Pid = [int]101
            StartedUtcTicks = [long]638914176000000000
            SessionId = [int]1
        }
        $activationIdentityB = [pscustomobject][ordered]@{
            Pid = [int]102
            StartedUtcTicks = [long]638914176010000000
            SessionId = [int]1
        }
        $activationIdentityRoundTrip = (
            $activationIdentityA | ConvertTo-Json -Compress | ConvertFrom-Json
        )
        Assert-True (
            Test-ClashVergeProcessIdentity $activationIdentityRoundTrip $activationIdentityA
        ) "JSON roundtrip changed a valid client identity"
        Assert-True (-not (Test-ClashVergeProcessIdentity ([pscustomobject][ordered]@{
            Pid = [long][int]::MaxValue + 1L
            StartedUtcTicks = [long]638914176000000000
            SessionId = [long]1
        }))) "client identity accepted a PID outside the Int32 process range"
        Assert-True (-not (Test-ClashVergeProcessIdentity ([pscustomobject][ordered]@{
            Pid = [long]101
            StartedUtcTicks = [long]638914176000000000
            SessionId = [long][int]::MaxValue + 1L
        }))) "client identity accepted a session outside the Int32 range"
        $activationAttemptSnapshot = Get-OptionalFileSnapshot $activationAttemptPath "activation attempt"
        $activationFirst = Set-SafeUpdateActivationAttempt `
            $activationAttemptPath $activationAttemptSnapshot $activationAttemptManifest `
            "UpdateDispatchCommittedFor" $activationIdentityA $activationRuntimeContext
        Assert-True ([bool]$activationFirst.Allowed) "first client activation attempt was rejected"
        try {
            Assert-True (
                (Test-ClashVergeProcessIdentity `
                    $activationFirst.Manifest.UpdateDispatchCommittedFor.Client $activationIdentityA) -and
                (Test-SafeUpdateRuntimeFingerprint `
                    $activationFirst.Manifest.UpdateDispatchCommittedFor.RuntimeBefore) -and
                [string]$activationFirst.Manifest.UpdateDispatchCommittedFor.RuntimeBefore.Sha256 -ceq
                    (Get-BytesSha256 (Get-StreamBytes $activationFirst.VersionGuard.Stream))
            ) "activation attempt did not persist the client and pre-dispatch runtime fingerprint"
            $runtimeWriteBlocked = $false
            try {
                [System.IO.File]::WriteAllText($activationRuntimePath, "runtime-before-send")
            } catch {
                $runtimeWriteBlocked = $true
            }
            Assert-True $runtimeWriteBlocked "runtime guard was released before the activation dispatch boundary"
        } finally {
            Close-SafeUpdateVersionGuard $activationFirst.VersionGuard
        }
        $activationAfterFirst = [System.IO.File]::ReadAllBytes($activationAttemptPath)
        $activationDuplicate = Set-SafeUpdateActivationAttempt `
            $activationAttemptPath $activationFirst.Snapshot $activationFirst.Manifest `
            "UpdateDispatchCommittedFor" $activationIdentityA $activationRuntimeContext
        Assert-True (-not [bool]$activationDuplicate.Allowed) "same client received a second activation eligibility"
        Assert-True (
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($activationAttemptPath)) -ceq
            [Convert]::ToBase64String($activationAfterFirst)
        ) "duplicate client activation changed the persisted attempt"
        [System.IO.File]::WriteAllText($activationRuntimePath, "runtime-after-refresh")
        Wait-ClashVergeRuntimeRefresh `
            $activationRuntimePath $activationDuplicate.Manifest.UpdateDispatchCommittedFor.RuntimeBefore
        $replacementRuntimeSnapshot = Get-OptionalFileSnapshot $activationRuntimePath "runtime"
        $replacementRuntimeContext = [pscustomobject]@{
            Snapshot = $replacementRuntimeSnapshot
            LastWriteTicks = [System.IO.File]::GetLastWriteTimeUtc($activationRuntimePath).Ticks
        }
        $activationReplacement = Set-SafeUpdateActivationAttempt `
            $activationAttemptPath $activationDuplicate.Snapshot $activationDuplicate.Manifest `
            "UpdateDispatchCommittedFor" $activationIdentityB $replacementRuntimeContext
        Assert-True (
            -not [bool]$activationReplacement.Allowed -and
            (Test-ClashVergeProcessIdentity `
                $activationReplacement.Manifest.UpdateDispatchCommittedFor.Client $activationIdentityA)
        ) "a new client process received a second activation eligibility"
    } finally {
        Exit-AppHomeMutationLock $activationAttemptLock
    }

    $privateMappingDirectory = Join-Path $sandbox "private-subscription-mapping"
    New-Item -ItemType Directory -Path $privateMappingDirectory -Force | Out-Null
    $privateMappingMessage = ""
    try {
        Get-RemoteSubscriptionTargets `
            "items:`n- uid: $privateSubscriptionUid`n  type: remote`n" `
            $privateMappingDirectory | Out-Null
    } catch { $privateMappingMessage = $_.Exception.Message }
    Assert-True (
        -not [string]::IsNullOrWhiteSpace($privateMappingMessage) -and
        -not $privateMappingMessage.Contains($privateSubscriptionUid)
    ) "subscription mapping failure exposed a non-UUID uid"

    $progressProbePath = Join-Path $sandbox "result-progress-probe.ps1"
    $progressProbeSource = @'
param(
    [string]$ResultContractPath,
    [string]$CommonModulePath,
    [switch]$Json
)
. $ResultContractPath
. $CommonModulePath
$script:ClaudeEasyMessages = New-Object System.Collections.ArrayList
$script:ClaudeEasyOperation = "test"
$script:ClaudeEasyProfile = $null
$unsafeProgress = "已更新并通过检查：11111111-2222-4333-8444-555555555555 错误token=private结束 错误Bearer private结束 错误https://secret.invalid/path结束$([char]27)[31m$([char]0x202E)`r`n伪造" + ("长" * 300)
Write-Info $unsafeProgress
if ($Json) {
    $result = New-ClaudeEasyResult -Command "install" -Operation "test" -Ok $true -Status "ok" -Code "ok" -ExitCode 0 -SummaryZh "完成" -Checks @("single-check") -Messages @($script:ClaudeEasyMessages) -Warnings @("first-warning", "second-warning")
    $result.items = ,@("nested-item")
    Write-ClaudeEasyResult $result
}
'@
    [System.IO.File]::WriteAllText($progressProbePath, $progressProbeSource, (New-Object System.Text.UTF8Encoding($true)))
    $unnamedProfileOutput = Invoke-TestPowerShell $progressProbePath @(
        "-ResultContractPath", $resultContract,
        "-CommonModulePath", (Join-Path $installerModuleRoot "common.ps1")
    )
    Assert-True ($unnamedProfileOutput.ExitCode -eq 0) "human-readable progress probe failed"
    Assert-True ($unnamedProfileOutput.Output -notmatch '11111111-2222-4333-8444-555555555555') "human-readable progress leaked a UUID from an unnamed profile"
    Assert-True ($unnamedProfileOutput.Output -notmatch 'private|secret\.invalid') "human-readable progress leaked a credential or URL next to Unicode text"
    Assert-True ($unnamedProfileOutput.Output.Trim() -notmatch '\x1B|\[31m|[\p{Cc}\p{Cf}]') "human-readable progress retained terminal or format controls"
    Assert-True ($unnamedProfileOutput.Output.Trim().Length -le 240) "human-readable progress exceeded the dynamic text limit"
    $unnamedProfileJson = Assert-JsonResult (Invoke-TestPowerShell $progressProbePath @(
        "-ResultContractPath", $resultContract,
        "-CommonModulePath", (Join-Path $installerModuleRoot "common.ps1"),
        "-Json"
    )) "install" 0
    Assert-True ((@($unnamedProfileJson.messages) -join "") -notmatch '11111111-2222-4333-8444-555555555555') "JSON progress leaked a UUID from an unnamed profile"
    Assert-True ((@($unnamedProfileJson.messages) -join "") -notmatch 'private|secret\.invalid') "JSON progress leaked a credential or URL next to Unicode text"
    Assert-True ([string]$unnamedProfileJson.messages[0] -notmatch '\x1B|\[31m|[\p{Cc}\p{Cf}]') "JSON progress retained terminal or format controls"
    Assert-True (([string]$unnamedProfileJson.messages[0]).Length -le 240) "JSON progress exceeded the dynamic text limit"
    foreach ($arrayField in @("changes", "checks", "items", "messages", "warnings")) {
        Assert-True ($unnamedProfileJson.$arrayField -is [System.Array]) "JSON result changed $arrayField from an array"
    }
    Assert-True (@($unnamedProfileJson.changes).Count -eq 0) "JSON result changed an empty array"
    Assert-True (@($unnamedProfileJson.checks).Count -eq 1) "JSON result changed a single-item array"
    Assert-True (@($unnamedProfileJson.warnings).Count -eq 2) "JSON result changed a multi-item array"
    Assert-True ($unnamedProfileJson.items[0] -is [System.Array] -and @($unnamedProfileJson.items[0]).Count -eq 1) "JSON result flattened a nested array"

    $jsonShowCase = Join-Path $sandbox "json-show-case"
    New-Item -ItemType Directory -Path $jsonShowCase -Force | Out-Null
    $jsonShow = Invoke-TestPowerShell $installer @("-AppHome", $jsonShowCase, "-ShowUsageProfile", "-Json")
    $jsonShowResult = Assert-JsonResult $jsonShow "install" 0
    Assert-True ($jsonShowResult.operation -eq "show_usage_profile") "show-profile operation mismatch"
    Assert-True ($jsonShowResult.profile -eq $null) "unset profile was not represented as null"

    $jsonInvalid = Invoke-TestPowerShell $installer @("-AppHome", $jsonShowCase, "-UsageProfile", "9", "-Json")
    $jsonInvalidResult = Assert-JsonResult $jsonInvalid "install" 64
    Assert-True (-not [bool]$jsonInvalidResult.ok) "invalid request was reported as successful"
    Assert-True ($jsonInvalidResult.status -eq "invalid_request") "invalid request status mismatch"
    foreach ($invalidProfile in @("abc", "999999999999999999999")) {
        $invalidProfileResult = Assert-JsonResult (Invoke-TestPowerShell $installer @(
            "-AppHome", $jsonShowCase, "-UsageProfile", $invalidProfile, "-Json"
        )) "install" 64
        Assert-True ($invalidProfileResult.code -eq "invalid_usage_profile") "non-numeric or overflowing profile bypassed JSON v1"
    }

    $unknownInstallBefore = Get-TreeContentSnapshot $jsonShowCase
    $unknownInstallResult = Assert-JsonResult (Invoke-TestPowerShell $installer @(
        "-AppHome", $jsonShowCase, "-ShowUsageProfiles", "-Json"
    )) "install" 64
    Assert-True ($unknownInstallResult.code -eq "invalid_arguments") "unknown install argument was not rejected"
    Assert-True ((Get-TreeContentSnapshot $jsonShowCase) -ceq $unknownInstallBefore) "unknown install argument changed AppHome"
    $unknownUninstallResult = Assert-JsonResult (Invoke-TestPowerShell $uninstaller @(
        "-AppHome", $jsonShowCase, "-UnknownOperation", "-Json"
    )) "uninstall" 64
    Assert-True ($unknownUninstallResult.code -eq "invalid_arguments") "unknown uninstall argument was not rejected"
    $unknownRouteResult = Assert-JsonResult (Invoke-TestPowerShell $routeVerifier @(
        "-UnknownOperation", "-Json"
    )) "verify_routes" 64
    Assert-True ($unknownRouteResult.code -eq "invalid_arguments") "unknown route-verifier argument was not rejected"

    $invalidAppHome = 'C:\bad|name'
    foreach ($entry in @(
        @{ Script = $installer; Command = "install" },
        @{ Script = $uninstaller; Command = "uninstall" }
    )) {
        $invalidHomeOutput = Invoke-TestPowerShell $entry.Script @(
            "-AppHome", $invalidAppHome, "-Json"
        )
        $invalidHomeResult = Assert-JsonResult $invalidHomeOutput $entry.Command 64
        Assert-True ($invalidHomeResult.code -eq "invalid_app_home") "invalid AppHome bypassed JSON v1"
        Assert-True ($invalidHomeOutput.Output -notlike "*$invalidAppHome*") "invalid AppHome leaked in JSON output"
    }

    $conflictingOperations = Invoke-TestPowerShell $installer @(
        "-AppHome", $jsonShowCase, "-ShowUsageProfile", "-ListBackups", "-Json"
    )
    $conflictingOperationsResult = Assert-JsonResult $conflictingOperations "install" 64
    Assert-True ($conflictingOperationsResult.code -eq "conflicting_operations") "conflicting public operations were not rejected"

    $orphanExpectedHash = Invoke-TestPowerShell $installer @(
        "-AppHome", $jsonShowCase, "-ExpectedCurrentSha256", ("a" * 64), "-Json"
    )
    $orphanExpectedHashResult = Assert-JsonResult $orphanExpectedHash "install" 64
    Assert-True ($orphanExpectedHashResult.code -eq "unexpected_hash") "orphan restore hash was not rejected"

    $missingExpectedHash = Invoke-TestPowerShell $installer @(
        "-AppHome", $jsonShowCase, "-RestoreBackup", "missing", "-Json"
    )
    $missingExpectedHashResult = Assert-JsonResult $missingExpectedHash "install" 64
    Assert-True ($missingExpectedHashResult.status -eq "invalid_request") "missing restore hash was not an invalid request"
    Assert-True ($missingExpectedHashResult.code -eq "expected_current_sha256_required") "missing restore hash returned the wrong code"

    $listSummary = Invoke-TestPowerShellWithSeparatedStreams $installer @(
        "-AppHome", $jsonShowCase, "-ListBackups"
    )
    Assert-True ($listSummary.ExitCode -eq 0) "non-JSON backup list failed"
    Assert-True ($listSummary.StandardOutput.Contains("备份清单已读取。")) "successful non-JSON install operation omitted its Chinese summary"
    Assert-True ([string]::IsNullOrWhiteSpace($listSummary.StandardError)) "successful non-JSON install operation wrote to stderr"
    $conflictSummary = Invoke-TestPowerShellWithSeparatedStreams $installer @(
        "-AppHome", $jsonShowCase, "-ShowUsageProfile", "-ListBackups"
    )
    Assert-True ($conflictSummary.ExitCode -eq 64) "non-JSON conflicting operation returned the wrong exit code"
    Assert-True ($conflictSummary.StandardError.Contains("一次只能执行一个操作。")) "failed non-JSON install operation omitted its Chinese summary from stderr"
    Assert-True ([string]::IsNullOrWhiteSpace($conflictSummary.StandardOutput)) "failed non-JSON install operation wrote its summary to stdout"

    $publicBackupCase = Join-Path $sandbox "public-backup-id-case"
    $publicBackupProfiles = Join-Path $publicBackupCase "profiles"
    $publicBackupRoot = Join-Path $publicBackupCase "claude-easy-backups"
    $publicBackupUid = "11111111-2222-4333-8444-555555555555"
    $publicBackupTarget = Join-Path $publicBackupProfiles "$publicBackupUid.yaml"
    $publicBackupText = "mode: rule`nipv6: false`nproxies: []`nproxy-groups:`n  - name: Main`n    type: select`n    proxies:`n      - DIRECT`nrules: []`n"
    $publicCurrentText = $publicBackupText.Replace("mode: rule", "mode: global")
    New-Item -ItemType Directory -Path $publicBackupProfiles -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $publicBackupCase "claude-easy-usage-profile.json"), '{"Version":1,"Profile":1}')
    [System.IO.File]::WriteAllText($publicBackupTarget, $publicBackupText)
    $publicBackupLock = Enter-AppHomeMutationLock $publicBackupCase
    try {
        $publicRawBackup = Split-Path -Leaf (Backup-Versioned $publicBackupTarget $publicBackupRoot "prewrite")
    } finally {
        Exit-AppHomeMutationLock $publicBackupLock
    }
    [System.IO.File]::WriteAllText($publicBackupTarget, $publicCurrentText)
    $publicIdSha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $publicIdDigest = ($publicIdSha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($publicRawBackup)) | ForEach-Object { $_.ToString("x2") }) -join ""
    } finally {
        $publicIdSha.Dispose()
    }
    $publicBackupId = "ce-backup-v1-$publicIdDigest"
    Assert-True ($publicRawBackup -match '^(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2}\.\d{7})([+-]\d{2})(\d{2})--') "public backup fixture has an invalid storage timestamp"
    $publicBackupCreatedAt = "$($Matches[1])T$($Matches[2]):$($Matches[3]):$($Matches[4])$($Matches[5]):$($Matches[6])"

    $publicList = Invoke-TestPowerShell $installer @("-AppHome", $publicBackupCase, "-ListBackups")
    Assert-True ($publicList.ExitCode -eq 0) "public backup list failed"
    Assert-True ($publicList.Output.Contains("$publicBackupCreatedAt`t$publicBackupId")) "public backup list omitted its creation time and opaque ID"
    Assert-True (-not $publicList.Output.Contains($publicBackupUid)) "public backup list exposed a UUID"
    Assert-True (-not $publicList.Output.Contains($publicRawBackup)) "public backup list exposed its storage filename"
    $publicListJson = Assert-JsonResult (Invoke-TestPowerShell $installer @(
        "-AppHome", $publicBackupCase, "-ListBackups", "-Json"
    )) "install" 0
    Assert-True (@($publicListJson.items).Count -eq 1) "JSON backup list returned the wrong item count"
    Assert-True ([string]($publicListJson.items[0].id) -ceq $publicBackupId) "JSON backup list did not return the opaque ID"
    Assert-True ([string]($publicListJson.items[0].created_at) -ceq $publicBackupCreatedAt) "JSON backup list did not return the RFC3339 creation time"
    Assert-True ((@($publicListJson.items[0].PSObject.Properties.Name | Sort-Object) -join ",") -ceq "created_at,id") "JSON backup list exposed storage metadata"

    if ($onWindows) {
        $linkedRawBackup = $publicRawBackup.Replace("--prewrite--", "--linked--")
        Assert-True ($linkedRawBackup -cne $publicRawBackup) "linked backup fixture did not receive a distinct storage name"
        $linkedBackupPath = Join-Path $publicBackupRoot $linkedRawBackup
        New-Item -ItemType HardLink -Path $linkedBackupPath -Target (Join-Path $publicBackupRoot $publicRawBackup) | Out-Null
        $linkedIdSha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $linkedIdDigest = ($linkedIdSha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($linkedRawBackup)) | ForEach-Object { $_.ToString("x2") }) -join ""
        } finally {
            $linkedIdSha.Dispose()
        }
        $linkedBackupId = "ce-backup-v1-$linkedIdDigest"
        $linkedTargetBefore = [System.IO.File]::ReadAllBytes($publicBackupTarget)
        try {
            $linkedList = Assert-JsonResult (Invoke-TestPowerShell $installer @(
                "-AppHome", $publicBackupCase, "-ListBackups", "-Json"
            )) "install" 0
            Assert-True (@($linkedList.items).Count -eq 0) "backup list published a file with a hard-link alias"
            $linkedCompare = Assert-JsonResult (Invoke-TestPowerShell $installer @(
                "-AppHome", $publicBackupCase, "-CompareBackup", $linkedBackupId, "-Json"
            )) "install" 1
            Assert-True ($linkedCompare.code -eq "operation_failed") "backup comparison accepted a file with a hard-link alias"
            $linkedRestore = Assert-JsonResult (Invoke-TestPowerShell $installer @(
                "-AppHome", $publicBackupCase,
                "-RestoreBackup", $linkedBackupId,
                "-ExpectedCurrentSha256", (Get-BytesSha256 $linkedTargetBefore),
                "-MihomoPath", $fakeCore,
                "-Json"
            )) "install" 1
            Assert-True ($linkedRestore.code -eq "operation_failed") "backup restore accepted a file with a hard-link alias"
            Assert-True (
                [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($publicBackupTarget)) -ceq
                [Convert]::ToBase64String($linkedTargetBefore)
            ) "rejected linked-backup restore changed the current configuration"
        } finally {
            Remove-Item -LiteralPath $linkedBackupPath -Force -ErrorAction SilentlyContinue
        }
    }

    $publicBackupHash = (Get-FileHash -LiteralPath (Join-Path $publicBackupRoot $publicRawBackup) -Algorithm SHA256).Hash.ToLowerInvariant()
    $publicCurrentHash = (Get-FileHash -LiteralPath $publicBackupTarget -Algorithm SHA256).Hash.ToLowerInvariant()
    $publicCompareInvocation = Invoke-TestPowerShell $installer @(
        "-AppHome", $publicBackupCase, "-CompareBackup", $publicBackupId, "-Json"
    )
    $publicCompare = Assert-JsonResult $publicCompareInvocation "install" 0
    $publicComparison = @($publicCompare.items)[0]
    Assert-True ((@($publicComparison.PSObject.Properties.Name | Sort-Object) -join ",") -ceq "backup_sha256,current_sha256,id,same") "backup comparison exposed fields outside the public machine contract"
    foreach ($comparisonField in @("id", "same", "backup_sha256", "current_sha256")) {
        Assert-True ($null -ne $publicComparison.PSObject.Properties[$comparisonField]) "backup comparison omitted $comparisonField"
    }
    Assert-True ([string]$publicComparison.id -ceq $publicBackupId) "backup comparison returned the wrong opaque ID"
    Assert-True (-not [bool]$publicComparison.same) "backup comparison reported changed files as identical"
    Assert-True ([string]$publicComparison.backup_sha256 -ceq $publicBackupHash) "backup comparison returned the wrong backup hash"
    Assert-True ([string]$publicComparison.current_sha256 -ceq $publicCurrentHash) "backup comparison returned the wrong current hash"
    $legacyComparison = Assert-JsonResult (Invoke-TestPowerShell $installer @(
        "-AppHome", $publicBackupCase, "-CompareBackup", $publicRawBackup, "-Json"
    )) "install" 0
    Assert-True ([string](@($legacyComparison.items)[0].id) -ceq $publicBackupId) "backup comparison dropped raw-filename compatibility"
    $publicHumanComparison = Invoke-TestPowerShell $installer @(
        "-AppHome", $publicBackupCase, "-CompareBackup", $publicBackupId
    )
    Assert-True (-not $publicHumanComparison.Output.Contains($publicBackupUid)) "human-readable backup comparison exposed a UUID"
    Assert-True ($publicHumanComparison.Output.Contains($publicBackupId)) "human-readable backup comparison omitted the complete opaque ID"
    Assert-True ($publicHumanComparison.Output.Contains($publicBackupHash)) "human-readable backup comparison omitted the complete backup hash"
    Assert-True ($publicHumanComparison.Output.Contains($publicCurrentHash)) "human-readable backup comparison omitted the complete current hash"

    $publicRestore = Assert-JsonResult (Invoke-TestPowerShell $installer @(
        "-AppHome", $publicBackupCase,
        "-RestoreBackup", $publicBackupId,
        "-ExpectedCurrentSha256", $publicCurrentHash,
        "-MihomoPath", $fakeCore,
        "-Json"
    )) "install" 0
    Assert-True ($publicRestore.code -eq "backup_restored") "opaque backup restore did not complete"
    Assert-True ((Get-Content -LiteralPath $publicBackupTarget -Raw) -ceq $publicBackupText) "opaque backup restore wrote the wrong content"
    [System.IO.File]::WriteAllText($publicBackupTarget, $publicCurrentText)
    $legacyCurrentHash = (Get-FileHash -LiteralPath $publicBackupTarget -Algorithm SHA256).Hash.ToLowerInvariant()
    $legacyRestore = Assert-JsonResult (Invoke-TestPowerShell $installer @(
        "-AppHome", $publicBackupCase,
        "-RestoreBackup", $publicRawBackup,
        "-ExpectedCurrentSha256", $legacyCurrentHash,
        "-MihomoPath", $fakeCore,
        "-Json"
    )) "install" 0
    Assert-True ($legacyRestore.code -eq "backup_restored") "backup restore dropped raw-filename compatibility"

    $sensitiveCorePath = Join-Path $sandbox "11111111-2222-4333-8444-555555555555-secret-core.exe"
    $sensitiveFailure = Invoke-TestPowerShellWithSeparatedStreams $installer @(
        "-AppHome", $jsonShowCase,
        "-UsageProfile", "1",
        "-MihomoPath", $sensitiveCorePath
    )
    Assert-True ($sensitiveFailure.ExitCode -eq 1) "missing sensitive core path did not fail"
    Assert-True ($sensitiveFailure.StandardError.Contains("安装失败：")) "redacted install failure omitted its Chinese summary"
    Assert-True (-not $sensitiveFailure.StandardError.Contains("11111111-2222-4333-8444-555555555555")) "install exception output exposed a UUID"
    Assert-True (-not $sensitiveFailure.StandardError.Contains($sensitiveCorePath)) "install exception output exposed a path"
    Assert-True ([string]::IsNullOrWhiteSpace($sensitiveFailure.StandardOutput)) "failed install wrote its summary to stdout"
    $forwardSlashCorePath = "D:/Work/ordinary/missing-core.exe"
    $forwardSlashFailure = Invoke-TestPowerShellWithSeparatedStreams $installer @(
        "-AppHome", $jsonShowCase,
        "-UsageProfile", "1",
        "-MihomoPath", $forwardSlashCorePath
    )
    Assert-True ($forwardSlashFailure.ExitCode -eq 1) "missing forward-slash core path did not fail"
    Assert-True (-not $forwardSlashFailure.StandardError.Contains($forwardSlashCorePath)) "human-readable exception exposed a forward-slash Windows path"
    Assert-True ([string]::IsNullOrWhiteSpace($forwardSlashFailure.StandardOutput)) "forward-slash path failure wrote to stdout"
    $forwardSlashJsonFailure = Assert-JsonResult (Invoke-TestPowerShell $installer @(
        "-AppHome", $jsonShowCase,
        "-UsageProfile", "1",
        "-MihomoPath", $forwardSlashCorePath,
        "-Json"
    )) "install" 1
    Assert-True (-not $forwardSlashJsonFailure.summary_zh.Contains($forwardSlashCorePath)) "JSON exception exposed a forward-slash Windows path"

    $jsonUninstall = Invoke-TestPowerShell $uninstaller @("-AppHome", $jsonShowCase, "-Json")
    $jsonUninstallResult = Assert-JsonResult $jsonUninstall "uninstall" 0
    Assert-True ($jsonUninstallResult.status -eq "no_change") "empty uninstall was not no_change"

    $rejectedRouteSecretCanary =
        "route-argument-canary-" + [Guid]::NewGuid().ToString("N")
    $routeProfileThreeHome = Join-Path $sandbox "route-profile-three"
    New-Item -ItemType Directory -Path $routeProfileThreeHome -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $routeProfileThreeHome "claude-easy-usage-profile.json"),
        '{"Version":1,"Profile":3}' + "`r`n",
        (New-Object System.Text.UTF8Encoding($false))
    )
    $jsonRouteFailure = Invoke-TestPowerShell $routeVerifier @(
        "-AppHome", $routeProfileThreeHome,
        "-ObservationSeconds", "1",
        "-Secret", $rejectedRouteSecretCanary,
        "-Json"
    )
    $jsonRouteFailureResult = Assert-JsonResult $jsonRouteFailure "verify_routes" 1
    Assert-True ($jsonRouteFailureResult.code -eq "route_verification_failed") "route verifier did not structure its parameter failure"
    Assert-True ($jsonRouteFailureResult.profile -eq 3) "route verifier failure omitted the saved profile"
    Assert-True (
        -not $jsonRouteFailure.Output.Contains($rejectedRouteSecretCanary)
    ) "route verifier echoed a rejected command-line secret"
    $invalidObservation = Invoke-TestPowerShell $routeVerifier @(
        "-ObservationSeconds", "0",
        "-Json"
    )
    $invalidObservationResult = Assert-JsonResult $invalidObservation "verify_routes" 64
    Assert-True (
        $invalidObservationResult.code -eq "invalid_arguments"
    ) "route verifier did not reject an invalid observation window consistently"
    $blankRouteGroup = Invoke-TestPowerShell $routeVerifier @(
        "-AiGroup", " ",
        "-Json"
    )
    $blankRouteGroupResult = Assert-JsonResult $blankRouteGroup "verify_routes" 64
    Assert-True (
        $blankRouteGroupResult.code -eq "invalid_arguments"
    ) "route verifier did not reject a blank group override consistently"
    $routeProfileOneHome = Join-Path $sandbox "route-profile-one"
    New-Item -ItemType Directory -Path $routeProfileOneHome -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $routeProfileOneHome "claude-easy-usage-profile.json"),
        '{"Version":1,"Profile":1}' + "`r`n",
        (New-Object System.Text.UTF8Encoding($false))
    )
    $profileOneRouteResult = Assert-JsonResult (Invoke-TestPowerShell $routeVerifier @(
        "-AppHome", $routeProfileOneHome,
        "-ObservationSeconds", "1",
        "-Json"
    )) "verify_routes" 10
    Assert-True ($profileOneRouteResult.code -eq "usage_profile_mismatch") "profile 1 route verification was not refused"
    Assert-True ($profileOneRouteResult.profile -eq 1) "profile 1 route refusal reported the wrong saved profile"

    $routeProfileUnsetHome = Join-Path $sandbox "route-profile-unset"
    New-Item -ItemType Directory -Path $routeProfileUnsetHome -Force | Out-Null
    $profileUnsetRouteResult = Assert-JsonResult (Invoke-TestPowerShell $routeVerifier @(
        "-AppHome", $routeProfileUnsetHome,
        "-ObservationSeconds", "1",
        "-Json"
    )) "verify_routes" 10
    Assert-True ($profileUnsetRouteResult.code -eq "usage_profile_unset") "unset route profile was not refused"
    Assert-True ($null -eq $profileUnsetRouteResult.profile) "unset route profile was reported as profile 3"

    $routeProfileInvalidHome = Join-Path $sandbox "route-profile-invalid"
    New-Item -ItemType Directory -Path $routeProfileInvalidHome -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $routeProfileInvalidHome "claude-easy-usage-profile.json"),
        '{"Version":1,"Profile":9}' + "`r`n",
        (New-Object System.Text.UTF8Encoding($false))
    )
    $profileInvalidRouteResult = Assert-JsonResult (Invoke-TestPowerShell $routeVerifier @(
        "-AppHome", $routeProfileInvalidHome,
        "-ObservationSeconds", "1",
        "-Json"
    )) "verify_routes" 10
    Assert-True ($profileInvalidRouteResult.code -eq "usage_profile_invalid") "invalid route profile was not refused"
    Assert-True ($null -eq $profileInvalidRouteResult.profile) "invalid route profile was reported as profile 3"

    $routeHarnessPath = Join-Path $sandbox "verify-route-observer.ps1"
    $routeFunctionSources = $routeFunctionAsts | ForEach-Object {
        $_.Extent.Text
    }
    $routeHarnessMocks = @'
$ErrorActionPreference = "Stop"
$ObservationSeconds = 1
$Json = $true
$script:ClaudeEasyChecks = New-Object System.Collections.ArrayList
function Get-ExactJsonProperty([object]$Object, [string]$Name) {
    foreach ($property in @($Object.PSObject.Properties)) {
        if ([string]$property.Name -ceq $Name) { return $property }
    }
    return $null
}
foreach ($acceptedControllerUrl in @(
    "http://127.0.0.1:9097",
    "https://127.255.1.2/",
    "http://[::1]:9097",
    "https://LOCALHOST:9443/base"
)) {
    [void](Get-ValidatedControllerBaseUri $acceptedControllerUrl)
}
foreach ($rejectedControllerUrl in @(
    "ftp://127.0.0.1/",
    "http://example.com/",
    "http://127.0.0.1.example.com/",
    "http://0177.0.0.1/",
    "http://2130706433/",
    "http://[::ffff:127.0.0.1]/",
    "http://friend@127.0.0.1/",
    "http://127.0.0.1/?token=value",
    "http://127.0.0.1/#fragment"
)) {
    $controllerUrlRejected = $false
    try {
        [void](Get-ValidatedControllerBaseUri $rejectedControllerUrl)
    } catch {
        $controllerUrlRejected = $true
    }
    if (-not $controllerUrlRejected) {
        throw "controller URL escaped the loopback-only validator"
    }
}
function Get-ConnectionIds { return @{} }
function Start-TestTraffic([string]$Url, [string]$ProxyUrl) {
    $process = [pscustomobject]@{ HasExited = $true }
    $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
    return [pscustomobject]@{ Process = $process; SourcePort = 45555 }
}
function Start-Sleep { }
function Invoke-ControllerJson([string]$Endpoint) {
    if ($Endpoint -eq "/rules") {
        return [pscustomobject]@{
            rules = @([pscustomobject]@{ type = "Match"; proxy = "Main" })
        }
    }
    if ($Endpoint -eq "/proxies") {
        return [pscustomobject]@{
            proxies = [pscustomobject]@{
                Main = [pscustomobject]@{ type = "LoadBalance"; now = "" }
                AI = [pscustomobject]@{ type = "Selector"; now = "Fixture Node" }
                "Custom Route" = [pscustomobject]@{ type = "Selector"; now = "Fixture Node" }
                "Fixture Node" = [pscustomobject]@{ type = "Shadowsocks" }
            }
        }
    }
    if ($Endpoint -eq "/providers/proxies") {
        return [pscustomobject]@{ providers = [pscustomobject]@{} }
    }
    if ($Endpoint -ne "/connections") { throw "unexpected controller endpoint: $Endpoint" }
    return [pscustomobject]@{
        connections = @(
            [pscustomobject]@{
                id = "background-google-connection"
                metadata = [pscustomobject]@{ host = "www.google.com"; network = "tcp"; sourcePort = 45556 }
                chains = @("Wrong Node", "Main")
            },
            [pscustomobject]@{
                id = "curl-google-connection"
                metadata = [pscustomobject]@{ host = "www.google.com"; network = "tcp"; sourcePort = 45555 }
                chains = @("Fixture Node", "Main")
            }
        )
    }
}
foreach ($groupType in @("Selector", "URLTest", "Fallback", "LoadBalance")) {
    $mainProxies = [pscustomobject]@{
        Main = [pscustomobject]@{ type = $groupType; now = "Fixture Node" }
    }
    if ((Get-LiveMainGroup $mainProxies) -ne "Main") {
        throw "Get-LiveMainGroup rejected supported group type: $groupType"
    }
}
$loadBalanceSelection = [pscustomobject]@{ type = "LoadBalance"; now = "" }
if (-not (Test-UsableRouteGroupSelection $loadBalanceSelection)) {
    throw "selectionless LoadBalance was rejected"
}
$selectorSelection = [pscustomobject]@{ type = "Selector"; now = "" }
if (Test-UsableRouteGroupSelection $selectorSelection) {
    throw "selectionless Selector was accepted"
}
$liveAiGroups = [pscustomobject]@{
    "AI Balanced" = [pscustomobject]@{ type = "LoadBalance"; now = "" }
}
if ((Find-Group $liveAiGroups @() "" "AI 分组") -ne "AI Balanced") {
    throw "live LoadBalance AI group was not detected"
}
$wrongCaseGroupRejected = $false
try { [void](Find-Group $liveAiGroups @() "ai balanced" "AI 分组") } catch {
    $wrongCaseGroupRejected = $true
}
if (-not $wrongCaseGroupRejected) {
    throw "explicit AI group accepted a different case"
}
$caseExactRouteGroups = [pscustomobject]@{
    AI = [pscustomobject]@{ type = "Selector"; now = "Node" }
    Node = [pscustomobject]@{ type = "Shadowsocks" }
}
if (Test-RouteChains $caseExactRouteGroups @("Node", "ai") "AI" "Node" "AI" $false) {
    throw "route chain accepted a different group case"
}
$liveAiCandidates = [pscustomobject]@{
    AI = [pscustomobject]@{ type = "Vmess" }
    OpenAI = [pscustomobject]@{ type = "Selector"; now = "Japan" }
}
if ((Find-Group $liveAiCandidates @("AI", "OpenAI") "" "AI 分组") -ne "OpenAI") {
    throw "non-group AI candidate blocked a later live AI group"
}
$unsupportedRejected = $false
try {
    [void](Get-LiveMainGroup ([pscustomobject]@{
        Main = [pscustomobject]@{ type = "Direct"; now = "" }
    }))
} catch {
    $unsupportedRejected = $true
}
if (-not $unsupportedRejected) {
    throw "Get-LiveMainGroup accepted a non-group MATCH target."
}
$routeSnapshot = [pscustomobject]@{
    MainGroup = "Main"
    MainSelection = ""
    AiGroup = "AI"
    AiSelection = "Fixture Node"
}
$customRouteSnapshot = [pscustomobject]@{
    MainGroup = "Main"
    MainSelection = ""
    AiGroup = "Custom Route"
    AiSelection = "Fixture Node"
}
if ($null -eq (Get-CurrentRouteSnapshot $customRouteSnapshot)) {
    throw "Get-CurrentRouteSnapshot re-discovered an explicit custom AI group."
}
$passed = Observe-Route "Google" "https://www.google.com/" "google" "Main" "" "AI" $true $routeSnapshot "http://127.0.0.1:7890"
if (-not $passed) { throw "Observe-Route rejected a matching routed connection." }
$script:RouteSnapshotChanged = $true
$script:ChangedConnectionReads = 0
function Invoke-ControllerJson([string]$Endpoint) {
    if ($Endpoint -eq "/rules") {
        return [pscustomobject]@{ rules = @([pscustomobject]@{ type = "Match"; proxy = "Main" }) }
    }
    if ($Endpoint -eq "/proxies") {
        return [pscustomobject]@{
            proxies = [pscustomobject]@{
                Main = [pscustomobject]@{ type = "LoadBalance"; now = "" }
                AI = [pscustomobject]@{ type = "Selector"; now = "Changed Node" }
                "Changed Node" = [pscustomobject]@{ type = "Shadowsocks" }
            }
        }
    }
    if ($Endpoint -eq "/providers/proxies") {
        return [pscustomobject]@{ providers = [pscustomobject]@{} }
    }
    if ($Endpoint -eq "/connections") {
        $script:ChangedConnectionReads += 1
        if ($script:ChangedConnectionReads -eq 1) {
            return [pscustomobject]@{ connections = @() }
        }
        return [pscustomobject]@{
            connections = @([pscustomobject]@{
                id = "changed-route"
                metadata = [pscustomobject]@{ host = "www.google.com"; network = "tcp"; sourcePort = 45555 }
                chains = @("Fixture Node", "Main")
            })
        }
    }
    throw "unexpected controller endpoint: $Endpoint"
}
$changedSnapshotPassed = Observe-Route "Google" "https://www.google.com/" "google" "Main" "" "AI" $true $routeSnapshot "http://127.0.0.1:7890"
if ($changedSnapshotPassed) { throw "Observe-Route accepted a proxy selection changed during observation." }
'@
    $routeHarness = (@($routeFunctionSources) + $routeHarnessMocks) -join "`r`n"
    [System.IO.File]::WriteAllText($routeHarnessPath, $routeHarness, (New-Object System.Text.UTF8Encoding($true)))
    $routeObservation = Invoke-TestPowerShell $routeHarnessPath @()
    $routeObservationFirstLine = [string](@(
        $routeObservation.Output -split "\r?\n" |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Select-Object -First 1
    )[0])
    Assert-True ($routeObservation.ExitCode -eq 0) (
        "Observe-Route crashed on a matching connection; first_line=$routeObservationFirstLine; " +
        (Get-TestOutputDiagnostic $routeObservation.Output)
    )

    if ($onWindows) {
        $routeSecretCanary =
            "route-stdin-canary-" + [Guid]::NewGuid().ToString("N")
        $routeSecretHasher = [System.Security.Cryptography.SHA256]::Create()
        try {
            $routeSecretCanaryHash = (
                $routeSecretHasher.ComputeHash(
                    [System.Text.Encoding]::UTF8.GetBytes($routeSecretCanary)
                ) | ForEach-Object { $_.ToString("x2") }
            ) -join ""
        } finally {
            $routeSecretHasher.Dispose()
        }
        $redirectProbe = [System.Net.Sockets.TcpListener]::new(
            [System.Net.IPAddress]::Loopback,
            0
        )
        $redirectProbe.Start()
        $routeRedirectPort =
            ([System.Net.IPEndPoint]$redirectProbe.LocalEndpoint).Port
        $redirectProbe.Stop()
        $sinkProbe = [System.Net.Sockets.TcpListener]::new(
            [System.Net.IPAddress]::Loopback,
            0
        )
        $sinkProbe.Start()
        $routeRedirectSinkPort =
            ([System.Net.IPEndPoint]$sinkProbe.LocalEndpoint).Port
        $sinkProbe.Stop()
        $routeRedirectReady = Join-Path $sandbox "route-redirect-ready"
        $routeRedirectSinkReady =
            Join-Path $sandbox "route-redirect-sink-ready"
        $routeRedirectAuthorized =
            Join-Path $sandbox "route-redirect-authorized"
        $routeRedirectObserved =
            Join-Path $sandbox "route-redirect-observed"
        $routeRedirectSinkHit = Join-Path $sandbox "route-redirect-sink-hit"
        $routeRedirectJob = Start-Job -ArgumentList @(
            $routeRedirectPort,
            $routeRedirectSinkPort,
            $routeRedirectReady,
            $routeRedirectAuthorized,
            $routeRedirectObserved,
            $routeSecretCanary
        ) -ScriptBlock {
            param(
                [int]$Port,
                [int]$SinkPort,
                [string]$ReadyPath,
                [string]$AuthorizedPath,
                [string]$ObservedPath,
                [string]$ExpectedSecret
            )
            $listener = [System.Net.Sockets.TcpListener]::new(
                [System.Net.IPAddress]::Loopback,
                $Port
            )
            $listener.Start()
            [System.IO.File]::WriteAllText($ReadyPath, "ready")
            try {
                $client = $listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $reader = [System.IO.StreamReader]::new(
                        $stream,
                        [System.Text.Encoding]::ASCII,
                        $false,
                        1024,
                        $true
                    )
                    [void]$reader.ReadLine()
                    $authorization = ""
                    while ($true) {
                        $line = $reader.ReadLine()
                        if ([string]::IsNullOrEmpty($line)) { break }
                        $separator = $line.IndexOf(":")
                        if ($separator -gt 0 -and
                            $line.Substring(0, $separator).Trim() -eq
                                "Authorization") {
                            $authorization =
                                $line.Substring($separator + 1).Trim()
                        }
                    }
                    [System.IO.File]::WriteAllText(
                        $ObservedPath,
                        (
                            "length={0};bearer={1}" -f
                                $authorization.Length,
                                $authorization.StartsWith(
                                    "Bearer ",
                                    [System.StringComparison]::Ordinal
                                )
                        )
                    )
                    if ($authorization -eq ("Bearer " + $ExpectedSecret)) {
                        [System.IO.File]::WriteAllText(
                            $AuthorizedPath,
                            "authorized"
                        )
                    }
                    $response = (
                        "HTTP/1.1 302 Found`r`n" +
                        "Location: http://127.0.0.1:$SinkPort/leak`r`n" +
                        "Content-Length: 0`r`n" +
                        "Connection: close`r`n`r`n"
                    )
                    $bytes = [System.Text.Encoding]::ASCII.GetBytes($response)
                    $stream.Write($bytes, 0, $bytes.Length)
                    $stream.Flush()
                    $reader.Dispose()
                } finally {
                    $client.Dispose()
                }
            } finally {
                $listener.Stop()
            }
        }
        $routeRedirectSinkJob = Start-Job -ArgumentList @(
            $routeRedirectSinkPort,
            $routeRedirectSinkReady,
            $routeRedirectSinkHit
        ) -ScriptBlock {
            param(
                [int]$Port,
                [string]$ReadyPath,
                [string]$HitPath
            )
            $listener = [System.Net.Sockets.TcpListener]::new(
                [System.Net.IPAddress]::Loopback,
                $Port
            )
            $listener.Start()
            [System.IO.File]::WriteAllText($ReadyPath, "ready")
            try {
                $deadline = [DateTime]::UtcNow.AddSeconds(3)
                while (-not $listener.Pending() -and
                    [DateTime]::UtcNow -lt $deadline) {
                    Start-Sleep -Milliseconds 25
                }
                if ($listener.Pending()) {
                    $client = $listener.AcceptTcpClient()
                    try {
                        [System.IO.File]::WriteAllText($HitPath, "hit")
                    } finally {
                        $client.Dispose()
                    }
                }
            } finally {
                $listener.Stop()
            }
        }
        try {
            $redirectReadyDeadline = [DateTime]::UtcNow.AddSeconds(10)
            while ((-not (Test-Path -LiteralPath $routeRedirectReady) -or
                -not (Test-Path -LiteralPath $routeRedirectSinkReady)) -and
                [DateTime]::UtcNow -lt $redirectReadyDeadline) {
                Start-Sleep -Milliseconds 25
            }
            Assert-True (
                (Test-Path -LiteralPath $routeRedirectReady) -and
                (Test-Path -LiteralPath $routeRedirectSinkReady)
            ) "route redirect fixture did not start"
            $routeRedirectResult = Invoke-TestPowerShellWithStandardInput `
                $routeVerifier `
                @(
                    "-AppHome",
                    $routeProfileThreeHome,
                    "-ControllerUrl",
                    "http://127.0.0.1:$routeRedirectPort",
                    "-SecretStdin",
                    "-ObservationSeconds",
                    "1",
                    "-Json"
                ) `
                $routeSecretCanary
            $routeRedirectResultJson =
                Assert-JsonResult $routeRedirectResult "verify_routes" 1
            Assert-True (
                -not $routeRedirectResult.Output.Contains($routeSecretCanary)
            ) "route verifier exposed its secret after a redirect response"
            Wait-Job $routeRedirectJob -Timeout 5 | Out-Null
            Wait-Job $routeRedirectSinkJob -Timeout 5 | Out-Null
            $routeRedirectObservation =
                if (Test-Path -LiteralPath $routeRedirectObserved) {
                    Get-Content -LiteralPath $routeRedirectObserved -Raw
                } else {
                    "request_not_observed"
                }
            Assert-True (
                Test-Path -LiteralPath $routeRedirectAuthorized
            ) (
                "route redirect fixture did not receive the stdin secret; " +
                "observed=$routeRedirectObservation; " +
                "job=$($routeRedirectJob.State); " +
                "code=$($routeRedirectResultJson.code)"
            )
            Assert-True (
                -not (Test-Path -LiteralPath $routeRedirectSinkHit)
            ) "route verifier followed a controller redirect with its credentials"
            $routeRedirectOutput =
                (Receive-Job $routeRedirectJob -Keep | Out-String) +
                (Receive-Job $routeRedirectSinkJob -Keep | Out-String)
            Assert-True (
                -not $routeRedirectOutput.Contains($routeSecretCanary)
            ) "route redirect fixture logged the controller secret"
        } finally {
            foreach ($routeJob in @(
                $routeRedirectJob,
                $routeRedirectSinkJob
            )) {
                if ($null -eq $routeJob) { continue }
                Stop-Job $routeJob -ErrorAction SilentlyContinue
                Remove-Job $routeJob -Force -ErrorAction SilentlyContinue
            }
        }
        $controllerReadyPath = Join-Path $sandbox "route-controller-ready"
        $fakeCurlArgsPath = Join-Path $sandbox "fake-curl-args.txt"
        $fakeCurlPidsPath = Join-Path $sandbox "fake-curl-pids.txt"
        $fakeCurlEnvironmentHashPrefix =
            Join-Path $sandbox "fake-curl-environment-hashes"
        $portProbe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $portProbe.Start()
        $routeControllerPort = ([System.Net.IPEndPoint]$portProbe.LocalEndpoint).Port
        $portProbe.Stop()
        $routeControllerJob = Start-Job -ArgumentList @(
            $routeControllerPort,
            $controllerReadyPath,
            $fakeCurlArgsPath,
            $fakeCurlPidsPath,
            $routeSecretCanary
        ) -ScriptBlock {
            param(
                [int]$Port,
                [string]$ReadyPath,
                [string]$CurlArgsPath,
                [string]$CurlPidsPath,
                [string]$ExpectedSecret
            )
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
            $listener.Start()
            [System.IO.File]::WriteAllText($ReadyPath, "ready")
            $connectionRequest = 0
            try {
                for ($requestNumber = 0; $requestNumber -lt 24; $requestNumber++) {
                    $client = $listener.AcceptTcpClient()
                    try {
                        $stream = $client.GetStream()
                        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
                        $requestLine = $reader.ReadLine()
                        $headers = @{}
                        while ($true) {
                            $line = $reader.ReadLine()
                            if ([string]::IsNullOrEmpty($line)) { break }
                            $separator = $line.IndexOf(":")
                            if ($separator -gt 0) {
                                $headers[$line.Substring(0, $separator).Trim()] = $line.Substring($separator + 1).Trim()
                            }
                        }
                        $path = $requestLine.Split(" ")[1]
                        $status = "200 OK"
                        if ($headers["Authorization"] -ne
                            ("Bearer " + $ExpectedSecret)) {
                            $status = "401 Unauthorized"
                            $body = '{"error":"unauthorized"}'
                        } elseif ($path -eq "/proxies") {
                            $body = @{
                                proxies = @{
                                    Main = @{ type = "LoadBalance" }
                                    AI = @{ type = "Selector"; now = "Provider AI" }
                                }
                            } | ConvertTo-Json -Depth 6 -Compress
                        } elseif ($path -eq "/rules") {
                            $body = @{
                                rules = @(
                                    @{ type = "DomainSuffix"; payload = "example.com"; proxy = "DIRECT" },
                                    @{ type = "Match"; payload = ""; proxy = "Main" }
                                )
                            } | ConvertTo-Json -Depth 6 -Compress
                        } elseif ($path -eq "/providers/proxies") {
                            $body = @{
                                providers = @{
                                    remote = @{
                                        proxies = @(
                                            @{ name = "Provider Main"; type = "Shadowsocks" },
                                            @{ name = "Provider AI"; type = "Vmess" }
                                        )
                                    }
                                }
                            } | ConvertTo-Json -Depth 6 -Compress
                        } elseif ($path -eq "/configs") {
                            $body = @{ "mixed-port" = 7890 } | ConvertTo-Json -Compress
                        } elseif ($path -eq "/connections") {
                            $connectionRequest += 1
                            if (($connectionRequest % 2) -eq 1) {
                                $connections = @()
                            } else {
                                if ($connectionRequest -eq 2) {
                                    Start-Sleep -Seconds 2
                                }
                                $routeIndex = [int]($connectionRequest / 2) - 1
                                $hosts = @("www.google.com", "openai.com", "www.anthropic.com", "claude.ai")
                                $groups = @("Main", "AI", "AI", "AI")
                                $nodes = @("Provider Main", "Provider AI", "Provider AI", "Provider AI")
                                $curlReadyDeadline =
                                    [DateTime]::UtcNow.AddSeconds(5)
                                do {
                                    $curlPidCount = @(
                                        Get-Content -LiteralPath $CurlPidsPath `
                                            -ErrorAction SilentlyContinue |
                                            Where-Object { $_ -match '^\d+$' }
                                    ).Count
                                    if ($curlPidCount -le $routeIndex) {
                                        Start-Sleep -Milliseconds 25
                                    }
                                } while ($curlPidCount -le $routeIndex -and
                                    [DateTime]::UtcNow -lt
                                        $curlReadyDeadline)
                                if ($curlPidCount -le $routeIndex) {
                                    throw "fake curl did not finish its metadata capture"
                                }
                                $curlArguments = Get-Content -LiteralPath $CurlArgsPath -Raw
                                if ($curlArguments -notmatch '--local-port\s+(\d+)') {
                                    throw "fake curl did not receive a source port"
                                }
                                $sourcePort = [int]$Matches[1]
                                $connections = @(@{
                                    id = "route-$routeIndex"
                                    metadata = @{ host = $hosts[$routeIndex]; network = "tcp"; sourcePort = $sourcePort }
                                    chains = @($nodes[$routeIndex], $groups[$routeIndex])
                                    providerChains = @("remote", "")
                                })
                            }
                            $body = @{ connections = $connections } | ConvertTo-Json -Depth 6 -Compress
                        } else {
                            $status = "404 Not Found"
                            $body = '{"error":"not_found"}'
                        }
                        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                        $responseHead = "HTTP/1.1 $status`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
                        $headBytes = [System.Text.Encoding]::ASCII.GetBytes($responseHead)
                        $stream.Write($headBytes, 0, $headBytes.Length)
                        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
                        $stream.Flush()
                        $reader.Dispose()
                    } finally {
                        $client.Dispose()
                    }
                }
            } finally {
                $listener.Stop()
            }
        }
        $fakeCurlDirectory = Join-Path $sandbox "fake-curl"
        New-Item -ItemType Directory -Path $fakeCurlDirectory -Force | Out-Null
        $fakeCurlPath = Join-Path $fakeCurlDirectory "curl.exe"
        $fakeCurlSource = @'
using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
public static class FakeCurl {
    private static string Hash(string value) {
        using (SHA256 sha = SHA256.Create()) {
            byte[] digest = sha.ComputeHash(Encoding.UTF8.GetBytes(value));
            StringBuilder output = new StringBuilder();
            foreach (byte item in digest) output.Append(item.ToString("x2"));
            return output.ToString();
        }
    }

    public static int Main(string[] args) {
        if (Environment.GetEnvironmentVariable("CLAUDE_EASY_TEST_CURL_IMMEDIATE_SUCCESS") == "1") {
            return 0;
        }
        string subscriptionOutput = Environment.GetEnvironmentVariable(
            "CLAUDE_EASY_TEST_SUBSCRIPTION_CURL_OUTPUT"
        );
        if (subscriptionOutput != null) {
            string config = Console.In.ReadToEnd();
            File.AppendAllText(
                Environment.GetEnvironmentVariable("CLAUDE_EASY_TEST_SUBSCRIPTION_CURL_CONFIG_PATH"),
                Convert.ToBase64String(Encoding.UTF8.GetBytes(config)) + Environment.NewLine
            );
            File.AppendAllText(
                Environment.GetEnvironmentVariable("CLAUDE_EASY_TEST_CURL_ARGS_PATH"),
                String.Join(" ", args) + Environment.NewLine
            );
            Console.OutputEncoding = new UTF8Encoding(false);
            Console.Write(subscriptionOutput);
            return 0;
        }
        int processId = Process.GetCurrentProcess().Id;
        File.WriteAllText(
            Environment.GetEnvironmentVariable("CLAUDE_EASY_TEST_CURL_ARGS_PATH"),
            String.Join(" ", args)
        );
        string hashPrefix = Environment.GetEnvironmentVariable(
            "CLAUDE_EASY_TEST_CURL_ENV_HASH_PREFIX"
        );
        int windowLength = __CANARY_LENGTH__;
        using (StreamWriter writer = new StreamWriter(
            hashPrefix + "." + processId.ToString(),
            false,
            new UTF8Encoding(false)
        )) {
            foreach (DictionaryEntry item in Environment.GetEnvironmentVariables()) {
                foreach (string value in new string[] {
                    Convert.ToString(item.Key),
                    Convert.ToString(item.Value)
                }) {
                    if (value == null || value.Length < windowLength) continue;
                    for (int index = 0;
                        index + windowLength <= value.Length;
                        index += 1) {
                        writer.WriteLine(Hash(value.Substring(index, windowLength)));
                    }
                }
            }
        }
        File.AppendAllText(
            Environment.GetEnvironmentVariable("CLAUDE_EASY_TEST_CURL_PIDS_PATH"),
            processId.ToString() + Environment.NewLine
        );
        Thread.Sleep(10000);
        return 0;
    }
}
'@
        $fakeCurlSource = $fakeCurlSource.Replace(
            "__CANARY_LENGTH__",
            [string]$routeSecretCanary.Length
        )
        $fakeCurlSourcePath = Join-Path $fakeCurlDirectory "FakeCurl.cs"
        [System.IO.File]::WriteAllText(
            $fakeCurlSourcePath,
            $fakeCurlSource,
            (New-Object System.Text.UTF8Encoding($false))
        )
        $compilerCandidates = @(
            (Join-Path $env:WINDIR "Microsoft.NET/Framework64/v4.0.30319/csc.exe"),
            (Join-Path $env:WINDIR "Microsoft.NET/Framework/v4.0.30319/csc.exe")
        )
        $csharpCompiler = $compilerCandidates |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($csharpCompiler)) {
            throw "Windows C# compiler was not found"
        }
        & $csharpCompiler /nologo /target:exe "/out:$fakeCurlPath" $fakeCurlSourcePath
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fakeCurlPath -PathType Leaf)) {
            throw "failed to compile fake curl.exe"
        }
        $previousPath = $env:PATH
        $previousCurlArgsPath = $env:CLAUDE_EASY_TEST_CURL_ARGS_PATH
        $previousCurlPidsPath = $env:CLAUDE_EASY_TEST_CURL_PIDS_PATH
        $previousCurlEnvironmentHashPrefix =
            $env:CLAUDE_EASY_TEST_CURL_ENV_HASH_PREFIX
        $fakeCurlPids = @()
        $routeSuccessProcess = $null
        try {
            $readyDeadline = [DateTime]::UtcNow.AddSeconds(10)
            while (-not (Test-Path -LiteralPath $controllerReadyPath) -and [DateTime]::UtcNow -lt $readyDeadline) {
                Start-Sleep -Milliseconds 100
            }
            Assert-True (Test-Path -LiteralPath $controllerReadyPath) "route success controller did not start: $(Receive-Job $routeControllerJob -Keep | Out-String)"
            $env:PATH = $fakeCurlDirectory + [System.IO.Path]::PathSeparator + $previousPath
            $env:CLAUDE_EASY_TEST_CURL_ARGS_PATH = $fakeCurlArgsPath
            $env:CLAUDE_EASY_TEST_CURL_PIDS_PATH = $fakeCurlPidsPath
            $env:CLAUDE_EASY_TEST_CURL_ENV_HASH_PREFIX =
                $fakeCurlEnvironmentHashPrefix
            [System.IO.File]::WriteAllText(
                (Join-Path $routeProfileThreeHome "clash-verge.yaml"),
                "external-controller: 127.0.0.1:$routeControllerPort`nsecret: $routeSecretCanary`n",
                (New-Object System.Text.UTF8Encoding($false))
            )
            $routeSuccessProcess = New-TestPowerShellProcess $routeVerifier @(
                "-AppHome", $routeProfileThreeHome,
                "-ObservationSeconds", "5",
                "-Json"
            )
            Assert-True ($routeSuccessProcess.Start()) "route verifier did not start"
            $routeSuccessProcess.StandardInput.Close()
            $routeVerifierCommandLine =
                Get-WindowsProcessCommandLine $routeSuccessProcess.Id
            Assert-True (
                -not [string]::IsNullOrWhiteSpace($routeVerifierCommandLine) -and
                -not $routeVerifierCommandLine.Contains($routeSecretCanary)
            ) "route verifier exposed its controller secret in the process command line"
            $curlStartDeadline = [DateTime]::UtcNow.AddSeconds(10)
            while (-not (Test-Path -LiteralPath $fakeCurlPidsPath -PathType Leaf) -and
                -not $routeSuccessProcess.HasExited -and
                [DateTime]::UtcNow -lt $curlStartDeadline) {
                Start-Sleep -Milliseconds 25
            }
            $routeStartDiagnostic = ""
            if ($routeSuccessProcess.HasExited) {
                $routeStartOutput =
                    $routeSuccessProcess.StandardOutput.ReadToEnd() +
                    $routeSuccessProcess.StandardError.ReadToEnd()
                try {
                    $routeStartResult = $routeStartOutput | ConvertFrom-Json
                    $routeStartDiagnostic =
                        "; exit=$($routeSuccessProcess.ExitCode); " +
                        "code=$($routeStartResult.code); " +
                        "summary=$($routeStartResult.summary_zh)"
                } catch {
                    $routeStartDiagnostic =
                        "; exit=$($routeSuccessProcess.ExitCode); output=" +
                        (Get-TestOutputDiagnostic $routeStartOutput)
                }
            }
            Assert-True (
                Test-Path -LiteralPath $fakeCurlPidsPath -PathType Leaf
            ) ("route verifier did not start the long-running curl fixture" +
                $routeStartDiagnostic)
            $firstFakeCurlPid = [int](
                Get-Content -LiteralPath $fakeCurlPidsPath |
                    Where-Object { $_ -match '^\d+$' } |
                    Select-Object -First 1
            )
            $fakeCurlCommandLine =
                Get-WindowsProcessCommandLine $firstFakeCurlPid
            Assert-True (
                -not [string]::IsNullOrWhiteSpace($fakeCurlCommandLine) -and
                -not $fakeCurlCommandLine.Contains($routeSecretCanary)
            ) "route verifier copied its controller secret into a child command line"
            Assert-True (
                -not $routeSuccessProcess.HasExited
            ) "route verifier ended before long-running metadata could be inspected"
            Assert-True (
                $routeSuccessProcess.WaitForExit(30000)
            ) "route verifier success fixture timed out"
            $routeSuccessOutput =
                $routeSuccessProcess.StandardOutput.ReadToEnd() +
                $routeSuccessProcess.StandardError.ReadToEnd()
            $routeSuccess = [pscustomobject]@{
                Output = $routeSuccessOutput
                ExitCode = $routeSuccessProcess.ExitCode
            }
            Assert-True (
                -not $routeSuccessOutput.Contains($routeSecretCanary)
            ) "route verifier exposed its controller secret in output"
            $routeSuccessResult = Assert-JsonResult $routeSuccess "verify_routes" 0
            Assert-True ($routeSuccessResult.code -eq "routes_verified") "route verifier success code mismatch"
            Assert-True ($routeSuccessResult.profile -eq 3) "route verifier success omitted the saved profile"
            Assert-True (@($routeSuccessResult.checks).Count -eq 4) "route verifier did not report all four route checks"
            Assert-True (@($routeSuccessResult.checks | Where-Object { -not [bool]$_.ok }).Count -eq 0) "route verifier reported a failed check on its success path"
            Assert-True (Test-Path -LiteralPath $fakeCurlPidsPath -PathType Leaf) "route verifier did not start the hanging curl fixture"
            $fakeCurlPids = @(
                Get-Content -LiteralPath $fakeCurlPidsPath |
                    Where-Object { $_ -match '^\d+$' } |
                    ForEach-Object { [int]$_ }
            )
            Assert-True ($fakeCurlPids.Count -eq 4) "route verifier did not create one isolated curl process per route"
            Assert-True (
                -not (Get-Content -LiteralPath $fakeCurlArgsPath -Raw).Contains(
                    $routeSecretCanary
                )
            ) "route verifier copied its controller secret into a child argument log"
            $capturedRouteCurlArguments = Get-Content -LiteralPath $fakeCurlArgsPath -Raw
            Assert-True (
                $capturedRouteCurlArguments -match '(?:^|\s)-q(?:\s|$)' -and
                $capturedRouteCurlArguments -match '--fail(?:\s|$)' -and
                $capturedRouteCurlArguments -match '--proxy\s+http://127\.0\.0\.1:7890(?:\s|$)'
            ) "route verifier did not isolate curl and use the live Mihomo proxy"
            $fakeCurlEnvironmentHashFiles = @(
                Get-ChildItem -LiteralPath $sandbox `
                    -Filter "fake-curl-environment-hashes.*" -File
            )
            Assert-True (
                $fakeCurlEnvironmentHashFiles.Count -eq 4
            ) "route verifier did not capture each child environment safely"
            Assert-True (
                @($fakeCurlEnvironmentHashFiles | Where-Object {
                    @(Get-Content -LiteralPath $_.FullName) -contains
                        $routeSecretCanaryHash
                }).Count -eq 0
            ) "route verifier copied its controller secret into a child environment"
            $routeControllerOutput =
                Receive-Job $routeControllerJob -Keep | Out-String
            Assert-True (
                -not $routeControllerOutput.Contains($routeSecretCanary)
            ) "route controller fixture logged the controller secret"
            $curlExitDeadline = [DateTime]::UtcNow.AddSeconds(5)
            do {
                $survivingCurlPids = @(
                    $fakeCurlPids |
                        Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) }
                )
                if ($survivingCurlPids.Count -gt 0) { Start-Sleep -Milliseconds 25 }
            } while ($survivingCurlPids.Count -gt 0 -and [DateTime]::UtcNow -lt $curlExitDeadline)
            Assert-True ($survivingCurlPids.Count -eq 0) "route verifier left hanging curl processes after observation"
        } finally {
            $env:PATH = $previousPath
            $env:CLAUDE_EASY_TEST_CURL_ARGS_PATH = $previousCurlArgsPath
            $env:CLAUDE_EASY_TEST_CURL_PIDS_PATH = $previousCurlPidsPath
            $env:CLAUDE_EASY_TEST_CURL_ENV_HASH_PREFIX =
                $previousCurlEnvironmentHashPrefix
            if ($null -ne $routeSuccessProcess) {
                if (-not $routeSuccessProcess.HasExited) {
                    try { $routeSuccessProcess.Kill() } catch { }
                }
                $routeSuccessProcess.Dispose()
            }
            foreach ($fakeCurlPid in $fakeCurlPids) {
                $fakeCurlProcess = Get-Process -Id $fakeCurlPid -ErrorAction SilentlyContinue
                if ($null -ne $fakeCurlProcess) {
                    Stop-Process -Id $fakeCurlPid -Force
                    [void]$fakeCurlProcess.WaitForExit(5000)
                }
            }
            if ($null -ne $routeControllerJob) {
                Stop-Job $routeControllerJob -ErrorAction SilentlyContinue
                Remove-Job $routeControllerJob -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $brokenPackageRoot = Join-Path $sandbox "broken-package"
    New-Item -ItemType Directory -Path $brokenPackageRoot -Force | Out-Null
    $brokenInstaller = Join-Path $brokenPackageRoot "install_windows.ps1"
    Copy-Item -LiteralPath $installer -Destination $brokenInstaller
    $missingContract = Invoke-TestPowerShell $brokenInstaller @("-AppHome", $jsonShowCase, "-Json")
    $missingContractResult = Assert-JsonResult $missingContract "install" 6
    Assert-True ($missingContractResult.code -eq "incomplete_package") "missing result contract was not structured"

    $brokenWindows = Join-Path $brokenPackageRoot "windows"
    New-Item -ItemType Directory -Path $brokenWindows -Force | Out-Null
    Copy-Item -LiteralPath $resultContract -Destination (Join-Path $brokenWindows "result_contract.ps1")
    $missingModules = Invoke-TestPowerShell $brokenInstaller @("-AppHome", $jsonShowCase, "-Json")
    $missingModulesResult = Assert-JsonResult $missingModules "install" 6
    Assert-True ($missingModulesResult.code -eq "incomplete_package") "missing installer modules were not structured"

    $missingEnginePackageParent = Join-Path $sandbox "missing-engine-package"
    New-Item -ItemType Directory -Path $missingEnginePackageParent -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root "claude-easy") -Destination $missingEnginePackageParent -Recurse
    $missingEnginePackage = Join-Path $missingEnginePackageParent "claude-easy"
    $missingEngineInstaller = Join-Path (Join-Path $missingEnginePackage "scripts") "install_windows.ps1"
    Remove-Item -LiteralPath (Join-Path (Join-Path $missingEnginePackage "scripts/windows") "clash_verge_global.js") -Force
    $missingEngineHome = Join-Path $sandbox "missing-engine-home"
    New-Item -ItemType Directory -Path $missingEngineHome -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $missingEngineHome "keep.txt"), "unchanged")
    $missingEngineBefore = Get-TreeContentSnapshot $missingEngineHome
    $missingEngineResult = Assert-JsonResult (Invoke-TestPowerShell $missingEngineInstaller @(
        "-AppHome", $missingEngineHome,
        "-UsageProfile", "1",
        "-MihomoPath", $fakeCore,
        "-Json"
    )) "install" 6
    Assert-True ($missingEngineResult.code -eq "incomplete_package") "missing global script did not report incomplete_package"
    Assert-True ((Get-TreeContentSnapshot $missingEngineHome) -ceq $missingEngineBefore) "missing global script changed AppHome before package validation"

    $brokenUninstaller = Join-Path $brokenPackageRoot "uninstall_windows.ps1"
    $brokenVerifier = Join-Path $brokenPackageRoot "verify_routes.ps1"
    Copy-Item -LiteralPath $uninstaller -Destination $brokenUninstaller
    Copy-Item -LiteralPath $routeVerifier -Destination $brokenVerifier
    Copy-Item -LiteralPath $installerModuleRoot -Destination $brokenWindows -Recurse
    $corruptContractText = "function Broken-ClaudeEasyContract {`r`n"
    [System.IO.File]::WriteAllText((Join-Path $brokenWindows "result_contract.ps1"), $corruptContractText)
    [System.IO.File]::WriteAllText((Join-Path $brokenPackageRoot "result_contract.ps1"), $corruptContractText)
    $corruptContractHomeBefore = Get-TreeContentSnapshot $jsonShowCase
    $corruptInstallContract = Assert-JsonResult (Invoke-TestPowerShell $brokenInstaller @(
        "-AppHome", $jsonShowCase, "-Json"
    )) "install" 6
    $corruptUninstallContract = Assert-JsonResult (Invoke-TestPowerShell $brokenUninstaller @(
        "-AppHome", $jsonShowCase, "-Json"
    )) "uninstall" 6
    $corruptVerifyContract = Assert-JsonResult (Invoke-TestPowerShell $brokenVerifier @(
        "-ObservationSeconds", "1", "-Json"
    )) "verify_routes" 6
    foreach ($corruptContractResult in @($corruptInstallContract, $corruptUninstallContract, $corruptVerifyContract)) {
        Assert-True ($corruptContractResult.code -eq "incomplete_package") "corrupt result contract did not report incomplete_package"
    }
    Assert-True ((Get-TreeContentSnapshot $jsonShowCase) -ceq $corruptContractHomeBefore) "corrupt result contract changed AppHome"
    Remove-Item -LiteralPath (Join-Path $brokenWindows "result_contract.ps1") -Force
    Remove-Item -LiteralPath (Join-Path $brokenPackageRoot "result_contract.ps1") -Force
    Assert-JsonResult (Invoke-TestPowerShell $brokenUninstaller @("-AppHome", $jsonShowCase, "-Json")) "uninstall" 6 | Out-Null
    Assert-JsonResult (Invoke-TestPowerShell $brokenVerifier @("-ObservationSeconds", "0", "-Json")) "verify_routes" 6 | Out-Null

    $corruptModulePackageParent = Join-Path $sandbox "corrupt-module-package"
    New-Item -ItemType Directory -Path $corruptModulePackageParent -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root "claude-easy") -Destination $corruptModulePackageParent -Recurse
    $corruptModulePackage = Join-Path $corruptModulePackageParent "claude-easy"
    $corruptModuleScripts = Join-Path $corruptModulePackage "scripts"
    $corruptModuleCommon = Join-Path (Join-Path $corruptModuleScripts "windows/install_windows") "common.ps1"
    $corruptModuleCommonText = [System.IO.File]::ReadAllText($corruptModuleCommon)
    foreach ($missingApi in @("Write-Info", "Write-ClaudeEasyHumanText")) {
        [System.IO.File]::WriteAllText(
            $corruptModuleCommon,
            $corruptModuleCommonText.Replace("function $missingApi", "function Missing-$missingApi")
        )
        $missingApiHome = Join-Path $sandbox ("missing-api-" + $missingApi)
        New-Item -ItemType Directory -Path $missingApiHome -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $missingApiHome "keep.txt"), "unchanged")
        $missingApiBefore = Get-TreeContentSnapshot $missingApiHome
        $missingApiResult = Assert-JsonResult (Invoke-TestPowerShell (Join-Path $corruptModuleScripts "install_windows.ps1") @(
            "-AppHome", $missingApiHome, "-Json"
        )) "install" 6
        Assert-True ($missingApiResult.code -eq "incomplete_package") "missing $missingApi did not report incomplete_package"
        Assert-True ((Get-TreeContentSnapshot $missingApiHome) -ceq $missingApiBefore) "missing $missingApi changed AppHome"
    }
    [System.IO.File]::WriteAllText($corruptModuleCommon, $corruptModuleCommonText)
    [System.IO.File]::WriteAllText(
        (Join-Path (Join-Path $corruptModuleScripts "windows/install_windows") "profiles.ps1"),
        'throw "C:\Users\private\module-load-canary"'
    )
    $corruptModuleHome = Join-Path $sandbox "corrupt-module-home"
    New-Item -ItemType Directory -Path $corruptModuleHome -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $corruptModuleHome "keep.txt"), "unchanged")
    $corruptModuleHomeBefore = Get-TreeContentSnapshot $corruptModuleHome
    $corruptModuleInstall = Assert-JsonResult (Invoke-TestPowerShell (Join-Path $corruptModuleScripts "install_windows.ps1") @(
        "-AppHome", $corruptModuleHome, "-Json"
    )) "install" 6
    $corruptModuleUninstall = Assert-JsonResult (Invoke-TestPowerShell (Join-Path $corruptModuleScripts "uninstall_windows.ps1") @(
        "-AppHome", $corruptModuleHome, "-Json"
    )) "uninstall" 6
    Assert-True ($corruptModuleInstall.code -eq "incomplete_package" -and $corruptModuleUninstall.code -eq "incomplete_package") "corrupt Windows module did not report incomplete_package"
    Assert-True ((Get-TreeContentSnapshot $corruptModuleHome) -ceq $corruptModuleHomeBefore) "corrupt Windows module changed AppHome"

    $missingLightConfigCase = Join-Path $sandbox "missing-light-config-case"
    New-Item -ItemType Directory -Path $missingLightConfigCase -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $missingLightConfigCase "profiles.yaml"),
        "items:`n- uid: R-light-missing`n  type: remote`n  option:`n    allow_auto_update: true`n"
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $missingLightConfigCase "verge.yaml"), "enable_tun_mode: false`n"
    )
    foreach ($lightProfile in @(1, 2)) {
        $lightInstall = Invoke-TestPowerShell $installer @(
            "-AppHome", $missingLightConfigCase, "-UsageProfile", "$lightProfile",
            "-MihomoPath", $fakeCore
        )
        Assert-True ($lightInstall.ExitCode -eq 0) "profile $lightProfile rejected an unchanged missing config.yaml; $(Get-TestOutputDiagnostic $lightInstall.Output)"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $missingLightConfigCase "config.yaml"))) "profile $lightProfile created config.yaml"
    }
    $fullInstall = Invoke-TestPowerShell $installer @(
        "-AppHome", $missingLightConfigCase, "-UsageProfile", "3", "-MihomoPath", $fakeCore
    )
    Assert-True ($fullInstall.ExitCode -eq 0) "profile 3 could not upgrade an unchanged missing config.yaml; $(Get-TestOutputDiagnostic $fullInstall.Output)"
    Assert-True (Test-Path -LiteralPath (Join-Path $missingLightConfigCase "config.yaml") -PathType Leaf) "profile 3 upgrade did not create config.yaml"

    $lightCase = Join-Path $sandbox "light-profile-case"
    New-Item -ItemType Directory -Path $lightCase -Force | Out-Null
    $lightConfig = "ipv6: true`ntun:`n  enable: false`n"
    $lightVerge = "enable_tun_mode: false`n"
    [System.IO.File]::WriteAllText((Join-Path $lightCase "config.yaml"), $lightConfig)
    [System.IO.File]::WriteAllText((Join-Path $lightCase "verge.yaml"), $lightVerge)
    [System.IO.File]::WriteAllText(
        (Join-Path $lightCase "profiles.yaml"),
        "items:`n- uid: R-light`n  type: remote`n  option:`n    allow_auto_update: true`n"
    )
    $profileOne = Invoke-TestPowerShell $installer @("-AppHome", $lightCase, "-UsageProfile", "1", "-MihomoPath", $fakeCore)
    Assert-True ($profileOne.ExitCode -eq 0) "profile 1 installer failed; $(Get-TestOutputDiagnostic $profileOne.Output)"
    Assert-True ((Get-Content -LiteralPath (Join-Path $lightCase "config.yaml") -Raw) -eq $lightConfig) "profile 1 modified config.yaml"
    $profileOneVerge = Get-Content -LiteralPath (Join-Path $lightCase "verge.yaml") -Raw
    Assert-True ($profileOneVerge -match '(?m)^enable_global_hotkey:\s+true\s*$') "profile 1 did not enable the subscription reactivation shortcut"
    Assert-True ($profileOneVerge -match '(?m)^\s+-\s+reactivate_profiles,CTRL\+ALT\+SHIFT\+F24\s*$') "profile 1 did not install the subscription reactivation shortcut"
    Assert-True ((Get-ClashVergeReactivationShortcut $profileOneVerge) -eq "CTRL+ALT+SHIFT+F24") "profile 1 reactivation shortcut could not be read back"
    $lightScript = Join-Path (Join-Path $lightCase "profiles") "Script.js"
    Assert-True (Test-Path -LiteralPath $lightScript -PathType Leaf) "profile 1 did not install the shared subscription patch"
    $profileOneScript = Read-TestUtf8Text $lightScript
    Assert-True ($profileOneScript.Contains("const CLAUDE_EASY_USAGE_PROFILE = 1;")) "profile 1 script has the wrong usage profile"
    Assert-True ($profileOneScript.Contains("cnDomainProvider")) "profile 1 script omitted the China-domain provider"
    Assert-True (
        (Get-Content -LiteralPath (Join-Path $lightCase "profiles.yaml") -Raw) -match
        '(?m)^\s+allow_auto_update:\s+false\s*$'
    ) "profile 1 did not disable remote subscription auto-update"
    Assert-True (
        Test-Path -LiteralPath (Join-Path $lightCase "claude-easy-auto-update-state.json") -PathType Leaf
    ) "profile 1 did not preserve auto-update restore ownership"
    $savedProfileOne = Get-Content -LiteralPath (Join-Path $lightCase "claude-easy-usage-profile.json") -Raw | ConvertFrom-Json
    Assert-True ([int]$savedProfileOne.Profile -eq 1) "profile 1 was not saved"
    $profileTwo = Invoke-TestPowerShell $installer @("-AppHome", $lightCase, "-UsageProfile", "2", "-MihomoPath", $fakeCore)
    Assert-True ($profileTwo.ExitCode -eq 0) "profile 2 installer failed; $(Get-TestOutputDiagnostic $profileTwo.Output)"
    Assert-True ((Get-Content -LiteralPath (Join-Path $lightCase "config.yaml") -Raw) -eq $lightConfig) "profile 2 modified config.yaml"
    Assert-True ((Get-Content -LiteralPath (Join-Path $lightCase "verge.yaml") -Raw) -ceq $profileOneVerge) "profile 2 duplicated or changed the reactivation shortcut"
    Assert-True (Test-Path -LiteralPath $lightScript -PathType Leaf) "profile 2 removed the shared subscription patch"
    $profileTwoScript = Read-TestUtf8Text $lightScript
    Assert-True ($profileTwoScript.Contains("const CLAUDE_EASY_USAGE_PROFILE = 2;")) "profile 2 script has the wrong usage profile"
    Assert-True ($profileTwoScript.Contains("cnDomainProvider")) "profile 2 script omitted the China-domain provider"
    Assert-True (
        (Get-Content -LiteralPath (Join-Path $lightCase "profiles.yaml") -Raw) -match
        '(?m)^\s+allow_auto_update:\s+false\s*$'
    ) "profile 2 re-enabled remote subscription auto-update"
    $savedProfileTwo = Get-Content -LiteralPath (Join-Path $lightCase "claude-easy-usage-profile.json") -Raw | ConvertFrom-Json
    Assert-True ([int]$savedProfileTwo.Profile -eq 2) "profile 2 was not saved"

    foreach ($lightProfile in @(1, 2)) {
        $invalidLightCase = Join-Path $sandbox "invalid-light-profile-$lightProfile"
        New-Item -ItemType Directory -Path $invalidLightCase -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $invalidLightCase "config.yaml"),
            "ipv6: true`ntun:`n  enable: false`n"
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $invalidLightCase "verge.yaml"),
            "enable_tun_mode: false`n--- # second document`nfriend: true`n"
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $invalidLightCase "profiles.yaml"),
            "items:`n- uid: R-light`n  type: remote`n  option:`n    allow_auto_update: true`n"
        )
        $invalidLightBefore = Get-TreeContentSnapshot $invalidLightCase
        $invalidLightInstall = Invoke-TestPowerShell $installer @(
            "-AppHome", $invalidLightCase,
            "-UsageProfile", "$lightProfile",
            "-MihomoPath", $fakeCore,
            "-Json"
        )
        Assert-True ($invalidLightInstall.ExitCode -eq 1) "profile $lightProfile accepted multi-document verge.yaml"
        Assert-True (
            (Get-TreeContentSnapshot $invalidLightCase) -ceq $invalidLightBefore
        ) "profile $lightProfile changed AppHome after rejecting multi-document verge.yaml"
    }

    $invalidSafeUpdateStateCase = Join-Path $sandbox "invalid-safe-update-state-case"
    New-Item -ItemType Directory -Path $invalidSafeUpdateStateCase -Force | Out-Null
    New-Item -ItemType Directory -Path (
        Join-Path $invalidSafeUpdateStateCase "claude-easy-safe-update.json"
    ) -Force | Out-Null
    $invalidSafeUpdateStateBefore = Get-TreeContentSnapshot $invalidSafeUpdateStateCase
    $invalidSafeUpdateStateResult = Assert-JsonResult (Invoke-TestPowerShell $installer @(
        "-AppHome", $invalidSafeUpdateStateCase,
        "-UsageProfile", "1",
        "-MihomoPath", $fakeCore,
        "-Json"
    )) "install" 1
    Assert-True (
        $invalidSafeUpdateStateResult.code -eq "safe_update_state_read_failed"
    ) "invalid safe-update state did not return a structured read failure"
    Assert-True (
        (Get-TreeContentSnapshot $invalidSafeUpdateStateCase) -ceq $invalidSafeUpdateStateBefore
    ) "invalid safe-update state changed AppHome"
    $invalidSafeUpdateStateRetry = Assert-JsonResult (Invoke-TestPowerShell $installer @(
        "-AppHome", $invalidSafeUpdateStateCase,
        "-ShowUsageProfile",
        "-Json"
    )) "install" 0
    Assert-True (
        $invalidSafeUpdateStateRetry.code -eq "usage_profile_shown"
    ) "invalid safe-update state failure retained the AppHome lock or blocked an unrelated read"

    $downgradeCase = Join-Path $sandbox "downgrade-without-uninstall-case"
    New-Item -ItemType Directory -Path $downgradeCase -Force | Out-Null
    $downgradeStatePath = Join-Path $downgradeCase "claude-easy-usage-profile.json"
    $downgradeState = '{"Version":1,"Profile":3}' + "`r`n"
    [System.IO.File]::WriteAllText($downgradeStatePath, $downgradeState)
    $downgradeResult = Invoke-TestPowerShell $installer @("-AppHome", $downgradeCase, "-UsageProfile", "1", "-MihomoPath", $fakeCore)
    Assert-True ($downgradeResult.ExitCode -eq 1) "profile 3 downgrade proceeded without the required safe uninstall"
    Assert-True ($downgradeResult.Output.Contains("先运行安全卸载")) "profile 3 downgrade rejection did not explain the required safe uninstall"
    Assert-True ((Get-Content -LiteralPath $downgradeStatePath -Raw) -eq $downgradeState) "rejected downgrade changed the saved usage profile"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path (Join-Path $downgradeCase "profiles") "Script.js"))) "rejected downgrade changed the global script"

    $unitStage = Set-YamlTopLevelScalar "ipv6 : true`ntun: null`n" "ipv6" "false"
    Assert-True ($unitStage -match '(?m)^tun:') "scalar transform lost tun node: $($unitStage | ConvertTo-Json -Compress)"
    $unitBlock = @(New-ManagedTunBlock)
    Assert-True ($unitBlock.Count -gt 2) "managed tun block collapsed: $($unitBlock | ConvertTo-Json -Compress)"
    $unitLines = @(Split-YamlLines $unitStage)
    Assert-True ($unitLines.Count -gt 1) "line splitter collapsed: $($unitLines | ConvertTo-Json -Compress)"
    $unitJoined = Join-YamlLines -Lines @($unitLines + $unitBlock)
    Assert-True ($unitJoined -match '(?m)^tun:') "line joiner collapsed: $($unitJoined | ConvertTo-Json -Compress)"
    $unitReplaced = @(Replace-YamlRange -Lines $unitLines -Start 1 -End 2 -Replacement $unitBlock)
    Assert-True ($unitReplaced.Count -gt 2) "range replacement collapsed: $($unitReplaced | ConvertTo-Json -Compress)"
    $unitOutput = Set-YamlTunMapping $unitStage
    $unitDebug = $unitOutput | ConvertTo-Json -Compress
    Assert-True ($unitOutput -match '(?m)^tun:') "unit transform lost tun node: type=$($unitOutput.GetType().FullName) count=$($unitOutput.Count) $(Get-TestOutputDiagnostic $unitDebug)"
    Test-GeneratedYaml $unitOutput "config.yaml" | Out-Null
    Test-GeneratedYaml (Set-YamlTunMapping "ipv6: false`n") "config.yaml" | Out-Null

    $quotedInput = "`"ipv6`" : true`n`"tun`": null`n"
    $quotedOutput = Set-YamlTunMapping (Set-YamlTopLevelScalar $quotedInput "ipv6" "false")
    Assert-True ([regex]::Matches($quotedOutput, '(?m)^["'']?tun["'']?\s*:').Count -eq 1) "quoted tun key was duplicated"
    Assert-True ([regex]::Matches($quotedOutput, '(?m)^["'']?ipv6["'']?\s*:').Count -eq 1) "quoted ipv6 key was duplicated"

    $commented = Set-YamlTopLevelScalar "ipv6: true # keep this note`n" "ipv6" "false"
    Assert-True ($commented.Contains("# keep this note")) "top-level scalar edit discarded an inline comment"
    $anchorRejected = $false
    try { Set-YamlTunMapping "tun: &defaults`n  enable: false`n" | Out-Null } catch { $anchorRejected = $true }
    Assert-True $anchorRejected "anchored tun mapping was modified instead of rejected"
    $scalarAnchorRejected = $false
    try { Set-YamlTopLevelScalar "enable_tun_mode: &shared false`nfriend: *shared`n" "enable_tun_mode" "true" | Out-Null } catch { $scalarAnchorRejected = $true }
    Assert-True $scalarAnchorRejected "anchored top-level scalar was modified and left a dangling alias"
    $commentedDocumentRejected = $false
    try { Test-GeneratedYaml "friend: true`n--- # second document`nother: false`n" "verge.yaml" | Out-Null } catch { $commentedDocumentRejected = $true }
    Assert-True $commentedDocumentRejected "commented YAML document marker was ignored"

    $profilesIndexInput = @'
current: R-first
items:
- uid: R-first
  type: remote
  name: First
  updated: null
  option:
    update_interval: 1440
    allow_auto_update: true
- uid: L-local
  type: local
  name: Local
- uid: R-second
  type: remote
  name: Second
  updated: 200
  option: null
'@
    $unsafeTypeInputs = @(
        "items:`n- uid: R-anchor-type`n  type: &kind remote`n",
        "items:`n- uid: R-tagged-type`n  type: !!str remote`n",
        "items:`n- uid: R-alias-type`n  kind: &kind remote`n  type: *kind`n",
        "items:`n- uid: R-flow-type`n  type: [remote]`n",
        ('items:' + "`n- uid: R-escaped-type`n" + '  type: "remo\u0074e"' + "`n")
    )
    foreach ($unsafeTypeInput in $unsafeTypeInputs) {
        $unsafeTypeRejected = $false
        try { Get-RemoteSubscriptionProfileItems @(Split-YamlLines $unsafeTypeInput) | Out-Null } catch { $unsafeTypeRejected = $true }
        Assert-True $unsafeTypeRejected "complex YAML type scalar was not rejected"
    }
    foreach ($quotedType in @("'remote'", '"remote"')) {
        $quotedTypeInput = "items:`n- uid: R-quoted-type`n  type: $quotedType`n"
        $quotedTypeOutput = Set-RemoteSubscriptionAutoUpdateDisabled $quotedTypeInput
        Assert-RemoteSubscriptionAutoUpdateDisabled $quotedTypeOutput
    }
    $unsafeKeyInputs = @(
        ('items:' + "`n- uid: R-escaped-option`n  type: remote`n" + '  "op\u0074ion":' + "`n    update_interval: 1440`n    allow_auto_update: true`n"),
        ('items:' + "`n- uid: R-escaped-auto-update`n  type: remote`n  option:`n" + '    "allow_auto_\u0075pdate": true' + "`n"),
        ('items:' + "`n" + '- "op\u0074ion":' + "`n    update_interval: 1440`n    allow_auto_update: true`n  uid: R-escaped-first-option`n  type: remote`n")
    )
    foreach ($unsafeKeyInput in $unsafeKeyInputs) {
        $unsafeKeyRejected = $false
        try { Set-RemoteSubscriptionAutoUpdateDisabled $unsafeKeyInput | Out-Null } catch { $unsafeKeyRejected = $true }
        Assert-True $unsafeKeyRejected "complex YAML mapping key was not rejected"
        $unsafeStateKeyRejected = $false
        try { Get-RemoteSubscriptionAutoUpdateStateRecords $unsafeKeyInput | Out-Null } catch { $unsafeStateKeyRejected = $true }
        Assert-True $unsafeStateKeyRejected "state reader ignored a complex YAML mapping key"
    }
    $profilesIndexOutput = Set-RemoteSubscriptionAutoUpdateDisabled $profilesIndexInput
    Assert-True ([regex]::Matches($profilesIndexOutput, '(?m)^\s+allow_auto_update:\s+false\s*$').Count -eq 2) "not every remote subscription was disabled"
    Assert-True ($profilesIndexOutput.Contains("type: local")) "local profile was removed"
    Assert-True ($profilesIndexOutput.Contains("update_interval: 1440")) "unrelated remote option was removed"
    Assert-True ((Set-RemoteSubscriptionAutoUpdateDisabled $profilesIndexOutput) -eq $profilesIndexOutput) "profiles.yaml transform is not idempotent"
    Assert-RemoteSubscriptionAutoUpdateDisabled $profilesIndexOutput
    $inlineOptionInput = @'
items:
- option:
    allow_auto_update: true
  uid: R-inline-option
  type: remote
'@
    $inlineOptionOutput = Set-RemoteSubscriptionAutoUpdateDisabled $inlineOptionInput
    Assert-True ([regex]::Matches($inlineOptionOutput, '(?m)^\s*-\s+option\s*:').Count -eq 1) "list-item-first option was duplicated"
    Assert-True ([regex]::Matches($inlineOptionOutput, '(?m)^\s+option\s*:').Count -eq 0) "list-item-first option gained a second mapping"
    Assert-True ($inlineOptionOutput -match '(?m)^\s+allow_auto_update:\s+false\s*$') "list-item-first option was not disabled"
    Assert-RemoteSubscriptionAutoUpdateDisabled $inlineOptionOutput
    $inlineOptionOwnership = @(Get-RemoteSubscriptionAutoUpdateOwnership $inlineOptionInput)
    Assert-True ($inlineOptionOwnership.Count -eq 1 -and $inlineOptionOwnership[0].OriginalState -eq "true") "list-item-first option ownership was not recorded"
    $inlineOptionRestored = Restore-RemoteSubscriptionAutoUpdate $inlineOptionOutput $inlineOptionOwnership
    $inlineOptionRestoredState = @(Get-RemoteSubscriptionAutoUpdateStateRecords $inlineOptionRestored)
    Assert-True ($inlineOptionRestoredState.Count -eq 1 -and $inlineOptionRestoredState[0].State -eq "true") "list-item-first option was not restored"
    Assert-True ([regex]::Matches($inlineOptionRestored, '(?m)^\s*-\s+option\s*:').Count -eq 1) "list-item-first option restore changed the list shape"
    $inlineScalarOptionCases = @(
        [pscustomobject]@{ Uid = "R-inline-null"; Value = "null # keep null" },
        [pscustomobject]@{ Uid = "R-inline-tilde"; Value = "~" },
        [pscustomobject]@{ Uid = "R-inline-empty-map"; Value = "{}" }
    )
    foreach ($inlineScalarOptionCase in $inlineScalarOptionCases) {
        $inlineScalarInput = "items:`r`n- option: $($inlineScalarOptionCase.Value)`r`n  uid: $($inlineScalarOptionCase.Uid)`r`n  type: remote`r`n"
        $inlineScalarOwnership = @(Get-RemoteSubscriptionAutoUpdateOwnership $inlineScalarInput)
        Assert-True ($inlineScalarOwnership.Count -eq 1 -and $inlineScalarOwnership[0].OriginalState -eq "missing") "list-item-first scalar option ownership was not recorded"
        $inlineScalarOutput = Set-RemoteSubscriptionAutoUpdateDisabled $inlineScalarInput
        Assert-True ([regex]::Matches($inlineScalarOutput, '(?m)^\s*-\s+option\s*:\s*$').Count -eq 1) "list-item-first scalar option lost its list shape"
        Assert-True ([regex]::Matches($inlineScalarOutput, '(?m)^\s+option\s*:').Count -eq 0) "list-item-first scalar option gained a duplicate mapping"
        Assert-True ($inlineScalarOutput -match '(?m)^\s+allow_auto_update:\s+false\s*$') "list-item-first scalar option was not disabled"
        Assert-RemoteSubscriptionAutoUpdateDisabled $inlineScalarOutput
        $inlineScalarRestored = Restore-RemoteSubscriptionAutoUpdate $inlineScalarOutput $inlineScalarOwnership
        Assert-True ($inlineScalarRestored -ceq $inlineScalarInput) "list-item-first scalar option was not restored byte-for-byte"
    }
    $inlineDuplicateOptionRejected = $false
    try {
        Assert-RemoteSubscriptionAutoUpdateDisabled @'
items:
- option:
    allow_auto_update: false
  uid: R-inline-duplicate
  type: remote
  option:
    allow_auto_update: false
'@
    } catch {
        $inlineDuplicateOptionRejected = $true
    }
    Assert-True $inlineDuplicateOptionRejected "auto-update self-check accepted duplicate option when the first mapping field was inline"
    $nullUpdatedTargets = @(
        Get-RemoteSubscriptionProfileItems @(Split-YamlLines $profilesIndexInput) |
            Where-Object { $_.Type -eq "remote" }
    )
    Assert-True (
        $nullUpdatedTargets.Count -eq 2 -and
        [string]::IsNullOrEmpty([string]$nullUpdatedTargets[0].Updated)
    ) "unquoted YAML null was not accepted as an absent client update timestamp"
    $quotedNullUpdatedRejected = $false
    try {
        Get-RemoteSubscriptionProfileItems @(
            Split-YamlLines (
                $profilesIndexInput.Replace("updated: null", 'updated: "null"')
            )
        ) | Out-Null
    } catch {
        $quotedNullUpdatedRejected = $true
    }
    Assert-True $quotedNullUpdatedRejected "quoted null was accepted as client update metadata"
    Assert-True (-not (Test-ClaudeEasyFlowSequenceHasItem "[ # missing close`nrules:`n  - MATCH,DIRECT")) "unterminated proxy-groups flow sequence consumed the next top-level section"
    $protocolRegressionRejected = $false
    try {
        Assert-SubscriptionProtocolPreserved `
            "proxies: [{ name: Node, type: anytls }]" `
            "proxies: [{ name: Node, type: ss }]"
    } catch {
        $protocolRegressionRejected = $true
    }
    Assert-True $protocolRegressionRejected "safe update accepted AnyTLS being replaced by Shadowsocks"
    $escapedBackslashProtocolRegressionRejected = $false
    try {
        Assert-SubscriptionProtocolPreserved `
            'proxies: [{ name: "Trailing\\", type: anytls }]' `
            "proxies: [{ name: Replacement, type: ss }]"
    } catch {
        $escapedBackslashProtocolRegressionRejected = $true
    }
    Assert-True $escapedBackslashProtocolRegressionRejected "an escaped trailing backslash hid an AnyTLS protocol regression"
    $escapedProtocolKeyRegressionRejected = $false
    try {
        Assert-SubscriptionProtocolPreserved `
            'proxies: [{ "t\u0079pe": anytls }]' `
            "proxies: [{ name: Replacement, type: ss }]"
    } catch {
        $escapedProtocolKeyRegressionRejected = $true
    }
    Assert-True $escapedProtocolKeyRegressionRejected "an escaped flow key hid an AnyTLS protocol regression"
    Assert-SubscriptionProtocolPreserved @'
proxies:
  - name: Existing SS
    type: ss
metadata:
  type: anytls
# type: anytls
'@ @'
proxies:
  - name: Existing SS
    type: ss
'@
    $dummyProtocolRegressionRejected = $false
    try {
        Assert-SubscriptionProtocolPreserved @'
proxies:
  - name: Existing AnyTLS
    type: anytls
'@ @'
proxies:
  - name: Replacement SS
    type: ss
    metadata:
      type: anytls
# type: anytls
'@
    } catch {
        $dummyProtocolRegressionRejected = $true
    }
    Assert-True $dummyProtocolRegressionRejected "comments or nested mappings bypassed the AnyTLS regression gate"
    $sameIndentRejected = $false
    try {
        Assert-SubscriptionProtocolPreserved @'
proxies:
- type: anytls
'@ @'
proxies:
- type: ss
'@
    } catch { $sameIndentRejected = $true }
    Assert-True $sameIndentRejected "same-indent proxies list bypassed the AnyTLS regression gate"
    $multilineFlowRejected = $false
    try {
        Assert-SubscriptionProtocolPreserved @'
proxies:
  - {
      name: Node,
      type: anytls
    }
'@ @'
proxies:
  - {
      name: Node,
      type: ss
    }
'@
    } catch { $multilineFlowRejected = $true }
    Assert-True $multilineFlowRejected "multiline flow-map proxies bypassed the AnyTLS regression gate"
    $inlineAnchorRejected = $false
    try {
        Assert-SubscriptionProtocolPreserved @'
proxies: &foo
  - name: n
    type: anytls
'@ @'
proxies:
  - name: n
    type: ss
'@
    } catch { $inlineAnchorRejected = $true }
    Assert-True $inlineAnchorRejected "inline proxies anchor was treated as an empty type list"
    Assert-SubscriptionProtocolPreserved @'
proxy-providers:
  remote:
    type: http
'@ @'
proxy-providers:
  remote:
    type: http
'@
    Assert-SubscriptionProtocolPreserved "proxies: []`n" "proxies: []`n"

    $ownershipInput = @'
current: R-a
items:
- uid: R-a
  type: remote
  option:
    allow_auto_update: true
- uid: R-b
  type: remote
  option:
    allow_auto_update: false
- uid: R-c
  type: remote
  name: Third
- uid: L-local
  type: local
  option:
    allow_auto_update: true
'@
    $autoUpdateOwnership = @(Get-RemoteSubscriptionAutoUpdateOwnership $ownershipInput)
    Assert-True ($autoUpdateOwnership.Count -eq 2) "auto-update ownership included an unchanged remote item"
    Assert-True (($autoUpdateOwnership | Where-Object { $_.Uid -eq "R-a" }).OriginalState -eq "true") "auto-update ownership lost an originally enabled item"
    Assert-True (($autoUpdateOwnership | Where-Object { $_.Uid -eq "R-c" }).OriginalState -eq "missing") "auto-update ownership lost an originally missing field"
    $ownershipDisabled = Set-RemoteSubscriptionAutoUpdateDisabled $ownershipInput
    $ownershipCurrent = $ownershipDisabled.Replace("current: R-a", "current: R-a`nlast_update: 12345")
    $ownershipRestored = Restore-RemoteSubscriptionAutoUpdate $ownershipCurrent $autoUpdateOwnership
    $restoredStates = @(Get-RemoteSubscriptionAutoUpdateStateRecords $ownershipRestored)
    Assert-True (($restoredStates | Where-Object { $_.Uid -eq "R-a" }).State -eq "true") "owned auto-update did not restore an originally enabled item"
    Assert-True (($restoredStates | Where-Object { $_.Uid -eq "R-b" }).State -eq "false") "owned auto-update changed an item that was already disabled"
    Assert-True (($restoredStates | Where-Object { $_.Uid -eq "R-c" }).State -eq "missing") "owned auto-update did not remove its inserted field"
    Assert-True ($ownershipRestored.Contains("last_update: 12345")) "owned auto-update restore discarded unrelated client metadata"
    Assert-True (($restoredStates | Where-Object { $_.Uid -eq "L-local" }).State -eq "true") "owned auto-update restore changed a local profile"

    $ownershipShapeInput = @'
items:
- uid: R-absent
  type: remote
- uid: R-null
  type: remote
  option: null # keep null
- uid: R-tilde
  type: remote
  option: ~
- uid: R-empty
  type: remote
  option: {}
- uid: R-block
  type: remote
  option: # keep block
    update_interval: 60
'@
    $ownershipShapeRecords = @(Get-RemoteSubscriptionAutoUpdateOwnership $ownershipShapeInput)
    Assert-True ($ownershipShapeRecords.Count -eq 5) "auto-update ownership missed a supported missing-field shape"
    $ownershipShapeDisabled = Set-RemoteSubscriptionAutoUpdateDisabled $ownershipShapeInput
    $ownershipShapeRestored = Restore-RemoteSubscriptionAutoUpdate $ownershipShapeDisabled $ownershipShapeRecords
    $ownershipShapeExpected = Join-YamlLines -Lines @(Split-YamlLines $ownershipShapeInput)
    Assert-True ($ownershipShapeRestored -ceq $ownershipShapeExpected) "auto-update restore did not reconstruct the original absent/null/tilde/empty-map shapes"

    $corruptOwnershipInput = "items:`n- uid: R-corrupt`n  type: remote`n  option: null`n"
    $corruptOwnershipDisabled = Set-RemoteSubscriptionAutoUpdateDisabled $corruptOwnershipInput
    foreach ($corruptOptionLine in @(
        "option: null",
        " option: null",
        "      option: null",
        "  option:`tnull",
        "  wrong: null",
        "  option: null`0"
    )) {
        $corruptOwnership = @(
            [pscustomobject]@{
                Uid = "R-corrupt"
                OriginalState = "missing"
                OriginalOptionBase64 = [Convert]::ToBase64String(
                    [System.Text.Encoding]::UTF8.GetBytes($corruptOptionLine)
                )
            }
        )
        $corruptOwnershipRejected = $false
        try {
            Restore-RemoteSubscriptionAutoUpdate $corruptOwnershipDisabled $corruptOwnership | Out-Null
        } catch {
            $corruptOwnershipRejected = $true
        }
        Assert-True $corruptOwnershipRejected "auto-update restore trusted a corrupt original option line: $corruptOptionLine"
        Assert-True (
            $corruptOwnershipDisabled -ceq (Set-RemoteSubscriptionAutoUpdateDisabled $corruptOwnershipInput)
        ) "corrupt auto-update ownership mutated the input before rejection"
    }

    $ownershipMetadataInput = "items:`n- uid: R-metadata`n  type: remote`n"
    $ownershipMetadataRecords = @(Get-RemoteSubscriptionAutoUpdateOwnership $ownershipMetadataInput)
    $ownershipMetadataDisabled = Set-RemoteSubscriptionAutoUpdateDisabled $ownershipMetadataInput
    $ownershipMetadataCurrent = $ownershipMetadataDisabled.Replace(
        "    allow_auto_update: false",
        "    last_update: 67890`r`n    allow_auto_update: false"
    )
    $ownershipMetadataRestored = Restore-RemoteSubscriptionAutoUpdate $ownershipMetadataCurrent $ownershipMetadataRecords
    Assert-True ($ownershipMetadataRestored.Contains("last_update: 67890")) "auto-update restore discarded metadata added beneath a managed option block"
    Assert-True ($ownershipMetadataRestored -notmatch '(?m)^\s+allow_auto_update:') "auto-update restore retained its inserted field after client metadata appeared"

    $aliasOwnershipRejected = $false
    try {
        Get-RemoteSubscriptionAutoUpdateOwnership @'
items:
- uid: Case-Alias
  type: remote
- uid: case-alias
  type: remote
'@ | Out-Null
    } catch { $aliasOwnershipRejected = $true }
    Assert-True $aliasOwnershipRejected "case-colliding remote subscription uids produced ambiguous ownership"

    $aliasMergeRejected = $false
    try {
        Merge-RemoteSubscriptionAutoUpdateOwnership @(
            [pscustomobject]@{ Uid = "Case-Alias"; OriginalState = "true"; OriginalOptionBase64 = "b3B0aW9uOg==" }
        ) @(
            [pscustomobject]@{ Uid = "case-alias"; OriginalState = "missing"; OriginalOptionBase64 = "" }
        ) | Out-Null
    } catch { $aliasMergeRejected = $true }
    Assert-True $aliasMergeRejected "ownership merge silently collapsed case-colliding subscription uids"

    $nestedProfilesInput = @'
items:
- uid: R-nested
  type: remote
  option:
    headers:
      User-Agent: Clash
    update_interval: 1440
'@
    $nestedProfilesOutput = Set-RemoteSubscriptionAutoUpdateDisabled $nestedProfilesInput
    Assert-True ($nestedProfilesOutput -match '(?m)^ {4}allow_auto_update: false\r?$') "nested option did not receive a direct allow_auto_update field"
    Assert-True ($nestedProfilesOutput -notmatch '(?m)^ {6}allow_auto_update: false\r?$') "allow_auto_update was inserted into a nested option mapping"
    Assert-True ($nestedProfilesOutput.Contains("      User-Agent: Clash")) "nested option content was changed"
    Assert-RemoteSubscriptionAutoUpdateDisabled $nestedProfilesOutput

    $nestedOnlyRejected = $false
    try {
        Assert-RemoteSubscriptionAutoUpdateDisabled @'
items:
- uid: R-nested
  type: remote
  option:
    headers:
      allow_auto_update: false
'@ | Out-Null
    } catch { $nestedOnlyRejected = $true }
    Assert-True $nestedOnlyRejected "nested allow_auto_update was mistaken for the direct option setting"

    $flowProfilesRejected = $false
    try { Set-RemoteSubscriptionAutoUpdateDisabled "items: [{ type: remote }]`n" | Out-Null } catch { $flowProfilesRejected = $true }
    Assert-True $flowProfilesRejected "inline profiles list was modified instead of rejected"

    $bareItemProfiles = "items:`n-`n  uid: R-bare-item`n  type: remote`n  option:`n    allow_auto_update: true`n"
    $bareItemRejected = $false
    try { Set-RemoteSubscriptionAutoUpdateDisabled $bareItemProfiles | Out-Null } catch { $bareItemRejected = $true }
    Assert-True $bareItemRejected "bare YAML list item was silently omitted"
    Assert-True ($bareItemProfiles -ceq "items:`n-`n  uid: R-bare-item`n  type: remote`n  option:`n    allow_auto_update: true`n") "bare YAML list rejection changed the input"
    $flowListProfiles = "items:`n  [`n    { uid: R-flow-list, type: remote, option: { allow_auto_update: true } }`n  ]`n"
    $flowListRejected = $false
    try { Set-RemoteSubscriptionAutoUpdateDisabled $flowListProfiles | Out-Null } catch { $flowListRejected = $true }
    Assert-True $flowListRejected "multiline flow YAML list was silently omitted"

    $backupOnlyCase = Join-Path $sandbox "subscription-backup-only-case"
    $backupOnlyProfiles = Join-Path $backupOnlyCase "profiles"
    New-Item -ItemType Directory -Path $backupOnlyProfiles -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $backupOnlyCase "profiles.yaml"), $profilesIndexInput)
    $backupFirstBytes = [System.Text.Encoding]::UTF8.GetBytes("first subscription bytes`n")
    $backupSecondBytes = [System.Text.Encoding]::UTF8.GetBytes("second subscription bytes`n")
    [System.IO.File]::WriteAllBytes((Join-Path $backupOnlyProfiles "R-first.yaml"), $backupFirstBytes)
    [System.IO.File]::WriteAllBytes((Join-Path $backupOnlyProfiles "R-second.yml"), $backupSecondBytes)
    $backupOnlyResult = Invoke-TestPowerShell $installer @(
        "-AppHome", $backupOnlyCase,
        "-BackupSubscriptions",
        "-Json"
    )
    $backupOnlyJson = Assert-JsonResult $backupOnlyResult "install" 0
    Assert-True (
        $backupOnlyJson.operation -eq "backup_subscriptions" -and
        $backupOnlyJson.code -eq "subscription_backups_created" -and
        $null -eq $backupOnlyJson.profile
    ) "subscription backup did not return the backup-only result"
    Assert-True (
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $backupOnlyProfiles "R-first.yaml"))) -ceq [Convert]::ToBase64String($backupFirstBytes) -and
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $backupOnlyProfiles "R-second.yml"))) -ceq [Convert]::ToBase64String($backupSecondBytes)
    ) "subscription backup changed a remote subscription"
    Assert-True (-not (
        Test-Path -LiteralPath (Join-Path $backupOnlyCase "claude-easy-usage-profile.json")
    )) "subscription backup created a usage profile"
    Assert-True (-not (
        Test-Path -LiteralPath (Join-Path $backupOnlyCase "claude-easy-safe-update.json")
    )) "subscription backup created a safe-update manifest"
    $backupOnlyFiles = @(Get-ChildItem -LiteralPath (Join-Path $backupOnlyCase "claude-easy-backups") -Recurse -File)
    Assert-True ($backupOnlyFiles.Count -eq 4) "subscription backup did not create initial and pre-update backups for every remote subscription"

    $safeUpdateCase = Join-Path $sandbox "safe-update-case"
    $unprofiledSafeUpdateCase = Join-Path $sandbox "safe-update-without-profile"
    New-Item -ItemType Directory -Path $unprofiledSafeUpdateCase -Force | Out-Null
    $unprofiledSafeUpdate = Invoke-TestPowerShell $installer @(
        "-AppHome", $unprofiledSafeUpdateCase,
        "-SnapshotProfiles",
        "-UsageProfile", "1",
        "-MihomoPath", $fakeCore,
        "-Json"
    )
    $unprofiledSafeUpdateJson = Assert-JsonResult $unprofiledSafeUpdate "install" 10
    Assert-True (
        $unprofiledSafeUpdateJson.code -eq "usage_profile_required" -and
        $null -eq $unprofiledSafeUpdateJson.profile
    ) "Windows safe update accepted a requested profile without a saved profile"
    Assert-True (-not (
        Test-Path -LiteralPath (Join-Path $unprofiledSafeUpdateCase "claude-easy-usage-profile.json")
    )) "Windows safe update created a missing saved profile"

    $safeUpdateProfiles = Join-Path $safeUpdateCase "profiles"
    New-Item -ItemType Directory -Path $safeUpdateProfiles -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $safeUpdateCase "profiles.yaml"), $profilesIndexInput)
    $firstSafeOriginal = @'
proxies:
  - name: Old One
    type: ss
    server: old-one.invalid
    port: 443
    cipher: aes-128-gcm
    password: fixture-secret
proxy-groups:
  - name: Main
    type: select
    proxies:
      - Old One
rules:
  - MATCH,Main
'@
    $secondSafeOriginal = @'
proxies:
  - name: Old Two
    type: ss
    server: old-two.invalid
    port: 443
    cipher: aes-128-gcm
    password: fixture-secret
proxy-groups:
  - name: Main
    type: select
    proxies:
      - Old Two
rules:
  - MATCH,Main
'@
    [System.IO.File]::WriteAllText((Join-Path $safeUpdateProfiles "R-first.yaml"), $firstSafeOriginal)
    [System.IO.File]::WriteAllText((Join-Path $safeUpdateProfiles "R-second.yml"), $secondSafeOriginal)
    [System.IO.File]::WriteAllText((Join-Path $safeUpdateProfiles "L-local.yaml"), "local: true`n")
    $safeUpdateInstall = Invoke-TestPowerShell $installer @(
        "-AppHome", $safeUpdateCase, "-UsageProfile", "1", "-MihomoPath", $fakeCore
    )
    Assert-True ($safeUpdateInstall.ExitCode -eq 0) "safe update fixture install failed; $(Get-TestOutputDiagnostic $safeUpdateInstall.Output)"
    $mismatchedSafeUpdate = Invoke-TestPowerShell $installer @(
        "-AppHome", $safeUpdateCase,
        "-SnapshotProfiles",
        "-UsageProfile", "2",
        "-MihomoPath", $fakeCore,
        "-Json"
    )
    $mismatchedSafeUpdateJson = Assert-JsonResult $mismatchedSafeUpdate "install" 64
    Assert-True (
        $mismatchedSafeUpdateJson.code -eq "usage_profile_mismatch" -and
        $null -eq $mismatchedSafeUpdateJson.profile
    ) "Windows safe update accepted a profile different from the saved profile"
    Assert-True (-not (
        Test-Path -LiteralPath (Join-Path $safeUpdateCase "claude-easy-safe-update.json")
    )) "Windows profile mismatch created a safe-update manifest"
    $remoteTargets = @(Get-RemoteSubscriptionTargets $profilesIndexInput $safeUpdateProfiles)
    Assert-True ($remoteTargets.Count -eq 2) "two distinct remote subscriptions were not mapped independently"
    Assert-True ((@($remoteTargets | ForEach-Object { $_.Path } | Sort-Object -Unique)).Count -eq 2) "distinct remote subscriptions were mapped to one file"
    $snapshotGuardContext = New-SafeUpdateSnapshotContext (
        Join-Path $safeUpdateCase "profiles.yaml"
    ) $safeUpdateProfiles
    try {
        foreach ($guardedPath in @(
            (Join-Path $safeUpdateCase "profiles.yaml"),
            (Join-Path $safeUpdateProfiles "R-first.yaml")
        )) {
            $writeBlocked = $false
            try {
                $writeProbe = [System.IO.File]::Open(
                    $guardedPath,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::ReadWrite
                )
                $writeProbe.Dispose()
            } catch {
                $writeBlocked = $true
            }
            Assert-True $writeBlocked "safe-update snapshot did not hold a read-only version guard: $guardedPath"
        }
    } finally {
        foreach ($guard in @($snapshotGuardContext.Guards)) { $guard.Dispose() }
    }
    if ($onWindows) {
        $caseAliasIndex = "items:`n- uid: Case-Alias`n  type: remote`n- uid: case-alias`n  type: remote`n"
        [System.IO.File]::WriteAllText((Join-Path $safeUpdateProfiles "case-alias.yaml"), "proxies: []`n")
        $caseAliasRejected = $false
        try { Get-RemoteSubscriptionTargets $caseAliasIndex $safeUpdateProfiles | Out-Null } catch { $caseAliasRejected = $true }
        Assert-True $caseAliasRejected "case-alias remote subscriptions were allowed to share one file"
    }
    if ($onWindows) {
        $safeUpdateControllerReady = Join-Path $sandbox "safe-update-controller-ready"
        $portProbe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $portProbe.Start()
        $script:safeUpdateControllerPort = ([System.Net.IPEndPoint]$portProbe.LocalEndpoint).Port
        $portProbe.Stop()
        $safeUpdatePolicy = Get-Content -LiteralPath (
            Join-Path (Join-Path $root "claude-easy/references") "policy.json"
        ) -Raw | ConvertFrom-Json
        $safeUpdateDomainProvider = $safeUpdatePolicy.cn_domain_provider
        $safeUpdateDirectResolvers = (@($safeUpdatePolicy.direct_resolvers) | ForEach-Object {
            "    - $_"
        }) -join "`n"
        $safeUpdatePolicyResolvers = (@($safeUpdatePolicy.direct_resolvers) | ForEach-Object {
            "      - $_"
        }) -join "`n"
        $script:safeUpdateRuntimeText = @"
external-controller: 127.0.0.1:$($script:safeUpdateControllerPort)
secret: ''
mixed-port: $($script:safeUpdateControllerPort)
profile:
  store-selected: true
dns:
  enable: true
  respect-rules: true
  direct-nameserver:
$safeUpdateDirectResolvers
  direct-nameserver-follow-policy: false
  nameserver-policy:
    "rule-set:$($safeUpdateDomainProvider.name)":
$safeUpdatePolicyResolvers
rule-providers:
  $($safeUpdateDomainProvider.name):
    type: $($safeUpdateDomainProvider.type)
    behavior: $($safeUpdateDomainProvider.behavior)
    format: $($safeUpdateDomainProvider.format)
    url: $($safeUpdateDomainProvider.url)
    path: $($safeUpdateDomainProvider.path)
    interval: $($safeUpdateDomainProvider.interval)
    proxy: Main
    size-limit: $($safeUpdateDomainProvider.size_limit)
rules:
  - RULE-SET,$($safeUpdateDomainProvider.name),DIRECT
  - MATCH,Main
"@
        $safeUpdateControllerJob = Start-Job -ArgumentList @(
            $script:safeUpdateControllerPort,
            $safeUpdateControllerReady,
            [string]$safeUpdateDomainProvider.name
        ) -ScriptBlock {
            param([int]$Port, [string]$ReadyPath, [string]$DomainProviderName)
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
            $listener.Start()
            [System.IO.File]::WriteAllText($ReadyPath, "ready")
            try {
                while ($true) {
                    $client = $listener.AcceptTcpClient()
                    try {
                        $stream = $client.GetStream()
                        $reader = [System.IO.StreamReader]::new(
                            $stream,
                            [System.Text.Encoding]::ASCII,
                            $false,
                            1024,
                            $true
                        )
                        $requestLine = $reader.ReadLine()
                        while (-not [string]::IsNullOrEmpty($reader.ReadLine())) { }
                        $parts = @($requestLine.Split(" "))
                        $method = $parts[0]
                        $path = $parts[1]
                        if ($method -eq "GET" -and $path -eq "/configs") {
                            $body = "{`"tun`":{`"enable`":false},`"mixed-port`":$Port}"
                        } elseif ($method -eq "GET" -and $path -eq "/proxies") {
                            $body = '{"proxies":{"Main":{"type":"Selector","now":"Node","all":["Node"]},"Node":{"type":"Shadowsocks"}}}'
                        } elseif ($method -eq "GET" -and $path -eq "/rules") {
                            $body = "{`"rules`":[{`"type`":`"RuleSet`",`"payload`":`"$DomainProviderName`",`"proxy`":`"DIRECT`"},{`"type`":`"Match`",`"payload`":`"`",`"proxy`":`"Main`"}]}"
                        } elseif ($method -eq "GET" -and $path -eq "/providers/proxies") {
                            $body = '{"providers":{}}'
                        } elseif ($method -eq "GET" -and $path -like "/dns/query?*") {
                            $body = '{"Status":0,"Answer":[{"data":"1.1.1.1"}]}'
                        } else {
                            $body = '{}'
                        }
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                        $headers = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
                        $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
                        $stream.Write($headerBytes, 0, $headerBytes.Length)
                        $stream.Write($bytes, 0, $bytes.Length)
                        $stream.Flush()
                    } finally {
                        $client.Dispose()
                    }
                }
            } finally {
                $listener.Stop()
            }
        }
        $readyDeadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $safeUpdateControllerReady) -and
            [DateTime]::UtcNow -lt $readyDeadline) {
            Start-Sleep -Milliseconds 100
        }
        Assert-True (Test-Path -LiteralPath $safeUpdateControllerReady) "safe-update controller did not start"
        $script:safeUpdateClientPath = Join-Path $sandbox "clash-verge.exe"
        Copy-Item -LiteralPath (Join-Path (Join-Path $env:SystemRoot "System32") "ping.exe") -Destination $script:safeUpdateClientPath
    }
    $noPrecheckSnapshotCase = Join-Path $sandbox "safe-update-snapshot-with-invalid-current-content"
    $noPrecheckSnapshotProfiles = Join-Path $noPrecheckSnapshotCase "profiles"
    New-Item -ItemType Directory -Path $noPrecheckSnapshotProfiles -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $noPrecheckSnapshotCase "profiles.yaml"), $profilesIndexInput)
    [System.IO.File]::WriteAllText(
        (Join-Path $noPrecheckSnapshotCase "claude-easy-usage-profile.json"),
        '{"Version":1,"Profile":1}'
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $noPrecheckSnapshotProfiles "R-first.yaml"),
        "proxy-groups: []`n"
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $noPrecheckSnapshotProfiles "R-second.yml"),
        "not valid Clash YAML`n"
    )
    $noPrecheckSnapshot = Invoke-TestPowerShell $installer @(
        "-AppHome", $noPrecheckSnapshotCase,
        "-SnapshotProfiles",
        "-MihomoPath", $fakeCore,
        "-Json"
    )
    $noPrecheckSnapshotJson = Assert-JsonResult $noPrecheckSnapshot "install" 0
    Assert-True (
        $noPrecheckSnapshotJson.code -eq "snapshot_created" -and
        (Test-Path -LiteralPath (Join-Path $noPrecheckSnapshotCase "claude-easy-safe-update.json"))
    ) "Windows ran subscription validation before creating the update snapshot"
    $noPrecheckBackups = @(
        Get-ChildItem -LiteralPath (Join-Path $noPrecheckSnapshotCase "claude-easy-backups") -File |
            Where-Object { $_.Name -like "*--pre-update--*" }
    )
    Assert-True ($noPrecheckBackups.Count -eq 2) "Windows did not back up every remote subscription before UI refresh"
    $snapshotResult = Invoke-TestPowerShell $installer @(
        "-AppHome", $safeUpdateCase,
        "-SnapshotProfiles",
        "-MihomoPath", $fakeCore,
        "-Json"
    )
    $snapshotJson = Assert-JsonResult $snapshotResult "install" 0
    Assert-True ($snapshotJson.profile -eq 1) "safe update snapshot did not report the saved profile"
    $snapshotManifest = Get-Content -LiteralPath (
        Join-Path $safeUpdateCase "claude-easy-safe-update.json"
    ) -Raw | ConvertFrom-Json
    Assert-True (
        [int]$snapshotManifest.Version -eq 4 -and
        $null -eq $snapshotManifest.UpdateDispatchCommittedFor -and
        $snapshotManifest.Runtime.TunEnabled -eq $false -and
        @($snapshotManifest.Runtime.Selections).Count -eq 1 -and
        [string]$snapshotManifest.Runtime.Selections[0].Group -ceq "Main" -and
        [string]$snapshotManifest.Runtime.Selections[0].Selection -ceq "Node"
    ) "safe update snapshot omitted the pre-update TUN or proxy selection"
    Assert-True (
        $snapshotJson.workflow_complete -eq $false -and
        $snapshotJson.completed_scope -eq "subscription_snapshot" -and
        (@($snapshotJson.required_followups) -join ",") -ceq (
            @(
                "subscription_refresh", "safe_update_verification",
                "client_switch_verification", "site_verification", "final_state_audit"
            ) -join ","
        )
    ) "safe update snapshot did not preserve the remaining profile 1 workflow"

    $profileThreeSnapshotCase = Join-Path $sandbox "profile-three-snapshot-case"
    $profileThreeSnapshotProfiles = Join-Path $profileThreeSnapshotCase "profiles"
    New-Item -ItemType Directory -Path $profileThreeSnapshotProfiles -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $profileThreeSnapshotCase "profiles.yaml"),
        $profilesIndexInput
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $profileThreeSnapshotCase "claude-easy-usage-profile.json"),
        '{"Version":1,"Profile":3}'
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $profileThreeSnapshotProfiles "R-first.yaml"),
        $firstSafeOriginal
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $profileThreeSnapshotProfiles "R-second.yml"),
        $secondSafeOriginal
    )
    $profileThreeSnapshotResult = Invoke-TestPowerShell $installer @(
        "-AppHome", $profileThreeSnapshotCase,
        "-SnapshotProfiles",
        "-MihomoPath", $fakeCore,
        "-Json"
    )
    $profileThreeSnapshotJson = Assert-JsonResult $profileThreeSnapshotResult "install" 0
    Assert-True (
        (@($profileThreeSnapshotJson.required_followups) -join ",") -ceq (
            @(
                "subscription_refresh", "safe_update_verification",
                "client_switch_verification", "site_verification",
                "agent_connectivity_verification", "route_verification", "dns_deep_test",
                "webrtc_test_1", "webrtc_test_2", "region_fingerprint_test",
                "final_state_audit"
            ) -join ","
        )
    ) "profile 3 snapshot did not defer every profile check until after subscription refresh"

    $safeBackups = @(Get-ChildItem -LiteralPath (Join-Path $safeUpdateCase "claude-easy-backups") -File | Where-Object { $_.Name -like "*--pre-update--*" })
    Assert-True ($safeBackups.Count -eq 2) "snapshot did not back up exactly the two remote subscriptions"
    $pendingSafeUpdateBeforeUninstall = Get-TreeContentSnapshot $safeUpdateCase
    $pendingSafeUpdateUninstall = Invoke-TestPowerShell $uninstaller @(
        "-AppHome", $safeUpdateCase,
        "-Json"
    )
    $pendingSafeUpdateUninstallJson = Assert-JsonResult $pendingSafeUpdateUninstall "uninstall" 1
    Assert-True (
        $pendingSafeUpdateUninstallJson.status -eq "partial" -and
        $pendingSafeUpdateUninstallJson.code -eq "safe_update_pending"
    ) "pending safe update uninstall did not return a retryable result"
    Assert-True (
        @($pendingSafeUpdateUninstallJson.changes).Count -eq 0
    ) "pending safe update uninstall reported committed changes"
    Assert-True (
        (Get-TreeContentSnapshot $safeUpdateCase) -ceq $pendingSafeUpdateBeforeUninstall
    ) "pending safe update uninstall changed AppHome"
    [System.IO.File]::WriteAllText((Join-Path $safeUpdateProfiles "R-first.yaml"), "changed: true`n")
    [System.IO.File]::WriteAllText((Join-Path $safeUpdateProfiles "R-second.yml"), "first: true`n---`nsecond: true`n")
    $verifyResult = Invoke-TestPowerShell $installer @(
        "-AppHome", $safeUpdateCase,
        "-VerifySafeUpdate",
        "-RefreshConfirmed",
        "-MihomoPath", $fakeCore,
        "-Json"
    ) -SimulateRuntimeRefresh
    $verifyJson = Assert-JsonResult $verifyResult "install" 1
    Assert-True (
        $verifyJson.code -eq "safe_update_rolled_back"
    ) "invalid safe update did not restore the previous runtime state; got $($verifyJson.code)"
    Assert-True ((Get-Content -LiteralPath (Join-Path $safeUpdateProfiles "R-first.yaml") -Raw) -eq $firstSafeOriginal) "failed safe update did not restore first remote subscription"
    Assert-True ((Get-Content -LiteralPath (Join-Path $safeUpdateProfiles "R-second.yml") -Raw) -eq $secondSafeOriginal) "failed safe update did not restore second remote subscription"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $safeUpdateCase "claude-easy-safe-update.json"))) "completed rollback left a reusable stale safe-update manifest"

    $missingTargetSnapshot = Invoke-TestPowerShell $installer @(
        "-AppHome", $safeUpdateCase,
        "-SnapshotProfiles",
        "-MihomoPath", $fakeCore,
        "-Json"
    )
    Assert-JsonResult $missingTargetSnapshot "install" 0 | Out-Null
    Remove-Item -LiteralPath (Join-Path $safeUpdateProfiles "R-first.yaml") -Force
    $missingTargetVerify = Invoke-TestPowerShell $installer @(
        "-AppHome", $safeUpdateCase,
        "-VerifySafeUpdate",
        "-RefreshConfirmed",
        "-MihomoPath", $fakeCore,
        "-Json"
    ) -SimulateRuntimeRefresh
    $missingTargetVerifyJson = Assert-JsonResult $missingTargetVerify "install" 1
    Assert-True (
        $missingTargetVerifyJson.status -eq "rolled_back" -and
        $missingTargetVerifyJson.code -eq "safe_update_rolled_back" -and
        @($missingTargetVerifyJson.warnings).Count -eq 0
    ) "missing safe-update target did not report a complete rollback"
    Assert-True (
        (Get-Content -LiteralPath (Join-Path $safeUpdateProfiles "R-first.yaml") -Raw) -eq
            $firstSafeOriginal
    ) "safe update did not recreate a missing remote subscription"
    Assert-True (
        (Get-Content -LiteralPath (Join-Path $safeUpdateProfiles "R-second.yml") -Raw) -eq
            $secondSafeOriginal
    ) "missing-target rollback changed another remote subscription"
    Assert-True (-not (
        Test-Path -LiteralPath (
            Join-Path $safeUpdateCase "claude-easy-safe-update.json"
        )
    )) "missing-target rollback retained a stale safe-update manifest"

    $noMainSnapshot = Invoke-TestPowerShell $installer @(
        "-AppHome", $safeUpdateCase,
        "-SnapshotProfiles",
        "-MihomoPath", $fakeCore
    )
    Assert-True ($noMainSnapshot.ExitCode -eq 0) "main-group failure snapshot failed; $(Get-TestOutputDiagnostic $noMainSnapshot.Output)"
    $noMainUpdated = @'
mode: rule
proxies:
  - name: Node
    type: ss
    server: proxy.invalid
    port: 443
    cipher: aes-128-gcm
    password: fixture-secret
proxy-groups: []
rules:
  - MATCH,DIRECT
'@
    [System.IO.File]::WriteAllText((Join-Path $safeUpdateProfiles "R-first.yaml"), $noMainUpdated)
    $noMainUpdatedMultiline = $noMainUpdated.Replace("proxy-groups: []", "proxy-groups: [ # empty flow list`n]")
    [System.IO.File]::WriteAllText((Join-Path $safeUpdateProfiles "R-second.yml"), $noMainUpdatedMultiline)
    $noMainVerify = Invoke-TestPowerShell $installer @("-AppHome", $safeUpdateCase, "-VerifySafeUpdate", "-RefreshConfirmed", "-MihomoPath", $fakeCore)
    Assert-True ($noMainVerify.ExitCode -eq 1) "safe update accepted subscriptions that the installed global script cannot patch"
    Assert-True ((Get-Content -LiteralPath (Join-Path $safeUpdateProfiles "R-first.yaml") -Raw) -eq $firstSafeOriginal) "main-group validation failure did not restore first remote subscription"
    Assert-True ((Get-Content -LiteralPath (Join-Path $safeUpdateProfiles "R-second.yml") -Raw) -eq $secondSafeOriginal) "main-group validation failure did not restore second remote subscription"
    $runtimeRecoveryPath = Join-Path $safeUpdateCase "claude-easy-safe-update.json"
    Assert-True (Test-Path -LiteralPath $runtimeRecoveryPath -PathType Leaf) "failed runtime rollback lost its recovery record"
    $runtimeRecovery = [System.IO.File]::ReadAllText($runtimeRecoveryPath) | ConvertFrom-Json
    Assert-True (
        (@($runtimeRecovery.PSObject.Properties.Name | Sort-Object) -join ",") -ceq
            "Kind,RestoreDispatchCommittedFor,Runtime,UsageProfile,Version" -and
        [int]$runtimeRecovery.Version -eq 2 -and
        $null -ne $runtimeRecovery.RestoreDispatchCommittedFor -and
        [string]$runtimeRecovery.Kind -ceq "safe_update_runtime_recovery"
    ) "failed runtime rollback did not publish a strict recovery record"
    $runtimeRecoveryRetry = Invoke-TestPowerShell $installer @(
        "-AppHome", $safeUpdateCase,
        "-VerifySafeUpdate",
        "-RefreshConfirmed",
        "-MihomoPath", $fakeCore,
        "-Json"
    ) -SimulateRuntimeRefresh
    $runtimeRecoveryRetryJson = Assert-JsonResult $runtimeRecoveryRetry "install" 1
    Assert-True (
        $runtimeRecoveryRetryJson.status -eq "rolled_back" -and
        $runtimeRecoveryRetryJson.code -eq "safe_update_rolled_back"
    ) "runtime-only safe-update recovery did not resume"
    Assert-True (-not (Test-Path -LiteralPath $runtimeRecoveryPath)) "completed runtime recovery retained its record"

    $successSnapshot = Invoke-TestPowerShell $installer @(
        "-AppHome", $safeUpdateCase,
        "-SnapshotProfiles",
        "-MihomoPath", $fakeCore
    )
    Assert-True ($successSnapshot.ExitCode -eq 0) "successful safe update snapshot failed; $(Get-TestOutputDiagnostic $successSnapshot.Output)"
    $firstSafeUpdated = @'
mode: rule
proxies:
  - name: Node
    type: ss
    server: proxy.invalid
    port: 443
    cipher: aes-128-gcm
    password: fixture-secret
proxy-groups:
  - name: Auto
    type: url-test
    proxies:
      - Node
    url: https://example.invalid
    interval: 300
rules:
  - MATCH,Auto
'@
    $secondSafeUpdated = @'
mode: global
proxies: [{ name: "Hong Kong #1", type: ss, server: proxy.invalid, port: 443, cipher: aes-128-gcm, password: fixture-secret }]
proxy-groups: [{ name: "AI", type: select, proxies: ["Hong Kong #1"] }]
rules: ["MATCH,AI"]
'@
    [System.IO.File]::WriteAllText((Join-Path $safeUpdateProfiles "R-first.yaml"), $firstSafeUpdated)
    [System.IO.File]::WriteAllText((Join-Path $safeUpdateProfiles "R-second.yml"), $secondSafeUpdated)
    $successVerify = Invoke-TestPowerShell $installer @("-AppHome", $safeUpdateCase, "-VerifySafeUpdate", "-RefreshConfirmed", "-MihomoPath", $fakeCore, "-Json") -SimulateRuntimeRefresh
    $successVerifyJson = $successVerify.Output | ConvertFrom-Json
    Assert-True ($successVerify.ExitCode -eq 0) (
        "valid safe update was rejected; code=$($successVerifyJson.code); " +
        "messages=$(@($successVerifyJson.messages) -join ';')"
    )
    Assert-JsonResult $successVerify "install" 0 | Out-Null
    Assert-True ((Get-Content -LiteralPath (Join-Path $safeUpdateProfiles "R-first.yaml") -Raw) -eq $firstSafeUpdated) "valid safe update incorrectly restored first remote subscription"
    Assert-True ((Get-Content -LiteralPath (Join-Path $safeUpdateProfiles "R-second.yml") -Raw) -eq $secondSafeUpdated) "valid safe update incorrectly restored second remote subscription"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $safeUpdateCase "claude-easy-safe-update.json"))) "accepted safe update left a stale manifest"

    $legacyRetirementSnapshot = Invoke-TestPowerShell $installer @(
        "-AppHome", $safeUpdateCase,
        "-SnapshotProfiles",
        "-MihomoPath", $fakeCore,
        "-Json"
    )
    Assert-JsonResult $legacyRetirementSnapshot "install" 0 | Out-Null
    $legacyManifestPath = Join-Path $safeUpdateCase "claude-easy-safe-update.json"
    $legacyManifest = (
        [System.IO.File]::ReadAllText($legacyManifestPath) | ConvertFrom-Json
    )
    $legacyManifest.Version = 1
    $legacyManifest.PSObject.Properties.Remove("Runtime")
    $legacyManifest.PSObject.Properties.Remove("UpdateDispatchCommittedFor")
    foreach ($profile in @($legacyManifest.Profiles)) {
        $profile.PSObject.Properties.Remove("BeforeUpdated")
    }
    Remove-Item -LiteralPath (
        Join-Path (
            Join-Path $safeUpdateCase "claude-easy-backups"
        ) @($legacyManifest.Profiles)[0].Backup
    ) -Force
    [System.IO.File]::WriteAllText(
        (
            Join-Path (
                Join-Path $safeUpdateCase "claude-easy-backups"
            ) @($legacyManifest.Profiles)[1].Backup
        ),
        "corrupted legacy backup"
    )
    [System.IO.File]::WriteAllText(
        $legacyManifestPath,
        (($legacyManifest | ConvertTo-Json -Depth 5) + "`r`n")
    )
    $legacyRetirementVerify = Invoke-TestPowerShell $installer @(
        "-AppHome", $safeUpdateCase,
        "-VerifySafeUpdate",
        "-RefreshConfirmed",
        "-MihomoPath", $fakeCore,
        "-Json"
    )
    $legacyRetirementJson = Assert-JsonResult $legacyRetirementVerify "install" 1
    Assert-True (
        $legacyRetirementJson.status -eq "partial" -and
        $legacyRetirementJson.code -eq "safe_update_legacy_snapshot_required"
    ) "unchanged valid legacy snapshot with missing or corrupted backups remained permanently pending"
    Assert-True (-not (
        Test-Path -LiteralPath $legacyManifestPath
    )) "validated legacy snapshot retirement retained its manifest"

    $legacySnapshot = Invoke-TestPowerShell $installer @(
        "-AppHome", $safeUpdateCase,
        "-SnapshotProfiles",
        "-MihomoPath", $fakeCore,
        "-Json"
    )
    Assert-JsonResult $legacySnapshot "install" 0 | Out-Null
    $legacyManifest = (
        [System.IO.File]::ReadAllText($legacyManifestPath) | ConvertFrom-Json
    )
    $legacyManifest.Version = 1
    $legacyManifest.PSObject.Properties.Remove("Runtime")
    $legacyManifest.PSObject.Properties.Remove("UpdateDispatchCommittedFor")
    foreach ($profile in @($legacyManifest.Profiles)) {
        $profile.PSObject.Properties.Remove("BeforeUpdated")
    }
    $legacyBadBackup = [System.Text.Encoding]::UTF8.GetBytes("proxy-groups: [`n")
    $legacyFirstProfile = @($legacyManifest.Profiles)[0]
    [System.IO.File]::WriteAllBytes(
        (Join-Path (Join-Path $safeUpdateCase "claude-easy-backups") $legacyFirstProfile.Backup),
        $legacyBadBackup
    )
    $legacyFirstProfile.BeforeSha256 = Get-BytesSha256 $legacyBadBackup
    [System.IO.File]::WriteAllText(
        $legacyManifestPath,
        (($legacyManifest | ConvertTo-Json -Depth 5) + "`r`n")
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $safeUpdateProfiles "R-first.yaml"),
        "proxy-groups: []`n"
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $safeUpdateProfiles "R-second.yml"),
        "proxy-groups: []`n"
    )
    $legacyCurrentBefore = Get-TreeContentSnapshot $safeUpdateProfiles
    $legacyManifestBefore = [System.IO.File]::ReadAllBytes($legacyManifestPath)
    $legacyVerify = Invoke-TestPowerShell $installer @(
        "-AppHome", $safeUpdateCase,
        "-VerifySafeUpdate",
        "-RefreshConfirmed",
        "-MihomoPath", $fakeCore,
        "-Json"
    )
    $legacyVerifyJson = Assert-JsonResult $legacyVerify "install" 1
    Assert-True (
        $legacyVerifyJson.status -eq "partial" -and
        $legacyVerifyJson.code -eq "safe_update_legacy_recovery_pending"
    ) "legacy safe-update manifest auto-restored an untrusted backup"
    Assert-True (
        (Get-TreeContentSnapshot $safeUpdateProfiles) -ceq $legacyCurrentBefore
    ) "legacy safe-update recovery changed current subscription files"
    Assert-True (
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($legacyManifestPath)) -eq
        [Convert]::ToBase64String($legacyManifestBefore)
    ) "legacy safe-update recovery consumed or rewrote its manifest"
    [System.IO.File]::WriteAllText(
        (Join-Path $safeUpdateProfiles "R-first.yaml"),
        $firstSafeUpdated
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $safeUpdateProfiles "R-second.yml"),
        ($secondSafeUpdated + "# refreshed after legacy recovery`n")
    )
    $legacyRecoveryRetry = Invoke-TestPowerShell $installer @(
        "-AppHome", $safeUpdateCase,
        "-VerifySafeUpdate",
        "-RefreshConfirmed",
        "-MihomoPath", $fakeCore,
        "-Json"
    )
    $legacyRecoveryRetryJson = Assert-JsonResult $legacyRecoveryRetry "install" 1
    Assert-True (
        $legacyRecoveryRetryJson.status -eq "partial" -and
        $legacyRecoveryRetryJson.code -eq "safe_update_legacy_snapshot_required"
    ) "legacy recovery without a runtime snapshot was reported as fully verified"
    Assert-True (-not (
        Test-Path -LiteralPath $legacyManifestPath
    )) "validated legacy recovery retry retained its manifest"
    [System.IO.File]::WriteAllText(
        (Join-Path $safeUpdateProfiles "R-second.yml"),
        $secondSafeUpdated
    )

    $noActionSnapshot = Invoke-TestPowerShell $installer @(
        "-AppHome", $safeUpdateCase,
        "-SnapshotProfiles",
        "-MihomoPath", $fakeCore,
        "-Json"
    )
    Assert-JsonResult $noActionSnapshot "install" 0 | Out-Null
    $noActionManifestPath = Join-Path $safeUpdateCase "claude-easy-safe-update.json"
    $missingRefreshConfirmation = Invoke-TestPowerShell $installer @(
        "-AppHome", $safeUpdateCase,
        "-VerifySafeUpdate",
        "-MihomoPath", $fakeCore,
        "-Json"
    )
    $missingRefreshConfirmationJson = Assert-JsonResult $missingRefreshConfirmation "install" 64
    Assert-True (
        $missingRefreshConfirmationJson.code -eq "missing_refresh_confirmation" -and
        (Test-Path -LiteralPath $noActionManifestPath)
    ) "safe update verification accepted a missing UI refresh confirmation"
    $noActionVerify = Invoke-TestPowerShell $installer @(
        "-AppHome", $safeUpdateCase,
        "-VerifySafeUpdate",
        "-RefreshConfirmed",
        "-MihomoPath", $fakeCore,
        "-Json"
    ) -SimulateRuntimeRefresh
    $noActionVerifyJson = Assert-JsonResult $noActionVerify "install" 0
    Assert-True (
        $noActionVerifyJson.code -eq "safe_update_verified"
    ) "explicit UI refresh confirmation rejected unchanged valid subscriptions"
    Assert-True (
        @($noActionVerifyJson.items | ForEach-Object { $_.status } | Where-Object { $_ -ne "unchanged" }).Count -eq 0
    ) "unchanged valid subscriptions were not reported as unchanged"
    Assert-True (-not (Test-Path -LiteralPath $noActionManifestPath)) "verified unchanged refresh retained the safe-update manifest"

    if ($onWindows) {
        Invoke-DeferredProbe "safe-update rollback manifest strong-kill recovery" {
            $rollbackCrashPackageParent = Join-Path $sandbox "safe-update-rollback-crash-package"
            New-Item -ItemType Directory -Path $rollbackCrashPackageParent -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $root "claude-easy") -Destination $rollbackCrashPackageParent -Recurse
            $rollbackCrashPackage = Join-Path $rollbackCrashPackageParent "claude-easy"
            $rollbackCrashInstaller = Join-Path (
                Join-Path $rollbackCrashPackage "scripts"
            ) "install_windows.ps1"
            $rollbackCrashInstallerText = [System.IO.File]::ReadAllText($rollbackCrashInstaller)
            $rollbackCrashNeedle = '                $manifestSnapshot $runtimeRecoveryBytes'
            $rollbackCrashOffset = $rollbackCrashInstallerText.IndexOf($rollbackCrashNeedle)
            Assert-True (
                $rollbackCrashOffset -ge 0 -and
                $rollbackCrashInstallerText.LastIndexOf($rollbackCrashNeedle) -eq $rollbackCrashOffset
            ) "safe-update rollback crash fixture could not find one rollback completion boundary"
            $rollbackCrashLineEnd = $rollbackCrashInstallerText.IndexOf("`n", $rollbackCrashOffset)
            Assert-True ($rollbackCrashLineEnd -gt $rollbackCrashOffset) "safe-update rollback call was not one complete line"
            $rollbackCrashHook = @'
        if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_EASY_TEST_SAFE_UPDATE_ROLLBACK_CRASH_READY)) {
            [System.IO.File]::WriteAllText($env:CLAUDE_EASY_TEST_SAFE_UPDATE_ROLLBACK_CRASH_READY, "ready")
            Start-Sleep -Seconds 30
        }
'@
            $rollbackCrashInstallerText = $rollbackCrashInstallerText.Insert(
                $rollbackCrashLineEnd + 1,
                $rollbackCrashHook
            )
            [System.IO.File]::WriteAllText(
                $rollbackCrashInstaller,
                $rollbackCrashInstallerText,
                (New-Object System.Text.UTF8Encoding($true))
            )

            $rollbackCrashHome = Join-Path $sandbox "safe-update-rollback-crash-home"
            $rollbackCrashProfiles = Join-Path $rollbackCrashHome "profiles"
            New-Item -ItemType Directory -Path $rollbackCrashProfiles -Force | Out-Null
            [System.IO.File]::WriteAllText(
                (Join-Path $rollbackCrashHome "config.yaml"),
                "mode: rule`nipv6: true`ntun: null`n"
            )
            [System.IO.File]::WriteAllText(
                (Join-Path $rollbackCrashHome "verge.yaml"),
                "enable_tun_mode: false`n"
            )
            [System.IO.File]::WriteAllText(
                (Join-Path $rollbackCrashHome "profiles.yaml"),
                "items:`n- uid: R-rollback-crash`n  type: remote`n  option:`n    allow_auto_update: true`n"
            )
            $rollbackCrashTarget = Join-Path $rollbackCrashProfiles "R-rollback-crash.yaml"
            $rollbackCrashOriginal = @'
mode: rule
proxies:
  - name: Node
    type: ss
    server: proxy.invalid
    port: 443
    cipher: aes-128-gcm
    password: fixture-secret
proxy-groups:
  - name: Main
    type: select
    proxies:
      - Node
rules:
  - MATCH,Main
'@
            [System.IO.File]::WriteAllText($rollbackCrashTarget, $rollbackCrashOriginal)
            $rollbackCrashInstall = Invoke-TestPowerShell $rollbackCrashInstaller @(
                "-AppHome", $rollbackCrashHome,
                "-UsageProfile", "1",
                "-MihomoPath", $fakeCore,
                "-Json"
            )
            Assert-JsonResult $rollbackCrashInstall "install" 0 | Out-Null
            $rollbackCrashSnapshot = Invoke-TestPowerShell $rollbackCrashInstaller @(
                "-AppHome", $rollbackCrashHome,
                "-SnapshotProfiles",
                "-MihomoPath", $fakeCore,
                "-Json"
            )
            Assert-JsonResult $rollbackCrashSnapshot "install" 0 | Out-Null
            [System.IO.File]::WriteAllText(
                $rollbackCrashTarget,
                "mode: rule`nproxies: []`nproxy-groups: []`nrules: []`n"
            )

            $rollbackCrashReady = Join-Path $sandbox "safe-update-rollback-crash.ready"
            $env:CLAUDE_EASY_TEST_SAFE_UPDATE_ROLLBACK_CRASH_READY = $rollbackCrashReady
            $rollbackCrashClient = Start-Process `
                -FilePath $script:safeUpdateClientPath `
                -ArgumentList @("-t", "127.0.0.1") `
                -PassThru
            $rollbackCrashChild = Start-Process -FilePath $PowerShellPath -ArgumentList @(
                "-NoLogo", "-NoProfile", "-File", $rollbackCrashInstaller,
                "-AppHome", $rollbackCrashHome,
                "-VerifySafeUpdate",
                "-RefreshConfirmed",
                "-MihomoPath", $fakeCore,
                "-Json"
            ) -PassThru
            try {
                $rollbackCrashDeadline = [DateTime]::UtcNow.AddSeconds(10)
                while (-not (Test-Path -LiteralPath $rollbackCrashReady -PathType Leaf) -and
                    -not $rollbackCrashChild.HasExited -and [DateTime]::UtcNow -lt $rollbackCrashDeadline) {
                    Start-Sleep -Milliseconds 25
                }
                Assert-True (
                    Test-Path -LiteralPath $rollbackCrashReady -PathType Leaf
                ) "safe-update verification did not reach the completed rollback boundary"
                Stop-Process -Id $rollbackCrashChild.Id -Force
                $rollbackCrashChild.WaitForExit()
            } finally {
                $env:CLAUDE_EASY_TEST_SAFE_UPDATE_ROLLBACK_CRASH_READY = $null
                if (-not $rollbackCrashChild.HasExited) {
                    Stop-Process -Id $rollbackCrashChild.Id -Force
                }
                if (-not $rollbackCrashClient.HasExited) {
                    Stop-Process -Id $rollbackCrashClient.Id -Force
                }
                $rollbackCrashClient.Dispose()
            }
            Assert-True (
                (Get-Content -LiteralPath $rollbackCrashTarget -Raw) -eq $rollbackCrashOriginal
            ) "safe-update rollback crash fixture did not restore the original subscription"
            $rollbackCrashRecoveryPath = Join-Path $rollbackCrashHome "claude-easy-safe-update.json"
            Assert-True (
                Test-Path -LiteralPath $rollbackCrashRecoveryPath -PathType Leaf
            ) "completed file rollback did not retain runtime recovery intent after process death"
            $rollbackCrashRecovery = [System.IO.File]::ReadAllText($rollbackCrashRecoveryPath) | ConvertFrom-Json
            Assert-True (
                (@($rollbackCrashRecovery.PSObject.Properties.Name | Sort-Object) -join ",") -ceq
                    "Kind,RestoreDispatchCommittedFor,Runtime,UsageProfile,Version" -and
                [string]$rollbackCrashRecovery.Kind -ceq "safe_update_runtime_recovery" -and
                [long]$rollbackCrashRecovery.Version -eq 2 -and
                $null -eq $rollbackCrashRecovery.RestoreDispatchCommittedFor
            ) "process death retained a reusable update manifest instead of strict runtime recovery intent"

            $rollbackCrashRetry = Invoke-TestPowerShell $rollbackCrashInstaller @(
                "-AppHome", $rollbackCrashHome,
                "-VerifySafeUpdate",
                "-RefreshConfirmed",
                "-MihomoPath", $fakeCore,
                "-Json"
            ) -SimulateRuntimeRefresh
            $rollbackCrashRetryJson = Assert-JsonResult $rollbackCrashRetry "install" 1
            Assert-True (
                $rollbackCrashRetryJson.status -eq "rolled_back" -and
                $rollbackCrashRetryJson.code -eq "safe_update_rolled_back"
            ) "runtime recovery did not resume after process death"
            Assert-True (-not (Test-Path -LiteralPath $rollbackCrashRecoveryPath)) "completed runtime recovery retained its record"
            Assert-True (
                (Get-Content -LiteralPath $rollbackCrashTarget -Raw) -eq $rollbackCrashOriginal
            ) "retry after rollback process death changed the restored subscription"
        }
    }

    if ($onWindows) {
        $concurrentVerifySnapshot = Invoke-TestPowerShell $installer @(
            "-AppHome", $safeUpdateCase,
            "-SnapshotProfiles",
            "-MihomoPath", $fakeCore
        )
        Assert-True ($concurrentVerifySnapshot.ExitCode -eq 0) "concurrent verification snapshot failed; $(Get-TestOutputDiagnostic $concurrentVerifySnapshot.Output)"
        [System.IO.File]::WriteAllText(
            (Join-Path $safeUpdateProfiles "R-first.yaml"),
            ($firstSafeUpdated + "# concurrent candidate one`n")
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $safeUpdateProfiles "R-second.yml"),
            ($secondSafeUpdated + "# concurrent candidate two`n")
        )
        $env:CLAUDE_EASY_MUTATE_TARGET = Join-Path $safeUpdateProfiles "R-first.yaml"
        try {
            $concurrentVerify = Invoke-TestPowerShell $installer @(
                "-AppHome", $safeUpdateCase, "-VerifySafeUpdate", "-RefreshConfirmed", "-MihomoPath", $mutatingCore
            )
        } finally {
            $env:CLAUDE_EASY_MUTATE_TARGET = $null
        }
        Assert-True ($concurrentVerify.ExitCode -eq 1) "safe update accepted bytes that replaced the file during Mihomo validation"
        Assert-True ((Get-Content -LiteralPath (Join-Path $safeUpdateProfiles "R-first.yaml") -Raw).Contains("friend_concurrent: true")) "safe update overwrote a concurrent refresh"
        Assert-True (Test-Path -LiteralPath (Join-Path $safeUpdateCase "claude-easy-safe-update.json") -PathType Leaf) "concurrent validation failure discarded its recovery manifest"
        Remove-Item -LiteralPath (Join-Path $safeUpdateCase "claude-easy-safe-update.json") -Force
        [System.IO.File]::WriteAllText(
            (Join-Path $safeUpdateProfiles "R-first.yaml"),
            $firstSafeUpdated
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $safeUpdateProfiles "R-second.yml"),
            $secondSafeUpdated
        )

        $indexConcurrentSnapshot = Invoke-TestPowerShell $installer @(
            "-AppHome", $safeUpdateCase,
            "-SnapshotProfiles",
            "-MihomoPath", $fakeCore,
            "-Json"
        )
        Assert-JsonResult $indexConcurrentSnapshot "install" 0 | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $safeUpdateProfiles "R-first.yaml"),
            ($firstSafeUpdated + "# index-race candidate one`n")
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $safeUpdateProfiles "R-second.yml"),
            ($secondSafeUpdated + "# index-race candidate two`n")
        )
        $indexConcurrentProfilesBefore = Get-TreeContentSnapshot $safeUpdateProfiles
        $indexConcurrentManifestPath = Join-Path $safeUpdateCase "claude-easy-safe-update.json"
        $indexConcurrentManifestBefore = [System.IO.File]::ReadAllBytes(
            $indexConcurrentManifestPath
        )
        $profilesIndexBeforeConcurrentVerify = [System.IO.File]::ReadAllBytes(
            (Join-Path $safeUpdateCase "profiles.yaml")
        )
        $env:CLAUDE_EASY_MUTATE_TARGET = Join-Path $safeUpdateCase "profiles.yaml"
        try {
            $indexConcurrentVerify = Invoke-TestPowerShell $installer @(
                "-AppHome", $safeUpdateCase,
                "-VerifySafeUpdate",
                "-RefreshConfirmed",
                "-MihomoPath", $mutatingCore,
                "-Json"
            )
        } finally {
            $env:CLAUDE_EASY_MUTATE_TARGET = $null
        }
        $indexConcurrentVerifyJson = Assert-JsonResult $indexConcurrentVerify "install" 1
        Assert-True (
            $indexConcurrentVerifyJson.status -eq "partial" -and
            $indexConcurrentVerifyJson.code -eq "safe_update_verification_retry_pending"
        ) "concurrent profiles index change triggered a safe-update rollback"
        Assert-True (
            (Get-TreeContentSnapshot $safeUpdateProfiles) -ceq
                $indexConcurrentProfilesBefore
        ) "concurrent profiles index change overwrote valid refreshed subscriptions"
        Assert-True (
            [Convert]::ToBase64String(
                [System.IO.File]::ReadAllBytes($indexConcurrentManifestPath)
            ) -eq [Convert]::ToBase64String($indexConcurrentManifestBefore)
        ) "concurrent profiles index change consumed or rewrote the recovery manifest"
        [System.IO.File]::WriteAllBytes(
            (Join-Path $safeUpdateCase "profiles.yaml"),
            $profilesIndexBeforeConcurrentVerify
        )
        Remove-Item -LiteralPath $indexConcurrentManifestPath -Force
        [System.IO.File]::WriteAllText(
            (Join-Path $safeUpdateProfiles "R-first.yaml"),
            $firstSafeUpdated
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $safeUpdateProfiles "R-second.yml"),
            $secondSafeUpdated
        )
    }

    Invoke-DeferredProbe "strict safe-update manifest schema" {
        $schemaSafeUpdateCase = Join-Path $sandbox "safe-update-schema-case"
        $schemaSafeUpdateProfiles = Join-Path $schemaSafeUpdateCase "profiles"
        New-Item -ItemType Directory -Path $schemaSafeUpdateProfiles -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $schemaSafeUpdateCase "profiles.yaml"),
            "items:`n- uid: R-schema`n  type: remote`n  option:`n    allow_auto_update: true`n"
        )
        $schemaSafeUpdateTarget = Join-Path $schemaSafeUpdateProfiles "R-schema.yaml"
        [System.IO.File]::WriteAllText(
            $schemaSafeUpdateTarget,
            "mode: rule`nproxies: []`nproxy-groups: [{ name: Main, type: select, proxies: [DIRECT] }]`nrules: [MATCH,Main]`n"
        )
        $schemaInstall = Invoke-TestPowerShell $installer @(
            "-AppHome", $schemaSafeUpdateCase,
            "-UsageProfile", "1",
            "-MihomoPath", $fakeCore
        )
        Assert-True ($schemaInstall.ExitCode -eq 0) "safe-update schema fixture install failed"
        $schemaSnapshot = Invoke-TestPowerShell $installer @(
            "-AppHome", $schemaSafeUpdateCase,
            "-SnapshotProfiles",
            "-MihomoPath", $fakeCore
        )
        Assert-True ($schemaSnapshot.ExitCode -eq 0) "safe-update schema fixture snapshot failed"
        $schemaUpdatedText = "mode: global`nproxy-groups: []`n"
        [System.IO.File]::WriteAllText($schemaSafeUpdateTarget, $schemaUpdatedText)
        $schemaManifestPath = Join-Path $schemaSafeUpdateCase "claude-easy-safe-update.json"
        $schemaManifest = Get-Content -LiteralPath $schemaManifestPath -Raw | ConvertFrom-Json
        $schemaManifest.Version = "1"
        $schemaManifest | Add-Member -NotePropertyName Extra -NotePropertyValue $true
        $schemaManifest.Profiles[0] | Add-Member -NotePropertyName Extra -NotePropertyValue $true
        [System.IO.File]::WriteAllText(
            $schemaManifestPath,
            (($schemaManifest | ConvertTo-Json -Depth 5) + "`r`n"),
            (New-Object System.Text.UTF8Encoding($false))
        )
        $schemaVerify = Invoke-TestPowerShell $installer @(
            "-AppHome", $schemaSafeUpdateCase,
            "-VerifySafeUpdate",
            "-RefreshConfirmed",
            "-MihomoPath", $fakeCore,
            "-Json"
        )
        Assert-True (
            $schemaVerify.ExitCode -eq 1 -and
            (Test-Path -LiteralPath $schemaManifestPath -PathType Leaf) -and
            (Get-Content -LiteralPath $schemaSafeUpdateTarget -Raw) -eq $schemaUpdatedText
        ) "safe update accepted a manifest with non-canonical types or extra fields"
    }

    Invoke-DeferredProbe "strict UTF-8 safe-update validation" {
        $utf8SafeUpdateCase = Join-Path $sandbox "safe-update-invalid-utf8-case"
        $utf8SafeUpdateProfiles = Join-Path $utf8SafeUpdateCase "profiles"
        New-Item -ItemType Directory -Path $utf8SafeUpdateProfiles -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $utf8SafeUpdateCase "profiles.yaml"),
            "items:`n- uid: R-utf8`n  type: remote`n  option:`n    allow_auto_update: true`n"
        )
        $utf8SafeUpdateTarget = Join-Path $utf8SafeUpdateProfiles "R-utf8.yaml"
        $utf8OriginalText = "mode: rule`nproxies: []`nproxy-groups: [{ name: Main, type: select, proxies: [DIRECT] }]`nrules: [MATCH,Main]`n"
        $utf8OriginalBytes = [System.Text.Encoding]::UTF8.GetBytes($utf8OriginalText)
        [System.IO.File]::WriteAllBytes($utf8SafeUpdateTarget, $utf8OriginalBytes)
        $utf8Install = Invoke-TestPowerShell $installer @(
            "-AppHome", $utf8SafeUpdateCase,
            "-UsageProfile", "1",
            "-MihomoPath", $fakeCore
        )
        Assert-True (
            $utf8Install.ExitCode -eq 0
        ) "invalid UTF-8 fixture install failed; $(Get-TestOutputDiagnostic $utf8Install.Output)"
        $utf8Snapshot = Invoke-TestPowerShell $installer @(
            "-AppHome", $utf8SafeUpdateCase,
            "-SnapshotProfiles",
            "-MihomoPath", $fakeCore
        )
        Assert-True ($utf8Snapshot.ExitCode -eq 0) "invalid UTF-8 fixture snapshot failed"
        [byte[]]$utf8InvalidBytes = @(
            [System.Text.Encoding]::UTF8.GetBytes("mode: rule`n# invalid ")
        ) + [byte[]]@(0xff) + [byte[]]@(
            [System.Text.Encoding]::UTF8.GetBytes(
                "`nproxies: []`nproxy-groups: [{ name: Main, type: select, proxies: [DIRECT] }]`nrules: [MATCH,Main]`n"
            )
        )
        [System.IO.File]::WriteAllBytes($utf8SafeUpdateTarget, $utf8InvalidBytes)
        $utf8Verify = Invoke-TestPowerShell $installer @(
            "-AppHome", $utf8SafeUpdateCase,
            "-VerifySafeUpdate",
            "-RefreshConfirmed",
            "-MihomoPath", $fakeCore,
            "-Json"
        ) -SimulateRuntimeRefresh
        $utf8ManifestPath = Join-Path $utf8SafeUpdateCase "claude-easy-safe-update.json"
        Assert-True (
            $utf8Verify.ExitCode -eq 1
        ) "safe update accepted invalid UTF-8 bytes; $(Get-TestOutputDiagnostic $utf8Verify.Output)"
        Assert-True (
            [Convert]::ToBase64String(
                [System.IO.File]::ReadAllBytes($utf8SafeUpdateTarget)
            ) -ceq [Convert]::ToBase64String($utf8OriginalBytes)
        ) "invalid UTF-8 safe update did not restore the exact original bytes"
        Assert-True (
            -not (Test-Path -LiteralPath $utf8ManifestPath)
        ) "invalid UTF-8 safe update retained a stale recovery manifest"
    }

    $missingMappingDirectory = Join-Path $safeUpdateCase "missing-mapping"
    New-Item -ItemType Directory -Path $missingMappingDirectory -Force | Out-Null
    $missingMappingTarget = Join-Path $missingMappingDirectory "R-mapping.yaml"
    $missingMappingRecovery = [pscustomobject]@{
        Uid = "R-mapping"
        File = "R-mapping.yaml"
        TargetPath = $missingMappingTarget
    }
    $missingMappingIndex = "items:`n- uid: R-mapping`n  type: remote`n"
    $missingMappingTargets = @(
        Get-SafeUpdateVerificationTargets `
            $missingMappingIndex $missingMappingDirectory @($missingMappingRecovery)
    )
    Assert-True (
        $missingMappingTargets.Count -eq 1 -and
        $missingMappingTargets[0].Path -eq $missingMappingTarget
    ) "safe update could not bind an absent manifest target to an unchanged index"
    $alternateMappingTarget = Join-Path $missingMappingDirectory "R-mapping.yml"
    [System.IO.File]::WriteAllText($alternateMappingTarget, "concurrent: true`n")
    $alternateMappingRejected = $false
    try {
        Get-SafeUpdateVerificationTargets `
            $missingMappingIndex $missingMappingDirectory @($missingMappingRecovery) | Out-Null
    } catch {
        $alternateMappingRejected = $true
    }
    Assert-True $alternateMappingRejected "safe update accepted a replacement under the alternate subscription extension"
    Assert-True (
        (Get-Content -LiteralPath $alternateMappingTarget -Raw) -eq "concurrent: true`n"
    ) "safe update changed a replacement under the alternate subscription extension"

    $unitRestoreManifestPath = Join-Path $safeUpdateProfiles "unit-restore-manifest.json"
    [System.IO.File]::WriteAllText($unitRestoreManifestPath, '{"Version":1}')
    $unitRestoreManifestSnapshot = Get-OptionalFileSnapshot $unitRestoreManifestPath "测试安全更新准备记录"
    $concurrentTarget = Join-Path $safeUpdateProfiles "concurrent.yaml"
    $concurrentBackup = Join-Path $safeUpdateProfiles "concurrent.backup"
    [System.IO.File]::WriteAllText($concurrentTarget, "observed: true`n")
    [System.IO.File]::WriteAllText($concurrentBackup, "before: true`n")
    $observedHashes = @{ $concurrentTarget = (Get-FileSha256 $concurrentTarget) }
    [System.IO.File]::WriteAllText($concurrentTarget, "newer: true`n")
    $concurrentRecovery = [pscustomobject]@{
        Uid = "account_private_42"
        File = "concurrent.yaml"
        TargetPath = $concurrentTarget
        BackupPath = $concurrentBackup
        BeforeSha256 = (Get-FileSha256 $concurrentBackup)
    }
    $concurrentRestore = Restore-SafeUpdateFiles `
        @($concurrentRecovery) $observedHashes $unitRestoreManifestPath $unitRestoreManifestSnapshot
    Assert-True ($concurrentRestore.Conflicts.Count -eq 1) "safe update rollback did not detect a concurrent subscription change"
    Assert-True (
        -not ((@($concurrentRestore.Conflicts) -join "").Contains("account_private_42")) -and
        -not ((@($concurrentRestore.Conflicts) -join "").Contains("concurrent.yaml"))
    ) "safe update rollback conflict exposed a uid or subscription filename"
    Assert-True ((Get-Content -LiteralPath $concurrentTarget -Raw) -eq "newer: true`n") "safe update rollback overwrote a concurrent subscription change"
    Assert-True (Test-Path -LiteralPath $unitRestoreManifestPath -PathType Leaf) "safe update conflict consumed its recovery manifest"

    $reappearedTarget = Join-Path $safeUpdateProfiles "reappeared.yaml"
    $reappearedBackup = Join-Path $safeUpdateProfiles "reappeared.backup"
    [System.IO.File]::WriteAllText($reappearedBackup, "before: true`n")
    $reappearedRecovery = [pscustomobject]@{
        File = "reappeared.yaml"
        TargetPath = $reappearedTarget
        BackupPath = $reappearedBackup
        BeforeSha256 = Get-FileSha256 $reappearedBackup
    }
    $missingObservedHashes = @{ $reappearedTarget = "" }
    [System.IO.File]::WriteAllText($reappearedTarget, "concurrent: true`n")
    $reappearedRestore = Restore-SafeUpdateFiles `
        @($reappearedRecovery) $missingObservedHashes $unitRestoreManifestPath $unitRestoreManifestSnapshot
    Assert-True ($reappearedRestore.Conflicts.Count -eq 1) "safe update rollback did not detect a subscription created after a missing-target observation"
    Assert-True ((Get-Content -LiteralPath $reappearedTarget -Raw) -eq "concurrent: true`n") "safe update rollback overwrote a subscription created after a missing-target observation"
    Assert-True (Test-Path -LiteralPath $unitRestoreManifestPath -PathType Leaf) "missing-target conflict consumed its recovery manifest"

    $batchFirstTarget = Join-Path $safeUpdateProfiles "batch-first.yaml"
    $batchFirstBackup = Join-Path $safeUpdateProfiles "batch-first.backup"
    $batchSecondTarget = Join-Path $safeUpdateProfiles "batch-second.yaml"
    $batchSecondBackup = Join-Path $safeUpdateProfiles "batch-second.backup"
    [System.IO.File]::WriteAllText($batchFirstTarget, "first-updated: true`n")
    [System.IO.File]::WriteAllText($batchFirstBackup, "first-before: true`n")
    [System.IO.File]::WriteAllText($batchSecondTarget, "second-concurrent: true`n")
    [System.IO.File]::WriteAllText($batchSecondBackup, "second-before: true`n")
    $batchRecoveryItems = @(
        [pscustomobject]@{
            File = "batch-first.yaml"
            TargetPath = $batchFirstTarget
            BackupPath = $batchFirstBackup
            BeforeSha256 = Get-FileSha256 $batchFirstBackup
        },
        [pscustomobject]@{
            File = "batch-second.yaml"
            TargetPath = $batchSecondTarget
            BackupPath = $batchSecondBackup
            BeforeSha256 = Get-FileSha256 $batchSecondBackup
        }
    )
    $batchObservedHashes = @{
        $batchFirstTarget = Get-FileSha256 $batchFirstTarget
        $batchSecondTarget = Get-BytesSha256 ([System.Text.Encoding]::UTF8.GetBytes("second-observed: true`n"))
    }
    $batchRestore = Restore-SafeUpdateFiles `
        $batchRecoveryItems $batchObservedHashes $unitRestoreManifestPath $unitRestoreManifestSnapshot
    Assert-True ($batchRestore.Conflicts.Count -eq 1) "safe update rollback missed a conflict in the second item"
    Assert-True ((Get-Content -LiteralPath $batchFirstTarget -Raw) -eq "first-updated: true`n") "safe update rollback partially restored the first item before finding a later conflict"
    Assert-True ((Get-Content -LiteralPath $batchSecondTarget -Raw) -eq "second-concurrent: true`n") "safe update rollback changed the conflicting second item"
    Assert-True (Test-Path -LiteralPath $unitRestoreManifestPath -PathType Leaf) "batch rollback conflict consumed its recovery manifest"

    $badBackupTarget = Join-Path $safeUpdateProfiles "bad-backup-target.yaml"
    $badBackupPath = Join-Path $safeUpdateProfiles "bad-backup.backup"
    [System.IO.File]::WriteAllText($badBackupTarget, "still-valid: true`n")
    [System.IO.File]::WriteAllText($badBackupPath, "original: true`n")
    $badBackupExpectedSha = Get-FileSha256 $badBackupPath
    $badBackupObservedHashes = @{ $badBackupTarget = (Get-FileSha256 $badBackupTarget) }
    [System.IO.File]::WriteAllText($badBackupPath, "corrupt: true`n")
    $badBackupRecovery = [pscustomobject]@{
        File = "bad-backup-target.yaml"
        TargetPath = $badBackupTarget
        BackupPath = $badBackupPath
        BeforeSha256 = $badBackupExpectedSha
    }
    $badBackupRestore = Restore-SafeUpdateFiles `
        @($badBackupRecovery) $badBackupObservedHashes $unitRestoreManifestPath $unitRestoreManifestSnapshot
    Assert-True ($badBackupRestore.Failures.Count -eq 1) "safe update rollback accepted backup bytes that changed after validation"
    Assert-True ((Get-Content -LiteralPath $badBackupTarget -Raw) -eq "still-valid: true`n") "corrupt backup overwrote a still-valid subscription before rejection"
    Assert-True (Test-Path -LiteralPath $unitRestoreManifestPath -PathType Leaf) "bad backup consumed its recovery manifest"

    if ($null -ne $safeUpdateControllerJob) {
        Stop-Job $safeUpdateControllerJob -ErrorAction SilentlyContinue
        Remove-Job $safeUpdateControllerJob -Force -ErrorAction SilentlyContinue
        $safeUpdateControllerJob = $null
    }
    $script:safeUpdateControllerPort = 0
    $script:safeUpdateClientPath = ""

    if ($onWindows) {
        Invoke-DeferredProbe "public restore same-byte identity replacement" {
            $identityRestoreCase = Join-Path $sandbox "public-restore-identity-case"
            $identityRestoreBackupRoot = Join-Path $identityRestoreCase "claude-easy-backups"
            $identityRestoreTarget = Join-Path $identityRestoreCase "config.yaml"
            New-Item -ItemType Directory -Path $identityRestoreCase -Force | Out-Null
            $identityRestoreBackupText = "mode: rule`nipv6: false`ntun:`n  enable: true`n  stack: system`n  dns-hijack:`n    - any:53`n  auto-route: true`n  auto-detect-interface: true`n  strict-route: true`nproxies: []`nproxy-groups: []`nrules: []`n"
            $identityRestoreCurrentText = "mode: global`nipv6: false`ntun:`n  enable: true`n  stack: system`n  dns-hijack:`n    - any:53`n  auto-route: true`n  auto-detect-interface: true`n  strict-route: true`nproxies: []`nproxy-groups: []`nrules: []`n"
            [System.IO.File]::WriteAllText((Join-Path $identityRestoreCase "claude-easy-usage-profile.json"), '{"Version":1,"Profile":3}')
            [System.IO.File]::WriteAllText($identityRestoreTarget, $identityRestoreBackupText)
            $identityRestoreBackup = Backup-Versioned $identityRestoreTarget $identityRestoreBackupRoot "prewrite"
            [System.IO.File]::WriteAllText($identityRestoreTarget, $identityRestoreCurrentText)
            $identityRestoreExpectedHash = Get-FileSha256 $identityRestoreTarget
            $env:CLAUDE_EASY_MUTATE_TARGET = $identityRestoreTarget
            try {
                $identityRestoreResult = Invoke-TestPowerShell $installer @(
                    "-AppHome", $identityRestoreCase,
                    "-RestoreBackup", (Split-Path -Leaf $identityRestoreBackup),
                    "-ExpectedCurrentSha256", $identityRestoreExpectedHash,
                    "-MihomoPath", $identityMutatingCore,
                    "-Json"
                )
            } finally {
                $env:CLAUDE_EASY_MUTATE_TARGET = $null
            }
            $identityRestorePreserved = (Get-Content -LiteralPath $identityRestoreTarget -Raw) -eq $identityRestoreCurrentText
            Assert-True (
                $identityRestoreResult.ExitCode -eq 1 -and
                $identityRestorePreserved
            ) "public restore overwrote a same-byte file whose identity changed during validation"
        }
    }

    $internalRestoreCase = Join-Path $sandbox "internal-state-restore-case"
    $internalRestoreBackupRoot = Join-Path $internalRestoreCase "claude-easy-backups"
    $internalUsagePath = Join-Path $internalRestoreCase "claude-easy-usage-profile.json"
    New-Item -ItemType Directory -Path $internalRestoreCase -Force | Out-Null
    [System.IO.File]::WriteAllText($internalUsagePath, '{"Version":1,"Profile":3}')
    $internalUsageBackup = Backup-Versioned $internalUsagePath $internalRestoreBackupRoot "prewrite"
    [System.IO.File]::WriteAllText($internalUsagePath, '{"Version":1,"Profile":2}')
    $internalUsageBeforeRestore = [System.IO.File]::ReadAllBytes($internalUsagePath)
    $internalRestoreResult = Invoke-TestPowerShell $installer @(
        "-AppHome", $internalRestoreCase,
        "-RestoreBackup", (Split-Path -Leaf $internalUsageBackup),
        "-ExpectedCurrentSha256", (Get-BytesSha256 $internalUsageBeforeRestore),
        "-MihomoPath", $fakeCore
    )
    Assert-True ($internalRestoreResult.ExitCode -eq 1) "public backup restore accepted an internal state file"
    Assert-True (
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($internalUsagePath)) -eq
        [Convert]::ToBase64String($internalUsageBeforeRestore)
    ) "rejected internal state restore changed the current state"

    $protectedProfilesPath = Join-Path $internalRestoreCase "profiles.yaml"
    [System.IO.File]::WriteAllText($protectedProfilesPath, "items:`n- uid: R-protected`n  type: remote`n  option:`n    allow_auto_update: true`n")
    $protectedProfilesBackup = Backup-Versioned $protectedProfilesPath $internalRestoreBackupRoot "prewrite"
    [System.IO.File]::WriteAllText($protectedProfilesPath, "items:`n- uid: R-protected`n  type: remote`n  option:`n    allow_auto_update: false`n")
    $protectedProfilesBeforeRestore = [System.IO.File]::ReadAllBytes($protectedProfilesPath)
    $protectedProfilesRestore = Invoke-TestPowerShell $installer @(
        "-AppHome", $internalRestoreCase,
        "-RestoreBackup", (Split-Path -Leaf $protectedProfilesBackup),
        "-ExpectedCurrentSha256", (Get-BytesSha256 $protectedProfilesBeforeRestore),
        "-MihomoPath", $fakeCore
    )
    Assert-True ($protectedProfilesRestore.ExitCode -eq 1) "public backup restore accepted profiles.yaml"
    Assert-True (
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($protectedProfilesPath)) -eq
        [Convert]::ToBase64String($protectedProfilesBeforeRestore)
    ) "rejected profiles.yaml restore changed automatic-update state"

    $beforeComparison = "dns:`n  nameserver:`n    - https://old-secret.invalid/dns-query`nrules:`n  - MATCH,OldSecret`nipv6: true`n"
    $afterComparison = "dns:`n  nameserver:`n    - https://new-secret.invalid/dns-query`nrules:`n  - MATCH,NewSecret`n  - GEOSITE,CN,DIRECT`ninvalid-key: kept`n"
    $changedFields = @(Get-RedactedYamlChangedPaths $beforeComparison $afterComparison)
    Assert-True ($changedFields -contains "dns.nameserver") "Windows comparison did not identify dns.nameserver"
    Assert-True ($changedFields -contains "rules") "Windows comparison did not identify the rules section"
    Assert-True ($changedFields -contains "ipv6") "Windows comparison did not identify a removed field"
    Assert-True ($changedFields -contains "invalid-key") "Windows comparison did not identify an added field"
    Assert-True (-not (($changedFields -join " ").Contains("Secret"))) "Windows comparison exposed a configuration value"
    $arrayBefore = "proxies:`n  - name: SecretOne`n    type: ss`n  - name: SecretTwo`n    type: vmess`n"
    $arrayAfter = "proxies:`n  - name: SecretOne`n    type: ss`n  - name: SecretTwo`n    type: trojan`n"
    $arrayChanges = @(Get-RedactedYamlChangedPaths $arrayBefore $arrayAfter)
    Assert-True ($arrayChanges -contains "proxies") "Windows comparison did not safely summarize a changed mapping array"
    Assert-True (-not (($arrayChanges -join " ").Contains("Secret"))) "Windows array comparison exposed a configuration value"
    $providerBefore = "proxy-providers:`n  provider-secret:`n    url: https://old.invalid/sub`n"
    $providerAfter = "proxy-providers:`n  provider-secret:`n    url: https://new.invalid/sub`n"
    $providerChanges = @(Get-RedactedYamlChangedPaths $providerBefore $providerAfter)
    Assert-True ($providerChanges -contains "proxy-providers.[item].url") "Windows comparison did not redact a provider key"
    Assert-True (-not (($providerChanges -join " ").Contains("provider-secret"))) "Windows comparison exposed a provider key"
    $mapBefore = "proxies:`n  secret-node:`n    type: ss`nproxy-groups:`n  secret-group:`n    type: select`n"
    $mapAfter = "proxies:`n  secret-node:`n    type: trojan`nproxy-groups:`n  secret-group:`n    type: url-test`n"
    $mapChanges = @(Get-RedactedYamlChangedPaths $mapBefore $mapAfter)
    Assert-True ($mapChanges -contains "proxies.[item].type") "Windows comparison did not redact a map-style proxy key"
    Assert-True ($mapChanges -contains "proxy-groups.[item].type") "Windows comparison did not redact a map-style group key"
    Assert-True (-not (($mapChanges -join " ").Contains("secret-"))) "Windows comparison exposed a map-style proxy or group key"
    $routeGroups = [pscustomobject]@{
        "Proxy" = [pscustomobject]@{ type = "Selector"; now = "Taiwan" }
        "🤖 AI · ClaudeEasy" = [pscustomobject]@{ type = "Selector"; now = "Taiwan" }
    }
    Assert-True ((Find-Group $routeGroups @("AI") "" "AI 分组") -eq "🤖 AI · ClaudeEasy") "Windows route verifier did not recognize its managed AI group"
    $routeChains = [pscustomobject]@{
        Main = [pscustomobject]@{ type = "Selector"; now = "Taiwan" }
        AI = [pscustomobject]@{ type = "Selector"; now = "Japan" }
        Taiwan = [pscustomobject]@{ type = "Shadowsocks" }
        Japan = [pscustomobject]@{ type = "Shadowsocks" }
        Singapore = [pscustomobject]@{ type = "Shadowsocks" }
        Google = [pscustomobject]@{ type = "Selector"; now = "Singapore" }
        Gaming = [pscustomobject]@{ type = "Selector"; now = "GameNode" }
        Balanced = [pscustomobject]@{ type = "LoadBalance" }
        "Balance Node" = [pscustomobject]@{ type = "Shadowsocks" }
        Auto = [pscustomobject]@{ type = "URLTest"; now = "Node A" }
        Fallback = [pscustomobject]@{ type = "Fallback"; now = "Node A" }
        "Node A" = [pscustomobject]@{ type = "Shadowsocks" }
        "Node B" = [pscustomobject]@{ type = "Vmess" }
        Local = [pscustomobject]@{ type = "Direct" }
    }
    Assert-True (
        Test-UsableRouteGroupSelection $routeChains.Balanced
    ) "Windows route verifier rejected a load-balance AI group without now"
    Assert-True (-not (Test-RouteChains $routeChains @("Singapore", "Google") "Main" "Taiwan" "AI" $true)) "Windows route verifier accepted Google without the main group"
    Assert-True (Test-RouteChains $routeChains @("Singapore", "Google", "Main") "Main" "Taiwan" "AI" $true) "Windows route verifier rejected Google through the main group"
    Assert-True (-not (Test-RouteChains $routeChains @("GameNode", "Gaming") "Main" "Taiwan" "AI" $true)) "Windows route verifier accepted an unrelated selector for Google traffic"
    Assert-True (-not (Test-RouteChains $routeChains @("Japan", "AI", "Google") "Main" "Taiwan" "AI" $true)) "Windows route verifier accepted the AI group for ordinary Google traffic"
    Assert-True (Test-RouteChains $routeChains @("Japan", "AI") "AI" "Japan" "AI" $true) "Windows route verifier rejected Google traffic when the expected group was the AI group"
    Assert-True (Test-RouteChains $routeChains @("Japan", "AI") "AI" "Japan" "AI" $false) "Windows route verifier rejected the required AI group"
    Assert-True (Test-RouteChains $routeChains @("Balance Node", "Balanced") "Balanced" "" "AI" $true) "Windows route verifier rejected a load-balance group without now"
    Assert-True (-not (Test-RouteChains $routeChains @("Balanced") "Balanced" "" "AI" $true)) "Windows route verifier accepted a load-balance chain without a concrete node"
    Assert-True (-not (Test-RouteChains $routeChains @("Balance Node", "Main") "Main" "" "AI" $true)) "Windows route verifier accepted a selector without now"
    Assert-True (Test-RouteChains $routeChains @("Node B", "Auto") "Auto" "Node A" "AI" $true) "Windows route verifier rejected the observed URLTest leaf"
    Assert-True (Test-RouteChains $routeChains @("Node B", "Fallback") "Fallback" "Node A" "AI" $true) "Windows route verifier rejected the observed Fallback leaf"
    foreach ($nonProxyType in @("Direct", "Dns", "Reject", "RejectDrop", "Pass", "PassRule", "Compatible", "Rematch", "Relay")) {
        $routeChains.Local.type = $nonProxyType
        Assert-True (
            -not (Test-RouteChains $routeChains @("Local", "Main") "Main" "Local" "AI" $true)
        ) "Windows route verifier accepted a custom $nonProxyType main leaf"
        Assert-True (
            -not (Test-RouteChains $routeChains @("Local", "AI") "AI" "Local" "AI" $false)
        ) "Windows route verifier accepted a custom $nonProxyType AI leaf"
    }
    $routeChains.Local.type = "Direct"
    $routeProviders = [pscustomobject]@{
        remote = [pscustomobject]@{
            proxies = @(
                [pscustomobject]@{ name = "Provider Node"; type = "Shadowsocks" },
                [pscustomobject]@{ name = "Provider Direct"; type = "Direct" }
            )
        }
    }
    Assert-True (
        Test-RouteChains $routeChains @("Provider Node", "Balanced") "Balanced" "" "AI" $true $routeProviders @("remote", "")
    ) "Windows route verifier rejected a provider-backed load-balance leaf"
    Assert-True (-not (
        Test-RouteChains $routeChains @("Provider Direct", "Balanced") "Balanced" "" "AI" $true $routeProviders @("remote", "")
    )) "Windows route verifier accepted a provider Direct leaf"
    Assert-True (-not (
        Test-RouteChains $routeChains @("Unknown", "Balanced") "Balanced" "" "AI" $true $routeProviders @("remote", "")
    )) "Windows route verifier accepted an unknown provider leaf"
    Assert-True (-not (
        Test-RouteChains $routeChains @("Provider Node", "Balanced") "Balanced" "" "AI" $true $routeProviders @("missing", "")
    )) "Windows route verifier accepted an unknown provider"
    Invoke-DeferredProbe "non-proxy route termini" {
        $acceptedNonProxyTermini = @(
            foreach ($terminus in @("REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "RELAY")) {
                if (Test-RouteChains $routeChains @($terminus, "Japan", "AI") "AI" "Japan" "AI" $false) {
                    $terminus
                }
            }
        )
        Assert-True ($acceptedNonProxyTermini.Count -eq 0) (
            "Windows route verifier accepted non-proxy termini: " + ($acceptedNonProxyTermini -join ", ")
        )
    }

    Assert-True (Test-MihomoVersionText "Mihomo Meta v1.19.27") "minimum Mihomo version was rejected"
    Assert-True (-not (Test-MihomoVersionText "Mihomo Meta v1.19.26")) "old Mihomo version was accepted"
    if ($onWindows) {
        $commandSyntaxCore = Join-Path $sandbox "mihomo&friend.cmd"
        [System.IO.File]::WriteAllText(
            $commandSyntaxCore,
            "@echo off`r`necho Mihomo Meta v1.19.27 windows amd64`r`n",
            [System.Text.Encoding]::ASCII
        )
        $commandSyntaxRejected = $false
        try { Invoke-Mihomo $commandSyntaxCore @("-v") | Out-Null } catch {
            $commandSyntaxRejected = $_.Exception.Message.Contains("命令解释器字符")
        }
        Assert-True $commandSyntaxRejected "Mihomo command-script path accepted command syntax"
    }
    $timeoutCore = $hangingCore
    $timeoutArguments = @("-v")
    if ($onWindows) {
        $timeoutCore = Join-Path (Join-Path $env:SystemRoot "System32") "ping.exe"
        $timeoutArguments = @("-n", "6", "127.0.0.1")
    }
    $timeoutRaised = $false
    $timeoutError = ""
    $timeoutWatch = [System.Diagnostics.Stopwatch]::StartNew()
    try { Invoke-Mihomo $timeoutCore $timeoutArguments 1 | Out-Null } catch {
        $timeoutError = $_.Exception.Message
        $timeoutRaised = $timeoutError.Contains("超过 1 秒")
    }
    $timeoutWatch.Stop()
    Assert-True $timeoutRaised "hanging Mihomo process did not fail closed after one second: $timeoutError"
    Assert-True ($timeoutWatch.Elapsed.TotalSeconds -lt 4) "hanging Mihomo process was not terminated promptly"

    if ($onWindows) {
        Invoke-DeferredProbe "Mihomo timeout terminates descendants" {
            $treeScriptPath = Join-Path $sandbox "mihomo-process-tree.ps1"
            $treeChildIdPath = Join-Path $sandbox "mihomo-process-tree-child-id.txt"
            $treeScriptSource = @'
param([string]$ChildIdPath)
$ErrorActionPreference = "Stop"
$child = Start-Process -FilePath (Join-Path $env:SystemRoot "System32\ping.exe") `
    -ArgumentList @("-n", "30", "127.0.0.1") -PassThru
[System.IO.File]::WriteAllText($ChildIdPath, $child.Id.ToString())
$child.WaitForExit()
'@
            [System.IO.File]::WriteAllText($treeScriptPath, $treeScriptSource, [System.Text.Encoding]::ASCII)
            $treeTimeoutRaised = $false
            try {
                Invoke-Mihomo $PowerShellPath @(
                    "-NoLogo", "-NoProfile", "-File", $treeScriptPath,
                    "-ChildIdPath", $treeChildIdPath
                ) 1 | Out-Null
            } catch {
                $treeTimeoutRaised = $_.Exception.Message.Contains("超过 1 秒")
            }
            $treeChildId = 0
            if (Test-Path -LiteralPath $treeChildIdPath -PathType Leaf) {
                $treeChildId = [int](Get-Content -LiteralPath $treeChildIdPath -Raw)
            }
            $treeChildAlive = $false
            if ($treeChildId -gt 0) {
                $treeChildExitDeadline = [DateTime]::UtcNow.AddSeconds(5)
                do {
                    $treeChildProcess = Get-Process -Id $treeChildId -ErrorAction SilentlyContinue
                    if ($null -eq $treeChildProcess) { break }
                    Start-Sleep -Milliseconds 25
                } while ([DateTime]::UtcNow -lt $treeChildExitDeadline)
                $treeChildProcess = Get-Process -Id $treeChildId -ErrorAction SilentlyContinue
                $treeChildAlive = $null -ne $treeChildProcess
                if ($treeChildAlive) {
                    Stop-Process -Id $treeChildId -Force
                    [void]$treeChildProcess.WaitForExit(5000)
                    Assert-True (
                        $null -eq (Get-Process -Id $treeChildId -ErrorAction SilentlyContinue)
                    ) "process-tree fixture could not clean up its descendant"
                }
            }
            Assert-True $treeTimeoutRaised "process-tree fixture did not reach the Mihomo timeout"
            Assert-True (-not $treeChildAlive) "Mihomo timeout left a descendant process running"
        }

        Invoke-DeferredProbe "Mihomo candidate privacy and cleanup after caller death" {
            $candidateDirectory = Join-Path $sandbox "candidate-process-death"
            $candidateChildPath = Join-Path $sandbox "candidate-process-death.ps1"
            New-Item -ItemType Directory -Path $candidateDirectory -Force | Out-Null
            $candidateChildSource = @'
param(
    [string]$TransactionModulePath,
    [string]$ModulePath,
    [string]$CorePath,
    [string]$Directory
)
$ErrorActionPreference = "Stop"
function Test-GeneratedYaml {
    param([string]$Text)
    return $true
}
. $TransactionModulePath
. $ModulePath
Test-MihomoCandidate $CorePath "proxies:`n  - name: fixture-private-marker" $Directory
'@
            [System.IO.File]::WriteAllText(
                $candidateChildPath,
                $candidateChildSource,
                [System.Text.Encoding]::ASCII
            )
            $candidateChild = Start-Process -FilePath $PowerShellPath -ArgumentList @(
                "-NoLogo", "-NoProfile", "-File", $candidateChildPath,
                "-TransactionModulePath", (Join-Path $installerModuleRoot "transaction.ps1"),
                "-ModulePath", (Join-Path $installerModuleRoot "mihomo.ps1"),
                "-CorePath", $candidateHangingCore,
                "-Directory", $candidateDirectory
            ) -PassThru
            $candidateDeadline = [DateTime]::UtcNow.AddSeconds(10)
            $candidateFiles = @()
            while ($candidateFiles.Count -eq 0 -and
                -not $candidateChild.HasExited -and [DateTime]::UtcNow -lt $candidateDeadline) {
                Start-Sleep -Milliseconds 25
                $candidateFiles = @(Get-ChildItem -LiteralPath $candidateDirectory -Filter ".claude-easy-validate-*.yaml" -File)
            }
            $candidateAppeared = $candidateFiles.Count -eq 1
            $candidateAclIsPrivate = $candidateAppeared -and
                (Test-PrivateWindowsFileAcl $candidateFiles[0].FullName)
            if (-not $candidateChild.HasExited) {
                Stop-Process -Id $candidateChild.Id -Force
                $candidateChild.WaitForExit()
            }
            $candidateCleanupDeadline = [DateTime]::UtcNow.AddSeconds(10)
            do {
                Start-Sleep -Milliseconds 100
                $candidateFiles = @(Get-ChildItem -LiteralPath $candidateDirectory -Filter ".claude-easy-validate-*.yaml" -File)
            } while ($candidateFiles.Count -gt 0 -and [DateTime]::UtcNow -lt $candidateCleanupDeadline)
            $candidateLeftBehind = $candidateFiles.Count -gt 0
            foreach ($candidateFile in $candidateFiles) {
                Remove-Item -LiteralPath $candidateFile.FullName -Force
            }
            Assert-True $candidateAppeared "candidate cleanup fixture never created its validation file"
            Assert-True $candidateAclIsPrivate "Mihomo candidate inherited access for unrelated accounts"
            Assert-True (-not $candidateLeftBehind) "caller death left a Mihomo candidate file behind"
        }
    }

    $backupSource = Join-Path $sandbox "backup-source.txt"
    $versionedBackupRoot = Join-Path $sandbox "versioned-backups"
    $backupBytes = [byte[]](0xEF, 0xBB, 0xBF, 0x66, 0x69, 0x72, 0x73, 0x74)
    [System.IO.File]::WriteAllBytes($backupSource, $backupBytes)
    $firstVersionedBackup = Backup-Versioned $backupSource $versionedBackupRoot "prewrite"
    [System.IO.File]::WriteAllText($backupSource, "second")
    $secondVersionedBackup = Backup-Versioned $backupSource $versionedBackupRoot "prewrite"
    Assert-True ($firstVersionedBackup -ne $secondVersionedBackup) "versioned backups collided"
    Assert-True ((Split-Path -Leaf $firstVersionedBackup) -match '^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.\d{7}[+-]\d{4}--prewrite--[0-9a-f]{16}--backup-source\.txt\.backup$') "versioned backup name lacks a date: $firstVersionedBackup"
    $savedBackup = [System.IO.File]::ReadAllBytes($firstVersionedBackup)
    Assert-True (([Convert]::ToBase64String($savedBackup)) -eq ([Convert]::ToBase64String($backupBytes))) "first versioned backup changed"
    Assert-True ((Get-Content -LiteralPath $secondVersionedBackup -Raw) -eq "second") "second versioned backup did not capture the next write"
    $cultureBackupSource = Join-Path $sandbox "culture-backup-source.txt"
    [System.IO.File]::WriteAllText($cultureBackupSource, "culture")
    $previousCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = New-Object System.Globalization.CultureInfo("th-TH")
        $gregorianYear = [DateTime]::Now.ToString("yyyy", [System.Globalization.CultureInfo]::InvariantCulture)
        $cultureBackup = Backup-Versioned $cultureBackupSource $versionedBackupRoot "prewrite"
        Assert-True ((Split-Path -Leaf $cultureBackup).StartsWith($gregorianYear + "-")) "versioned backup timestamp followed the host calendar"
        Get-PublicBackupDescriptor (Split-Path -Leaf $cultureBackup) | Out-Null
    } finally {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture
    }
    $lockedBackupGuard = Open-SafeUpdateVersionGuard $backupSource "测试备份来源"
    try {
        $lockedBackupBytes = Get-StreamBytes $lockedBackupGuard.Stream
        $lockedVersionedBackup = Backup-Versioned `
            $backupSource `
            $versionedBackupRoot `
            "pre-update" `
            -SourceBytes $lockedBackupBytes `
            -UseSourceBytes
        Assert-True (
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($lockedVersionedBackup)) -eq
            [Convert]::ToBase64String($lockedBackupBytes)
        ) "locked snapshot bytes were not used for the versioned backup"
    } finally {
        $lockedBackupGuard.Stream.Dispose()
        for ($guardIndex = $lockedBackupGuard.DirectoryGuards.Count - 1; $guardIndex -ge 0; $guardIndex--) {
            $lockedBackupGuard.DirectoryGuards[$guardIndex].Dispose()
        }
    }
    $initialOne = Backup-InitialOnce $backupSource $versionedBackupRoot
    $initialTwo = Backup-InitialOnce $backupSource $versionedBackupRoot
    Assert-True (-not [string]::IsNullOrWhiteSpace($initialOne)) "initial backup was not created"
    Assert-True ([string]::IsNullOrWhiteSpace($initialTwo)) "initial backup was duplicated"
    $emptyHashFile = Join-Path $sandbox "empty-hash.bin"
    [System.IO.File]::WriteAllBytes($emptyHashFile, [byte[]]@())
    Assert-True ((Get-FileSha256 $emptyHashFile) -eq "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") "empty content did not hash as the empty SHA-256"
    if ($onWindows) {
        Invoke-DeferredProbe "backup publication survives caller death" {
            $backupCrashPackageParent = Join-Path $sandbox "backup-crash-package"
            New-Item -ItemType Directory -Path $backupCrashPackageParent -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $root "claude-easy") -Destination $backupCrashPackageParent -Recurse
            $backupCrashPackage = Join-Path $backupCrashPackageParent "claude-easy"
            $backupCrashInstaller = Join-Path (Join-Path $backupCrashPackage "scripts") "install_windows.ps1"
            $backupCrashTransaction = Join-Path (Join-Path (Join-Path $backupCrashPackage "scripts") "windows/install_windows") "transaction.ps1"
            $backupCrashTransactionText = [System.IO.File]::ReadAllText($backupCrashTransaction)
            $backupCopyNeedle = '        $sourceStream.CopyTo($backupStream)'
            $backupCopyOffset = $backupCrashTransactionText.IndexOf($backupCopyNeedle)
            Assert-True ($backupCopyOffset -ge 0) "backup crash fixture could not find the backup copy boundary"
            $backupCrashHook = @'
        $partial = [System.Text.Encoding]::UTF8.GetBytes("function main(config) {")
        $backupStream.Write($partial, 0, $partial.Length)
        $backupStream.SetLength($partial.Length)
        $backupStream.Flush($true)
        [System.IO.File]::WriteAllText($env:CLAUDE_EASY_TEST_BACKUP_CRASH_READY, "ready")
        Start-Sleep -Seconds 30
'@
            $backupCrashTransactionText = $backupCrashTransactionText.Insert(
                $backupCopyOffset,
                $backupCrashHook
            )
            [System.IO.File]::WriteAllText(
                $backupCrashTransaction,
                $backupCrashTransactionText,
                (New-Object System.Text.UTF8Encoding($true))
            )

            $backupCrashHome = Join-Path $sandbox "backup-crash-home"
            $backupCrashProfiles = Join-Path $backupCrashHome "profiles"
            $backupCrashRoot = Join-Path $backupCrashHome "claude-easy-backups"
            $backupCrashReady = Join-Path $sandbox "backup-crash.ready"
            New-Item -ItemType Directory -Path $backupCrashProfiles -Force | Out-Null
            Write-TestUtf8Text `
                (Join-Path $backupCrashProfiles "Script.js") `
                "function main(config) { config.friend = true; return config; }`n"
            [System.IO.File]::WriteAllText((Join-Path $backupCrashHome "config.yaml"), "ipv6: true`ntun: null`n")
            [System.IO.File]::WriteAllText((Join-Path $backupCrashHome "verge.yaml"), "enable_tun_mode: false`n")
            [System.IO.File]::WriteAllText(
                (Join-Path $backupCrashHome "profiles.yaml"),
                "items:`n- uid: R-backup-crash`n  type: remote`n  option:`n    allow_auto_update: true`n"
            )
            $env:CLAUDE_EASY_TEST_BACKUP_CRASH_READY = $backupCrashReady
            $backupCrashChild = Start-Process -FilePath $PowerShellPath -ArgumentList @(
                "-NoLogo", "-NoProfile", "-File", $backupCrashInstaller,
                "-AppHome", $backupCrashHome,
                "-UsageProfile", "1",
                "-MihomoPath", $fakeCore
            ) -PassThru
            try {
                $backupCrashDeadline = [DateTime]::UtcNow.AddSeconds(10)
                while (-not (Test-Path -LiteralPath $backupCrashReady -PathType Leaf) -and
                    -not $backupCrashChild.HasExited -and [DateTime]::UtcNow -lt $backupCrashDeadline) {
                    Start-Sleep -Milliseconds 25
                }
                Assert-True (Test-Path -LiteralPath $backupCrashReady -PathType Leaf) "public installer did not reach the partial backup write"
                Stop-Process -Id $backupCrashChild.Id -Force
                $backupCrashChild.WaitForExit()
            } finally {
                $env:CLAUDE_EASY_TEST_BACKUP_CRASH_READY = $null
                if (-not $backupCrashChild.HasExited) { Stop-Process -Id $backupCrashChild.Id -Force }
            }
            $publishedBackups = @(
                Get-ChildItem -LiteralPath $backupCrashRoot -File -Filter "*.backup" -ErrorAction SilentlyContinue
            )
            Assert-True ($publishedBackups.Count -eq 0) "caller death published a partial formal backup"
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $backupCrashHome ".claude-easy-transaction.json"))) "partial backup unexpectedly created a file transaction journal"
            $backupCrashList = Invoke-TestPowerShell $backupCrashInstaller @(
                "-AppHome", $backupCrashHome,
                "-ListBackups",
                "-Json"
            )
            $backupCrashListJson = Assert-JsonResult $backupCrashList "install" 0
            Assert-True (@($backupCrashListJson.items).Count -eq 0) "public backup list exposed an interrupted temporary backup"
        }

        $stableKeyHome = Join-Path $sandbox "stable-key-home"
        $stableKeyProfiles = Join-Path $stableKeyHome "profiles"
        $stableKeyTarget = Join-Path $stableKeyProfiles "R-stable.yaml"
        New-Item -ItemType Directory -Path $stableKeyProfiles -Force | Out-Null
        [System.IO.File]::WriteAllText($stableKeyTarget, "proxies: []`n")
        $stableKeyLock = Enter-AppHomeMutationLock $stableKeyHome
        try {
            $stableKeyBeforeRename = Get-PathKey $stableKeyTarget
            $stableKeyCaseAlias = Get-PathKey (Join-Path ($stableKeyHome.ToUpperInvariant()) "PROFILES\R-STABLE.YAML")
            $stableKeyExtendedAlias = Get-PathKey ("\\?\" + $stableKeyTarget)
            Assert-True ($stableKeyBeforeRename -eq $stableKeyCaseAlias) "backup identity changed across a case-only path alias"
            Assert-True ($stableKeyBeforeRename -eq $stableKeyExtendedAlias) "backup identity changed across an extended path alias"
            Invoke-DeferredProbe "short-path backup identity alias" {
                $stableKeyShortTarget = Get-WindowsShortPath $stableKeyTarget
                if ([string]::IsNullOrWhiteSpace($stableKeyShortTarget) -or
                    [string]::Equals(
                        $stableKeyShortTarget,
                        $stableKeyTarget,
                        [StringComparison]::OrdinalIgnoreCase
                    )) {
                    Write-Host "8.3 short-path aliases are unavailable on this runner; short-path identity case skipped"
                    return
                }
                $stableKeyShortAlias = Get-PathKey $stableKeyShortTarget
                Assert-True ($stableKeyBeforeRename -eq $stableKeyShortAlias) "backup identity changed across an 8.3 short-path alias"
            }
        } finally {
            Exit-AppHomeMutationLock $stableKeyLock
        }
        $stableKeyRenamedHome = Join-Path $sandbox "stable-key-home-renamed"
        [System.IO.Directory]::Move($stableKeyHome, $stableKeyRenamedHome)
        $stableKeyLock = Enter-AppHomeMutationLock $stableKeyRenamedHome
        try {
            $stableKeyAfterRename = Get-PathKey (Join-Path (Join-Path $stableKeyRenamedHome "profiles") "R-stable.yaml")
            Assert-True ($stableKeyBeforeRename -eq $stableKeyAfterRename) "backup identity changed after AppHome was renamed"
        } finally {
            Exit-AppHomeMutationLock $stableKeyLock
        }

        $backupAcl = Get-Acl -LiteralPath $firstVersionedBackup
        Assert-True $backupAcl.AreAccessRulesProtected "backup ACL still inherits permissions"
        $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $hasCurrentUser = @($backupAcl.Access | Where-Object {
            $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq $currentSid -and
            $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow
        }).Count -gt 0
        Assert-True $hasCurrentUser "backup ACL does not allow the current user"
    }

    $uninstallBackupSource = Join-Path $sandbox "uninstall-script.js"
    [System.IO.File]::WriteAllBytes($uninstallBackupSource, $backupBytes)
    $uninstallBackupOne = New-UninstallBackup $uninstallBackupSource
    $uninstallBackupTwo = New-UninstallBackup $uninstallBackupSource
    Assert-True ($uninstallBackupOne -ne $uninstallBackupTwo) "same-second uninstall backups collided"
    Assert-True (([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($uninstallBackupOne))) -eq ([Convert]::ToBase64String($backupBytes))) "first uninstall backup changed bytes"
    Assert-True (([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($uninstallBackupTwo))) -eq ([Convert]::ToBase64String($backupBytes))) "second uninstall backup changed bytes"

    $transactionDir = Join-Path $sandbox "transaction"
    New-Item -ItemType Directory -Path $transactionDir -Force | Out-Null
    $stateSnapshotPath = Join-Path $transactionDir "state-snapshot.json"
    $stateSnapshotBytes = [System.Text.Encoding]::UTF8.GetBytes('{"Version":1}')
    [System.IO.File]::WriteAllBytes($stateSnapshotPath, $stateSnapshotBytes)
    $stateSnapshot = Get-OptionalFileSnapshot $stateSnapshotPath "test state"
    [System.IO.File]::WriteAllText($stateSnapshotPath, "changed-after-read")
    Assert-True $stateSnapshot.Exists "optional state snapshot missed an existing file"
    Assert-True (
        [Convert]::ToBase64String($stateSnapshot.Bytes) -eq [Convert]::ToBase64String($stateSnapshotBytes)
    ) "optional state snapshot did not retain the exact bytes it parsed"
    $missingStateSnapshot = Get-OptionalFileSnapshot (Join-Path $transactionDir "missing-state.json") "missing state"
    Assert-True (-not $missingStateSnapshot.Exists) "optional state snapshot invented a missing file"
    $stateDirectoryPath = Join-Path $transactionDir "state-directory"
    New-Item -ItemType Directory -Path $stateDirectoryPath -Force | Out-Null
    $stateDirectoryRejected = $false
    try { Get-OptionalFileSnapshot $stateDirectoryPath "directory state" | Out-Null } catch { $stateDirectoryRejected = $true }
    Assert-True $stateDirectoryRejected "optional state snapshot treated a directory as missing state"
    $stateBindingEntry = [pscustomobject]@{
        Existed = $true
        OriginalBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("pre-install"))
        InstalledSha256 = Get-BytesSha256 ([System.Text.Encoding]::UTF8.GetBytes("installed-a"))
    }
    $stateBindingSnapshot = [pscustomobject]@{
        Exists = $true
        Bytes = [System.Text.Encoding]::UTF8.GetBytes("installed-b")
    }
    $stateBindingRejected = $false
    try { Assert-StateSnapshotUnchanged $stateBindingEntry $stateBindingSnapshot "state binding" } catch {
        $stateBindingRejected = $true
    }
    Assert-True $stateBindingRejected "reinstall accepted a snapshot that did not match the saved installed version"
    $missingInstalledEntry = [pscustomobject]@{
        Existed = $false
        OriginalBase64 = ""
        InstalledSha256 = Get-BytesSha256 ([byte[]]@())
    }
    $missingInstalledSnapshot = [pscustomobject]@{ Exists = $false; Bytes = $null }
    $missingInstalledAccepted = $true
    try { Assert-StateSnapshotUnchanged $missingInstalledEntry $missingInstalledSnapshot "missing installed file" } catch {
        $missingInstalledAccepted = $false
    }
    Assert-True $missingInstalledAccepted "reinstall rejected a file that remained absent after a lightweight install"
    $stateSnapshotWritePath = Join-Path $transactionDir "state-snapshot-write.txt"
    $stateSnapshotWriteOriginal = [System.Text.Encoding]::UTF8.GetBytes("state-write-original")
    [System.IO.File]::WriteAllBytes($stateSnapshotWritePath, $stateSnapshotWriteOriginal)
    $stateSnapshotWriteIdentity = (Get-OptionalFileSnapshot $stateSnapshotWritePath "state snapshot write").Identity
    $staleStateSnapshotRejected = $false
    try {
        Invoke-VerifiedWriteDeleteTransaction @(
            [pscustomobject]@{
                Path = $stateSnapshotWritePath
                Bytes = [System.Text.Encoding]::UTF8.GetBytes("state-write-new")
                Existed = $true
                OriginalBytes = $stateSnapshotWriteOriginal
                OriginalIdentity = $stateSnapshotWriteIdentity
            }
        ) @(
            [pscustomobject]@{
                Path = $stateSnapshotPath
                Existed = $true
                OriginalBytes = $stateSnapshot.Bytes
                OriginalIdentity = $stateSnapshot.Identity
            }
        )
    } catch { $staleStateSnapshotRejected = $true }
    Assert-True $staleStateSnapshotRejected "transaction deleted a newer state file using an older parsed snapshot"
    Assert-True ((Get-Content -LiteralPath $stateSnapshotPath -Raw) -eq "changed-after-read") "stale state rejection changed the newer state file"
    Assert-True ((Get-Content -LiteralPath $stateSnapshotWritePath -Raw) -eq "state-write-original") "stale state rejection changed an unrelated write target"

    if ($onWindows) {
        $preparationRecoveryDir = Join-Path $sandbox "preparation-recovery"
        $preparationRecoveryTarget = Join-Path $preparationRecoveryDir "new-state.json"
        New-Item -ItemType Directory -Path $preparationRecoveryDir -Force | Out-Null
        $preparationRecoveryLock = Enter-AppHomeMutationLock $preparationRecoveryDir
        try {
            Write-FileTransactionPreparation @(
                [pscustomobject]@{
                    Path = $preparationRecoveryTarget
                    CreateNew = $true
                }
            ) | Out-Null
            [System.IO.File]::WriteAllText($preparationRecoveryTarget, "external-content")
            $preparationExternalRejected = $false
            try { Repair-InterruptedFilePreparation } catch { $preparationExternalRejected = $true }
            Assert-True $preparationExternalRejected "preparation recovery deleted a nonempty external target"
            Assert-True (
                (Get-Content -LiteralPath $preparationRecoveryTarget -Raw) -eq "external-content"
            ) "preparation recovery changed a nonempty external target"
            Assert-True (
                Test-Path -LiteralPath (
                    Join-Path $preparationRecoveryDir ".claude-easy-transaction-preparation.json"
                ) -PathType Leaf
            ) "failed preparation recovery discarded its retry record"

            [System.IO.File]::WriteAllBytes($preparationRecoveryTarget, [byte[]]@())
            Repair-InterruptedFilePreparation
            Assert-True (-not (
                Test-Path -LiteralPath $preparationRecoveryTarget
            )) "preparation recovery retained an empty transaction target"
            Assert-True (-not (
                Test-Path -LiteralPath (
                    Join-Path $preparationRecoveryDir ".claude-easy-transaction-preparation.json"
                )
            )) "successful preparation recovery retained its record"
        } finally {
            Exit-AppHomeMutationLock $preparationRecoveryLock
        }

        $outsideTransactionDir = Join-Path $sandbox "outside-transaction"
        $junctionPath = Join-Path $transactionDir "junction"
        $outsideSentinelPath = Join-Path $outsideTransactionDir "sentinel.txt"
        New-Item -ItemType Directory -Path $outsideTransactionDir -Force | Out-Null
        [System.IO.File]::WriteAllText($outsideSentinelPath, "outside-original")
        New-Item -ItemType Junction -Path $junctionPath -Target $outsideTransactionDir | Out-Null
        $junctionRejected = $false
        try {
            Invoke-VerifiedFileTransaction @(
                [pscustomobject]@{
                    Path = Join-Path $junctionPath "sentinel.txt"
                    Bytes = [System.Text.Encoding]::UTF8.GetBytes("outside-overwritten")
                    Existed = $true
                    OriginalBytes = [System.Text.Encoding]::UTF8.GetBytes("outside-original")
                }
            )
        } catch { $junctionRejected = $true }
        Assert-True $junctionRejected "transaction followed a directory junction outside its expected tree"
        Assert-True ((Get-Content -LiteralPath $outsideSentinelPath -Raw) -eq "outside-original") "junction rejection did not preserve the outside sentinel"

        $raceParentPath = Join-Path $transactionDir "race-parent"
        $raceParentMovedPath = Join-Path $transactionDir "race-parent-original"
        $raceOutsidePath = Join-Path $outsideTransactionDir "race-parent"
        New-Item -ItemType Directory -Path $raceParentPath -Force | Out-Null
        New-Item -ItemType Directory -Path $raceOutsidePath -Force | Out-Null
        $raceTargetPath = Join-Path $raceParentPath "target.txt"
        $raceOutsideTargetPath = Join-Path $raceOutsidePath "target.txt"
        [System.IO.File]::WriteAllText($raceTargetPath, "inside-original")
        [System.IO.File]::WriteAllText($raceOutsideTargetPath, "outside-original")
        $raceSnapshot = Get-OptionalFileSnapshot $raceTargetPath "race target"
        $savedNoReparseAssertion = ${function:Assert-NoReparsePointPath}
        $script:parentSwapInjected = $false
        try {
            function Assert-NoReparsePointPath([string]$Path, [string]$Label) {
                & $savedNoReparseAssertion $Path $Label
                if (-not $script:parentSwapInjected -and $Path -eq $raceTargetPath) {
                    $script:parentSwapInjected = $true
                    [System.IO.Directory]::Move($raceParentPath, $raceParentMovedPath)
                    New-Item -ItemType Junction -Path $raceParentPath -Target $raceOutsidePath | Out-Null
                }
            }
            $parentSwapRejected = $false
            try {
                Invoke-VerifiedFileTransaction @(
                    [pscustomobject]@{
                        Path = $raceTargetPath
                        Bytes = [System.Text.Encoding]::UTF8.GetBytes("must-not-write")
                        Existed = $true
                        OriginalBytes = $raceSnapshot.Bytes
                        OriginalIdentity = $raceSnapshot.Identity
                    }
                )
            } catch { $parentSwapRejected = $true }
            Assert-True $script:parentSwapInjected "parent-junction race fixture did not run"
            Assert-True $parentSwapRejected "transaction followed a parent directory swapped after path validation"
            Assert-True ((Get-Content -LiteralPath $raceOutsideTargetPath -Raw) -eq "outside-original") "parent-junction race changed the outside target"
            Assert-True ((Get-Content -LiteralPath (Join-Path $raceParentMovedPath "target.txt") -Raw) -eq "inside-original") "parent-junction race changed the original target"
        } finally {
            Set-Item -Path Function:\Assert-NoReparsePointPath -Value $savedNoReparseAssertion
            Remove-Variable -Name parentSwapInjected -Scope Script -ErrorAction SilentlyContinue
        }

        $hardLinkSourcePath = Join-Path $transactionDir "hardlink-source.txt"
        $hardLinkAliasPath = Join-Path $transactionDir "hardlink-alias.txt"
        [System.IO.File]::WriteAllText($hardLinkSourcePath, "hardlink-original")
        New-Item -ItemType HardLink -Path $hardLinkAliasPath -Target $hardLinkSourcePath | Out-Null
        $hardLinkRejected = $false
        try {
            Invoke-VerifiedFileTransaction @(
                [pscustomobject]@{
                    Path = $hardLinkAliasPath
                    Bytes = [System.Text.Encoding]::UTF8.GetBytes("hardlink-overwritten")
                    Existed = $true
                    OriginalBytes = [System.Text.Encoding]::UTF8.GetBytes("hardlink-original")
                }
            )
        } catch { $hardLinkRejected = $true }
        Assert-True $hardLinkRejected "transaction modified a file with a hard-link alias"
        Assert-True ((Get-Content -LiteralPath $hardLinkSourcePath -Raw) -eq "hardlink-original") "hard-link rejection changed the aliased source"
        Assert-True ((Get-Content -LiteralPath $hardLinkAliasPath -Raw) -eq "hardlink-original") "hard-link rejection changed the target alias"

        $sameBytesWritePath = Join-Path $transactionDir "same-bytes-write.txt"
        $sameBytesWriteReplacement = Join-Path $transactionDir "same-bytes-write-replacement.txt"
        $sameBytes = [System.Text.Encoding]::UTF8.GetBytes("same-bytes")
        [System.IO.File]::WriteAllBytes($sameBytesWritePath, $sameBytes)
        $sameBytesWriteSnapshot = Get-OptionalFileSnapshot $sameBytesWritePath "same-bytes write"
        [System.IO.File]::WriteAllBytes($sameBytesWriteReplacement, $sameBytes)
        $sameBytesWriteBackup = Join-Path $transactionDir "same-bytes-write-old.txt"
        [System.IO.File]::Replace($sameBytesWriteReplacement, $sameBytesWritePath, $sameBytesWriteBackup)
        [System.IO.File]::Delete($sameBytesWriteBackup)
        $sameBytesWriteCurrent = Get-OptionalFileSnapshot $sameBytesWritePath "same-bytes replaced write"
        Assert-True ($sameBytesWriteCurrent.Identity -cne $sameBytesWriteSnapshot.Identity) "same-bytes write fixture did not replace the file identity"
        Wait-ClashVergeRuntimeRefresh $sameBytesWritePath ([pscustomobject]@{
            Snapshot = $sameBytesWriteSnapshot
        })
        $sameBytesWriteRejected = $false
        try {
            Invoke-VerifiedFileTransaction @(
                [pscustomobject]@{
                    Path = $sameBytesWritePath
                    Bytes = [System.Text.Encoding]::UTF8.GetBytes("must-not-write")
                    Existed = $true
                    OriginalBytes = $sameBytesWriteSnapshot.Bytes
                    OriginalIdentity = $sameBytesWriteSnapshot.Identity
                }
            )
        } catch { $sameBytesWriteRejected = $true }
        Assert-True $sameBytesWriteRejected "transaction overwrote a same-content replacement with a different file identity"
        Assert-True ((Get-Content -LiteralPath $sameBytesWritePath -Raw) -eq "same-bytes") "identity rejection changed the replacement write target"

        $sameBytesDeletePath = Join-Path $transactionDir "same-bytes-delete.txt"
        $sameBytesDeleteReplacement = Join-Path $transactionDir "same-bytes-delete-replacement.txt"
        [System.IO.File]::WriteAllBytes($sameBytesDeletePath, $sameBytes)
        $sameBytesDeleteSnapshot = Get-OptionalFileSnapshot $sameBytesDeletePath "same-bytes delete"
        [System.IO.File]::WriteAllBytes($sameBytesDeleteReplacement, $sameBytes)
        $sameBytesDeleteBackup = Join-Path $transactionDir "same-bytes-delete-old.txt"
        [System.IO.File]::Replace($sameBytesDeleteReplacement, $sameBytesDeletePath, $sameBytesDeleteBackup)
        [System.IO.File]::Delete($sameBytesDeleteBackup)
        $sameBytesDeleteCurrent = Get-OptionalFileSnapshot $sameBytesDeletePath "same-bytes replaced delete"
        Assert-True ($sameBytesDeleteCurrent.Identity -cne $sameBytesDeleteSnapshot.Identity) "same-bytes delete fixture did not replace the file identity"
        $sameBytesDeleteRejected = $false
        try {
            Invoke-VerifiedWriteDeleteTransaction @() @(
                [pscustomobject]@{
                    Path = $sameBytesDeletePath
                    Existed = $true
                    OriginalBytes = $sameBytesDeleteSnapshot.Bytes
                    OriginalIdentity = $sameBytesDeleteSnapshot.Identity
                }
            )
        } catch { $sameBytesDeleteRejected = $true }
        Assert-True $sameBytesDeleteRejected "transaction deleted a same-content replacement with a different file identity"
        Assert-True ((Get-Content -LiteralPath $sameBytesDeletePath -Raw) -eq "same-bytes") "identity rejection removed the replacement delete target"

        $crashWriteHome = Join-Path $sandbox "crash-write-home"
        $crashWriteFirstPath = Join-Path $crashWriteHome "first.txt"
        $crashWriteSecondPath = Join-Path $crashWriteHome "second.txt"
        $crashWriteReadyPath = Join-Path $sandbox "crash-write.ready"
        $crashWriteChildPath = Join-Path $sandbox "crash-write-child.ps1"
        New-Item -ItemType Directory -Path $crashWriteHome -Force | Out-Null
        [System.IO.File]::WriteAllText($crashWriteFirstPath, "first-original")
        [System.IO.File]::WriteAllText($crashWriteSecondPath, "second-original")
        $crashWriteChildSource = @'
param(
    [string]$ModulePath,
    [string]$AppHome,
    [string]$FirstPath,
    [string]$SecondPath,
    [string]$ReadyPath
)
$ErrorActionPreference = "Stop"
. $ModulePath
$held = Enter-AppHomeMutationLock $AppHome
$first = Get-OptionalFileSnapshot $FirstPath "first"
$second = Get-OptionalFileSnapshot $SecondPath "second"
$savedWriter = ${function:Write-LockedStreamBytes}
$script:writeCount = 0
function Write-LockedStreamBytes(
    [System.IO.FileStream]$Stream,
    [byte[]]$Replacement,
    [byte[]]$Original
) {
    & $savedWriter $Stream $Replacement $Original
    $script:writeCount++
    if ($script:writeCount -eq 1) {
        [System.IO.File]::WriteAllText($ReadyPath, "ready")
        Start-Sleep -Seconds 30
    }
}
try {
    Invoke-VerifiedFileTransaction @(
        [pscustomobject]@{ Path = $FirstPath; Bytes = [System.Text.Encoding]::UTF8.GetBytes("first-new"); Existed = $true; OriginalBytes = $first.Bytes; OriginalIdentity = $first.Identity },
        [pscustomobject]@{ Path = $SecondPath; Bytes = [System.Text.Encoding]::UTF8.GetBytes("second-new"); Existed = $true; OriginalBytes = $second.Bytes; OriginalIdentity = $second.Identity }
    )
} finally {
    Exit-AppHomeMutationLock $held
}
'@
        [System.IO.File]::WriteAllText($crashWriteChildPath, $crashWriteChildSource, [System.Text.Encoding]::ASCII)
        $crashWriteChild = Start-Process -FilePath $PowerShellPath -ArgumentList @(
            "-NoLogo", "-NoProfile", "-File", $crashWriteChildPath,
            "-ModulePath", (Join-Path $installerModuleRoot "transaction.ps1"),
            "-AppHome", $crashWriteHome,
            "-FirstPath", $crashWriteFirstPath,
            "-SecondPath", $crashWriteSecondPath,
            "-ReadyPath", $crashWriteReadyPath
        ) -PassThru
        $crashWriteDeadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $crashWriteReadyPath -PathType Leaf) -and
            -not $crashWriteChild.HasExited -and [DateTime]::UtcNow -lt $crashWriteDeadline) {
            Start-Sleep -Milliseconds 25
        }
        Assert-True (Test-Path -LiteralPath $crashWriteReadyPath -PathType Leaf) "crash-write child did not reach the first durable write"
        Stop-Process -Id $crashWriteChild.Id -Force
        $crashWriteChild.WaitForExit()
        Assert-True ((Get-Content -LiteralPath $crashWriteFirstPath -Raw) -eq "first-new") "crash-write fixture did not leave a partial transaction"
        Assert-True ((Get-Content -LiteralPath $crashWriteSecondPath -Raw) -eq "second-original") "crash-write fixture unexpectedly completed the transaction"
        $crashWriteJournalPath = Join-Path $crashWriteHome ".claude-easy-transaction.json"
        $crashWriteJournalIsPrivate = Test-PrivateWindowsFileAcl $crashWriteJournalPath
        Invoke-DeferredProbe "private transaction journal ACL" {
            Assert-True $crashWriteJournalIsPrivate "transaction journal inherited access for unrelated accounts"
        }
        $crashWriteRecoveryLock = Enter-AppHomeMutationLock $crashWriteHome
        Exit-AppHomeMutationLock $crashWriteRecoveryLock
        Assert-True ((Get-Content -LiteralPath $crashWriteFirstPath -Raw) -eq "first-original") "next operation did not recover a write interrupted by process death"
        Assert-True ((Get-Content -LiteralPath $crashWriteSecondPath -Raw) -eq "second-original") "write recovery changed an untouched transaction target"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $crashWriteHome ".claude-easy-transaction.json"))) "write recovery left a stale transaction journal"

        Invoke-DeferredProbe "interrupted transaction same-byte identity replacement" {
            $identityCrashHome = Join-Path $sandbox "identity-crash-write-home"
            $identityCrashFirstPath = Join-Path $identityCrashHome "first.txt"
            $identityCrashSecondPath = Join-Path $identityCrashHome "second.txt"
            $identityCrashReadyPath = Join-Path $sandbox "identity-crash-write.ready"
            New-Item -ItemType Directory -Path $identityCrashHome -Force | Out-Null
            [System.IO.File]::WriteAllText($identityCrashFirstPath, "first-original")
            [System.IO.File]::WriteAllText($identityCrashSecondPath, "second-original")
            $identityCrashChild = Start-Process -FilePath $PowerShellPath -ArgumentList @(
                "-NoLogo", "-NoProfile", "-File", $crashWriteChildPath,
                "-ModulePath", (Join-Path $installerModuleRoot "transaction.ps1"),
                "-AppHome", $identityCrashHome,
                "-FirstPath", $identityCrashFirstPath,
                "-SecondPath", $identityCrashSecondPath,
                "-ReadyPath", $identityCrashReadyPath
            ) -PassThru
            try {
                $identityCrashDeadline = [DateTime]::UtcNow.AddSeconds(10)
                while (-not (Test-Path -LiteralPath $identityCrashReadyPath -PathType Leaf) -and
                    -not $identityCrashChild.HasExited -and [DateTime]::UtcNow -lt $identityCrashDeadline) {
                    Start-Sleep -Milliseconds 25
                }
                Assert-True (Test-Path -LiteralPath $identityCrashReadyPath -PathType Leaf) "identity crash child did not reach the first durable write"
                Stop-Process -Id $identityCrashChild.Id -Force
                $identityCrashChild.WaitForExit()
            } finally {
                if (-not $identityCrashChild.HasExited) { Stop-Process -Id $identityCrashChild.Id -Force }
            }
            Assert-True ((Get-Content -LiteralPath $identityCrashFirstPath -Raw) -eq "first-new") "identity crash fixture did not leave a partial transaction"
            $writtenIdentity = (Get-OptionalFileSnapshot $identityCrashFirstPath "identity crash written target").Identity
            $identityReplacement = Join-Path $identityCrashHome "replacement.tmp"
            $identityDisplaced = Join-Path $identityCrashHome "displaced.tmp"
            [System.IO.File]::WriteAllText($identityReplacement, "first-new")
            [System.IO.File]::Move($identityCrashFirstPath, $identityDisplaced)
            [System.IO.File]::Move($identityReplacement, $identityCrashFirstPath)
            [System.IO.File]::Delete($identityDisplaced)
            $replacementIdentity = (Get-OptionalFileSnapshot $identityCrashFirstPath "identity crash replacement").Identity
            Assert-True ($replacementIdentity -cne $writtenIdentity) "identity crash fixture did not replace the file identity"

            $identityRecoveryRejected = $false
            try {
                $identityRecoveryLock = Enter-AppHomeMutationLock $identityCrashHome
                Exit-AppHomeMutationLock $identityRecoveryLock
            } catch {
                $identityRecoveryRejected = $true
            }
            $identityAfterRecovery = (Get-OptionalFileSnapshot $identityCrashFirstPath "identity crash after recovery").Identity
            $identityContentPreserved = (Get-Content -LiteralPath $identityCrashFirstPath -Raw) -eq "first-new"
            Assert-True (
                $identityRecoveryRejected -and
                $identityAfterRecovery -ceq $replacementIdentity -and
                $identityContentPreserved
            ) "interrupted recovery overwrote a same-byte file with a different identity"

            $originalReplacement = Join-Path $identityCrashHome "original-replacement.tmp"
            $displacedReplacement = Join-Path $identityCrashHome "replacement-displaced.tmp"
            [System.IO.File]::WriteAllText($originalReplacement, "first-original")
            [System.IO.File]::Move($identityCrashFirstPath, $displacedReplacement)
            [System.IO.File]::Move($originalReplacement, $identityCrashFirstPath)
            [System.IO.File]::Delete($displacedReplacement)
            $originalReplacementIdentity = (
                Get-OptionalFileSnapshot $identityCrashFirstPath "identity crash original replacement"
            ).Identity

            $identityRecoveryLock = Enter-AppHomeMutationLock $identityCrashHome
            Exit-AppHomeMutationLock $identityRecoveryLock

            $recoveredOriginal = Get-OptionalFileSnapshot (
                $identityCrashFirstPath
            ) "identity crash recovered original replacement"
            Assert-True (
                $recoveredOriginal.Identity -ceq $originalReplacementIdentity -and
                (Get-Content -LiteralPath $identityCrashFirstPath -Raw) -eq "first-original" -and
                -not (Test-Path -LiteralPath (Join-Path $identityCrashHome ".claude-easy-transaction.json"))
            ) "interrupted recovery rejected an independently restored original file"
        }

        $crashDeleteHome = Join-Path $sandbox "crash-delete-home"
        $crashDeleteFirstPath = Join-Path $crashDeleteHome "first.txt"
        $crashDeleteSecondPath = Join-Path $crashDeleteHome "second.txt"
        $crashDeleteReadyPath = Join-Path $sandbox "crash-delete.ready"
        $crashDeleteChildPath = Join-Path $sandbox "crash-delete-child.ps1"
        New-Item -ItemType Directory -Path $crashDeleteHome -Force | Out-Null
        [System.IO.File]::WriteAllText($crashDeleteFirstPath, "first-original")
        [System.IO.File]::WriteAllText($crashDeleteSecondPath, "second-original")
        $crashDeleteChildSource = @'
param(
    [string]$ModulePath,
    [string]$AppHome,
    [string]$FirstPath,
    [string]$SecondPath,
    [string]$ReadyPath
)
$ErrorActionPreference = "Stop"
. $ModulePath
$held = Enter-AppHomeMutationLock $AppHome
$first = Get-OptionalFileSnapshot $FirstPath "first"
$second = Get-OptionalFileSnapshot $SecondPath "second"
$savedDelete = ${function:Set-VerifiedDeleteDisposition}
$script:deleteCount = 0
function Set-VerifiedDeleteDisposition([System.IO.FileStream]$Stream, [bool]$DeleteFile) {
    & $savedDelete $Stream $DeleteFile
    if ($DeleteFile) {
        $script:deleteCount++
        if ($script:deleteCount -eq 1) {
            [System.IO.File]::WriteAllText($ReadyPath, "ready")
            Start-Sleep -Seconds 30
        }
    }
}
try {
    Invoke-VerifiedWriteDeleteTransaction @() @(
        [pscustomobject]@{ Path = $FirstPath; Existed = $true; OriginalBytes = $first.Bytes; OriginalIdentity = $first.Identity },
        [pscustomobject]@{ Path = $SecondPath; Existed = $true; OriginalBytes = $second.Bytes; OriginalIdentity = $second.Identity }
    )
} finally {
    Exit-AppHomeMutationLock $held
}
'@
        [System.IO.File]::WriteAllText($crashDeleteChildPath, $crashDeleteChildSource, [System.Text.Encoding]::ASCII)
        $crashDeleteChild = Start-Process -FilePath $PowerShellPath -ArgumentList @(
            "-NoLogo", "-NoProfile", "-File", $crashDeleteChildPath,
            "-ModulePath", (Join-Path $installerModuleRoot "transaction.ps1"),
            "-AppHome", $crashDeleteHome,
            "-FirstPath", $crashDeleteFirstPath,
            "-SecondPath", $crashDeleteSecondPath,
            "-ReadyPath", $crashDeleteReadyPath
        ) -PassThru
        $crashDeleteDeadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $crashDeleteReadyPath -PathType Leaf) -and
            -not $crashDeleteChild.HasExited -and [DateTime]::UtcNow -lt $crashDeleteDeadline) {
            Start-Sleep -Milliseconds 25
        }
        Assert-True (Test-Path -LiteralPath $crashDeleteReadyPath -PathType Leaf) "crash-delete child did not mark the first deletion"
        Stop-Process -Id $crashDeleteChild.Id -Force
        $crashDeleteChild.WaitForExit()
        Assert-True (-not (Test-Path -LiteralPath $crashDeleteFirstPath)) "crash-delete fixture did not leave a partial transaction"
        Assert-True (Test-Path -LiteralPath $crashDeleteSecondPath -PathType Leaf) "crash-delete fixture unexpectedly completed the transaction"
        $crashDeleteJournalPath = Join-Path $crashDeleteHome ".claude-easy-transaction.json"
        $crashDeleteJournalBytes = [System.IO.File]::ReadAllBytes($crashDeleteJournalPath)
        $crashDeleteOriginalBytes = [System.Text.Encoding]::UTF8.GetBytes("first-original")
        $deleteReplacementCases = @(
            [pscustomobject]@{ Name = "empty"; Bytes = [byte[]]@() },
            [pscustomobject]@{
                Name = "prefix"
                Bytes = [System.Text.Encoding]::UTF8.GetBytes("first-")
            },
            [pscustomobject]@{
                Name = "other"
                Bytes = [System.Text.Encoding]::UTF8.GetBytes("friend-replacement")
            }
        )
        foreach ($deleteReplacementCase in $deleteReplacementCases) {
            [System.IO.File]::WriteAllBytes(
                $crashDeleteFirstPath,
                [byte[]]$deleteReplacementCase.Bytes
            )
            $deleteReplacementBefore = Get-OptionalFileSnapshot (
                $crashDeleteFirstPath
            ) "delete replacement before recovery"
            $deleteReplacementRejected = $false
            try {
                $deleteReplacementLock = Enter-AppHomeMutationLock $crashDeleteHome
                Exit-AppHomeMutationLock $deleteReplacementLock
            } catch {
                $deleteReplacementRejected = $true
            }
            $deleteReplacementAfter = Get-OptionalFileSnapshot (
                $crashDeleteFirstPath
            ) "delete replacement after recovery"
            Assert-True (
                $deleteReplacementRejected -and
                $deleteReplacementAfter.Identity -ceq $deleteReplacementBefore.Identity -and
                (Get-BytesSha256 $deleteReplacementAfter.Bytes) -eq
                    (Get-BytesSha256 $deleteReplacementBefore.Bytes) -and
                [Convert]::ToBase64String(
                    [System.IO.File]::ReadAllBytes($crashDeleteJournalPath)
                ) -ceq [Convert]::ToBase64String($crashDeleteJournalBytes)
            ) "delete recovery changed or accepted a different-identity $($deleteReplacementCase.Name) replacement"
            [System.IO.File]::Delete($crashDeleteFirstPath)
        }
        [System.IO.File]::WriteAllBytes($crashDeleteFirstPath, $crashDeleteOriginalBytes)
        $sameBytesReplacementBefore = Get-OptionalFileSnapshot (
            $crashDeleteFirstPath
        ) "same-byte delete replacement before recovery"
        $crashDeleteRecoveryLock = Enter-AppHomeMutationLock $crashDeleteHome
        Exit-AppHomeMutationLock $crashDeleteRecoveryLock
        $sameBytesReplacementAfter = Get-OptionalFileSnapshot (
            $crashDeleteFirstPath
        ) "same-byte delete replacement after recovery"
        Assert-True ((Get-Content -LiteralPath $crashDeleteFirstPath -Raw) -eq "first-original") "next operation did not recover a deletion interrupted by process death"
        Assert-True (
            $sameBytesReplacementAfter.Identity -ceq $sameBytesReplacementBefore.Identity
        ) "delete recovery rewrote a complete same-byte replacement with a different identity"
        Assert-True ((Get-Content -LiteralPath $crashDeleteSecondPath -Raw) -eq "second-original") "delete recovery changed an untouched transaction target"
        Assert-True (-not (Test-Path -LiteralPath $crashDeleteJournalPath)) "delete recovery left a stale transaction journal"

        $publicCrashPackageParent = Join-Path $sandbox "public-crash-package"
        New-Item -ItemType Directory -Path $publicCrashPackageParent -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root "claude-easy") -Destination $publicCrashPackageParent -Recurse
        $publicCrashPackage = Join-Path $publicCrashPackageParent "claude-easy"
        $publicCrashInstaller = Join-Path (Join-Path $publicCrashPackage "scripts") "install_windows.ps1"
        $publicCrashUninstaller = Join-Path (Join-Path $publicCrashPackage "scripts") "uninstall_windows.ps1"
        $publicCrashTransaction = Join-Path (Join-Path (Join-Path $publicCrashPackage "scripts") "windows/install_windows") "transaction.ps1"
        $publicCrashTransactionText = [System.IO.File]::ReadAllText($publicCrashTransaction)
        $publicCrashFunctionOffset = $publicCrashTransactionText.IndexOf("function Write-LockedStreamBytes(")
        $publicCrashFlushNeedle = '        $Stream.Flush($true)'
        $publicCrashFlushOffset = $publicCrashTransactionText.IndexOf(
            $publicCrashFlushNeedle,
            $publicCrashFunctionOffset
        )
        Assert-True ($publicCrashFunctionOffset -ge 0 -and $publicCrashFlushOffset -ge 0) "public crash fixture could not find the durable write boundary"
        $publicCrashFlushEnd = $publicCrashFlushOffset + $publicCrashFlushNeedle.Length
        $publicCrashHook = @'

        if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_EASY_TEST_PUBLIC_CRASH_READY) -and
            -not (Test-Path -LiteralPath $env:CLAUDE_EASY_TEST_PUBLIC_CRASH_READY)) {
            [System.IO.File]::WriteAllText($env:CLAUDE_EASY_TEST_PUBLIC_CRASH_READY, "ready")
            Start-Sleep -Seconds 30
        }
'@
        $publicCrashTransactionText = $publicCrashTransactionText.Insert(
            $publicCrashFlushEnd,
            $publicCrashHook
        )
        [System.IO.File]::WriteAllText(
            $publicCrashTransaction,
            $publicCrashTransactionText,
            (New-Object System.Text.UTF8Encoding($true))
        )

        $publicCrashHome = Join-Path $sandbox "public-crash-home"
        $publicCrashProfiles = Join-Path $publicCrashHome "profiles"
        $publicCrashReady = Join-Path $sandbox "public-installer-crash.ready"
        $publicCrashConfig = "ipv6: true`ntun: null`n"
        $publicCrashVerge = "enable_tun_mode: false`n"
        $publicCrashProfilesIndex = "items:`n- uid: R-public-crash`n  type: remote`n  option:`n    allow_auto_update: true`n"
        New-Item -ItemType Directory -Path $publicCrashProfiles -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $publicCrashHome "config.yaml"), $publicCrashConfig)
        [System.IO.File]::WriteAllText((Join-Path $publicCrashHome "verge.yaml"), $publicCrashVerge)
        [System.IO.File]::WriteAllText((Join-Path $publicCrashHome "profiles.yaml"), $publicCrashProfilesIndex)
        $env:CLAUDE_EASY_TEST_PUBLIC_CRASH_READY = $publicCrashReady
        $publicCrashChild = Start-Process -FilePath $PowerShellPath -ArgumentList @(
            "-NoLogo", "-NoProfile", "-File", $publicCrashInstaller,
            "-AppHome", $publicCrashHome,
            "-UsageProfile", "1",
            "-MihomoPath", $fakeCore
        ) -PassThru
        try {
            $publicCrashDeadline = [DateTime]::UtcNow.AddSeconds(10)
            while (-not (Test-Path -LiteralPath $publicCrashReady -PathType Leaf) -and
                -not $publicCrashChild.HasExited -and [DateTime]::UtcNow -lt $publicCrashDeadline) {
                Start-Sleep -Milliseconds 25
            }
            Assert-True (Test-Path -LiteralPath $publicCrashReady -PathType Leaf) "public installer did not reach its first durable transaction write"
            Stop-Process -Id $publicCrashChild.Id -Force
            $publicCrashChild.WaitForExit()
        } finally {
            $env:CLAUDE_EASY_TEST_PUBLIC_CRASH_READY = $null
            if (-not $publicCrashChild.HasExited) { Stop-Process -Id $publicCrashChild.Id -Force }
        }
        Assert-True (Test-Path -LiteralPath (Join-Path $publicCrashHome ".claude-easy-transaction.json") -PathType Leaf) "public installer crash did not leave a recoverable transaction journal"
        $publicRecoveryResult = Invoke-TestPowerShell $publicCrashUninstaller @(
            "-AppHome", $publicCrashHome,
            "-Json"
        )
        $publicRecoveryJson = Assert-JsonResult $publicRecoveryResult "uninstall" 0
        Assert-True ($publicRecoveryJson.code -eq "uninstalled") "public uninstaller did not finish after recovering an interrupted install"
        Assert-True ((Get-Content -LiteralPath (Join-Path $publicCrashHome "config.yaml") -Raw) -ceq $publicCrashConfig) "public-entry recovery changed original config.yaml"
        Assert-True ((Get-Content -LiteralPath (Join-Path $publicCrashHome "verge.yaml") -Raw) -ceq $publicCrashVerge) "public-entry recovery changed original verge.yaml"
        Assert-True ((Get-Content -LiteralPath (Join-Path $publicCrashHome "profiles.yaml") -Raw) -ceq $publicCrashProfilesIndex) "public-entry recovery changed original profiles.yaml"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $publicCrashProfiles "Script.js"))) "public-entry recovery retained a partially installed Script.js"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $publicCrashHome ".claude-easy-transaction.json"))) "public uninstaller left the recovered transaction journal"

        $publicUninstallCrashHome = Join-Path $sandbox "public-uninstaller-crash-home"
        $publicUninstallCrashProfiles = Join-Path $publicUninstallCrashHome "profiles"
        $publicUninstallCrashReady = Join-Path $sandbox "public-uninstaller-crash.ready"
        $publicUninstallRecoveryCrashReady = Join-Path $sandbox "public-uninstaller-recovery-crash.ready"
        New-Item -ItemType Directory -Path $publicUninstallCrashProfiles -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $publicUninstallCrashHome "config.yaml"), $publicCrashConfig)
        [System.IO.File]::WriteAllText((Join-Path $publicUninstallCrashHome "verge.yaml"), $publicCrashVerge)
        [System.IO.File]::WriteAllText((Join-Path $publicUninstallCrashHome "profiles.yaml"), $publicCrashProfilesIndex)
        $publicUninstallSetup = Invoke-TestPowerShell $publicCrashInstaller @(
            "-AppHome", $publicUninstallCrashHome,
            "-UsageProfile", "1",
            "-MihomoPath", $fakeCore,
            "-Json"
        )
        Assert-JsonResult $publicUninstallSetup "install" 0 | Out-Null
        $publicUninstallTargets = @(
            "config.yaml",
            "verge.yaml",
            "profiles.yaml",
            "profiles\Script.js",
            "claude-easy-usage-profile.json",
            "claude-easy-auto-update-state.json"
        ) | ForEach-Object { Join-Path $publicUninstallCrashHome $_ }
        $publicUninstallSnapshots = @{}
        foreach ($publicUninstallTarget in $publicUninstallTargets) {
            Assert-True (Test-Path -LiteralPath $publicUninstallTarget -PathType Leaf) "public uninstall crash fixture omitted an installed target"
            $publicUninstallSnapshots[$publicUninstallTarget] = [Convert]::ToBase64String(
                [System.IO.File]::ReadAllBytes($publicUninstallTarget)
            )
        }
        $publicUninstallTransactionText = [System.IO.File]::ReadAllText($publicCrashTransaction)
        $publicUninstallFunctionOffset = $publicUninstallTransactionText.IndexOf(
            "function Set-VerifiedDeleteDisposition("
        )
        $publicUninstallDeleteNeedle = '    [ClaudeEasy.VerifiedDeleteNative]::SetDeleteDisposition($Stream.SafeFileHandle, $DeleteFile)'
        $publicUninstallDeleteOffset = $publicUninstallTransactionText.IndexOf(
            $publicUninstallDeleteNeedle,
            $publicUninstallFunctionOffset
        )
        Assert-True ($publicUninstallFunctionOffset -ge 0 -and $publicUninstallDeleteOffset -ge 0) "public uninstall crash fixture could not find the durable delete boundary"
        $publicUninstallDeleteEnd = $publicUninstallDeleteOffset + $publicUninstallDeleteNeedle.Length
        $publicUninstallHook = @'

    if ($DeleteFile -and
        -not [string]::IsNullOrWhiteSpace($env:CLAUDE_EASY_TEST_UNINSTALL_CRASH_READY) -and
        -not (Test-Path -LiteralPath $env:CLAUDE_EASY_TEST_UNINSTALL_CRASH_READY)) {
        [System.IO.File]::WriteAllText($env:CLAUDE_EASY_TEST_UNINSTALL_CRASH_READY, "ready")
        Start-Sleep -Seconds 30
    }
'@
        $publicUninstallTransactionText = $publicUninstallTransactionText.Insert(
            $publicUninstallDeleteEnd,
            $publicUninstallHook
        )
        $publicUninstallRecoveryFunctionOffset = $publicUninstallTransactionText.IndexOf(
            "function New-InterruptedRecoveryTemporaryFile("
        )
        $publicUninstallRecoveryNeedle = @'
        $stream.Write($Bytes, 0, $Bytes.Length)
'@
        $publicUninstallRecoveryOffset = $publicUninstallTransactionText.IndexOf(
            $publicUninstallRecoveryNeedle,
            $publicUninstallRecoveryFunctionOffset
        )
        Assert-True (
            $publicUninstallRecoveryFunctionOffset -ge 0 -and
            $publicUninstallRecoveryOffset -ge 0
        ) "public uninstall crash fixture could not find the private recovery write boundary"
        $publicUninstallRecoveryEnd =
            $publicUninstallRecoveryOffset + $publicUninstallRecoveryNeedle.Length
        $publicUninstallRecoveryHook = @'

                if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_EASY_TEST_RECOVERY_CRASH_READY)) {
                    [System.IO.File]::WriteAllText($env:CLAUDE_EASY_TEST_RECOVERY_CRASH_READY, "ready")
                    Start-Sleep -Seconds 30
                }
'@
        $publicUninstallTransactionText = $publicUninstallTransactionText.Insert(
            $publicUninstallRecoveryEnd,
            $publicUninstallRecoveryHook
        )
        [System.IO.File]::WriteAllText(
            $publicCrashTransaction,
            $publicUninstallTransactionText,
            (New-Object System.Text.UTF8Encoding($true))
        )
        $env:CLAUDE_EASY_TEST_UNINSTALL_CRASH_READY = $publicUninstallCrashReady
        $publicUninstallCrashChild = Start-Process -FilePath $PowerShellPath -ArgumentList @(
            "-NoLogo", "-NoProfile", "-File", $publicCrashUninstaller,
            "-AppHome", $publicUninstallCrashHome
        ) -PassThru
        try {
            $publicUninstallCrashDeadline = [DateTime]::UtcNow.AddSeconds(10)
            while (-not (Test-Path -LiteralPath $publicUninstallCrashReady -PathType Leaf) -and
                -not $publicUninstallCrashChild.HasExited -and
                [DateTime]::UtcNow -lt $publicUninstallCrashDeadline) {
                Start-Sleep -Milliseconds 25
            }
            Assert-True (Test-Path -LiteralPath $publicUninstallCrashReady -PathType Leaf) "public uninstaller did not reach its first durable deletion"
            Stop-Process -Id $publicUninstallCrashChild.Id -Force
            $publicUninstallCrashChild.WaitForExit()
        } finally {
            $env:CLAUDE_EASY_TEST_UNINSTALL_CRASH_READY = $null
            if (-not $publicUninstallCrashChild.HasExited) {
                Stop-Process -Id $publicUninstallCrashChild.Id -Force
            }
        }
        Assert-True (Test-Path -LiteralPath (Join-Path $publicUninstallCrashHome ".claude-easy-transaction.json") -PathType Leaf) "public uninstaller crash did not leave a recoverable transaction journal"
        $publicUninstallMissingBeforeRecovery = @(
            $publicUninstallTargets | Where-Object {
                -not (Test-Path -LiteralPath $_ -PathType Leaf)
            }
        )
        Assert-True (
            $publicUninstallMissingBeforeRecovery.Count -gt 0
        ) "public uninstall crash fixture did not leave a missing target"
        $publicUninstallInterruptedProfiles = Join-Path $publicUninstallCrashHome "profiles.yaml"
        $publicUninstallInterruptedUsage = Join-Path $publicUninstallCrashHome "claude-easy-usage-profile.json"
        $publicUninstallJournal = Join-Path $publicUninstallCrashHome ".claude-easy-transaction.json"
        $publicUninstallInterruptedProfilesBytes = [System.IO.File]::ReadAllBytes(
            $publicUninstallInterruptedProfiles
        )
        Assert-True (
            Test-Path -LiteralPath $publicUninstallInterruptedUsage -PathType Leaf
        ) "public uninstall crash fixture removed usage state before the recovery guard probe"
        $publicUninstallInterruptedUsageBytes = [System.IO.File]::ReadAllBytes(
            $publicUninstallInterruptedUsage
        )
        $publicUninstallJournalBytes = [System.IO.File]::ReadAllBytes(
            $publicUninstallJournal
        )
        $publicUninstallRunningClientPath = Join-Path $publicUninstallCrashHome "clash-verge.exe"
        Copy-Item -LiteralPath (
            Join-Path (Join-Path $env:SystemRoot "System32") "ping.exe"
        ) -Destination $publicUninstallRunningClientPath
        $publicUninstallRunningClient = Start-Process `
            -FilePath $publicUninstallRunningClientPath `
            -ArgumentList @("-n", "20", "127.0.0.1") `
            -PassThru
        try {
            Start-Sleep -Milliseconds 100
            $blockedPublicUninstallRecovery = Invoke-TestPowerShell $publicCrashInstaller @(
                "-AppHome", $publicUninstallCrashHome,
                "-ShowUsageProfile",
                "-Json"
            )
            $blockedPublicUninstallJson = Assert-JsonResult `
                $blockedPublicUninstallRecovery "install" 1
            Assert-True (
                $blockedPublicUninstallJson.status -eq "partial" -and
                $blockedPublicUninstallJson.code -eq "transaction_recovery_pending"
            ) "running client did not defer interrupted client-sensitive recovery"
            Assert-True (
                [Convert]::ToBase64String(
                    [System.IO.File]::ReadAllBytes($publicUninstallInterruptedProfiles)
                ) -eq [Convert]::ToBase64String(
                    $publicUninstallInterruptedProfilesBytes
                )
            ) "running client changed an interrupted profiles.yaml target"
            Assert-True (
                (Test-Path -LiteralPath $publicUninstallInterruptedUsage -PathType Leaf) -and
                [Convert]::ToBase64String(
                    [System.IO.File]::ReadAllBytes($publicUninstallInterruptedUsage)
                ) -eq [Convert]::ToBase64String(
                    $publicUninstallInterruptedUsageBytes
                )
            ) "running client changed an interrupted usage-profile state"
            Assert-True (
                [Convert]::ToBase64String(
                    [System.IO.File]::ReadAllBytes($publicUninstallJournal)
                ) -eq [Convert]::ToBase64String($publicUninstallJournalBytes)
            ) "running client consumed an interrupted client-sensitive journal"
        } finally {
            if (-not $publicUninstallRunningClient.HasExited) {
                Stop-Process -Id $publicUninstallRunningClient.Id -Force
            }
            $publicUninstallRunningClient.WaitForExit()
        }
        $env:CLAUDE_EASY_TEST_RECOVERY_CRASH_READY = $publicUninstallRecoveryCrashReady
        $publicUninstallRecoveryCrashChild = Start-Process -FilePath $PowerShellPath -ArgumentList @(
            "-NoLogo", "-NoProfile", "-File", $publicCrashInstaller,
            "-AppHome", $publicUninstallCrashHome,
            "-ShowUsageProfile",
            "-Json"
        ) -PassThru
        try {
            $publicUninstallRecoveryCrashDeadline = [DateTime]::UtcNow.AddSeconds(10)
            while (-not (Test-Path -LiteralPath $publicUninstallRecoveryCrashReady -PathType Leaf) -and
                -not $publicUninstallRecoveryCrashChild.HasExited -and
                [DateTime]::UtcNow -lt $publicUninstallRecoveryCrashDeadline) {
                Start-Sleep -Milliseconds 25
            }
            Assert-True (
                Test-Path -LiteralPath $publicUninstallRecoveryCrashReady -PathType Leaf
            ) "public recovery did not recreate an interrupted deletion"
            Stop-Process -Id $publicUninstallRecoveryCrashChild.Id -Force
            $publicUninstallRecoveryCrashChild.WaitForExit()
        } finally {
            $env:CLAUDE_EASY_TEST_RECOVERY_CRASH_READY = $null
            if (-not $publicUninstallRecoveryCrashChild.HasExited) {
                Stop-Process -Id $publicUninstallRecoveryCrashChild.Id -Force
            }
        }
        Assert-True (
            Test-Path -LiteralPath (Join-Path $publicUninstallCrashHome ".claude-easy-transaction.json") -PathType Leaf
        ) "second recovery interruption removed the transaction journal"
        $interruptedRecoveryTemporaryFiles = @(
            Get-ChildItem -LiteralPath $publicUninstallCrashHome `
                -Filter ".claude-easy-recovery-*.tmp" -File -Recurse
        )
        Assert-True (
            $interruptedRecoveryTemporaryFiles.Count -gt 0 -and
            @($interruptedRecoveryTemporaryFiles | Where-Object {
                -not (Test-PrivateWindowsFileAcl $_.FullName)
            }).Count -eq 0
        ) "interrupted recovery did not keep its temporary bytes private"
        foreach ($publicUninstallStillMissing in $publicUninstallMissingBeforeRecovery) {
            Assert-True (-not (
                Test-Path -LiteralPath $publicUninstallStillMissing
            )) "interrupted recovery exposed an empty or partial target instead of a private temporary file"
        }
        $publicUninstallRecovery = Invoke-TestPowerShell $publicCrashInstaller @(
            "-AppHome", $publicUninstallCrashHome,
            "-ShowUsageProfile",
            "-Json"
        )
        $publicUninstallRecoveryJson = Assert-JsonResult $publicUninstallRecovery "install" 0
        Assert-True ([int]$publicUninstallRecoveryJson.profile -eq 1) "public installer did not recover the saved profile after an interrupted uninstall"
        foreach ($publicUninstallTarget in $publicUninstallTargets) {
            Assert-True (
                (Test-Path -LiteralPath $publicUninstallTarget -PathType Leaf) -and
                [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($publicUninstallTarget)) -ceq
                    $publicUninstallSnapshots[$publicUninstallTarget]
            ) "public installer did not restore an interrupted uninstall target"
        }
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $publicUninstallCrashHome ".claude-easy-transaction.json"))) "public installer left the recovered uninstall journal"
        $publicUninstallCompletion = Invoke-TestPowerShell $publicCrashUninstaller @(
            "-AppHome", $publicUninstallCrashHome,
            "-Json"
        )
        Assert-JsonResult $publicUninstallCompletion "uninstall" 0 | Out-Null

        Invoke-DeferredProbe "public restore strong-kill atomicity" {
            $publicRestorePackageParent = Join-Path $sandbox "public-restore-crash-package"
            New-Item -ItemType Directory -Path $publicRestorePackageParent -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $root "claude-easy") -Destination $publicRestorePackageParent -Recurse
            $publicRestorePackage = Join-Path $publicRestorePackageParent "claude-easy"
            $publicRestoreInstaller = Join-Path (Join-Path $publicRestorePackage "scripts") "install_windows.ps1"
            $publicRestoreTransaction = Join-Path (Join-Path (Join-Path $publicRestorePackage "scripts") "windows/install_windows") "transaction.ps1"
            $publicRestoreTransactionText = [System.IO.File]::ReadAllText($publicRestoreTransaction)
            $publicRestoreFunctionOffset = $publicRestoreTransactionText.IndexOf("function Write-LockedStreamBytes(")
            $publicRestoreWriteNeedle = '        $Stream.Write($Replacement, 0, $Replacement.Length)'
            $publicRestoreWriteOffset = $publicRestoreTransactionText.IndexOf(
                $publicRestoreWriteNeedle,
                $publicRestoreFunctionOffset
            )
            Assert-True ($publicRestoreFunctionOffset -ge 0 -and $publicRestoreWriteOffset -ge 0) "public restore crash fixture could not find the stream write boundary"
            $publicRestoreHook = @'
        if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_EASY_TEST_RESTORE_CRASH_READY)) {
            $Stream.Write($Replacement, 0, $Replacement.Length)
            $Stream.Flush($true)
            [System.IO.File]::WriteAllText($env:CLAUDE_EASY_TEST_RESTORE_CRASH_READY, "ready")
            Start-Sleep -Seconds 30
        }
'@
            $publicRestoreTransactionText = $publicRestoreTransactionText.Remove(
                $publicRestoreWriteOffset,
                $publicRestoreWriteNeedle.Length
            ).Insert(
                $publicRestoreWriteOffset,
                $publicRestoreHook + $publicRestoreWriteNeedle
            )
            [System.IO.File]::WriteAllText(
                $publicRestoreTransaction,
                $publicRestoreTransactionText,
                (New-Object System.Text.UTF8Encoding($true))
            )

            $publicRestoreHome = Join-Path $sandbox "public-restore-crash-home"
            $publicRestoreProfiles = Join-Path $publicRestoreHome "profiles"
            $publicRestoreTarget = Join-Path $publicRestoreProfiles "R-public-restore.yaml"
            $publicRestoreBackupRoot = Join-Path $publicRestoreHome "claude-easy-backups"
            $publicRestoreReady = Join-Path $sandbox "public-restore-crash.ready"
            $publicRestoreBackupBytes = [System.Text.Encoding]::UTF8.GetBytes(
                "mode: rule`nipv6: false`ntun:`n  enable: true`n  stack: system`n  dns-hijack:`n    - any:53`n  auto-route: true`n  auto-detect-interface: true`n  strict-route: true`nproxies: []`nproxy-groups: []`nrules: []`n"
            )
            $publicRestoreCurrentBytes = [System.Text.Encoding]::UTF8.GetBytes(
                "mode: global`nipv6: false`ntun:`n  enable: true`n  stack: system`n  dns-hijack:`n    - any:53`n  auto-route: true`n  auto-detect-interface: true`n  strict-route: true`nproxies: []`nproxy-groups: []`nrules: []`n"
            )
            Assert-True (
                $publicRestoreBackupBytes.Length -lt $publicRestoreCurrentBytes.Length
            ) "public restore crash fixture must replace a longer file with shorter bytes"
            New-Item -ItemType Directory -Path $publicRestoreProfiles -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $publicRestoreHome "claude-easy-usage-profile.json"), '{"Version":1,"Profile":3}')
            [System.IO.File]::WriteAllBytes($publicRestoreTarget, $publicRestoreBackupBytes)
            $publicRestoreLock = Enter-AppHomeMutationLock $publicRestoreHome
            try {
                $publicRestoreBackup = Backup-Versioned $publicRestoreTarget $publicRestoreBackupRoot "prewrite"
            } finally {
                Exit-AppHomeMutationLock $publicRestoreLock
            }
            [System.IO.File]::WriteAllBytes($publicRestoreTarget, $publicRestoreCurrentBytes)
            $publicRestoreExpectedHash = Get-FileSha256 $publicRestoreTarget
            $env:CLAUDE_EASY_TEST_RESTORE_CRASH_READY = $publicRestoreReady
            $publicRestoreChild = Start-Process -FilePath $PowerShellPath -ArgumentList @(
                "-NoLogo", "-NoProfile", "-File", $publicRestoreInstaller,
                "-AppHome", $publicRestoreHome,
                "-RestoreBackup", (Split-Path -Leaf $publicRestoreBackup),
                "-ExpectedCurrentSha256", $publicRestoreExpectedHash,
                "-MihomoPath", $fakeCore
            ) -PassThru
            try {
                $publicRestoreDeadline = [DateTime]::UtcNow.AddSeconds(10)
                while (-not (Test-Path -LiteralPath $publicRestoreReady -PathType Leaf) -and
                    -not $publicRestoreChild.HasExited -and [DateTime]::UtcNow -lt $publicRestoreDeadline) {
                    Start-Sleep -Milliseconds 25
                }
                Assert-True (Test-Path -LiteralPath $publicRestoreReady -PathType Leaf) "public restore did not reach an interrupted stream write"
                Stop-Process -Id $publicRestoreChild.Id -Force
                $publicRestoreChild.WaitForExit()
            } finally {
                $env:CLAUDE_EASY_TEST_RESTORE_CRASH_READY = $null
                if (-not $publicRestoreChild.HasExited) { Stop-Process -Id $publicRestoreChild.Id -Force }
            }
            $publicRestoreJournal = Join-Path $publicRestoreHome ".claude-easy-transaction.json"
            Assert-True (Test-Path -LiteralPath $publicRestoreJournal -PathType Leaf) "interrupted public restore did not leave a recovery journal"
            $publicRestoreJournalRecord = Get-Content -LiteralPath $publicRestoreJournal -Raw |
                ConvertFrom-Json
            Assert-True (
                [int]$publicRestoreJournalRecord.Version -eq 2 -and
                [string]$publicRestoreJournalRecord.RecoveryPolicy -eq "client_stopped"
            ) "ordinary remote-profile restore did not persist its stopped-client recovery policy"
            $publicRestoreInterruptedBytes = [System.IO.File]::ReadAllBytes($publicRestoreTarget)
            $publicRestoreRunningClientPath = Join-Path $publicRestoreHome "clash-verge.exe"
            Copy-Item -LiteralPath (
                Join-Path (Join-Path $env:SystemRoot "System32") "ping.exe"
            ) -Destination $publicRestoreRunningClientPath
            $publicRestoreRunningClient = Start-Process `
                -FilePath $publicRestoreRunningClientPath `
                -ArgumentList @("-n", "20", "127.0.0.1") `
                -PassThru
            try {
                Start-Sleep -Milliseconds 100
                $blockedPublicRestoreRecovery = Invoke-TestPowerShell $publicRestoreInstaller @(
                    "-AppHome", $publicRestoreHome,
                    "-ShowUsageProfile",
                    "-Json"
                )
                $blockedPublicRestoreJson = Assert-JsonResult `
                    $blockedPublicRestoreRecovery "install" 1
                Assert-True (
                    $blockedPublicRestoreJson.status -eq "partial" -and
                    $blockedPublicRestoreJson.code -eq "transaction_recovery_pending"
                ) "running client did not defer interrupted current-config recovery"
                Assert-True (
                    [Convert]::ToBase64String(
                        [System.IO.File]::ReadAllBytes($publicRestoreTarget)
                    ) -eq [Convert]::ToBase64String($publicRestoreInterruptedBytes)
                ) "running client changed an interrupted remote-profile restore target"
                Assert-True (
                    Test-Path -LiteralPath $publicRestoreJournal -PathType Leaf
                ) "running client consumed an interrupted remote-profile restore journal"
            } finally {
                if (-not $publicRestoreRunningClient.HasExited) {
                    Stop-Process -Id $publicRestoreRunningClient.Id -Force
                }
                $publicRestoreRunningClient.WaitForExit()
            }
            $publicRestoreRecovery = Invoke-TestPowerShell $publicRestoreInstaller @(
                "-AppHome", $publicRestoreHome,
                "-ShowUsageProfile",
                "-Json"
            )
            Assert-JsonResult $publicRestoreRecovery "install" 0 | Out-Null
            Assert-True (
                (Get-BytesSha256 ([System.IO.File]::ReadAllBytes($publicRestoreTarget))) -eq
                (Get-BytesSha256 $publicRestoreCurrentBytes)
            ) "next public operation did not recover an interrupted restore"
            Assert-True (-not (Test-Path -LiteralPath $publicRestoreJournal)) "recovered public restore retained its transaction journal"
        }

        Invoke-DeferredProbe "public new-target pre-journal strong-kill recovery" {
            $publicPreJournalPackageParent = Join-Path $sandbox "public-pre-journal-crash-package"
            New-Item -ItemType Directory -Path $publicPreJournalPackageParent -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $root "claude-easy") -Destination $publicPreJournalPackageParent -Recurse
            $publicPreJournalPackage = Join-Path $publicPreJournalPackageParent "claude-easy"
            $publicPreJournalInstaller = Join-Path (Join-Path $publicPreJournalPackage "scripts") "install_windows.ps1"
            $publicPreJournalTransaction = Join-Path (
                Join-Path (Join-Path $publicPreJournalPackage "scripts") "windows/install_windows"
            ) "transaction.ps1"
            $publicPreJournalTransactionText = [System.IO.File]::ReadAllText($publicPreJournalTransaction)
            $publicPreJournalFunctionOffset = $publicPreJournalTransactionText.IndexOf(
                "function Invoke-VerifiedPathTransaction("
            )
            $publicPreJournalNeedle = '        $journalBytes = Write-FileTransactionJournal $opened $InterruptedRecoveryPolicy'
            $publicPreJournalOffset = $publicPreJournalTransactionText.IndexOf(
                $publicPreJournalNeedle,
                $publicPreJournalFunctionOffset
            )
            Assert-True (
                $publicPreJournalFunctionOffset -ge 0 -and $publicPreJournalOffset -ge 0
            ) "public pre-journal crash fixture could not find the transaction journal boundary"
            $publicPreJournalHook = @'
        if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_EASY_TEST_PREJOURNAL_CRASH_READY)) {
            [System.IO.File]::WriteAllText($env:CLAUDE_EASY_TEST_PREJOURNAL_CRASH_READY, "ready")
            Start-Sleep -Seconds 30
        }
'@
            $publicPreJournalTransactionText = $publicPreJournalTransactionText.Insert(
                $publicPreJournalOffset,
                $publicPreJournalHook
            )
            [System.IO.File]::WriteAllText(
                $publicPreJournalTransaction,
                $publicPreJournalTransactionText,
                (New-Object System.Text.UTF8Encoding($true))
            )

            $publicPreJournalHome = Join-Path $sandbox "public-pre-journal-crash-home"
            $publicPreJournalProfiles = Join-Path $publicPreJournalHome "profiles"
            $publicPreJournalReady = Join-Path $sandbox "public-pre-journal-crash.ready"
            New-Item -ItemType Directory -Path $publicPreJournalProfiles -Force | Out-Null
            [System.IO.File]::WriteAllText(
                (Join-Path $publicPreJournalHome "profiles.yaml"),
                "items:`n- uid: R-pre-journal`n  type: remote`n  option:`n    allow_auto_update: true`n"
            )
            $env:CLAUDE_EASY_TEST_PREJOURNAL_CRASH_READY = $publicPreJournalReady
            $publicPreJournalChild = Start-Process -FilePath $PowerShellPath -ArgumentList @(
                "-NoLogo", "-NoProfile", "-File", $publicPreJournalInstaller,
                "-AppHome", $publicPreJournalHome,
                "-UsageProfile", "3",
                "-MihomoPath", $fakeCore
            ) -PassThru
            try {
                $publicPreJournalDeadline = [DateTime]::UtcNow.AddSeconds(10)
                while (-not (Test-Path -LiteralPath $publicPreJournalReady -PathType Leaf) -and
                    -not $publicPreJournalChild.HasExited -and
                    [DateTime]::UtcNow -lt $publicPreJournalDeadline) {
                    Start-Sleep -Milliseconds 25
                }
                Assert-True (
                    Test-Path -LiteralPath $publicPreJournalReady -PathType Leaf
                ) "public install did not reach the pre-journal new-target boundary"
                Stop-Process -Id $publicPreJournalChild.Id -Force
                $publicPreJournalChild.WaitForExit()
            } finally {
                $env:CLAUDE_EASY_TEST_PREJOURNAL_CRASH_READY = $null
                if (-not $publicPreJournalChild.HasExited) {
                    Stop-Process -Id $publicPreJournalChild.Id -Force
                }
            }
            $publicPreJournalUsage = Join-Path $publicPreJournalHome "claude-easy-usage-profile.json"
            $publicPreJournalConfig = Join-Path $publicPreJournalHome "config.yaml"
            $publicPreJournalVerge = Join-Path $publicPreJournalHome "verge.yaml"
            $publicPreJournalPreparation = Join-Path $publicPreJournalHome ".claude-easy-transaction-preparation.json"
            Assert-True (
                (Test-Path -LiteralPath $publicPreJournalUsage -PathType Leaf) -and
                (Get-Item -LiteralPath $publicPreJournalUsage).Length -eq 0
            ) "public pre-journal crash fixture did not leave the newly created empty state"
            Assert-True (
                (Test-Path -LiteralPath $publicPreJournalConfig -PathType Leaf) -and
                (Get-Item -LiteralPath $publicPreJournalConfig).Length -eq 0 -and
                (Test-Path -LiteralPath $publicPreJournalVerge -PathType Leaf) -and
                (Get-Item -LiteralPath $publicPreJournalVerge).Length -eq 0
            ) "public pre-journal crash fixture did not leave empty current-config targets"
            Assert-True (-not (
                Test-Path -LiteralPath (Join-Path $publicPreJournalHome ".claude-easy-transaction.json")
            )) "public pre-journal crash unexpectedly published the main transaction journal"
            Assert-True (
                Test-Path -LiteralPath $publicPreJournalPreparation -PathType Leaf
            ) "public pre-journal crash did not leave a preparation record"

            $publicPreJournalPreparationBytes = [System.IO.File]::ReadAllBytes(
                $publicPreJournalPreparation
            )
            $publicPreJournalRunningClientPath = Join-Path $publicPreJournalHome "clash-verge.exe"
            Copy-Item -LiteralPath (
                Join-Path (Join-Path $env:SystemRoot "System32") "ping.exe"
            ) -Destination $publicPreJournalRunningClientPath
            $publicPreJournalRunningClient = Start-Process `
                -FilePath $publicPreJournalRunningClientPath `
                -ArgumentList @("-n", "20", "127.0.0.1") `
                -PassThru
            try {
                Start-Sleep -Milliseconds 100
                $blockedPreJournalRecovery = Invoke-TestPowerShell $publicPreJournalInstaller @(
                    "-AppHome", $publicPreJournalHome,
                    "-ShowUsageProfile",
                    "-Json"
                )
                $blockedPreJournalJson = Assert-JsonResult `
                    $blockedPreJournalRecovery "install" 1
                Assert-True (
                    $blockedPreJournalJson.status -eq "partial" -and
                    $blockedPreJournalJson.code -eq "transaction_recovery_pending"
                ) "running client did not defer prepared current-config recovery"
                Assert-True (
                    (Get-Item -LiteralPath $publicPreJournalConfig).Length -eq 0 -and
                    (Get-Item -LiteralPath $publicPreJournalVerge).Length -eq 0
                ) "running client changed a prepared current-config target"
                Assert-True (
                    [Convert]::ToBase64String(
                        [System.IO.File]::ReadAllBytes($publicPreJournalPreparation)
                    ) -eq [Convert]::ToBase64String($publicPreJournalPreparationBytes)
                ) "running client consumed a current-config preparation record"
            } finally {
                if (-not $publicPreJournalRunningClient.HasExited) {
                    Stop-Process -Id $publicPreJournalRunningClient.Id -Force
                }
                $publicPreJournalRunningClient.WaitForExit()
            }
            $publicPreJournalRecovery = Invoke-TestPowerShell $publicPreJournalInstaller @(
                "-AppHome", $publicPreJournalHome,
                "-UsageProfile", "3",
                "-MihomoPath", $fakeCore,
                "-Json"
            )
            $publicPreJournalRecoveryJson = Assert-JsonResult $publicPreJournalRecovery "install" 0
            Assert-True (
                $publicPreJournalRecoveryJson.code -eq "installed"
            ) "next public install did not recover the pre-journal new target"
            $publicPreJournalUsageJson = Get-Content -LiteralPath $publicPreJournalUsage -Raw | ConvertFrom-Json
            Assert-True ([int]$publicPreJournalUsageJson.Profile -eq 3) "recovered install did not replace the empty usage state"
            Assert-True (-not (
                Test-Path -LiteralPath $publicPreJournalPreparation
            )) "recovered install retained the preparation record"
        }

        Invoke-DeferredProbe "interrupted recovery rechecks a newly started client" {
            $recoveryRacePackageParent = Join-Path $sandbox "recovery-client-race-package"
            New-Item -ItemType Directory -Path $recoveryRacePackageParent -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $root "claude-easy") -Destination $recoveryRacePackageParent -Recurse
            $recoveryRacePackage = Join-Path $recoveryRacePackageParent "claude-easy"
            $recoveryRaceInstaller = Join-Path (
                Join-Path $recoveryRacePackage "scripts"
            ) "install_windows.ps1"
            $recoveryRaceTransaction = Join-Path (
                Join-Path (Join-Path $recoveryRacePackage "scripts") "windows/install_windows"
            ) "transaction.ps1"
            $recoveryRaceText = [System.IO.File]::ReadAllText($recoveryRaceTransaction)
            $recoveryRacePreparationFunction = $recoveryRaceText.IndexOf(
                "function Repair-InterruptedFilePreparation"
            )
            $recoveryRaceJournalFunction = $recoveryRaceText.IndexOf(
                "function Repair-InterruptedFileTransaction"
            )
            $recoveryRacePreparationNeedle = '                $finalizeRejected = -not ('
            $recoveryRaceJournalNeedle = '        if (-not (Test-InterruptedRecoveryCommitCondition $preCommitCondition)) {'
            $recoveryRacePreparationOffset = $recoveryRaceText.IndexOf(
                $recoveryRacePreparationNeedle,
                $recoveryRacePreparationFunction
            )
            $recoveryRaceJournalCallOffset = $recoveryRaceText.IndexOf(
                $recoveryRaceJournalNeedle,
                $recoveryRaceJournalFunction
            )
            $recoveryRaceJournalLineBreak = if ($recoveryRaceJournalCallOffset -ge 0) {
                $recoveryRaceText.LastIndexOf(
                    [char]10,
                    $recoveryRaceJournalCallOffset
                )
            } else {
                -1
            }
            $recoveryRaceJournalOffset = $recoveryRaceJournalLineBreak + 1
            Assert-True (
                $recoveryRacePreparationFunction -ge 0 -and
                $recoveryRaceJournalFunction -ge 0 -and
                $recoveryRacePreparationOffset -ge 0 -and
                $recoveryRaceJournalCallOffset -ge 0 -and
                $recoveryRaceJournalLineBreak -ge 0
            ) "recovery client race fixture could not find both recovery commit boundaries"
            $recoveryRaceHelper = @'
function Start-ClaudeEasyRecoveryRaceClient([string]$ExpectedMode) {
    if ($env:CLAUDE_EASY_TEST_RECOVERY_RACE_MODE -cne $ExpectedMode) { return }
    if ([string]::IsNullOrWhiteSpace($env:CLAUDE_EASY_TEST_RECOVERY_RACE_EXECUTABLE) -or
        [string]::IsNullOrWhiteSpace($env:CLAUDE_EASY_TEST_RECOVERY_RACE_PID)) {
        throw "recovery client race fixture is incomplete"
    }
    $injected = Start-Process `
        -FilePath $env:CLAUDE_EASY_TEST_RECOVERY_RACE_EXECUTABLE `
        -ArgumentList @("-n", "20", "127.0.0.1") -PassThru
    [void]$injected.Handle
    [System.IO.File]::WriteAllText(
        $env:CLAUDE_EASY_TEST_RECOVERY_RACE_PID,
        [string]$injected.Id
    )
    $seen = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not $injected.HasExited -and -not $seen -and [DateTime]::UtcNow -lt $deadline) {
        $seen = $null -ne (
            Get-Process -Name "clash-verge" -ErrorAction SilentlyContinue |
                Select-Object -First 1
        )
        if (-not $seen) { Start-Sleep -Milliseconds 25 }
    }
    if (-not $seen) { throw "injected recovery client was not visible" }
}

'@
            $recoveryRaceText = $recoveryRaceText.Insert(
                $recoveryRacePreparationFunction,
                $recoveryRaceHelper
            )
            $recoveryRacePreparationOffset += $recoveryRaceHelper.Length
            $recoveryRaceJournalOffset += $recoveryRaceHelper.Length
            $recoveryRacePreparationHook = '            Start-ClaudeEasyRecoveryRaceClient "preparation"' + [Environment]::NewLine
            $recoveryRaceText = $recoveryRaceText.Insert(
                $recoveryRacePreparationOffset,
                $recoveryRacePreparationHook
            )
            $recoveryRaceJournalOffset += $recoveryRacePreparationHook.Length
            $recoveryRaceJournalHook = '        Start-ClaudeEasyRecoveryRaceClient "journal"' + [Environment]::NewLine
            $recoveryRaceText = $recoveryRaceText.Insert(
                $recoveryRaceJournalOffset,
                $recoveryRaceJournalHook
            )
            [System.IO.File]::WriteAllText(
                $recoveryRaceTransaction,
                $recoveryRaceText,
                (New-Object System.Text.UTF8Encoding($true))
            )

            $recoveryRaceClient = Join-Path $sandbox "clash-verge.exe"
            Copy-Item -LiteralPath (
                Join-Path (Join-Path $env:SystemRoot "System32") "ping.exe"
            ) -Destination $recoveryRaceClient
            $stopRecoveryRaceClient = {
                param([string]$PidPath)
                if (-not (Test-Path -LiteralPath $PidPath -PathType Leaf)) { return }
                $injectedId = 0
                if ([int]::TryParse(
                    [System.IO.File]::ReadAllText($PidPath),
                    [ref]$injectedId
                )) {
                    $injectedProcess = Get-Process -Id $injectedId -ErrorAction SilentlyContinue
                    if ($null -ne $injectedProcess) {
                        Stop-Process -Id $injectedId -Force
                        $injectedProcess.WaitForExit()
                    }
                }
            }

            $journalRaceHome = Join-Path $sandbox "recovery-journal-client-race-home"
            $journalRacePid = Join-Path $sandbox "recovery-journal-client-race.pid"
            New-Item -ItemType Directory -Path $journalRaceHome -Force | Out-Null
            $journalRaceTarget = Join-Path $journalRaceHome "config.yaml"
            $journalRaceMissingTarget = Join-Path $journalRaceHome "verge.yaml"
            $journalRaceOriginal = [System.Text.Encoding]::UTF8.GetBytes(
                "mode: rule`nipv6: true`n"
            )
            $journalRaceReplacement = [System.Text.Encoding]::UTF8.GetBytes(
                "mode: global`nipv6: false`n"
            )
            $journalRaceMissingOriginal = [System.Text.Encoding]::UTF8.GetBytes(
                "enable_tun_mode: false`n"
            )
            [System.IO.File]::WriteAllBytes($journalRaceTarget, $journalRaceOriginal)
            $journalRaceIdentity = (Get-OptionalFileSnapshot (
                $journalRaceTarget
            ) "recovery race target").Identity
            [System.IO.File]::WriteAllBytes($journalRaceTarget, $journalRaceReplacement)
            [System.IO.File]::WriteAllBytes(
                $journalRaceMissingTarget,
                $journalRaceMissingOriginal
            )
            $journalRaceMissingIdentity = (Get-OptionalFileSnapshot (
                $journalRaceMissingTarget
            ) "recovery race missing target").Identity
            [System.IO.File]::Delete($journalRaceMissingTarget)
            $journalRacePath = Join-Path $journalRaceHome ".claude-easy-transaction.json"
            $journalRaceRecord = [ordered]@{
                Version = 1
                Actions = @(
                    [ordered]@{
                        Action = "write"
                        Path = "config.yaml"
                        Existed = $true
                        Identity = $journalRaceIdentity
                        OriginalBase64 = [Convert]::ToBase64String($journalRaceOriginal)
                        ReplacementBase64 = [Convert]::ToBase64String($journalRaceReplacement)
                    },
                    [ordered]@{
                        Action = "delete"
                        Path = "verge.yaml"
                        Existed = $true
                        Identity = $journalRaceMissingIdentity
                        OriginalBase64 = [Convert]::ToBase64String(
                            $journalRaceMissingOriginal
                        )
                        ReplacementBase64 = ""
                    }
                )
            }
            [System.IO.File]::WriteAllText(
                $journalRacePath,
                ($journalRaceRecord | ConvertTo-Json -Depth 5 -Compress),
                (New-Object System.Text.UTF8Encoding($false))
            )
            $journalRaceRecordBytes = [System.IO.File]::ReadAllBytes($journalRacePath)
            try {
                $env:CLAUDE_EASY_TEST_RECOVERY_RACE_MODE = "journal"
                $env:CLAUDE_EASY_TEST_RECOVERY_RACE_EXECUTABLE = $recoveryRaceClient
                $env:CLAUDE_EASY_TEST_RECOVERY_RACE_PID = $journalRacePid
                $journalRaceResult = Invoke-TestPowerShell $recoveryRaceInstaller @(
                    "-AppHome", $journalRaceHome,
                    "-ShowUsageProfile",
                    "-Json"
                )
                $journalRaceJson = Assert-JsonResult $journalRaceResult "install" 1
                Assert-True (
                    $journalRaceJson.status -eq "partial" -and
                    $journalRaceJson.code -eq "transaction_recovery_pending"
                ) "newly started client did not defer interrupted journal recovery"
                Assert-True (
                    [Convert]::ToBase64String(
                        [System.IO.File]::ReadAllBytes($journalRaceTarget)
                    ) -eq [Convert]::ToBase64String($journalRaceReplacement)
                ) "newly started client allowed interrupted journal recovery to rewrite config.yaml"
                Assert-True (-not (
                    Test-Path -LiteralPath $journalRaceMissingTarget
                )) "rejected journal recovery retained a newly created placeholder"
                Assert-True (
                    [Convert]::ToBase64String(
                        [System.IO.File]::ReadAllBytes($journalRacePath)
                    ) -eq [Convert]::ToBase64String($journalRaceRecordBytes)
                ) "newly started client allowed interrupted journal recovery to consume its record"
            } finally {
                & $stopRecoveryRaceClient $journalRacePid
                $env:CLAUDE_EASY_TEST_RECOVERY_RACE_MODE = $null
                $env:CLAUDE_EASY_TEST_RECOVERY_RACE_EXECUTABLE = $null
                $env:CLAUDE_EASY_TEST_RECOVERY_RACE_PID = $null
            }

            $preparationRaceHome = Join-Path $sandbox "recovery-preparation-client-race-home"
            $preparationRacePid = Join-Path $sandbox "recovery-preparation-client-race.pid"
            New-Item -ItemType Directory -Path $preparationRaceHome -Force | Out-Null
            $preparationRaceConfig = Join-Path $preparationRaceHome "config.yaml"
            $preparationRaceVerge = Join-Path $preparationRaceHome "verge.yaml"
            [System.IO.File]::WriteAllBytes($preparationRaceConfig, [byte[]]@())
            [System.IO.File]::WriteAllBytes($preparationRaceVerge, [byte[]]@())
            $preparationRacePath = Join-Path (
                $preparationRaceHome
            ) ".claude-easy-transaction-preparation.json"
            $preparationRaceRecord = [ordered]@{
                Version = 1
                Paths = @("config.yaml", "verge.yaml")
            }
            [System.IO.File]::WriteAllText(
                $preparationRacePath,
                ($preparationRaceRecord | ConvertTo-Json -Depth 3 -Compress),
                (New-Object System.Text.UTF8Encoding($false))
            )
            $preparationRaceRecordBytes = [System.IO.File]::ReadAllBytes(
                $preparationRacePath
            )
            try {
                $env:CLAUDE_EASY_TEST_RECOVERY_RACE_MODE = "preparation"
                $env:CLAUDE_EASY_TEST_RECOVERY_RACE_EXECUTABLE = $recoveryRaceClient
                $env:CLAUDE_EASY_TEST_RECOVERY_RACE_PID = $preparationRacePid
                $preparationRaceResult = Invoke-TestPowerShell $recoveryRaceInstaller @(
                    "-AppHome", $preparationRaceHome,
                    "-ShowUsageProfile",
                    "-Json"
                )
                $preparationRaceJson = Assert-JsonResult $preparationRaceResult "install" 1
                Assert-True (
                    $preparationRaceJson.status -eq "partial" -and
                    $preparationRaceJson.code -eq "transaction_recovery_pending"
                ) "newly started client did not defer interrupted preparation recovery"
                Assert-True (
                    (Test-Path -LiteralPath $preparationRaceConfig -PathType Leaf) -and
                    (Get-Item -LiteralPath $preparationRaceConfig).Length -eq 0 -and
                    (Test-Path -LiteralPath $preparationRaceVerge -PathType Leaf) -and
                    (Get-Item -LiteralPath $preparationRaceVerge).Length -eq 0
                ) "newly started client allowed prepared current-config targets to be deleted"
                Assert-True (
                    [Convert]::ToBase64String(
                        [System.IO.File]::ReadAllBytes($preparationRacePath)
                    ) -eq [Convert]::ToBase64String($preparationRaceRecordBytes)
                ) "newly started client allowed preparation recovery to consume its record"
            } finally {
                & $stopRecoveryRaceClient $preparationRacePid
                $env:CLAUDE_EASY_TEST_RECOVERY_RACE_MODE = $null
                $env:CLAUDE_EASY_TEST_RECOVERY_RACE_EXECUTABLE = $null
                $env:CLAUDE_EASY_TEST_RECOVERY_RACE_PID = $null
            }
        }

        Invoke-DeferredProbe "public new-target journal handoff strong-kill recovery" {
            $publicHandoffPackageParent = Join-Path $sandbox "public-journal-handoff-crash-package"
            New-Item -ItemType Directory -Path $publicHandoffPackageParent -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $root "claude-easy") -Destination $publicHandoffPackageParent -Recurse
            $publicHandoffPackage = Join-Path $publicHandoffPackageParent "claude-easy"
            $publicHandoffInstaller = Join-Path (
                Join-Path $publicHandoffPackage "scripts"
            ) "install_windows.ps1"
            $publicHandoffTransaction = Join-Path (
                Join-Path (Join-Path $publicHandoffPackage "scripts") "windows/install_windows"
            ) "transaction.ps1"
            $publicHandoffTransactionText = [System.IO.File]::ReadAllText($publicHandoffTransaction)
            $publicHandoffFunctionOffset = $publicHandoffTransactionText.IndexOf(
                "function Invoke-VerifiedPathTransaction("
            )
            $publicHandoffNeedle = '        $journalBytes = Write-FileTransactionJournal $opened $InterruptedRecoveryPolicy'
            $publicHandoffOffset = $publicHandoffTransactionText.IndexOf(
                $publicHandoffNeedle,
                $publicHandoffFunctionOffset
            )
            Assert-True (
                $publicHandoffFunctionOffset -ge 0 -and
                $publicHandoffOffset -ge 0 -and
                $publicHandoffTransactionText.LastIndexOf($publicHandoffNeedle) -eq $publicHandoffOffset
            ) "public journal handoff fixture could not find one transaction journal boundary"
            $publicHandoffLineEnd = $publicHandoffTransactionText.IndexOf("`n", $publicHandoffOffset)
            Assert-True ($publicHandoffLineEnd -gt $publicHandoffOffset) "transaction journal call was not one complete line"
            $publicHandoffHook = @'
        if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_EASY_TEST_JOURNAL_HANDOFF_CRASH_READY)) {
            [System.IO.File]::WriteAllText($env:CLAUDE_EASY_TEST_JOURNAL_HANDOFF_CRASH_READY, "ready")
            Start-Sleep -Seconds 30
        }
'@
            $publicHandoffTransactionText = $publicHandoffTransactionText.Insert(
                $publicHandoffLineEnd + 1,
                $publicHandoffHook
            )
            [System.IO.File]::WriteAllText(
                $publicHandoffTransaction,
                $publicHandoffTransactionText,
                (New-Object System.Text.UTF8Encoding($true))
            )

            $publicHandoffHome = Join-Path $sandbox "public-journal-handoff-crash-home"
            $publicHandoffProfiles = Join-Path $publicHandoffHome "profiles"
            $publicHandoffReady = Join-Path $sandbox "public-journal-handoff-crash.ready"
            New-Item -ItemType Directory -Path $publicHandoffProfiles -Force | Out-Null
            [System.IO.File]::WriteAllText(
                (Join-Path $publicHandoffHome "config.yaml"),
                "ipv6: true`ntun: null`n"
            )
            [System.IO.File]::WriteAllText(
                (Join-Path $publicHandoffHome "verge.yaml"),
                "enable_tun_mode: false`n"
            )
            [System.IO.File]::WriteAllText(
                (Join-Path $publicHandoffHome "profiles.yaml"),
                "items:`n- uid: R-journal-handoff`n  type: remote`n  option:`n    allow_auto_update: true`n"
            )
            $env:CLAUDE_EASY_TEST_JOURNAL_HANDOFF_CRASH_READY = $publicHandoffReady
            $publicHandoffChild = Start-Process -FilePath $PowerShellPath -ArgumentList @(
                "-NoLogo", "-NoProfile", "-File", $publicHandoffInstaller,
                "-AppHome", $publicHandoffHome,
                "-UsageProfile", "1",
                "-MihomoPath", $fakeCore
            ) -PassThru
            try {
                $publicHandoffDeadline = [DateTime]::UtcNow.AddSeconds(10)
                while (-not (Test-Path -LiteralPath $publicHandoffReady -PathType Leaf) -and
                    -not $publicHandoffChild.HasExited -and
                    [DateTime]::UtcNow -lt $publicHandoffDeadline) {
                    Start-Sleep -Milliseconds 25
                }
                Assert-True (
                    Test-Path -LiteralPath $publicHandoffReady -PathType Leaf
                ) "public install did not reach the journal handoff boundary"
                Stop-Process -Id $publicHandoffChild.Id -Force
                $publicHandoffChild.WaitForExit()
            } finally {
                $env:CLAUDE_EASY_TEST_JOURNAL_HANDOFF_CRASH_READY = $null
                if (-not $publicHandoffChild.HasExited) {
                    Stop-Process -Id $publicHandoffChild.Id -Force
                }
            }

            $publicHandoffUsage = Join-Path $publicHandoffHome "claude-easy-usage-profile.json"
            $publicHandoffJournal = Join-Path $publicHandoffHome ".claude-easy-transaction.json"
            $publicHandoffPreparation = Join-Path (
                $publicHandoffHome
            ) ".claude-easy-transaction-preparation.json"
            Assert-True (
                (Test-Path -LiteralPath $publicHandoffUsage -PathType Leaf) -and
                (Get-Item -LiteralPath $publicHandoffUsage).Length -eq 0
            ) "journal handoff fixture did not leave its newly created empty state"
            Assert-True (
                Test-Path -LiteralPath $publicHandoffJournal -PathType Leaf
            ) "journal handoff crash did not publish the main transaction record"
            Assert-True (
                Test-Path -LiteralPath $publicHandoffPreparation -PathType Leaf
            ) "journal handoff crash removed the preparation record too early"

            $publicHandoffRecovery = Invoke-TestPowerShell $publicHandoffInstaller @(
                "-AppHome", $publicHandoffHome,
                "-UsageProfile", "1",
                "-MihomoPath", $fakeCore,
                "-Json"
            )
            $publicHandoffRecoveryJson = Assert-JsonResult $publicHandoffRecovery "install" 0
            Assert-True (
                $publicHandoffRecoveryJson.code -eq "installed_common_baseline"
            ) "next public install did not recover the journal handoff"
            $publicHandoffUsageJson = Get-Content -LiteralPath $publicHandoffUsage -Raw | ConvertFrom-Json
            Assert-True ([int]$publicHandoffUsageJson.Profile -eq 1) "handoff recovery did not publish a valid usage state"
            Assert-True (-not (
                (Test-Path -LiteralPath $publicHandoffJournal) -or
                (Test-Path -LiteralPath $publicHandoffPreparation)
            )) "handoff recovery retained a transaction record"
        }
    }

    $verifiedTargetPath = Join-Path $transactionDir "verified-target.txt"
    $verifiedOriginal = [System.Text.Encoding]::UTF8.GetBytes("original")
    [System.IO.File]::WriteAllBytes($verifiedTargetPath, $verifiedOriginal)
    $verifiedOriginalIdentity = (Get-OptionalFileSnapshot $verifiedTargetPath "verified target").Identity
    $verifiedTarget = [pscustomobject]@{
        Path = $verifiedTargetPath
        Bytes = [System.Text.Encoding]::UTF8.GetBytes("replacement")
        Existed = $true
        OriginalBytes = $verifiedOriginal
        OriginalIdentity = $verifiedOriginalIdentity
    }
    [System.IO.File]::WriteAllText($verifiedTargetPath, "concurrent")
    $verifiedTransactionRejected = $false
    try { Invoke-VerifiedFileTransaction @($verifiedTarget) } catch { $verifiedTransactionRejected = $true }
    Assert-True $verifiedTransactionRejected "verified transaction overwrote a target that changed after candidate generation"
    Assert-True ((Get-Content -LiteralPath $verifiedTargetPath -Raw) -eq "concurrent") "verified transaction did not preserve concurrent content"

    $rollbackOnePath = Join-Path $transactionDir "rollback-one.txt"
    $rollbackTwoPath = Join-Path $transactionDir "rollback-two.txt"
    $rollbackOneOriginal = [System.Text.Encoding]::UTF8.GetBytes("one-original")
    $rollbackTwoOriginal = [System.Text.Encoding]::UTF8.GetBytes("two-original")
    [System.IO.File]::WriteAllBytes($rollbackOnePath, $rollbackOneOriginal)
    [System.IO.File]::WriteAllBytes($rollbackTwoPath, $rollbackTwoOriginal)
    $rollbackOneIdentity = (Get-OptionalFileSnapshot $rollbackOnePath "rollback one").Identity
    $rollbackTwoIdentity = (Get-OptionalFileSnapshot $rollbackTwoPath "rollback two").Identity
    $savedWriteLockedStreamBytes = ${function:Write-LockedStreamBytes}
    $script:transactionWriteCallCount = 0
    try {
        function Write-LockedStreamBytes(
            [System.IO.FileStream]$Stream,
            [byte[]]$Replacement,
            [byte[]]$Original
        ) {
            $script:transactionWriteCallCount++
            if ($script:transactionWriteCallCount -eq 2) { throw "primary write failure" }
            if ($script:transactionWriteCallCount -eq 3) { throw "rollback failure" }
            $Stream.Position = 0
            $Stream.Write($Replacement, 0, $Replacement.Length)
            $Stream.SetLength($Replacement.Length)
            $Stream.Flush()
        }
        $rollbackFailureMessage = ""
        try {
            Invoke-VerifiedFileTransaction @(
                [pscustomobject]@{ Path = $rollbackOnePath; Bytes = [System.Text.Encoding]::UTF8.GetBytes("one-new"); Existed = $true; OriginalBytes = $rollbackOneOriginal; OriginalIdentity = $rollbackOneIdentity },
                [pscustomobject]@{ Path = $rollbackTwoPath; Bytes = [System.Text.Encoding]::UTF8.GetBytes("two-new"); Existed = $true; OriginalBytes = $rollbackTwoOriginal; OriginalIdentity = $rollbackTwoIdentity }
            )
        } catch {
            $rollbackFailureMessage = $_.Exception.Message
        }
        Assert-True $rollbackFailureMessage.Contains("primary write failure") "verified transaction hid its original failure"
        Assert-True $rollbackFailureMessage.Contains("rollback failure") "verified transaction hid a rollback failure"
        Assert-True ((Get-Content -LiteralPath $rollbackOnePath -Raw) -eq "one-original") "verified transaction stopped rollback after one restore failed"
    } finally {
        Set-Item -Path Function:\Write-LockedStreamBytes -Value $savedWriteLockedStreamBytes
        Remove-Variable -Name transactionWriteCallCount -Scope Script -ErrorAction SilentlyContinue
    }

    $deletePreflightWritePath = Join-Path $transactionDir "delete-preflight-write.txt"
    $deletePreflightTargetPath = Join-Path $transactionDir "delete-preflight-target.txt"
    $deletePreflightWriteBytes = [System.Text.Encoding]::UTF8.GetBytes("write-original")
    $deletePreflightTargetBytes = [System.Text.Encoding]::UTF8.GetBytes("delete-original")
    [System.IO.File]::WriteAllBytes($deletePreflightWritePath, $deletePreflightWriteBytes)
    [System.IO.File]::WriteAllBytes($deletePreflightTargetPath, $deletePreflightTargetBytes)
    $deletePreflightWriteIdentity = (Get-OptionalFileSnapshot $deletePreflightWritePath "delete preflight write").Identity
    $deletePreflightTargetIdentity = (Get-OptionalFileSnapshot $deletePreflightTargetPath "delete preflight target").Identity
    [System.IO.File]::WriteAllText($deletePreflightTargetPath, "delete-concurrent")
    $deletePreflightRejected = $false
    try {
        Invoke-VerifiedWriteDeleteTransaction @(
            [pscustomobject]@{
                Path = $deletePreflightWritePath
                Bytes = [System.Text.Encoding]::UTF8.GetBytes("write-replacement")
                Existed = $true
                OriginalBytes = $deletePreflightWriteBytes
                OriginalIdentity = $deletePreflightWriteIdentity
            }
        ) @(
            [pscustomobject]@{
                Path = $deletePreflightTargetPath
                Existed = $true
                OriginalBytes = $deletePreflightTargetBytes
                OriginalIdentity = $deletePreflightTargetIdentity
            }
        )
    } catch { $deletePreflightRejected = $true }
    Assert-True $deletePreflightRejected "write/delete transaction wrote files before validating every delete target"
    Assert-True ((Get-Content -LiteralPath $deletePreflightWritePath -Raw) -eq "write-original") "delete preflight conflict changed a write target"
    Assert-True ((Get-Content -LiteralPath $deletePreflightTargetPath -Raw) -eq "delete-concurrent") "delete preflight conflict changed its delete target"

    $overlapPath = Join-Path $transactionDir "write-delete-overlap.txt"
    $overlapOriginal = [System.Text.Encoding]::UTF8.GetBytes("overlap-original")
    [System.IO.File]::WriteAllBytes($overlapPath, $overlapOriginal)
    $overlapRejected = $false
    try {
        Invoke-VerifiedWriteDeleteTransaction @(
            [pscustomobject]@{
                Path = $overlapPath
                Bytes = [byte[]]@()
                Existed = $true
                OriginalBytes = $overlapOriginal
            }
        ) @(
            [pscustomobject]@{
                Path = $overlapPath
                Existed = $true
                OriginalBytes = $overlapOriginal
            }
        )
    } catch { $overlapRejected = $true }
    Assert-True $overlapRejected "write/delete transaction accepted an ambiguous overlapping target"
    Assert-True ((Get-Content -LiteralPath $overlapPath -Raw) -eq "overlap-original") "overlap rejection changed the target"

    $visibilityExistingPath = Join-Path $transactionDir "visibility-existing.txt"
    $visibilityNewPath = Join-Path $transactionDir "visibility-new.txt"
    $visibilityDeletePath = Join-Path $transactionDir "visibility-delete.txt"
    $visibilityMovedPath = Join-Path $transactionDir "visibility-delete-moved.txt"
    $visibilityExistingOriginal = [System.Text.Encoding]::UTF8.GetBytes("visibility-old")
    $visibilityDeleteOriginal = [System.Text.Encoding]::UTF8.GetBytes("visibility-delete")
    [System.IO.File]::WriteAllBytes($visibilityExistingPath, $visibilityExistingOriginal)
    [System.IO.File]::WriteAllBytes($visibilityDeletePath, $visibilityDeleteOriginal)
    $visibilityExistingIdentity = (Get-OptionalFileSnapshot $visibilityExistingPath "visibility existing").Identity
    $visibilityDeleteIdentity = (Get-OptionalFileSnapshot $visibilityDeletePath "visibility delete").Identity
    $savedVisibilityWriter = ${function:Write-LockedStreamBytes}
    $script:visibilityProbeRan = $false
    $script:visibilityExistingReadBlocked = $false
    $script:visibilityNewReadBlocked = $false
    $script:visibilityDeleteMoveBlocked = $false
    try {
        function Write-LockedStreamBytes(
            [System.IO.FileStream]$Stream,
            [byte[]]$Replacement,
            [byte[]]$Original
        ) {
            if (-not $script:visibilityProbeRan) {
                $script:visibilityProbeRan = $true
                try { [System.IO.File]::ReadAllText($visibilityExistingPath) | Out-Null } catch {
                    $script:visibilityExistingReadBlocked = $true
                }
                try { [System.IO.File]::ReadAllText($visibilityNewPath) | Out-Null } catch {
                    $script:visibilityNewReadBlocked = $true
                }
                try { [System.IO.File]::Move($visibilityDeletePath, $visibilityMovedPath) } catch {
                    $script:visibilityDeleteMoveBlocked = $true
                }
            }
            & $savedVisibilityWriter $Stream $Replacement $Original
        }
        Invoke-VerifiedWriteDeleteTransaction @(
            [pscustomobject]@{
                Path = $visibilityExistingPath
                Bytes = [System.Text.Encoding]::UTF8.GetBytes("visibility-new")
                Existed = $true
                OriginalBytes = $visibilityExistingOriginal
                OriginalIdentity = $visibilityExistingIdentity
            },
            [pscustomobject]@{
                Path = $visibilityNewPath
                Bytes = [System.Text.Encoding]::UTF8.GetBytes("visibility-created")
                Existed = $false
                OriginalBytes = $null
                OriginalIdentity = $null
            }
        ) @(
            [pscustomobject]@{
                Path = $visibilityDeletePath
                Existed = $true
                OriginalBytes = $visibilityDeleteOriginal
                OriginalIdentity = $visibilityDeleteIdentity
            }
        )
        Assert-True $script:visibilityProbeRan "transaction never exercised its visibility probe"
        Assert-True $script:visibilityExistingReadBlocked "transaction exposed an existing file while it was being rewritten"
        Assert-True $script:visibilityNewReadBlocked "transaction exposed a zero-byte new file before the batch committed"
        Assert-True $script:visibilityDeleteMoveBlocked "transaction started writing before every delete target was locked"
        Assert-True ((Get-Content -LiteralPath $visibilityExistingPath -Raw) -eq "visibility-new") "visibility transaction did not update its existing target"
        Assert-True ((Get-Content -LiteralPath $visibilityNewPath -Raw) -eq "visibility-created") "visibility transaction did not create its new target"
        Assert-True (-not (Test-Path -LiteralPath $visibilityDeletePath)) "visibility transaction did not delete its target"
        Assert-True (-not (Test-Path -LiteralPath $visibilityMovedPath)) "visibility transaction allowed its delete target to move"
    } finally {
        Set-Item -Path Function:\Write-LockedStreamBytes -Value $savedVisibilityWriter
        Remove-Variable -Name visibilityProbeRan -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name visibilityExistingReadBlocked -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name visibilityNewReadBlocked -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name visibilityDeleteMoveBlocked -Scope Script -ErrorAction SilentlyContinue
    }

    $lockedDeletePath = Join-Path $transactionDir "locked-delete-target.txt"
    $lockedDeleteMovedPath = Join-Path $transactionDir "locked-delete-moved.txt"
    $lockedDeleteBytes = [System.Text.Encoding]::UTF8.GetBytes("locked-delete-original")
    [System.IO.File]::WriteAllBytes($lockedDeletePath, $lockedDeleteBytes)
    $lockedDeleteIdentity = (Get-OptionalFileSnapshot $lockedDeletePath "locked delete").Identity
    $savedGetStreamBytes = ${function:Get-StreamBytes}
    $script:lockedDeleteWriteAttempted = $false
    $script:lockedDeleteWriteBlocked = $false
    $script:lockedDeleteReplaceAttempted = $false
    $script:lockedDeleteReplaceBlocked = $false
    try {
        function Get-StreamBytes([System.IO.FileStream]$Stream) {
            if (-not $script:lockedDeleteWriteAttempted) {
                $script:lockedDeleteWriteAttempted = $true
                try {
                    [System.IO.File]::WriteAllText($lockedDeletePath, "friend-concurrent")
                } catch {
                    $script:lockedDeleteWriteBlocked = $true
                }
                $script:lockedDeleteReplaceAttempted = $true
                try {
                    [System.IO.File]::Move($lockedDeletePath, $lockedDeleteMovedPath)
                    [System.IO.File]::WriteAllText($lockedDeletePath, "friend-replacement")
                } catch {
                    $script:lockedDeleteReplaceBlocked = $true
                }
            }
            return (& $savedGetStreamBytes $Stream)
        }
        Invoke-VerifiedWriteDeleteTransaction @() @(
            [pscustomobject]@{
                Path = $lockedDeletePath
                Existed = $true
                OriginalBytes = $lockedDeleteBytes
                OriginalIdentity = $lockedDeleteIdentity
            }
        )
        Assert-True $script:lockedDeleteWriteAttempted "delete transaction did not verify through a held file handle"
        Assert-True $script:lockedDeleteWriteBlocked "delete transaction allowed a same-target write between verification and deletion"
        Assert-True $script:lockedDeleteReplaceAttempted "delete transaction did not exercise an atomic replacement attempt"
        Assert-True $script:lockedDeleteReplaceBlocked "delete transaction allowed the verified file to be moved and replaced"
        Assert-True (-not (Test-Path -LiteralPath $lockedDeletePath)) "locked delete transaction did not remove the verified version"
        Assert-True (-not (Test-Path -LiteralPath $lockedDeleteMovedPath)) "locked delete transaction left the verified version under a moved path"
    } finally {
        Set-Item -Path Function:\Get-StreamBytes -Value $savedGetStreamBytes
        Remove-Variable -Name lockedDeleteWriteAttempted -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name lockedDeleteWriteBlocked -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name lockedDeleteReplaceAttempted -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name lockedDeleteReplaceBlocked -Scope Script -ErrorAction SilentlyContinue
    }

    $deleteRaceWritePath = Join-Path $transactionDir "delete-race-write.txt"
    $deleteRaceFirstPath = Join-Path $transactionDir "delete-race-first.txt"
    $deleteRaceSecondPath = Join-Path $transactionDir "delete-race-second.txt"
    $deleteRaceWriteOriginal = [System.Text.Encoding]::UTF8.GetBytes("race-original")
    $deleteRaceFirstOriginal = [System.Text.Encoding]::UTF8.GetBytes("first-original")
    $deleteRaceSecondOriginal = [System.Text.Encoding]::UTF8.GetBytes("second-original")
    [System.IO.File]::WriteAllBytes($deleteRaceWritePath, $deleteRaceWriteOriginal)
    [System.IO.File]::WriteAllBytes($deleteRaceFirstPath, $deleteRaceFirstOriginal)
    [System.IO.File]::WriteAllBytes($deleteRaceSecondPath, $deleteRaceSecondOriginal)
    $deleteRaceWriteIdentity = (Get-OptionalFileSnapshot $deleteRaceWritePath "delete race write").Identity
    $deleteRaceFirstIdentity = (Get-OptionalFileSnapshot $deleteRaceFirstPath "delete race first").Identity
    $deleteRaceSecondIdentity = (Get-OptionalFileSnapshot $deleteRaceSecondPath "delete race second").Identity
    $savedSetVerifiedDeleteDisposition = ${function:Set-VerifiedDeleteDisposition}
    $script:deleteRaceCallCount = 0
    try {
        function Set-VerifiedDeleteDisposition([System.IO.FileStream]$Stream, [bool]$DeleteFile) {
            if ($DeleteFile) {
                $script:deleteRaceCallCount++
                if ($script:deleteRaceCallCount -eq 2) { throw "injected delete failure" }
            }
            & $savedSetVerifiedDeleteDisposition $Stream $DeleteFile
        }
        $deleteRaceRejected = $false
        try {
            Invoke-VerifiedWriteDeleteTransaction @(
                [pscustomobject]@{
                    Path = $deleteRaceWritePath
                    Bytes = [System.Text.Encoding]::UTF8.GetBytes("race-replacement")
                    Existed = $true
                    OriginalBytes = $deleteRaceWriteOriginal
                    OriginalIdentity = $deleteRaceWriteIdentity
                }
            ) @(
                [pscustomobject]@{
                    Path = $deleteRaceFirstPath
                    Existed = $true
                    OriginalBytes = $deleteRaceFirstOriginal
                    OriginalIdentity = $deleteRaceFirstIdentity
                },
                [pscustomobject]@{
                    Path = $deleteRaceSecondPath
                    Existed = $true
                    OriginalBytes = $deleteRaceSecondOriginal
                    OriginalIdentity = $deleteRaceSecondIdentity
                }
            )
        } catch { $deleteRaceRejected = $true }
        Assert-True $deleteRaceRejected "write/delete transaction hid an injected delete failure"
        Assert-True ((Get-Content -LiteralPath $deleteRaceWritePath -Raw) -eq "race-original") "delete rollback did not restore its write target"
        Assert-True ((Get-Content -LiteralPath $deleteRaceFirstPath -Raw) -eq "first-original") "delete rollback did not cancel an earlier delete mark"
        Assert-True ((Get-Content -LiteralPath $deleteRaceSecondPath -Raw) -eq "second-original") "delete failure changed a later delete target"
    } finally {
        Set-Item -Path Function:\Set-VerifiedDeleteDisposition -Value $savedSetVerifiedDeleteDisposition
        Remove-Variable -Name deleteRaceCallCount -Scope Script -ErrorAction SilentlyContinue
    }

    if ($onWindows) {
        $rejectingCore = Join-Path $sandbox "mihomo-reject.cmd"
        $rejectingCoreText = "@echo off`r`nif `"%1`"==`"-v`" (`r`n  echo Mihomo Meta v1.19.27 windows amd64`r`n  exit /b 0`r`n)`r`nexit /b 17`r`n"
        [System.IO.File]::WriteAllText($rejectingCore, $rejectingCoreText, [System.Text.Encoding]::ASCII)
        $validationFailureCase = Join-Path $sandbox "mihomo-validation-failure-case"
        New-Item -ItemType Directory -Path $validationFailureCase -Force | Out-Null
        $validationConfig = "ipv6: true`ntun: null`n"
        $validationVerge = "enable_tun_mode: false`n"
        $validationProfiles = "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n"
        $validationUsage = '{"Version":1,"Profile":1}' + "`r`n"
        [System.IO.File]::WriteAllText((Join-Path $validationFailureCase "config.yaml"), $validationConfig)
        [System.IO.File]::WriteAllText((Join-Path $validationFailureCase "verge.yaml"), $validationVerge)
        [System.IO.File]::WriteAllText((Join-Path $validationFailureCase "profiles.yaml"), $validationProfiles)
        [System.IO.File]::WriteAllText((Join-Path $validationFailureCase "claude-easy-usage-profile.json"), $validationUsage)

        $validationFailure = Invoke-TestPowerShell $installer @(
            "-AppHome", $validationFailureCase, "-UsageProfile", "3", "-MihomoPath", $rejectingCore
        )

        Assert-True ($validationFailure.ExitCode -eq 1) "installer ignored a failed Mihomo candidate validation"
        Assert-True ((Get-Content -LiteralPath (Join-Path $validationFailureCase "config.yaml") -Raw) -eq $validationConfig) "failed Mihomo validation changed config.yaml"
        Assert-True ((Get-Content -LiteralPath (Join-Path $validationFailureCase "verge.yaml") -Raw) -eq $validationVerge) "failed Mihomo validation changed verge.yaml"
        Assert-True ((Get-Content -LiteralPath (Join-Path $validationFailureCase "profiles.yaml") -Raw) -eq $validationProfiles) "failed Mihomo validation changed profiles.yaml"
        Assert-True ((Get-Content -LiteralPath (Join-Path $validationFailureCase "claude-easy-usage-profile.json") -Raw) -eq $validationUsage) "failed Mihomo validation changed the usage profile"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $validationFailureCase "claude-easy-auto-update-state.json"))) "failed Mihomo validation created auto-update ownership"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path (Join-Path $validationFailureCase "profiles") "Script.js"))) "failed Mihomo validation created Script.js"

        $concurrentInstallCase = Join-Path $sandbox "concurrent-install-case"
        New-Item -ItemType Directory -Path $concurrentInstallCase -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $concurrentInstallCase "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
        [System.IO.File]::WriteAllText((Join-Path $concurrentInstallCase "config.yaml"), "ipv6: true`ntun: null`n")
        [System.IO.File]::WriteAllText((Join-Path $concurrentInstallCase "verge.yaml"), "enable_tun_mode: false`n")
        $env:CLAUDE_EASY_MUTATE_TARGET = Join-Path $concurrentInstallCase "config.yaml"
        try {
            $concurrentInstall = Invoke-TestPowerShell $installer @(
                "-AppHome", $concurrentInstallCase, "-UsageProfile", "3", "-MihomoPath", $mutatingCore
            )
        } finally {
            $env:CLAUDE_EASY_MUTATE_TARGET = $null
        }
        Assert-True ($concurrentInstall.ExitCode -eq 1) "installer overwrote a config change made while the candidate was being validated"
        Assert-True ((Get-Content -LiteralPath (Join-Path $concurrentInstallCase "config.yaml") -Raw).Contains("friend_concurrent: true")) "installer did not preserve concurrent config content"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $concurrentInstallCase "claude-easy-auto-update-state.json"))) "rejected concurrent install created auto-update ownership"

    }

    $nullCase = Join-Path $sandbox "null-case"
    New-Item -ItemType Directory -Path $nullCase -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $nullCase "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
    [System.IO.File]::WriteAllText((Join-Path $nullCase "config.yaml"), "ipv6 : true`ntun: null`n")
    [System.IO.File]::WriteAllText((Join-Path $nullCase "verge.yaml"), "enable_tun_mode: false`n")
    Invoke-Installer $nullCase
    $nullOutput = Get-Content -LiteralPath (Join-Path $nullCase "config.yaml") -Raw
    Assert-True ([regex]::Matches($nullOutput, '(?m)^tun\s*:').Count -eq 1) "tun: null produced duplicate tun keys"
    Assert-True ([regex]::Matches($nullOutput, '(?m)^ipv6\s*:').Count -eq 1) "spaced ipv6 produced duplicate ipv6 keys"
    Assert-True ($nullOutput.Contains("dns-hijack:`n") -or $nullOutput.Contains("dns-hijack:`r`n")) "dns-hijack block missing"
    $nullProfilesIndex = Get-Content -LiteralPath (Join-Path $nullCase "profiles.yaml") -Raw
    Assert-True ($nullProfilesIndex -match '(?m)^\s+allow_auto_update:\s+false\s*$') "profile 3 did not disable subscription auto-update"
    $nullAutoUpdateStatePath = Join-Path $nullCase "claude-easy-auto-update-state.json"
    Assert-True (Test-Path -LiteralPath $nullAutoUpdateStatePath -PathType Leaf) "profile 3 did not save auto-update ownership"
    $nullAutoUpdateStateBeforeReinstall = [System.IO.File]::ReadAllBytes($nullAutoUpdateStatePath)
    $profilesBackups = @(Get-ChildItem -LiteralPath (Join-Path $nullCase "claude-easy-backups") -File | Where-Object { $_.Name -like "*--profiles.yaml.backup" })
    Assert-True ($profilesBackups.Count -ge 1) "profiles.yaml was changed without a dated backup"
    $nullUsageStatePath = Join-Path $nullCase "claude-easy-usage-profile.json"
    $nullUsageStateBytes = [System.IO.File]::ReadAllBytes($nullUsageStatePath)
    Remove-Item -LiteralPath $nullUsageStatePath -Force
    $missingUsageBefore = Get-TreeContentSnapshot $nullCase
    $missingUsageDowngrade = Invoke-TestPowerShell $installer @("-AppHome", $nullCase, "-UsageProfile", "1", "-MihomoPath", $fakeCore)
    Assert-True ($missingUsageDowngrade.ExitCode -eq 1 -and (Get-TreeContentSnapshot $nullCase) -ceq $missingUsageBefore) "missing usage state bypassed profile 3 safe uninstall"
    [System.IO.File]::WriteAllBytes($nullUsageStatePath, $nullUsageStateBytes)
    $nullCaseJson = Invoke-TestPowerShell $installer @("-AppHome", $nullCase, "-MihomoPath", $fakeCore, "-Json")
    Assert-JsonResult $nullCaseJson "install" 0 | Out-Null
    Assert-True (([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($nullAutoUpdateStatePath))) -eq ([Convert]::ToBase64String($nullAutoUpdateStateBeforeReinstall))) "reinstall replaced the original auto-update ownership with the already-disabled state"
    Invoke-Uninstaller $nullCase
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $nullCase "claude-easy-usage-profile.json"))) "successful safe uninstall retained the profile 3 gate"
    Assert-True (-not (Test-Path -LiteralPath $nullAutoUpdateStatePath)) "successful safe uninstall retained auto-update ownership state"
    Assert-True ((Get-Content -LiteralPath (Join-Path $nullCase "profiles.yaml") -Raw) -match '(?m)^\s+allow_auto_update:\s+true\s*$') "safe uninstall did not restore remote subscription auto-update"
    $postUninstallLight = Invoke-TestPowerShell $installer @("-AppHome", $nullCase, "-UsageProfile", "1", "-MihomoPath", $fakeCore)
    Assert-True ($postUninstallLight.ExitCode -eq 0) "safe uninstall did not permit a documented profile 3 to profile 1 downgrade; $(Get-TestOutputDiagnostic $postUninstallLight.Output)"
    $postUninstallProfile = Get-Content -LiteralPath (Join-Path $nullCase "claude-easy-usage-profile.json") -Raw | ConvertFrom-Json
    Assert-True ([int]$postUninstallProfile.Profile -eq 1) "post-uninstall downgrade did not save profile 1"
    Assert-True (
        (Get-Content -LiteralPath (Join-Path $nullCase "profiles.yaml") -Raw) -match
        '(?m)^\s+allow_auto_update:\s+false\s*$'
    ) "profile 1 did not disable remote subscription auto-update"
    Assert-True (
        Test-Path -LiteralPath (Join-Path $nullCase "claude-easy-auto-update-state.json") -PathType Leaf
    ) "profile 1 did not preserve auto-update restore ownership"
    Invoke-Uninstaller $nullCase
    Assert-True (
        (Get-Content -LiteralPath (Join-Path $nullCase "profiles.yaml") -Raw) -match
        '(?m)^\s+allow_auto_update:\s+true\s*$'
    ) "profile 1 uninstall did not restore remote subscription auto-update"
    if ($onWindows) {
        $mihomoArguments = Get-Content -LiteralPath (Join-Path $sandbox "mihomo-arguments.log") -Raw
        Assert-True ($mihomoArguments -match '(?m)(^| )-t( |$)') "installer never asked Mihomo to test a generated candidate"
        Assert-True ($mihomoArguments -match '(?m)(^| )-f( |$)') "installer never passed the generated candidate to Mihomo"

        $createdSettingsCase = Join-Path $sandbox "created-settings-uninstall-case"
        New-Item -ItemType Directory -Path $createdSettingsCase -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $createdSettingsCase "profiles.yaml"),
            "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n"
        )
        Invoke-Installer $createdSettingsCase
        foreach ($createdPath in @(
            (Join-Path (Join-Path $createdSettingsCase "profiles") "Script.js"),
            (Join-Path $createdSettingsCase "config.yaml"),
            (Join-Path $createdSettingsCase "verge.yaml")
        )) {
            Assert-True (Test-Path -LiteralPath $createdPath -PathType Leaf) "installer did not create the expected managed file: $createdPath"
        }
        Invoke-Uninstaller $createdSettingsCase
        foreach ($removedPath in @(
            (Join-Path (Join-Path $createdSettingsCase "profiles") "Script.js"),
            (Join-Path $createdSettingsCase "config.yaml"),
            (Join-Path $createdSettingsCase "verge.yaml"),
            (Join-Path $createdSettingsCase "claude-easy-install-state.json"),
            (Join-Path $createdSettingsCase "claude-easy-auto-update-state.json"),
            (Join-Path $createdSettingsCase "claude-easy-usage-profile.json")
        )) {
            Assert-True (-not (Test-Path -LiteralPath $removedPath)) "safe uninstall retained a file created by the installer: $removedPath"
        }
        Assert-True (
            (Get-Content -LiteralPath (Join-Path $createdSettingsCase "profiles.yaml") -Raw) -match
            '(?m)^\s+allow_auto_update:\s+true\s*$'
        ) "safe uninstall did not restore auto-update when every application settings file was installer-created"

        foreach ($stateFileName in @(
            "claude-easy-install-state.json",
            "claude-easy-auto-update-state.json",
            "claude-easy-usage-profile.json"
        )) {
            $nonFileStateCase = Join-Path $sandbox ("non-file-state-" + $stateFileName.Replace(".", "-"))
            New-Item -ItemType Directory -Path $nonFileStateCase -Force | Out-Null
            [System.IO.File]::WriteAllText(
                (Join-Path $nonFileStateCase "profiles.yaml"),
                "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n"
            )
            [System.IO.File]::WriteAllText((Join-Path $nonFileStateCase "config.yaml"), "ipv6: true`ntun: null`n")
            [System.IO.File]::WriteAllText((Join-Path $nonFileStateCase "verge.yaml"), "enable_tun_mode: false`n")
            Invoke-Installer $nonFileStateCase
            $nonFileStatePath = Join-Path $nonFileStateCase $stateFileName
            Remove-Item -LiteralPath $nonFileStatePath -Force
            New-Item -ItemType Directory -Path $nonFileStatePath -Force | Out-Null
            $nonFileStateBefore = Get-TreeContentSnapshot $nonFileStateCase

            $nonFileStateResult = Invoke-TestPowerShell $uninstaller @("-AppHome", $nonFileStateCase, "-Json")
            $nonFileStateJson = Assert-JsonResult $nonFileStateResult "uninstall" 1

            Assert-True ($nonFileStateJson.status -eq "failed") "non-file state path did not fail the whole uninstall: $stateFileName"
            Assert-True (
                (Get-TreeContentSnapshot $nonFileStateCase) -ceq $nonFileStateBefore
            ) "non-file state path allowed a partial uninstall: $stateFileName"
        }

        $invalidUsageCase = Join-Path $sandbox "invalid-usage-state-case"
        New-Item -ItemType Directory -Path $invalidUsageCase -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $invalidUsageCase "profiles.yaml"),
            "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n"
        )
        [System.IO.File]::WriteAllText((Join-Path $invalidUsageCase "config.yaml"), "ipv6: true`ntun: null`n")
        [System.IO.File]::WriteAllText((Join-Path $invalidUsageCase "verge.yaml"), "enable_tun_mode: false`n")
        Invoke-Installer $invalidUsageCase
        $invalidUsageStatePath = Join-Path $invalidUsageCase "claude-easy-usage-profile.json"
        foreach ($invalidUsageState in @(
            "{",
            '{"Version":2,"Profile":3}',
            '{"Version":"1","Profile":3}',
            '{"Version":1,"Profile":"3"}',
            '{"Version":1,"Profile":0}',
            '{"Version":1}',
            '{"Version":1,"Profile":3,"Extra":true}',
            '{"Version":1,"Version":1,"Profile":3}'
        )) {
            [System.IO.File]::WriteAllText($invalidUsageStatePath, $invalidUsageState)
            $invalidUsageBefore = Get-TreeContentSnapshot $invalidUsageCase
            $invalidUsageResult = Invoke-TestPowerShell $uninstaller @("-AppHome", $invalidUsageCase, "-Json")
            $invalidUsageJson = Assert-JsonResult $invalidUsageResult "uninstall" 1
            Assert-True ($invalidUsageJson.status -eq "failed") "invalid usage state did not fail the whole uninstall: $invalidUsageState"
            Assert-True (
                (Get-TreeContentSnapshot $invalidUsageCase) -ceq $invalidUsageBefore
            ) "invalid usage state allowed a partial uninstall: $invalidUsageState"
        }

        $uninstallConflictCase = Join-Path $sandbox "uninstall-conflict-case"
        New-Item -ItemType Directory -Path $uninstallConflictCase -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $uninstallConflictCase "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
        [System.IO.File]::WriteAllText((Join-Path $uninstallConflictCase "config.yaml"), "ipv6: true`ntun: null`n")
        [System.IO.File]::WriteAllText((Join-Path $uninstallConflictCase "verge.yaml"), "enable_tun_mode: false`n")
        Invoke-Installer $uninstallConflictCase
        $conflictScriptPath = Join-Path (Join-Path $uninstallConflictCase "profiles") "Script.js"
        $conflictProfilesPath = Join-Path $uninstallConflictCase "profiles.yaml"
        $conflictConfigPath = Join-Path $uninstallConflictCase "config.yaml"
        $conflictVergePath = Join-Path $uninstallConflictCase "verge.yaml"
        $conflictAutoUpdateStatePath = Join-Path $uninstallConflictCase "claude-easy-auto-update-state.json"
        $conflictScriptBefore = [System.IO.File]::ReadAllBytes($conflictScriptPath)
        $conflictProfilesBefore = [System.IO.File]::ReadAllBytes($conflictProfilesPath)
        $conflictConfigBefore = [System.IO.File]::ReadAllBytes($conflictConfigPath)
        $conflictAutoUpdateStateBefore = [System.IO.File]::ReadAllBytes($conflictAutoUpdateStatePath)
        [System.IO.File]::WriteAllText($conflictVergePath, "enable_tun_mode: true`nfriend_after_install: true`n")
        $conflictVergeBefore = [System.IO.File]::ReadAllBytes($conflictVergePath)

        $uninstallConflict = Invoke-TestPowerShell $uninstaller @("-AppHome", $uninstallConflictCase, "-Json")
        $uninstallConflictResult = Assert-JsonResult $uninstallConflict "uninstall" 1

        Assert-True ($uninstallConflictResult.status -eq "failed") "conflicting uninstall did not fail closed"
        Assert-True (([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($conflictScriptPath))) -eq ([Convert]::ToBase64String($conflictScriptBefore))) "conflicting uninstall removed the global script before checking every target"
        Assert-True (([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($conflictProfilesPath))) -eq ([Convert]::ToBase64String($conflictProfilesBefore))) "conflicting uninstall restored auto-update before checking every target"
        Assert-True (([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($conflictConfigPath))) -eq ([Convert]::ToBase64String($conflictConfigBefore))) "conflicting uninstall restored config.yaml before checking every target"
        Assert-True (([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($conflictVergePath))) -eq ([Convert]::ToBase64String($conflictVergeBefore))) "conflicting uninstall changed the user-edited verge.yaml"
        Assert-True (([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($conflictAutoUpdateStatePath))) -eq ([Convert]::ToBase64String($conflictAutoUpdateStateBefore))) "conflicting uninstall removed auto-update recovery state"
        Assert-True (Test-Path -LiteralPath (Join-Path $uninstallConflictCase "claude-easy-install-state.json") -PathType Leaf) "conflicting uninstall removed its recovery state"
        Assert-True (Test-Path -LiteralPath (Join-Path $uninstallConflictCase "claude-easy-usage-profile.json") -PathType Leaf) "conflicting uninstall removed the profile 3 gate"

        $scriptOwnershipCases = @{}
        foreach ($name in @("managed-edit", "restored-main", "package-upgrade")) {
            $case = Join-Path $sandbox $name
            New-Item -ItemType Directory -Path (Join-Path $case "profiles") -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $case "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
            [System.IO.File]::WriteAllText((Join-Path $case "config.yaml"), "ipv6: true`ntun: null`n")
            [System.IO.File]::WriteAllText((Join-Path $case "verge.yaml"), "enable_tun_mode: false`n")
            if ($name -eq "restored-main") {
                [System.IO.File]::WriteAllText((Join-Path (Join-Path $case "profiles") "Script.js"), "function main(config) { return config; }`n")
            }
            Invoke-Installer $case
            $scriptOwnershipCases[$name] = $case
        }

        $managedEdit = $scriptOwnershipCases["managed-edit"]
        $managedEditScript = Join-Path (Join-Path $managedEdit "profiles") "Script.js"
        $managedEditText = [System.IO.File]::ReadAllText($managedEditScript).Replace(
            "function claudeEasyTransform(config, profileName, usageProfile) {",
            "function claudeEasyTransform(config, profileName, usageProfile) {`n// user edit"
        )
        Assert-True ($managedEditText -cne [System.IO.File]::ReadAllText($managedEditScript)) "managed-script mutation fixture did not change Script.js"
        [System.IO.File]::WriteAllText($managedEditScript, $managedEditText)
        $managedEditBefore = Get-TreeContentSnapshot $managedEdit
        Assert-JsonResult (Invoke-TestPowerShell $uninstaller @("-AppHome", $managedEdit, "-Json")) "uninstall" 1 | Out-Null
        Assert-True ((Get-TreeContentSnapshot $managedEdit) -ceq $managedEditBefore) "modified managed script changed during uninstall"

        $restoredMain = $scriptOwnershipCases["restored-main"]
        [System.IO.File]::AppendAllText((Join-Path (Join-Path $restoredMain "profiles") "Script.js"), "`nconst main = config => config;`n")
        $restoredMainBefore = Get-TreeContentSnapshot $restoredMain
        Assert-JsonResult (Invoke-TestPowerShell $uninstaller @("-AppHome", $restoredMain, "-Json")) "uninstall" 1 | Out-Null
        Assert-True ((Get-TreeContentSnapshot $restoredMain) -ceq $restoredMainBefore) "conflicting restored main changed during uninstall"

        $versionedPackage = Join-Path $sandbox "versioned-uninstall-package"
        Copy-Item -LiteralPath (Join-Path $root "claude-easy") -Destination $versionedPackage -Recurse
        [System.IO.File]::AppendAllText((Join-Path $versionedPackage "scripts/windows/clash_verge_global.js"), "`n// next version`n")
        $versionedUninstaller = Join-Path $versionedPackage "scripts/uninstall_windows.ps1"
        Assert-JsonResult (Invoke-TestPowerShell $versionedUninstaller @(
            "-AppHome", $scriptOwnershipCases["package-upgrade"], "-Json"
        )) "uninstall" 0 | Out-Null

        $invalidOwnershipCase = Join-Path $sandbox "invalid-auto-update-ownership-case"
        New-Item -ItemType Directory -Path $invalidOwnershipCase -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $invalidOwnershipCase "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
        [System.IO.File]::WriteAllText((Join-Path $invalidOwnershipCase "config.yaml"), "ipv6: true`ntun: null`n")
        [System.IO.File]::WriteAllText((Join-Path $invalidOwnershipCase "verge.yaml"), "enable_tun_mode: false`n")
        Invoke-Installer $invalidOwnershipCase
        $invalidOwnershipStatePath = Join-Path $invalidOwnershipCase "claude-easy-auto-update-state.json"
        [System.IO.File]::WriteAllText(
            $invalidOwnershipStatePath,
            '{"Version":1,"Profiles":[{"Uid":"R-test","OriginalState":"true","OriginalOptionBase64":"***"}]}'
        )
        $invalidOwnershipProtectedPaths = @(
            (Join-Path (Join-Path $invalidOwnershipCase "profiles") "Script.js"),
            (Join-Path $invalidOwnershipCase "profiles.yaml"),
            (Join-Path $invalidOwnershipCase "config.yaml"),
            (Join-Path $invalidOwnershipCase "verge.yaml"),
            (Join-Path $invalidOwnershipCase "claude-easy-install-state.json"),
            (Join-Path $invalidOwnershipCase "claude-easy-usage-profile.json"),
            $invalidOwnershipStatePath
        )
        $invalidOwnershipBefore = @{}
        foreach ($protectedPath in $invalidOwnershipProtectedPaths) {
            $invalidOwnershipBefore[$protectedPath] = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($protectedPath))
        }
        $invalidOwnershipUninstall = Invoke-TestPowerShell $uninstaller @("-AppHome", $invalidOwnershipCase, "-Json")
        Assert-JsonResult $invalidOwnershipUninstall "uninstall" 1 | Out-Null
        foreach ($protectedPath in $invalidOwnershipProtectedPaths) {
            Assert-True (
                [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($protectedPath)) -eq
                $invalidOwnershipBefore[$protectedPath]
            ) "invalid auto-update ownership changed a protected uninstall target: $protectedPath"
        }
    }

    if ($onWindows) {
        $runningCase = Join-Path $sandbox "running-client-case"
        $runningProfiles = Join-Path $runningCase "profiles"
        New-Item -ItemType Directory -Path $runningProfiles -Force | Out-Null
        $runningConfig = "ipv6: true`ntun: null`n"
        $runningVerge = "enable_tun_mode: false`n"
        [System.IO.File]::WriteAllText((Join-Path $runningCase "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
        [System.IO.File]::WriteAllText((Join-Path $runningProfiles "R-test.yaml"), "proxies: []`n")
        [System.IO.File]::WriteAllText((Join-Path $runningCase "config.yaml"), $runningConfig)
        [System.IO.File]::WriteAllText((Join-Path $runningCase "verge.yaml"), $runningVerge)
        $runningFixtureLock = Enter-AppHomeMutationLock $runningCase
        Exit-AppHomeMutationLock $runningFixtureLock
        $runningClientPath = Join-Path $sandbox "clash-verge.exe"
        Copy-Item -LiteralPath (Join-Path (Join-Path $env:SystemRoot "System32") "ping.exe") -Destination $runningClientPath
        $runningClient = Start-Process -FilePath $runningClientPath -ArgumentList @("-n", "20", "127.0.0.1") -PassThru
        $runningBefore = Get-TreeContentSnapshot $runningCase
        try {
            Start-Sleep -Milliseconds 100
            $runningResult = Invoke-TestPowerShell $installer @(
                "-AppHome", $runningCase,
                "-MihomoPath", $fakeCore,
                "-Json"
            )
            $runningJson = Assert-JsonResult $runningResult "install" 1
            Assert-True (
                $runningJson.status -eq "partial" -and
                $runningJson.code -eq "client_running_profile_three_deferred"
            ) "running profile 3 install reported success without changing the client's in-memory subscription state"
            Assert-True (
                (Get-TreeContentSnapshot $runningCase) -ceq $runningBefore
            ) "deferred running profile 3 install changed AppHome"

            $runningLightResult = Invoke-TestPowerShell $installer @(
                "-AppHome", $runningCase,
                "-UsageProfile", "1",
                "-MihomoPath", $fakeCore,
                "-Json"
            )
            $runningLightJson = Assert-JsonResult $runningLightResult "install" 1
            Assert-True (
                $runningLightJson.status -eq "partial" -and
                $runningLightJson.code -eq "client_running_auto_update_deferred"
            ) "running profile 1 install changed files without synchronizing the client's auto-update state"
            Assert-True (
                (Get-TreeContentSnapshot $runningCase) -ceq $runningBefore
            ) "deferred running profile 1 install changed AppHome"
        } finally {
            if (-not $runningClient.HasExited) { Stop-Process -Id $runningClient.Id -Force }
        }
        Invoke-Installer $runningCase
        Assert-True (Test-Path -LiteralPath (Join-Path $runningProfiles "Script.js") -PathType Leaf) "stopped-client retry did not install the global script"
        Assert-True ((Get-Content -LiteralPath (Join-Path $runningCase "profiles.yaml") -Raw) -match '(?m)^\s+allow_auto_update:\s+false\s*$') "stopped-client retry did not disable remote auto-update"
        Invoke-Uninstaller $runningCase
        Assert-True ((Get-Content -LiteralPath (Join-Path $runningCase "profiles.yaml") -Raw) -match '(?m)^\s+allow_auto_update:\s+true\s*$') "stopped-client retry could not later restore auto-update"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $runningCase "claude-easy-auto-update-state.json"))) "stopped-client retry uninstall retained auto-update ownership"

        $runningLightUninstallCase = Join-Path $sandbox "running-light-uninstall-case"
        $runningLightProfiles = Join-Path $runningLightUninstallCase "profiles"
        New-Item -ItemType Directory -Path $runningLightProfiles -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $runningLightUninstallCase "profiles.yaml"),
            "items:`n- uid: R-light`n  type: remote`n  option:`n    allow_auto_update: true`n"
        )
        $runningLightInstall = Invoke-TestPowerShell $installer @(
            "-AppHome", $runningLightUninstallCase,
            "-UsageProfile", "1",
            "-MihomoPath", $fakeCore,
            "-Json"
        )
        Assert-JsonResult $runningLightInstall "install" 0 | Out-Null
        $runningLightProtectedPaths = @(
            (Join-Path $runningLightProfiles "Script.js"),
            (Join-Path $runningLightUninstallCase "profiles.yaml"),
            (Join-Path $runningLightUninstallCase "claude-easy-auto-update-state.json"),
            (Join-Path $runningLightUninstallCase "claude-easy-usage-profile.json")
        )
        $runningLightProtectedBefore = @{}
        foreach ($protectedPath in $runningLightProtectedPaths) {
            $runningLightProtectedBefore[$protectedPath] =
                [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($protectedPath))
        }
        $runningLightClient = Start-Process -FilePath $runningClientPath -ArgumentList @("-n", "20", "127.0.0.1") -PassThru
        try {
            Start-Sleep -Milliseconds 100
            $runningLightUninstall = Invoke-TestPowerShell $uninstaller @(
                "-AppHome", $runningLightUninstallCase,
                "-Json"
            )
            $runningLightUninstallJson = Assert-JsonResult $runningLightUninstall "uninstall" 1
            Assert-True (
                $runningLightUninstallJson.status -eq "partial" -and
                $runningLightUninstallJson.code -eq "client_running"
            ) "running profile 1 uninstall reported success while Clash Verge Rev could still rewrite its in-memory profiles state"
            foreach ($protectedPath in $runningLightProtectedPaths) {
                Assert-True (
                    [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($protectedPath)) -eq
                    $runningLightProtectedBefore[$protectedPath]
                ) "running profile 1 uninstall changed a protected target: $protectedPath"
            }
        } finally {
            if (-not $runningLightClient.HasExited) { Stop-Process -Id $runningLightClient.Id -Force }
        }
        Invoke-Uninstaller $runningLightUninstallCase
        Assert-True (
            (Get-Content -LiteralPath (Join-Path $runningLightUninstallCase "profiles.yaml") -Raw) -match
            '(?m)^\s+allow_auto_update:\s+true\s*$'
        ) "stopped profile 1 uninstall did not restore subscription auto-update"
        Assert-True (
            -not (Test-Path -LiteralPath (Join-Path $runningLightUninstallCase "claude-easy-auto-update-state.json"))
        ) "stopped profile 1 uninstall retained auto-update ownership"

        $deferredUninstallCase = Join-Path $sandbox "deferred-running-uninstall-case"
        New-Item -ItemType Directory -Path $deferredUninstallCase -Force | Out-Null
        $deferredConfigOriginal = "ipv6: true`ntun: null`n"
        $deferredVergeOriginal = "enable_tun_mode: false`n"
        [System.IO.File]::WriteAllText((Join-Path $deferredUninstallCase "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
        [System.IO.File]::WriteAllText((Join-Path $deferredUninstallCase "config.yaml"), $deferredConfigOriginal)
        [System.IO.File]::WriteAllText((Join-Path $deferredUninstallCase "verge.yaml"), $deferredVergeOriginal)
        Invoke-Installer $deferredUninstallCase
        $deferredProtectedPaths = @(
            (Join-Path (Join-Path $deferredUninstallCase "profiles") "Script.js"),
            (Join-Path $deferredUninstallCase "profiles.yaml"),
            (Join-Path $deferredUninstallCase "config.yaml"),
            (Join-Path $deferredUninstallCase "verge.yaml"),
            (Join-Path $deferredUninstallCase "claude-easy-install-state.json"),
            (Join-Path $deferredUninstallCase "claude-easy-auto-update-state.json"),
            (Join-Path $deferredUninstallCase "claude-easy-usage-profile.json")
        )
        $deferredProtectedBefore = @{}
        foreach ($protectedPath in $deferredProtectedPaths) {
            $deferredProtectedBefore[$protectedPath] = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($protectedPath))
        }
        $deferredClient = Start-Process -FilePath $runningClientPath -ArgumentList @("-n", "20", "127.0.0.1") -PassThru
        try {
            Start-Sleep -Milliseconds 100
            $deferredResult = Invoke-TestPowerShell $uninstaller @("-AppHome", $deferredUninstallCase, "-Json")
            $deferredJson = Assert-JsonResult $deferredResult "uninstall" 1
            Assert-True ($deferredJson.status -eq "partial") "running offline uninstall did not report a partial result"
            Assert-True (@($deferredJson.changes).Count -eq 0) "running offline uninstall reported changes despite deferring the whole batch"
            foreach ($protectedPath in $deferredProtectedPaths) {
                Assert-True (
                    [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($protectedPath)) -eq
                    $deferredProtectedBefore[$protectedPath]
                ) "running offline uninstall changed a protected target: $protectedPath"
            }
        } finally {
            if (-not $deferredClient.HasExited) { Stop-Process -Id $deferredClient.Id -Force }
        }
        Invoke-Uninstaller $deferredUninstallCase
        Assert-True ((Get-Content -LiteralPath (Join-Path $deferredUninstallCase "config.yaml") -Raw) -eq $deferredConfigOriginal) "second safe uninstall did not restore deferred config.yaml"
        Assert-True ((Get-Content -LiteralPath (Join-Path $deferredUninstallCase "verge.yaml") -Raw) -eq $deferredVergeOriginal) "second safe uninstall did not restore deferred verge.yaml"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $deferredUninstallCase "claude-easy-usage-profile.json"))) "second safe uninstall retained the profile 3 gate"

        Invoke-DeferredProbe "stopped-client transactions recheck after locked target verification" {
            $clientStartPackageParent = Join-Path $sandbox "client-start-uninstall-package"
            New-Item -ItemType Directory -Path $clientStartPackageParent -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $root "claude-easy") -Destination $clientStartPackageParent -Recurse
            $clientStartPackage = Join-Path $clientStartPackageParent "claude-easy"
            $clientStartUninstaller = Join-Path (
                Join-Path $clientStartPackage "scripts"
            ) "uninstall_windows.ps1"
            $clientStartTransaction = Join-Path (
                Join-Path (Join-Path $clientStartPackage "scripts") "windows/install_windows"
            ) "transaction.ps1"
            $clientStartTransactionText = [System.IO.File]::ReadAllText($clientStartTransaction)
            $clientStartWriteFunctionOffset = $clientStartTransactionText.IndexOf(
                "function Write-LockedStreamBytes("
            )
            $clientStartWriteTryOffset = $clientStartTransactionText.IndexOf(
                "    try {",
                $clientStartWriteFunctionOffset
            )
            Assert-True (
                $clientStartWriteFunctionOffset -ge 0 -and
                $clientStartWriteTryOffset -ge 0
            ) "client-start fixture could not find the locked-stream write boundary"
            $clientStartWriteSpyHook = @'
    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_EASY_TEST_CLIENT_START_WRITE_SPY)) {
        [System.IO.File]::WriteAllText($env:CLAUDE_EASY_TEST_CLIENT_START_WRITE_SPY, "write")
    }
'@
            $clientStartTransactionText = $clientStartTransactionText.Insert(
                $clientStartWriteTryOffset,
                $clientStartWriteSpyHook
            )
            $clientStartFunctionOffset = $clientStartTransactionText.IndexOf(
                "function Invoke-VerifiedPathTransaction("
            )
            $clientStartGuardNeedle = '        if ($null -ne $PreCommitCondition) {'
            $clientStartGuardOffset = $clientStartTransactionText.IndexOf(
                $clientStartGuardNeedle,
                $clientStartFunctionOffset
            )
            Assert-True (
                $clientStartFunctionOffset -ge 0 -and
                $clientStartGuardOffset -ge 0 -and
                $clientStartTransactionText.LastIndexOf($clientStartGuardNeedle) -eq
                    $clientStartGuardOffset
            ) "client-start fixture could not find one locked-target precommit boundary"
            $clientStartHook = @'
        if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_EASY_TEST_CLIENT_START_READY) -and
            -not [string]::IsNullOrWhiteSpace($env:CLAUDE_EASY_TEST_CLIENT_START_RELEASE)) {
            [System.IO.File]::WriteAllText($env:CLAUDE_EASY_TEST_CLIENT_START_READY, "ready")
            $clientStartReleaseDeadline = [DateTime]::UtcNow.AddSeconds(10)
            while (-not (Test-Path -LiteralPath $env:CLAUDE_EASY_TEST_CLIENT_START_RELEASE -PathType Leaf) -and
                [DateTime]::UtcNow -lt $clientStartReleaseDeadline) {
                Start-Sleep -Milliseconds 25
            }
            if (-not (Test-Path -LiteralPath $env:CLAUDE_EASY_TEST_CLIENT_START_RELEASE -PathType Leaf)) {
                throw "client-start fixture timed out waiting for release"
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_EASY_TEST_CLIENT_START_EXECUTABLE) -and
            -not [string]::IsNullOrWhiteSpace($env:CLAUDE_EASY_TEST_CLIENT_START_PID)) {
            $clientStartInjected = Start-Process `
                -FilePath $env:CLAUDE_EASY_TEST_CLIENT_START_EXECUTABLE `
                -ArgumentList @("-n", "20", "127.0.0.1") -PassThru
            [void]$clientStartInjected.Handle
            [System.IO.File]::WriteAllText(
                $env:CLAUDE_EASY_TEST_CLIENT_START_PID,
                [string]$clientStartInjected.Id
            )
            $clientStartInjectedSeen = $false
            $clientStartInjectedDeadline = [DateTime]::UtcNow.AddSeconds(5)
            while (-not $clientStartInjected.HasExited -and
                -not $clientStartInjectedSeen -and
                [DateTime]::UtcNow -lt $clientStartInjectedDeadline) {
                $clientStartInjectedSeen = $null -ne (
                    Get-Process -Name "clash-verge" -ErrorAction SilentlyContinue |
                        Select-Object -First 1
                )
                if (-not $clientStartInjectedSeen) { Start-Sleep -Milliseconds 25 }
            }
            if (-not $clientStartInjectedSeen) {
                throw "injected client was not visible to the transaction precommit check"
            }
        }
'@
            $clientStartTransactionText = $clientStartTransactionText.Insert(
                $clientStartGuardOffset,
                $clientStartHook
            )
            [System.IO.File]::WriteAllText(
                $clientStartTransaction,
                $clientStartTransactionText,
                (New-Object System.Text.UTF8Encoding($true))
            )

            $clientStartHome = Join-Path $sandbox "client-start-uninstall-home"
            New-Item -ItemType Directory -Path $clientStartHome -Force | Out-Null
            $clientStartConfigOriginal = "ipv6: true`ntun: null`n"
            $clientStartVergeOriginal = "enable_tun_mode: false`n"
            [System.IO.File]::WriteAllText(
                (Join-Path $clientStartHome "profiles.yaml"),
                "items:`n- uid: R-client-start`n  type: remote`n  option:`n    allow_auto_update: true`n"
            )
            [System.IO.File]::WriteAllText(
                (Join-Path $clientStartHome "config.yaml"),
                $clientStartConfigOriginal
            )
            [System.IO.File]::WriteAllText(
                (Join-Path $clientStartHome "verge.yaml"),
                $clientStartVergeOriginal
            )
            Invoke-Installer $clientStartHome
            $clientStartProtectedPaths = @(
                (Join-Path (Join-Path $clientStartHome "profiles") "Script.js"),
                (Join-Path $clientStartHome "profiles.yaml"),
                (Join-Path $clientStartHome "config.yaml"),
                (Join-Path $clientStartHome "verge.yaml"),
                (Join-Path $clientStartHome "claude-easy-install-state.json"),
                (Join-Path $clientStartHome "claude-easy-auto-update-state.json"),
                (Join-Path $clientStartHome "claude-easy-usage-profile.json")
            )
            $clientStartProtectedBefore = @{}
            foreach ($protectedPath in $clientStartProtectedPaths) {
                Assert-True (
                    Test-Path -LiteralPath $protectedPath -PathType Leaf
                ) "client-start fixture omitted a protected uninstall target: $protectedPath"
                $clientStartProtectedBefore[$protectedPath] = [Convert]::ToBase64String(
                    [System.IO.File]::ReadAllBytes($protectedPath)
                )
            }

            $clientStartReady = Join-Path $sandbox "client-start-uninstall.ready"
            $clientStartRelease = Join-Path $sandbox "client-start-uninstall.release"
            $clientStartStdout = Join-Path $sandbox "client-start-uninstall.stdout"
            $clientStartStderr = Join-Path $sandbox "client-start-uninstall.stderr"
            $clientStartWriteSpy = Join-Path $sandbox "client-start-uninstall.write-spy"
            $env:CLAUDE_EASY_TEST_CLIENT_START_READY = $clientStartReady
            $env:CLAUDE_EASY_TEST_CLIENT_START_RELEASE = $clientStartRelease
            $env:CLAUDE_EASY_TEST_CLIENT_START_WRITE_SPY = $clientStartWriteSpy
            $clientStartChild = $null
            $clientStartProcess = $null
            try {
                $clientStartChild = Start-Process -FilePath $PowerShellPath -ArgumentList @(
                    "-NoLogo", "-NoProfile", "-File", $clientStartUninstaller,
                    "-AppHome", $clientStartHome,
                    "-Json"
                ) -RedirectStandardOutput $clientStartStdout `
                    -RedirectStandardError $clientStartStderr -PassThru
                [void]$clientStartChild.Handle
                $clientStartReadyDeadline = [DateTime]::UtcNow.AddSeconds(10)
                while (-not (Test-Path -LiteralPath $clientStartReady -PathType Leaf) -and
                    -not $clientStartChild.HasExited -and
                    [DateTime]::UtcNow -lt $clientStartReadyDeadline) {
                    Start-Sleep -Milliseconds 25
                }
                Assert-True (
                    Test-Path -LiteralPath $clientStartReady -PathType Leaf
                ) "uninstaller did not reach the locked-target precommit boundary"

                $clientStartProcess = Start-Process -FilePath $runningClientPath `
                    -ArgumentList @("-n", "20", "127.0.0.1") -PassThru
                $clientStartSeen = $false
                $clientStartSeenDeadline = [DateTime]::UtcNow.AddSeconds(5)
                while (-not $clientStartProcess.HasExited -and
                    -not $clientStartSeen -and
                    [DateTime]::UtcNow -lt $clientStartSeenDeadline) {
                    $clientStartSeen = $null -ne (
                        Get-Process -Name "clash-verge" -ErrorAction SilentlyContinue |
                            Select-Object -First 1
                    )
                    if (-not $clientStartSeen) { Start-Sleep -Milliseconds 25 }
                }
                Assert-True $clientStartSeen "fixture client was not visible to the uninstall process check"
                [System.IO.File]::WriteAllText($clientStartRelease, "release")
                Assert-True (
                    $clientStartChild.WaitForExit(10000)
                ) "client-start uninstall did not finish after release"
                $clientStartChild.WaitForExit()
                $clientStartInvocation = [pscustomobject]@{
                    Output = [System.IO.File]::ReadAllText($clientStartStdout)
                    ExitCode = $clientStartChild.ExitCode
                }
                $clientStartJson = Assert-JsonResult $clientStartInvocation "uninstall" 1
                Assert-True (
                    $clientStartJson.status -eq "partial" -and
                    $clientStartJson.code -eq "client_running"
                ) "client-start uninstall did not return the retryable running-client result"
                Assert-True (
                    @($clientStartJson.changes).Count -eq 0
                ) "client-start uninstall reported committed changes"
                Assert-True (-not (
                    Test-Path -LiteralPath $clientStartWriteSpy -PathType Leaf
                )) "client-start abort rewrote an existing transaction target"
                foreach ($protectedPath in $clientStartProtectedPaths) {
                    Assert-True (
                        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($protectedPath)) -ceq
                            $clientStartProtectedBefore[$protectedPath]
                    ) "client-start race changed a protected uninstall target: $protectedPath"
                }
                Assert-True (-not (
                    Test-Path -LiteralPath (
                        Join-Path $clientStartHome ".claude-easy-transaction.json"
                    )
                )) "client-start abort retained a transaction journal"
                Assert-True (-not (
                    Test-Path -LiteralPath (
                        Join-Path $clientStartHome ".claude-easy-transaction-preparation.json"
                    )
                )) "client-start abort retained a transaction preparation record"
            } finally {
                $env:CLAUDE_EASY_TEST_CLIENT_START_READY = $null
                $env:CLAUDE_EASY_TEST_CLIENT_START_RELEASE = $null
                $env:CLAUDE_EASY_TEST_CLIENT_START_WRITE_SPY = $null
                if (-not (Test-Path -LiteralPath $clientStartRelease -PathType Leaf)) {
                    [System.IO.File]::WriteAllText($clientStartRelease, "release")
                }
                if ($null -ne $clientStartChild -and -not $clientStartChild.HasExited) {
                    Stop-Process -Id $clientStartChild.Id -Force
                    $clientStartChild.WaitForExit()
                }
                if ($null -ne $clientStartProcess -and -not $clientStartProcess.HasExited) {
                    Stop-Process -Id $clientStartProcess.Id -Force
                    $clientStartProcess.WaitForExit()
                }
            }
            Invoke-Uninstaller $clientStartHome
            Assert-True (
                (Get-Content -LiteralPath (Join-Path $clientStartHome "config.yaml") -Raw) -ceq
                    $clientStartConfigOriginal
            ) "retry after client-start abort did not restore config.yaml"
            Assert-True (
                (Get-Content -LiteralPath (Join-Path $clientStartHome "verge.yaml") -Raw) -ceq
                    $clientStartVergeOriginal
            ) "retry after client-start abort did not restore verge.yaml"
            Assert-True (-not (
                Test-Path -LiteralPath (
                    Join-Path $clientStartHome "claude-easy-install-state.json"
                )
            )) "retry after client-start abort retained install recovery state"

            $invokeClientStartTransaction = {
                param(
                    [string]$Name,
                    [string]$ScriptPath,
                    [string[]]$Arguments,
                    [string]$WriteSpyPath
                )
                $pidPath = Join-Path $sandbox ("client-start-" + $Name + ".pid")
                $env:CLAUDE_EASY_TEST_CLIENT_START_EXECUTABLE = $runningClientPath
                $env:CLAUDE_EASY_TEST_CLIENT_START_PID = $pidPath
                $env:CLAUDE_EASY_TEST_CLIENT_START_WRITE_SPY = $WriteSpyPath
                try {
                    return (Invoke-TestPowerShell $ScriptPath $Arguments)
                } finally {
                    $env:CLAUDE_EASY_TEST_CLIENT_START_EXECUTABLE = $null
                    $env:CLAUDE_EASY_TEST_CLIENT_START_PID = $null
                    $env:CLAUDE_EASY_TEST_CLIENT_START_WRITE_SPY = $null
                    if (Test-Path -LiteralPath $pidPath -PathType Leaf) {
                        $startedPid = [int]([System.IO.File]::ReadAllText($pidPath))
                        $startedProcess = Get-Process -Id $startedPid -ErrorAction SilentlyContinue
                        if ($null -ne $startedProcess -and -not $startedProcess.HasExited) {
                            Stop-Process -Id $startedPid -Force
                            $startedProcess.WaitForExit()
                        }
                    }
                }
            }

            $clientStartInstaller = Join-Path (
                Join-Path $clientStartPackage "scripts"
            ) "install_windows.ps1"
            $clientStartInstallHome = Join-Path $sandbox "client-start-install-home"
            $clientStartInstallProfiles = Join-Path $clientStartInstallHome "profiles"
            New-Item -ItemType Directory -Path $clientStartInstallProfiles -Force | Out-Null
            $clientStartInstallConfig = "ipv6: true`ntun: null`n"
            $clientStartInstallVerge = "enable_tun_mode: false`n"
            $clientStartInstallIndex = "items:`n- uid: R-install-client-start`n  type: remote`n  option:`n    allow_auto_update: true`n"
            [System.IO.File]::WriteAllText(
                (Join-Path $clientStartInstallHome "config.yaml"),
                $clientStartInstallConfig
            )
            [System.IO.File]::WriteAllText(
                (Join-Path $clientStartInstallHome "verge.yaml"),
                $clientStartInstallVerge
            )
            [System.IO.File]::WriteAllText(
                (Join-Path $clientStartInstallHome "profiles.yaml"),
                $clientStartInstallIndex
            )
            $clientStartInstallWriteSpy = Join-Path $sandbox "client-start-install.write-spy"
            $clientStartInstallInvocation = & $invokeClientStartTransaction `
                -Name "install" `
                -ScriptPath $clientStartInstaller `
                -Arguments @(
                    "-AppHome", $clientStartInstallHome,
                    "-UsageProfile", "3",
                    "-MihomoPath", $fakeCore,
                    "-Json"
                ) `
                -WriteSpyPath $clientStartInstallWriteSpy
            $clientStartInstallJson = Assert-JsonResult $clientStartInstallInvocation "install" 1
            Assert-True (
                $clientStartInstallJson.status -eq "failed" -and
                $clientStartInstallJson.code -eq "install_failed"
            ) "client-start install did not return the stopped-client failure"
            Assert-True (
                (Get-Content -LiteralPath (Join-Path $clientStartInstallHome "config.yaml") -Raw) -ceq
                    $clientStartInstallConfig -and
                (Get-Content -LiteralPath (Join-Path $clientStartInstallHome "verge.yaml") -Raw) -ceq
                    $clientStartInstallVerge -and
                (Get-Content -LiteralPath (Join-Path $clientStartInstallHome "profiles.yaml") -Raw) -ceq
                    $clientStartInstallIndex
            ) "client-start install changed a protected target"
            foreach ($unexpectedInstallPath in @(
                (Join-Path $clientStartInstallProfiles "Script.js"),
                (Join-Path $clientStartInstallHome "claude-easy-install-state.json"),
                (Join-Path $clientStartInstallHome "claude-easy-auto-update-state.json"),
                (Join-Path $clientStartInstallHome "claude-easy-usage-profile.json"),
                (Join-Path $clientStartInstallHome ".claude-easy-transaction.json"),
                (Join-Path $clientStartInstallHome ".claude-easy-transaction-preparation.json")
            )) {
                Assert-True (-not (
                    Test-Path -LiteralPath $unexpectedInstallPath
                )) "client-start install retained a protected target: $unexpectedInstallPath"
            }
            Assert-True (-not (
                Test-Path -LiteralPath $clientStartInstallWriteSpy -PathType Leaf
            )) "client-start install wrote after the locked precommit check"
            $clientStartInstallRetry = Invoke-TestPowerShell $clientStartInstaller @(
                "-AppHome", $clientStartInstallHome,
                "-UsageProfile", "3",
                "-MihomoPath", $fakeCore,
                "-Json"
            )
            Assert-JsonResult $clientStartInstallRetry "install" 0 | Out-Null

            $clientStartRestoreHome = Join-Path $sandbox "client-start-restore-home"
            $clientStartRestoreTarget = Join-Path $clientStartRestoreHome "config.yaml"
            $clientStartRestoreBackupRoot = Join-Path (
                $clientStartRestoreHome
            ) "claude-easy-backups"
            New-Item -ItemType Directory -Path $clientStartRestoreHome -Force | Out-Null
            $clientStartRestoreBackupText = "mode: rule`nipv6: false`ntun:`n  enable: true`n  stack: system`n  dns-hijack:`n    - any:53`n  auto-route: true`n  auto-detect-interface: true`n  strict-route: true`nproxies: []`nproxy-groups: []`nrules: []`n"
            $clientStartRestoreCurrentText = "mode: global`nipv6: false`ntun:`n  enable: true`n  stack: system`n  dns-hijack:`n    - any:53`n  auto-route: true`n  auto-detect-interface: true`n  strict-route: true`nproxies: []`nproxy-groups: []`nrules: []`n"
            [System.IO.File]::WriteAllText((Join-Path $clientStartRestoreHome "claude-easy-usage-profile.json"), '{"Version":1,"Profile":3}')
            [System.IO.File]::WriteAllText(
                $clientStartRestoreTarget,
                $clientStartRestoreBackupText
            )
            $clientStartRestoreLock = Enter-AppHomeMutationLock $clientStartRestoreHome
            try {
                $clientStartRestoreBackup = Backup-Versioned `
                    $clientStartRestoreTarget $clientStartRestoreBackupRoot "prewrite"
            } finally {
                Exit-AppHomeMutationLock $clientStartRestoreLock
            }
            [System.IO.File]::WriteAllText(
                $clientStartRestoreTarget,
                $clientStartRestoreCurrentText
            )
            $clientStartRestoreHash = Get-FileSha256 $clientStartRestoreTarget
            $clientStartRestoreWriteSpy = Join-Path $sandbox "client-start-restore.write-spy"
            $clientStartRestoreInvocation = & $invokeClientStartTransaction `
                -Name "restore" `
                -ScriptPath $clientStartInstaller `
                -Arguments @(
                    "-AppHome", $clientStartRestoreHome,
                    "-RestoreBackup", (Split-Path -Leaf $clientStartRestoreBackup),
                    "-ExpectedCurrentSha256", $clientStartRestoreHash,
                    "-MihomoPath", $fakeCore,
                    "-Json"
                ) `
                -WriteSpyPath $clientStartRestoreWriteSpy
            $clientStartRestoreJson = Assert-JsonResult $clientStartRestoreInvocation "install" 1
            Assert-True (
                $clientStartRestoreJson.operation -eq "restore_backup" -and
                $clientStartRestoreJson.code -eq "operation_failed"
            ) "client-start restore did not return the stopped-client failure"
            Assert-True (
                (Get-Content -LiteralPath $clientStartRestoreTarget -Raw) -ceq
                    $clientStartRestoreCurrentText
            ) "client-start restore changed current configuration"
            Assert-True (-not (
                Test-Path -LiteralPath $clientStartRestoreWriteSpy -PathType Leaf
            )) "client-start restore wrote after the locked precommit check"
            foreach ($unexpectedRestorePath in @(
                (Join-Path $clientStartRestoreHome ".claude-easy-transaction.json"),
                (Join-Path $clientStartRestoreHome ".claude-easy-transaction-preparation.json")
            )) {
                Assert-True (-not (
                    Test-Path -LiteralPath $unexpectedRestorePath
                )) "client-start restore retained transaction state: $unexpectedRestorePath"
            }
            $clientStartRestoreRetry = Invoke-TestPowerShell $clientStartInstaller @(
                "-AppHome", $clientStartRestoreHome,
                "-RestoreBackup", (Split-Path -Leaf $clientStartRestoreBackup),
                "-ExpectedCurrentSha256", $clientStartRestoreHash,
                "-MihomoPath", $fakeCore,
                "-Json"
            )
            Assert-JsonResult $clientStartRestoreRetry "install" 0 | Out-Null
            Assert-True (
                (Get-Content -LiteralPath $clientStartRestoreTarget -Raw) -ceq
                    $clientStartRestoreBackupText
            ) "retry after client-start restore abort did not restore the requested backup"
        }
    }

    $blockCase = Join-Path $sandbox "block-case"
    New-Item -ItemType Directory -Path $blockCase -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $blockCase "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
    $blockInput = "ipv6: true`ntun:`n  enable: false`n  dns-hijack:`n    - 0.0.0.0:53`n  device: Clash`n"
    [System.IO.File]::WriteAllText((Join-Path $blockCase "config.yaml"), $blockInput)
    [System.IO.File]::WriteAllText((Join-Path $blockCase "verge.yaml"), "enable_dns_settings: true`n")
    Invoke-Installer $blockCase
    $blockAutoUpdateStatePath = Join-Path $blockCase "claude-easy-auto-update-state.json"
    $blockAutoUpdateStateBeforeReinstall = [System.IO.File]::ReadAllBytes($blockAutoUpdateStatePath)
    Invoke-Installer $blockCase
    Assert-True (([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($blockAutoUpdateStatePath))) -eq ([Convert]::ToBase64String($blockAutoUpdateStateBeforeReinstall))) "second install forgot the pre-patch auto-update state"
    $blockOutput = Get-Content -LiteralPath (Join-Path $blockCase "config.yaml") -Raw
    Assert-True (-not $blockOutput.Contains("0.0.0.0:53")) "old dns-hijack child survived"
    Assert-True ($blockOutput.Contains("device: Clash")) "unmanaged tun setting was removed"
    Assert-True ([regex]::Matches($blockOutput, '(?m)^  dns-hijack\s*:').Count -eq 1) "dns-hijack was duplicated"

    $composeCase = Join-Path $sandbox "compose-case"
    $composeProfiles = Join-Path $composeCase "profiles"
    New-Item -ItemType Directory -Path $composeProfiles -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $composeCase "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
    $composeConfigOriginal = "ipv6: true`ntun: null`n"
    $composeVergeOriginal = "enable_tun_mode: false`nenable_dns_settings: true`n"
    [System.IO.File]::WriteAllText((Join-Path $composeCase "config.yaml"), $composeConfigOriginal)
    [System.IO.File]::WriteAllText((Join-Path $composeCase "verge.yaml"), $composeVergeOriginal)
    $originalScript = @'
"use strict";
var friendGlobal = 40;
function helper() {
  return 41;
}
var friendTopLevelThis = this === globalThis;
function main(config) {
  config.friend = globalThis.friendGlobal + 1;
  config.helper = globalThis.helper();
  config.friendTopLevelThis = friendTopLevelThis;
  config.friendCallThis = this === undefined;
  try {
    friendStrictLeak = true;
    config.friendStrictAssignment = false;
  } catch (error) {
    config.friendStrictAssignment = error instanceof ReferenceError;
  }
  globalThis.main = function(value) { value.bypassed = true; return value; };
  globalThis["claude" + "EasyTransform"] = function(value) { value.bypassed = true; return value; };
  return config;
}
Object.defineProperty(globalThis, "main", {
  value: function(value) { value.bypassed = true; return value; },
  writable: true,
  configurable: true
});
'@
    $javaScriptLineSeparator = [string][char]0x2028
    $originalScript = $originalScript.Replace(
        "var friendGlobal = 40;",
        ('var friendSeparator = "a' + $javaScriptLineSeparator + 'b";' + "`nvar friendGlobal = 40;")
    ).Replace("`nfunction main(config)", $javaScriptLineSeparator + "function main(config)")
    $bomStrictScript = ([string][char]0xFEFF) + $originalScript
    Assert-True (
        @(Get-JavaScriptDirectivePrologue $bomStrictScript).Count -eq 1
    ) "BOM hid a JavaScript strict directive"
    Assert-True (
        @(Get-JavaScriptDirectivePrologue ('"use strict"' + "`n+0;`nfunction main(config) { return config; }")).Count -eq 0
    ) "a continued string expression was promoted to a strict directive"
    Assert-True (
        @(Get-JavaScriptDirectivePrologue ('"use strict"' + "`ninstanceof Object;`nfunction main(config) { return config; }")).Count -eq 0
    ) "a keyword continuation was promoted to a strict directive"
    Assert-True (
        @(Get-JavaScriptDirectivePrologue ('"use strict"' + "`ninπ;`nfunction main(config) { return config; }")).Count -eq 1
    ) "a Unicode identifier beginning with a keyword hid a strict directive"
    Assert-True (
        @(Get-JavaScriptDirectivePrologue ('"use strict"' + "`nin·;`nfunction main(config) { return config; }")).Count -eq 1
    ) "an Other_ID_Continue character hid a strict directive"
    Assert-True (
        @(Get-JavaScriptDirectivePrologue ('"use strict"' + ([string][char]0x2003) + ";`nfunction main(config) { return config; }")).Count -eq 1
    ) "ECMAScript whitespace before a semicolon hid a strict directive"
    Assert-True (
        @(Get-JavaScriptDirectivePrologue ('// comment' + ([string][char]0x2028) + '"use strict"; function main(config) { return config; }')).Count -eq 1
    ) "a Unicode line terminator kept a line comment open"
    Assert-True (
        @(Get-JavaScriptDirectivePrologue ('"use strict"' + "`nfunction main(config) { return config; }")).Count -eq 1
    ) "a semicolon-free strict directive before a function was lost"
    Assert-True (
        @(Get-JavaScriptDirectivePrologue ('"use strict";' + "`n" + '"use asm";' + "`nfunction main(config) { return config; }")).Count -eq 2
    ) "multiple terminated directives were not preserved"
    Assert-True (
        @(Get-JavaScriptDirectivePrologue ('"use strict"' + "`n" + '"use asm"' + "`nfunction main(config) { return config; }")).Count -eq 2
    ) "multiple ASI-terminated directives were not preserved"
    Assert-True (
        @(Get-JavaScriptDirectivePrologue ('`banner`' + "`n" + '"use strict"; function main(config) { return config; }')).Count -eq 0
    ) "a directive after a template expression was promoted"
    Assert-True (
        @(Get-JavaScriptDirectivePrologue ('"use strict"' + "`n" + '`continued`' + "`nfunction main(config) { return config; }")).Count -eq 0
    ) "a template continuation was promoted to a directive"
    Write-TestUtf8Text (Join-Path $composeProfiles "Script.js") $bomStrictScript
    Invoke-Installer $composeCase
    $composedPath = Join-Path $composeProfiles "Script.js"
    $enginePath = Join-Path (Join-Path $root "claude-easy/scripts/windows") "clash_verge_global.js"
    $canonicalComposedBytes = [System.IO.File]::ReadAllBytes($composedPath)
    $commentWrappedComposed = "// friend prefix comment`r`n" +
        (Read-TestUtf8Text $composedPath) +
        "/* friend suffix comment */`r`n"
    Write-TestUtf8Text $composedPath $commentWrappedComposed
    Assert-ClaudeEasyManagedScriptCurrent (
        Read-TestUtf8Text $composedPath
    ) 3 $enginePath $composedPath
    Assert-True (
        (Read-TestUtf8Text $composedPath).Contains("🤖 AI · ClaudeEasy")
    ) "Script.js UTF-8 fixture corrupted non-ASCII managed content"
    [System.IO.File]::WriteAllBytes($composedPath, $canonicalComposedBytes)

    $directivePrefix = '"use strict"' + "`r`n"
    Write-TestUtf8Text $composedPath (
        $directivePrefix + (Read-TestUtf8Text $composedPath)
    )
    $directivePrefixRejected = $false
    try {
        Assert-ClaudeEasyManagedScriptCurrent (
            Read-TestUtf8Text $composedPath
        ) 3 $enginePath $composedPath
    } catch {
        $directivePrefixRejected = $true
    }
    Assert-True $directivePrefixRejected "safe-update script check accepted a string directive outside the managed block"
    [System.IO.File]::WriteAllBytes($composedPath, $canonicalComposedBytes)

    $templateSuffix = "`r`n" + '`friend template literal`'
    Write-TestUtf8Text $composedPath (
        (Read-TestUtf8Text $composedPath) + $templateSuffix
    )
    $templateSuffixRejected = $false
    try {
        Assert-ClaudeEasyManagedScriptCurrent (
            Read-TestUtf8Text $composedPath
        ) 3 $enginePath $composedPath
    } catch {
        $templateSuffixRejected = $true
    }
    Assert-True $templateSuffixRejected "safe-update script check accepted a template literal outside the managed block"
    [System.IO.File]::WriteAllBytes($composedPath, $canonicalComposedBytes)

    $prefixPollution = "Object.prototype.friendOutsideManagedBlock = true;`r`n"
    Write-TestUtf8Text $composedPath (
        $prefixPollution + (Read-TestUtf8Text $composedPath)
    )
    $prefixPollutionRejected = $false
    try {
        Assert-ClaudeEasyManagedScriptCurrent (
            Read-TestUtf8Text $composedPath
        ) 3 $enginePath $composedPath
    } catch {
        $prefixPollutionRejected = $true
    }
    Assert-True $prefixPollutionRejected "safe-update script check accepted executable prefix code outside the managed block"
    Invoke-Installer $composeCase
    $migratedPrefixScript = Read-TestUtf8Text $composedPath
    Assert-True (
        $migratedPrefixScript.Contains($prefixPollution.Trim()) -and
        $migratedPrefixScript.TrimStart().StartsWith("// CLAUDEEASY BEGIN")
    ) "reinstall did not migrate executable prefix code into the preserved original-script block"
    Assert-ClaudeEasyManagedScriptCurrent $migratedPrefixScript 3 $enginePath $composedPath

    $composedWithSuffix = $migratedPrefixScript + "const friendAfterPatch = true;`r`n"
    Write-TestUtf8Text $composedPath $composedWithSuffix
    $suffixCodeRejected = $false
    try {
        Assert-ClaudeEasyManagedScriptCurrent (
            Read-TestUtf8Text $composedPath
        ) 3 $enginePath $composedPath
    } catch {
        $suffixCodeRejected = $true
    }
    Assert-True $suffixCodeRejected "safe-update script check accepted executable suffix code outside the managed block"
    Invoke-Installer $composeCase
    Assert-True ((Read-TestUtf8Text $composedPath).Contains("const friendAfterPatch = true;")) "reinstall discarded code after the managed block"
    Assert-ClaudeEasyManagedScriptCurrent (
        Read-TestUtf8Text $composedPath
    ) 3 $enginePath $composedPath
    $safeComposedBytes = [System.IO.File]::ReadAllBytes($composedPath)
    Write-TestUtf8Text $composedPath (
        (Read-TestUtf8Text $composedPath) +
            "function main(config) { config.suffixMain = true; return config; }`r`n"
    )
    $suffixMainCurrentRejected = $false
    try {
        Assert-ClaudeEasyManagedScriptCurrent (
            Read-TestUtf8Text $composedPath
        ) 3 $enginePath $composedPath
    } catch {
        $suffixMainCurrentRejected = $true
    }
    Assert-True $suffixMainCurrentRejected "safe-update script check accepted a main binding after the managed block"
    $reboundBytes = [System.IO.File]::ReadAllBytes($composedPath)
    $reboundResult = Invoke-TestPowerShell $installer @(
        "-AppHome", $composeCase,
        "-UsageProfile", "3",
        "-MihomoPath", $fakeCore
    )
    Assert-True ($reboundResult.ExitCode -eq 1) "reinstall accepted a main binding after the managed block"
    Assert-True (
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($composedPath)) -ceq
            [Convert]::ToBase64String($reboundBytes)
    ) "rejected suffix main changed Script.js"
    [System.IO.File]::WriteAllBytes($composedPath, $safeComposedBytes)
    if ($onWindows) {
        $generatedScriptHarness = Join-Path $sandbox "run-generated-script.js"
        $generatedScriptHarnessSource = @'
const fs = require("node:fs");
const vm = require("node:vm");
const generatedPath = process.argv[2];
const context = {};
vm.createContext(context);
function fixture() {
  return {
    proxies: [{ name: "Node", type: "ss", server: "proxy.invalid", password: "fixture-secret" }],
    "proxy-groups": [{ name: "Main", type: "select", proxies: ["Node"] }],
    dns: { enable: true, nameserver: ["223.5.5.5"], "nameserver-policy": {} },
    rules: ["MATCH,Main"]
  };
}
context.__claudeEasyFixture = fixture;
const script = fs.readFileSync(generatedPath, "utf8");
vm.runInContext(
  script + "\n" +
    "this.__claudeEasyResults = [];\n" +
    "for (let attempt = 0; attempt < 2; attempt += 1) this.__claudeEasyResults.push(JSON.stringify(main(this.__claudeEasyFixture()) || ''));\n",
  context,
  { filename: generatedPath }
);
for (const serialized of context.__claudeEasyResults) {
  const result = JSON.parse(serialized);
  if (!result || result.friend !== 41) throw new Error("previous global writes were not forwarded");
  if (result.helper !== 41) throw new Error("previous top-level function was not installed on globalThis");
  if (result.friendTopLevelThis !== true) throw new Error("previous top-level this was not the Script global");
  if (result.friendCallThis !== true) throw new Error("previous main lost strict this semantics");
  if (result.friendStrictAssignment !== true) throw new Error("previous main lost strict assignment semantics");
  if (result.bypassed === true) throw new Error("previous script replaced a managed binding");
  if (!result["rule-providers"] || !Object.keys(result["rule-providers"]).some((name) => name.indexOf("claude-easy-cn-domain") === 0)) {
    throw new Error("ClaudeEasy transform did not run");
  }
}
'@
        [System.IO.File]::WriteAllText($generatedScriptHarness, $generatedScriptHarnessSource, (New-Object System.Text.UTF8Encoding($false)))
        $node = Get-Command node.exe -ErrorAction Stop
        $generatedScriptOutput = & $node.Source $generatedScriptHarness $composedPath 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0) "generated Script.js failed syntax or execution; $(Get-TestOutputDiagnostic $generatedScriptOutput)"
    }
    Invoke-Uninstaller $composeCase
    $restoredScript = Read-TestUtf8Text (Join-Path $composeProfiles "Script.js")
    Assert-True ($restoredScript.Contains($originalScript.Trim())) "uninstaller did not restore the composed script"
    Assert-True ($restoredScript.Contains("const friendAfterPatch = true;")) "uninstaller discarded code after the managed block"
    Assert-True ((Get-Content -LiteralPath (Join-Path $composeCase "config.yaml") -Raw) -eq $composeConfigOriginal) "uninstaller did not restore config.yaml"
    Assert-True ((Get-Content -LiteralPath (Join-Path $composeCase "verge.yaml") -Raw) -eq $composeVergeOriginal) "uninstaller did not restore verge.yaml"

    $lexicalCase = Join-Path $sandbox "lexical-global-case"
    $lexicalProfiles = Join-Path $lexicalCase "profiles"
    New-Item -ItemType Directory -Path $lexicalProfiles -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $lexicalCase "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
    [System.IO.File]::WriteAllText((Join-Path $lexicalCase "config.yaml"), "ipv6: true`ntun: null`n")
    [System.IO.File]::WriteAllText((Join-Path $lexicalCase "verge.yaml"), "enable_tun_mode: false`n")
    $lexicalScript = @'
const globalThis = { name: "globalThis" };
let window = { name: "window" };
class self {}
const global = { name: "global" };
function main(config) {
  config.lexicalGlobals = [globalThis.name, window.name, self.name, global.name].join(",");
  config.templateValue = `${globalThis.name}:${config.templateInput}`;
  return config;
}
'@
    $lexicalScriptPath = Join-Path $lexicalProfiles "Script.js"
    Write-TestUtf8Text $lexicalScriptPath $lexicalScript
    Invoke-Installer $lexicalCase
    if ($onWindows) {
        $lexicalHarness = Join-Path $sandbox "run-lexical-script.js"
        $lexicalHarnessSource = @'
const fs = require("node:fs");
const vm = require("node:vm");
const context = {};
vm.createContext(context);
context.__claudeEasyFixture = {
  templateInput: "friend",
  proxies: [{ name: "Node", type: "ss", server: "proxy.invalid", password: "fixture-secret" }],
  "proxy-groups": [{ name: "Main", type: "select", proxies: ["Node"] }],
  dns: { enable: true, nameserver: ["223.5.5.5"], "nameserver-policy": {} },
  rules: ["MATCH,Main"]
};
const script = fs.readFileSync(process.argv[2], "utf8");
vm.runInContext(
  script + "\n;this.__claudeEasyResult = JSON.stringify(main(this.__claudeEasyFixture) || '');\n",
  context
);
const result = JSON.parse(context.__claudeEasyResult);
if (!result || result.lexicalGlobals !== "globalThis,window,self,global") {
  throw new Error("top-level lexical global declarations did not survive composition");
}
if (result.templateValue !== "globalThis:friend") {
  throw new Error("template string interpolation did not survive composition");
}
'@
        [System.IO.File]::WriteAllText($lexicalHarness, $lexicalHarnessSource, (New-Object System.Text.UTF8Encoding($false)))
        $lexicalOutput = & $node.Source $lexicalHarness $lexicalScriptPath 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0) "generated lexical Script.js failed; $(Get-TestOutputDiagnostic $lexicalOutput)"
    }
    Invoke-Uninstaller $lexicalCase
    Assert-True (
        (Read-TestUtf8Text $lexicalScriptPath).Contains($lexicalScript.Trim())
    ) "uninstaller did not restore lexical global declarations"

    $intrinsicCase = Join-Path $sandbox "intrinsic-pollution-case"
    $intrinsicProfiles = Join-Path $intrinsicCase "profiles"
    New-Item -ItemType Directory -Path $intrinsicProfiles -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $intrinsicCase "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
    [System.IO.File]::WriteAllText((Join-Path $intrinsicCase "config.yaml"), "ipv6: true`ntun: null`n")
    [System.IO.File]::WriteAllText((Join-Path $intrinsicCase "verge.yaml"), "enable_tun_mode: false`n")
    $intrinsicScript = @'
Array.isArray = function () { return false; };
function main(config) {
  Object.keys = function () { return []; };
  JSON.stringify = function () { return "polluted"; };
  config.previousRan = true;
  return config;
}
'@
    $intrinsicScriptPath = Join-Path $intrinsicProfiles "Script.js"
    Write-TestUtf8Text $intrinsicScriptPath $intrinsicScript
    Invoke-Installer $intrinsicCase
    if ($onWindows) {
        $intrinsicHarness = Join-Path $sandbox "run-intrinsic-script.js"
        $intrinsicHarnessSource = @'
const fs = require("node:fs");
const vm = require("node:vm");
const context = {};
vm.createContext(context);
context.__claudeEasyFixture = {
  proxies: [{ name: "Node", type: "ss", server: "proxy.invalid", password: "fixture-secret" }],
  "proxy-groups": [{ name: "Main", type: "select", proxies: ["Node"] }],
  dns: { enable: true, nameserver: ["223.5.5.5"], "nameserver-policy": {} },
  rules: ["MATCH,Main"]
};
const script = fs.readFileSync(process.argv[2], "utf8");
vm.runInContext(
  script + "\n" +
    ";this.__claudeEasyResult = JSON.stringify(main(this.__claudeEasyFixture) || '');\n" +
    "this.__claudeEasyIntrinsicsIntact = Array.isArray([]) && Object.keys({ friend: true }).length === 1 && JSON.stringify({ friend: true }).indexOf('friend') !== -1;\n",
  context
);
const result = JSON.parse(context.__claudeEasyResult);
if (!result || result.previousRan !== true) {
  throw new Error("previous main did not run");
}
if (!result["rule-providers"] || !Object.keys(result["rule-providers"]).some((name) => name.indexOf("claude-easy-cn-domain") === 0)) {
  throw new Error("intrinsic pollution disabled the managed transform");
}
if (context.__claudeEasyIntrinsicsIntact !== true) {
  throw new Error("previous script polluted shared intrinsics");
}
'@
        [System.IO.File]::WriteAllText($intrinsicHarness, $intrinsicHarnessSource, (New-Object System.Text.UTF8Encoding($false)))
        $intrinsicOutput = & $node.Source $intrinsicHarness $intrinsicScriptPath 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0) "generated Script.js did not isolate intrinsic pollution; $(Get-TestOutputDiagnostic $intrinsicOutput)"
    }
    Invoke-Uninstaller $intrinsicCase
    Assert-True (
        (Read-TestUtf8Text $intrinsicScriptPath).Contains($intrinsicScript.Trim())
    ) "uninstaller did not restore the intrinsic-polluting script"

    $asyncCase = Join-Path $sandbox "async-case"
    $asyncProfiles = Join-Path $asyncCase "profiles"
    New-Item -ItemType Directory -Path $asyncProfiles -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $asyncCase "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
    $asyncConfig = "ipv6: true`ntun: null`n"
    $asyncVerge = "enable_tun_mode: false`n"
    $asyncScript = "async function main(config) { return config; }`n"
    [System.IO.File]::WriteAllText((Join-Path $asyncCase "config.yaml"), $asyncConfig)
    [System.IO.File]::WriteAllText((Join-Path $asyncCase "verge.yaml"), $asyncVerge)
    $asyncScriptPath = Join-Path $asyncProfiles "Script.js"
    Write-TestUtf8Text $asyncScriptPath $asyncScript
    $asyncUsageStatePath = Join-Path $asyncCase "claude-easy-usage-profile.json"
    $asyncUsageState = '{"Version":1,"Profile":1}' + "`r`n"
    [System.IO.File]::WriteAllText($asyncUsageStatePath, $asyncUsageState)
    $asyncResult = Invoke-TestPowerShell $installer @("-AppHome", $asyncCase, "-UsageProfile", "3", "-MihomoPath", $fakeCore)
    Assert-True ($asyncResult.ExitCode -eq 1) "installer accepted an async main that Clash Verge Rev cannot await"
    Assert-True ($asyncResult.Output.Contains("异步 main")) "async main rejection did not explain the incompatibility"
    Assert-True ((Read-TestUtf8Text $asyncScriptPath) -eq $asyncScript) "async main rejection changed Script.js"
    Assert-True ((Get-Content -LiteralPath (Join-Path $asyncCase "config.yaml") -Raw) -eq $asyncConfig) "async main rejection changed config.yaml"
    Assert-True ((Get-Content -LiteralPath (Join-Path $asyncCase "verge.yaml") -Raw) -eq $asyncVerge) "async main rejection changed verge.yaml"
    Assert-True ((Get-Content -LiteralPath $asyncUsageStatePath -Raw) -eq $asyncUsageState) "failed install changed the saved usage profile"

    $templateMarkerCase = Join-Path $sandbox "template-marker-case"
    $templateMarkerProfiles = Join-Path $templateMarkerCase "profiles"
    New-Item -ItemType Directory -Path $templateMarkerProfiles -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $templateMarkerCase "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
    [System.IO.File]::WriteAllText((Join-Path $templateMarkerCase "config.yaml"), "ipv6: true`ntun: null`n")
    [System.IO.File]::WriteAllText((Join-Path $templateMarkerCase "verge.yaml"), "enable_tun_mode: false`n")
    $templateScript = @'
function main(config) {
  const markerPayload = `
// CLAUDEEASY BEGIN
friend payload
// CLAUDEEASY END
`;
  config.markerPayload = markerPayload;
  return config;
}
'@
    $templateScriptPath = Join-Path $templateMarkerProfiles "Script.js"
    Write-TestUtf8Text $templateScriptPath $templateScript
    Invoke-Installer $templateMarkerCase
    $templateComposed = Read-TestUtf8Text $templateScriptPath
    Assert-True ($templateComposed.Contains("friend payload")) "marker text inside a template literal was treated as a managed boundary"
    Invoke-Uninstaller $templateMarkerCase
    Assert-True ((Read-TestUtf8Text $templateScriptPath).Contains("friend payload")) "uninstaller discarded marker text inside a template literal"

    Assert-InstallerRejectsScript "reserved-symbol-case" "const claudeEasyTransform = 1;`nfunction main(config) { return config; }`n" "保留标识符"
    Assert-InstallerRejectsScript "unicode-reserved-symbol-case" "const cl\u0061udeEasyTransform = 1;`nfunction main(config) { return config; }`n" "Unicode 转义"
    Assert-InstallerRejectsScript "postfix-division-reserved-symbol-case" "function main(config) { let x = 1; x++ / (claudeEasyInstallManagedMain = null) / 2; return config; }`n" "保留标识符"
    Assert-InstallerRejectsScript "regex-hidden-reserved-symbol-case" 'function main(config) { return config; }
const first = /"/;
const claudeEasyFinalizer = 1;
const second = /"/;
' "保留标识符"
    $regexAndDivisionScript = @'
function main(config) {
  const quote = /["']/;
  config.ratio = 6 / 3;
  config.hasQuote = quote.test('"');
  return config;
}
'@
    Assert-JavaScriptCanCompose $regexAndDivisionScript
    $renamedRegexAndDivision = Rename-JavaScriptMain $regexAndDivisionScript "main" "friendMain"
    Assert-True ($renamedRegexAndDivision.Contains('const quote = /["'']/;')) "regex literal changed during main rename"
    Assert-True ($renamedRegexAndDivision.Contains("config.ratio = 6 / 3;")) "division expression changed during main rename"
    Assert-InstallerRejectsScript "recursive-main-case" "function main(config) { return config.retry ? main(config) : config; }`n" "递归"
    Assert-InstallerRejectsScript "main-property-reference-case" "function main(config) { return config; }`nmain.version = 1;`n" "引用 main"
    Assert-InstallerRejectsScript "main-alias-reference-case" "function main(config) { const handler = main; return handler(config); }`n" "引用 main"
    Assert-InstallerRejectsScript "main-shorthand-reference-case" "function main(config) { module.exports = { main }; return config; }`n" "引用 main"
    Assert-InstallerRejectsScript "reassigned-main-case" "function main(config) { return config; }`nmain = function(config) { config.override = true; return config; };`n" "重新定义 main"
    Assert-InstallerRejectsScript "eval-case" "function main(config) { return (0, eval)('config'); }`n" "动态执行"
    Assert-InstallerRejectsScript "function-constructor-case" "function main(config) { return Function('return config')(); }`n" "动态执行"
    Assert-InstallerRejectsScript "constructor-escape-case" "function main(config) { return (() => {}).constructor('return config')(); }`n" "动态执行"
    Assert-InstallerRejectsScript "computed-constructor-escape-case" 'function main(config) { return (() => {})["constructor"]("return config")(); }' "动态执行"
    Assert-InstallerRejectsScript "reflect-constructor-escape-case" 'function main(config) { const fn = () => {}; return Reflect.get(fn, "constructor")("return config")(); }' "动态执行"
    Assert-InstallerRejectsScript "template-expression-case" 'function main(config) { return `${eval("config")}`; }' "动态执行"

    $invalidStateCase = Join-Path $sandbox "invalid-state-case"
    New-Item -ItemType Directory -Path $invalidStateCase -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $invalidStateCase "profiles.yaml"), "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n")
    $invalidStateConfig = "ipv6: true`ntun: null`n"
    $invalidStateVerge = "enable_tun_mode: false`n"
    [System.IO.File]::WriteAllText((Join-Path $invalidStateCase "config.yaml"), $invalidStateConfig)
    [System.IO.File]::WriteAllText((Join-Path $invalidStateCase "verge.yaml"), $invalidStateVerge)
    [System.IO.File]::WriteAllText((Join-Path $invalidStateCase "claude-easy-install-state.json"), '{"Version":1}')
    $invalidStateResult = Invoke-TestPowerShell $installer @("-AppHome", $invalidStateCase, "-MihomoPath", $fakeCore)
    Assert-True ($invalidStateResult.ExitCode -eq 1) "installer accepted incomplete state"
    Assert-True ($invalidStateResult.Output.Contains("安装状态文件无效")) "incomplete state rejection was unclear"
    Assert-True ((Get-Content -LiteralPath (Join-Path $invalidStateCase "config.yaml") -Raw) -eq $invalidStateConfig) "invalid state changed config.yaml"
    Assert-True ((Get-Content -LiteralPath (Join-Path $invalidStateCase "verge.yaml") -Raw) -eq $invalidStateVerge) "invalid state changed verge.yaml"

    $badMarkerCase = Join-Path $sandbox "bad-marker-case"
    $badMarkerProfiles = Join-Path $badMarkerCase "profiles"
    New-Item -ItemType Directory -Path $badMarkerProfiles -Force | Out-Null
    $badMarkerPath = Join-Path $badMarkerProfiles "Script.js"
    $badMarkerScript = "// CLAUDEEASY BEGIN`nfunction main(config) { return config; }`n// CLAUDEEASY END`n// CLAUDEEASY END`n"
    Write-TestUtf8Text $badMarkerPath $badMarkerScript
    $badMarkerResult = Invoke-TestPowerShell $uninstaller @("-AppHome", $badMarkerCase)
    Assert-True ($badMarkerResult.ExitCode -eq 1) "uninstaller accepted duplicate end markers"
    Assert-True ((Read-TestUtf8Text $badMarkerPath) -eq $badMarkerScript) "uninstaller modified an ambiguously marked script"

    if ($script:deferredProbeFailures.Count -gt 0) {
        throw ("deferred production probes failed:`n- " + ($script:deferredProbeFailures -join "`n- "))
    }
    Write-Host "Windows installer behavioral cases passed"
} finally {
    $env:CLAUDE_EASY_USAGE_PROFILE = $previousUsageProfile
    if ($null -ne $safeUpdateControllerJob) {
        Stop-Job $safeUpdateControllerJob -ErrorAction SilentlyContinue
        Remove-Job $safeUpdateControllerJob -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
}

if (-not [string]::IsNullOrWhiteSpace($CompletionReceiptPath)) {
    $completionReceipt = [ordered]@{
        Mode = "Full"
        PSEdition = $ExpectedPSEdition
        PSMajor = $ExpectedPSMajor
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText(
        $CompletionReceiptPath,
        $completionReceipt,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

exit 0
