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
    [string]$TestGroup = ""
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
if ($TestGroup -and $TestGroup -notin @('core', 'safe-update', 'recovery')) {
    throw "TestGroup must be empty or one of: core, safe-update, recovery (got '$TestGroup')"
}
$root = Split-Path -Parent $PSScriptRoot
$installer = Join-Path (Join-Path $root "claude-easy/scripts") "install_windows.ps1"
$uninstaller = Join-Path (Join-Path $root "claude-easy/scripts") "uninstall_windows.ps1"
$installWrapper = Join-Path (Join-Path $root "claude-easy/scripts") "install_windows.cmd"
$uninstallWrapper = Join-Path (Join-Path $root "claude-easy/scripts") "uninstall_windows.cmd"
$routeVerifier = Join-Path (Join-Path $root "claude-easy/scripts/windows") "verify_routes.ps1"
$resultContract = Join-Path (Join-Path $root "claude-easy/scripts/windows") "result_contract.ps1"
. $resultContract
$installerModuleRoot = Join-Path (Join-Path $root "claude-easy/scripts/windows") "install_windows"
$installerModules = @(
    "common.ps1", "yaml.ps1", "profiles.ps1", "mihomo.ps1",
    "transaction.ps1", "script_js.ps1", "runtime.ps1", "safe_update.ps1", "remote_preflight.ps1"
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
$script:executedScenarioCount = 0
$fakeCore = Join-Path $sandbox $(if ($onWindows) { "mihomo-test.cmd" } else { "mihomo-test.sh" })
$hangingCore = Join-Path $sandbox $(if ($onWindows) { "mihomo-hang.cmd" } else { "mihomo-hang.sh" })
$mutatingCore = Join-Path $sandbox "mihomo-mutate.cmd"
$identityMutatingCore = Join-Path $sandbox "mihomo-identity-mutate.cmd"
$candidateHangingCore = Join-Path $sandbox "mihomo-candidate-hang.cmd"

foreach ($modulePath in $installerModules) {
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw "missing installer module: $modulePath" }
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
$routeFunctionAsts | ForEach-Object {
    . ([scriptblock]::Create($_.Extent.Text))
}
$uninstallTokens = $null
$uninstallParseErrors = $null
$uninstallAst = [System.Management.Automation.Language.Parser]::ParseFile($uninstaller, [ref]$uninstallTokens, [ref]$uninstallParseErrors)
if ($uninstallParseErrors.Count -gt 0) { throw ($uninstallParseErrors | Out-String) }
$uninstallAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "New-UninstallBackup"
}, $true) | ForEach-Object {
    . ([scriptblock]::Create($_.Extent.Text))
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Test-GroupSelected([string]$Name) {
    return (-not $TestGroup) -or ($TestGroup -eq $Name)
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
        Expected = @("client_switch_verification", "site_verification", "final_state_audit")
    },
    [pscustomobject]@{
        Profile = 3
        Expected = @(
            "client_switch_verification", "site_verification",
            "route_verification", "dns_deep_test",
            "webrtc_test", "local_region_fingerprint_test", "final_state_audit"
        )
    }
)
foreach ($followupCase in $safeUpdateFollowupCases) {
    $actualFollowups = @(Get-SafeUpdateRequiredFollowups ([int]$followupCase.Profile))
    Assert-True (
        ($actualFollowups -join ",") -ceq (@($followupCase.Expected) -join ",")
    ) "Windows safe-update follow-ups differ from the shared profile workflow for profile $($followupCase.Profile)"
}

$remoteCompareRoot = Join-Path $sandbox "remote-compare"
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
New-Item -ItemType Directory -Path $remoteCompareRoot -Force | Out-Null
$sameLocalPath = Join-Path $remoteCompareRoot "same.yaml"
$changedLocalPath = Join-Path $remoteCompareRoot "changed.yaml"
[System.IO.File]::WriteAllText($sameLocalPath, @'
# local formatting differs only
proxies:
  - name: node-a
    server: example.com
'@)
[System.IO.File]::WriteAllText($changedLocalPath, @'
proxies:
  - name: node-b
    server: old.example.com
'@)
$remoteCompareTargets = @(
    [pscustomobject]@{ Uid = "same"; Name = "Same"; Path = $sameLocalPath; Url = "https://same.invalid/sub" },
    [pscustomobject]@{ Uid = "changed"; Name = "Changed"; Path = $changedLocalPath; Url = "https://changed.invalid/sub" }
)
$remoteComparePlan = @(Get-RemoteSubscriptionUpdatePlan $remoteCompareTargets {
    param($target)
    if ($target.Uid -eq "same") {
        return @'
proxies:
    - name: node-a # remote comment
      server: example.com
'@
    }
    return @'
proxies:
  - name: node-b
    server: new.example.com
'@
})
Assert-True ($remoteComparePlan.Count -eq 2) "remote comparison did not inspect every subscription"
Assert-True (-not [bool]$remoteComparePlan[0].Changed) "semantic-only YAML formatting change was reported as an update"
Assert-True ([bool]$remoteComparePlan[1].Changed) "remote subscription content change was not detected"
$flatLocalPath = Join-Path $remoteCompareRoot "flat.yaml"
[System.IO.File]::WriteAllText($flatLocalPath, @'
proxies:
- name: node-a
  server: example.com
'@)
$flatRemoteTarget = [pscustomobject]@{ Uid = "flat"; Name = "Flat"; Path = $flatLocalPath; Url = "https://flat.invalid/sub" }
$flatRemotePlan = @(Get-RemoteSubscriptionUpdatePlan @($flatRemoteTarget) {
    return @'
proxies:
- name: node-b
  server: example.com
'@
})
Assert-True ([bool]$flatRemotePlan[0].Changed) "top-level YAML sequence item change was not detected"

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
    $script:executedScenarioCount++
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
    $script:executedScenarioCount++
    try {
        & $Probe
    } catch {
        [void]$script:deferredProbeFailures.Add(("{0}: {1}" -f $Name, $_.Exception.Message))
    }
}

function Invoke-TestPowerShell(
    [string]$ScriptPath,
    [string[]]$ScriptArguments,
    [switch]$SimulateRuntimeRefresh,
    [int]$FirstRuntimeRefreshDelayMilliseconds = 200,
    [switch]$FailRestoreRuntimeDispatch,
    [string]$RuntimeDispatchLogPath = "",
    [int]$RefreshStartedAgeSeconds = 0
) {
    $temporarySafeUpdateClient = $null
    $simulatedRuntimeBootstrap = $null
    $previousSafeUpdatePath = $null
    $previousImmediateCurl = $null
    $usesSafeUpdateRuntime = $onWindows -and $script:safeUpdateControllerPort -gt 0 -and
        (Split-Path -Leaf $ScriptPath) -eq "install_windows.ps1" -and
        ($SimulateRuntimeRefresh -or
            $ScriptArguments -contains "-SnapshotProfiles" -or
            $ScriptArguments -contains "-BeginSafeUpdateRefresh" -or
            $ScriptArguments -contains "-VerifySafeUpdate")
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
        if ($usesSafeUpdateRuntime -and
            $ScriptArguments -contains "-VerifySafeUpdate" -and
            $ScriptArguments -contains "-RefreshConfirmed") {
            $manifestPath = Join-Path $runtimeHome "claude-easy-safe-update.json"
            if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
                $manifestText = [System.IO.File]::ReadAllText($manifestPath)
                $manifest = $manifestText | ConvertFrom-Json
                $manifestProperties = @($manifest.PSObject.Properties.Name | Sort-Object)
                $canBeginRefresh = ($manifestProperties -join ",") -ceq
                    "CreatedAt,Profiles,RefreshStartedAt,Runtime,UpdateDispatchCommittedFor,Version" -and
                    ($manifest.Version -is [int] -or $manifest.Version -is [long]) -and
                    [long]$manifest.Version -eq 4 -and
                    $null -eq $manifest.RefreshStartedAt
                if ($canBeginRefresh) {
                    $beginOutput = & $PowerShellPath -NoLogo -NoProfile -File $ScriptPath `
                        -AppHome $runtimeHome -BeginSafeUpdateRefresh -MihomoPath $fakeCore -Json 2>&1 | Out-String
                    if ($LASTEXITCODE -ne 0) {
                        throw "failed to start safe-update refresh timer: $(Get-TestOutputDiagnostic $beginOutput)"
                    }
                }
            }
        }
        if ($SimulateRuntimeRefresh) {
            $mihomoPathIndex = [Array]::IndexOf($ScriptArguments, "-MihomoPath")
            $payload = [pscustomobject]@{
                ScriptPath = $ScriptPath
                AppHome = [string]$ScriptArguments[$appHomeIndex + 1]
                MihomoPath = [string]$ScriptArguments[$mihomoPathIndex + 1]
                Json = $ScriptArguments -contains "-Json"
                RuntimePath = $runtimePath
                FirstRuntimeRefreshDelayMilliseconds = $FirstRuntimeRefreshDelayMilliseconds
                FailRestoreRuntimeDispatch = [bool]$FailRestoreRuntimeDispatch
                RuntimeDispatchLogPath = $RuntimeDispatchLogPath
                RefreshStartedAgeSeconds = $RefreshStartedAgeSeconds
                RunOriginalCommand = -not ($ScriptArguments -contains "-VerifySafeUpdate")
                ScriptArguments = @($ScriptArguments)
            } | ConvertTo-Json -Compress -Depth 3
            $payloadBase64 = [Convert]::ToBase64String(
                [System.Text.Encoding]::UTF8.GetBytes($payload)
            )
            $bootstrap = @'
$payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__')) | ConvertFrom-Json
Add-Type -TypeDefinition 'namespace ClaudeEasy { public static class SendInputNative { public static string RuntimePath; public static string AppHome; public static string DispatchLogPath; public static int FirstDelayMilliseconds; public static bool FailRestoreDispatch; private static int SendCount; private static bool IsRestoreKindManifest() { if (string.IsNullOrEmpty(AppHome)) { return false; } string manifestPath = System.IO.Path.Combine(AppHome, "claude-easy-safe-update.json"); if (!System.IO.File.Exists(manifestPath)) { return false; } return System.Text.RegularExpressions.Regex.IsMatch(System.IO.File.ReadAllText(manifestPath), "\\\"Kind\\\"\\s*:\\s*\\\"safe_update_runtime_recovery\\\"", System.Text.RegularExpressions.RegexOptions.CultureInvariant); } public static bool Send(System.UInt16[] keys) { if (keys == null || keys.Length != 4 || keys[0] != 0x11 || keys[1] != 0x12 || keys[2] != 0x10 || keys[3] != 0x87) { return false; } int count = System.Threading.Interlocked.Increment(ref SendCount); if (!string.IsNullOrEmpty(DispatchLogPath)) { System.IO.File.AppendAllText(DispatchLogPath, count.ToString() + "\n"); } bool isRestore = IsRestoreKindManifest(); if (FailRestoreDispatch && (count >= 2 || isRestore)) { return false; } string path = RuntimePath; int delay = isRestore ? 200 : FirstDelayMilliseconds; var delayThread = new System.Threading.Thread(delegate() { System.Threading.Thread.Sleep(delay); System.IO.File.AppendAllText(path, "\n# simulated refresh\n"); }); delayThread.IsBackground = true; delayThread.Start(); return true; } } }' -ErrorAction Stop | Out-Null
[ClaudeEasy.SendInputNative]::RuntimePath = [string]$payload.RuntimePath
[ClaudeEasy.SendInputNative]::AppHome = [string]$payload.AppHome
[ClaudeEasy.SendInputNative]::DispatchLogPath = [string]$payload.RuntimeDispatchLogPath
[ClaudeEasy.SendInputNative]::FirstDelayMilliseconds = [int]$payload.FirstRuntimeRefreshDelayMilliseconds
[ClaudeEasy.SendInputNative]::FailRestoreDispatch = [bool]$payload.FailRestoreRuntimeDispatch
if ($payload.RefreshStartedAgeSeconds -gt 0) {
    $manifestPath = Join-Path ([string]$payload.AppHome) "claude-easy-safe-update.json"
    $manifestText = [System.IO.File]::ReadAllText($manifestPath)
    $refreshStartedAt = [DateTimeOffset]::UtcNow.AddSeconds(
        -[int]$payload.RefreshStartedAgeSeconds
    ).ToString("o")
    $refreshStampPattern = [regex]'(?i)("RefreshStartedAt"\s*:\s*)(?:null|"(?:[^"\\]|\\.)*")'
    $updatedManifestText = $refreshStampPattern.Replace(
        $manifestText,
        ('$1"' + $refreshStartedAt + '"'),
        1
    )
    [System.IO.File]::WriteAllText($manifestPath, $updatedManifestText)
}
$arguments = @{
    AppHome = [string]$payload.AppHome
    MihomoPath = [string]$payload.MihomoPath
    VerifySafeUpdate = $true
    RefreshConfirmed = $true
    Json = [bool]$payload.Json
}
if ([bool]$payload.RunOriginalCommand) {
    $originalArguments = @($payload.ScriptArguments | ForEach-Object { [string]$_ })
    & ([string]$payload.ScriptPath) @originalArguments
} else {
    & ([string]$payload.ScriptPath) @arguments
}
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
    $script:executedScenarioCount++
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
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    if (Test-GroupSelected 'core') {
    $installerSource = [System.IO.File]::ReadAllText($installer)
    $runtimeSource = [System.IO.File]::ReadAllText((Join-Path $installerModuleRoot "runtime.ps1"))
    Assert-True (
        -not [regex]::IsMatch($installerSource, '(?m)^\s*\[switch\]\$SafeUpdate\s*$') -and
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
    $sameIndentTunList = @'
tun:
  enable: false
  dns-hijack:
  # legacy list entry follows
  - stale.example:53
  - tcp://stale.example:53
  auto-route: false
  auto-detect-interface: false
  strict-route: false
'@
    $updatedSameIndentTunList = Set-YamlTunMapping $sameIndentTunList
    $managedDnsHijackEntries = @($updatedSameIndentTunList -split "`r?`n" | Where-Object {
        $_ -match '^    - '
    })
    Assert-True (
        $updatedSameIndentTunList -notmatch 'stale\.example:53'
    ) "TUN update retained stale same-indent dns-hijack entries"
    Assert-True (
        $updatedSameIndentTunList -match '(?m)^  auto-route: true\r?$'
    ) "TUN update removed the following auto-route sibling"
    Assert-True (
        $managedDnsHijackEntries.Count -eq 2 -and
        $managedDnsHijackEntries -ccontains '    - any:53' -and
        $managedDnsHijackEntries -ccontains '    - tcp://any:53'
    ) "TUN update did not write exactly the two managed dns-hijack entries"
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
    }

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
                    $realInstallJson = Assert-JsonResult $realInstall "install" 1
                    Assert-True (
                        $realInstallJson.code -eq "runtime_activation_required"
                    ) "real Mihomo install without a client runtime reported complete"
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
            $expectedRealCases = @()
            $expectedCoreIndex = 0
            foreach ($realMihomoPath in $RealMihomoPaths) {
                $expectedCoreIndex++
                foreach ($realUsageProfile in @(1, 2, 3)) {
                    $expectedRealCases += ("{0}:{1}" -f $expectedCoreIndex, $realUsageProfile)
                }
            }
            $actualRealCases = @($realCompletedCases | ForEach-Object {
                "{0}:{1}" -f $_.Core, $_.Profile
            })
            Assert-True (@(Compare-Object $expectedRealCases $actualRealCases).Count -eq 0) (
                "real Mihomo suite did not execute every core/profile pair; expected=$($expectedRealCases -join ',') actual=$($actualRealCases -join ',')"
            )
            Write-Host "Windows real Mihomo public-entry cases passed"
            return
        }

    }
    if ((Test-GroupSelected 'core') -and $onWindows) {
        $customCoreDirectory = Join-Path $sandbox "D-clash-verge"
        $customCorePath = Join-Path $customCoreDirectory "verge-mihomo.exe"
        New-Item -ItemType Directory -Path $customCoreDirectory -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot "System32/ping.exe") -Destination $customCorePath
        $customCoreProcess = Start-Process -FilePath $customCorePath -ArgumentList @("-n", "20", "127.0.0.1") -PassThru
        try {
            Start-Sleep -Milliseconds 100
            Assert-True (
                (Find-MihomoCore "") -ceq $customCorePath
            ) "running custom-directory verge-mihomo.exe was not discovered"
        } finally {
            if (-not $customCoreProcess.HasExited) { Stop-Process -Id $customCoreProcess.Id -Force }
            $customCoreProcess.WaitForExit()
        }

        $accessDeniedLockError = New-Object System.ComponentModel.Win32Exception 5
        $sharingViolationLockError = New-Object System.ComponentModel.Win32Exception 32
        Assert-True (-not (Test-AppHomeMutationLockContention $accessDeniedLockError)) "access denied while opening the operation lock was classified as another operation"
        Assert-True (Test-AppHomeMutationLockContention $sharingViolationLockError) "sharing violation while opening the operation lock was not classified as another operation"

        $activationRequiredHome = Join-Path $sandbox "install-runtime-activation-required"
        New-Item -ItemType Directory -Path (Join-Path $activationRequiredHome "profiles") -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $activationRequiredHome "config.yaml"),
            "mode: rule`nipv6: true`ntun: null`n"
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $activationRequiredHome "verge.yaml"),
            "enable_tun_mode: false`n"
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $activationRequiredHome "profiles.yaml"),
            "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n"
        )
        $activationRequiredInstall = Invoke-TestPowerShell $installer @(
            "-AppHome", $activationRequiredHome, "-MihomoPath", $fakeCore, "-Json"
        )
        $activationRequiredJson = Assert-JsonResult $activationRequiredInstall "install" 1
        Assert-True (
            $activationRequiredJson.status -eq "partial" -and
            $activationRequiredJson.code -eq "runtime_activation_required" -and
            $activationRequiredJson.workflow_complete -eq $false -and
            $activationRequiredJson.completed_scope -eq "configuration_written" -and
            @($activationRequiredJson.required_followups).Count -gt 0 -and
            (Test-Path -LiteralPath (Join-Path $activationRequiredHome "profiles/Script.js") -PathType Leaf)
        ) "install reported complete before runtime activation was verified"

        $liveClientPath = Join-Path $sandbox "clash-verge.exe"
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot "System32/ping.exe") -Destination $liveClientPath
        $liveClient = Start-Process -FilePath $liveClientPath -ArgumentList @("-n", "180", "127.0.0.1") -PassThru
        try {
            foreach ($liveProfile in @(1, 2, 3)) {
                Assert-True (Test-ClashVergeRunning) "live configuration fixture has no running client"
                $liveHome = Join-Path $sandbox "live-profile-$liveProfile"
                New-Item -ItemType Directory -Path (Join-Path $liveHome "profiles") -Force | Out-Null
                $liveOriginal = @{
                    "config.yaml" = "ipv6: true`ntun: null`n"
                    "verge.yaml" = "enable_tun_mode: false`n"
                    "profiles.yaml" = "current: R-test`r`nitems:`r`n- uid: R-test`r`n  type: remote`r`n  selected: # saved selections`r`n  - name: Main`r`n    now: DIRECT`r`n  - name: Auto`r`n    now: Node`r`n  updated: null`r`n  option:`r`n    allow_auto_update: true`r`n"
                }
                foreach ($name in $liveOriginal.Keys) {
                    Write-TestUtf8Text (Join-Path $liveHome $name) $liveOriginal[$name]
                }
                $liveInstall = Invoke-TestPowerShell $installer @(
                    "-AppHome", $liveHome, "-UsageProfile", $liveProfile.ToString(), "-MihomoPath", $fakeCore, "-Json"
                )
                $liveInstallJson = Assert-JsonResult $liveInstall "install" 1
                Assert-True (
                    $liveInstallJson.code -eq "runtime_activation_required"
                ) "live install without a controller reported complete"
                $liveUsage = Get-Content -LiteralPath (Join-Path $liveHome "claude-easy-usage-profile.json") -Raw | ConvertFrom-Json
                Assert-True ([int]$liveUsage.Profile -eq $liveProfile) "live install did not save the requested profile"
                Assert-True (Test-Path -LiteralPath (Join-Path $liveHome "profiles/Script.js")) "live install omitted the global script"
                Assert-RemoteSubscriptionAutoUpdateDisabled (Read-TestUtf8Text (Join-Path $liveHome "profiles.yaml")) | Out-Null
                if ($liveProfile -eq 3) {
                    Assert-True ((Read-TestUtf8Text (Join-Path $liveHome "config.yaml")) -match 'ipv6: false') "live profile 3 did not write application settings"
                }
                $liveUninstall = Invoke-TestPowerShell $uninstaller @("-AppHome", $liveHome, "-Json")
                Assert-JsonResult $liveUninstall "uninstall" 0 | Out-Null
                foreach ($name in $liveOriginal.Keys) {
                    Assert-True ((Read-TestUtf8Text (Join-Path $liveHome $name)) -ceq $liveOriginal[$name]) "live uninstall did not restore $name"
                }
                Assert-True (-not (Test-Path -LiteralPath (Join-Path $liveHome "claude-easy-usage-profile.json"))) "live uninstall retained the profile state"
                Assert-True (-not $liveClient.HasExited) "configuration commands stopped the client"
            }
        } finally {
            if (-not $liveClient.HasExited) { Stop-Process -Id $liveClient.Id -Force }
            $liveClient.WaitForExit()
        }
    }

    if (Test-GroupSelected 'core') {
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
    }

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

    if (Test-GroupSelected 'safe-update') {

    $fileFieldCase = Join-Path $sandbox "remote-target-file-field"
    $fileFieldProfiles = Join-Path $fileFieldCase "profiles"
    New-Item -ItemType Directory -Path $fileFieldProfiles -Force | Out-Null
    $fileFieldIndex = @"
items:
- uid: R-custom
  type: remote
  name: Custom
  file: custom.yaml
"@
    [System.IO.File]::WriteAllText((Join-Path $fileFieldProfiles "R-custom.yaml"), "leftover: true`n")
    [System.IO.File]::WriteAllText((Join-Path $fileFieldProfiles "custom.yaml"), "live: true`n")
    $fileFieldTargets = @(Get-RemoteSubscriptionTargets $fileFieldIndex $fileFieldProfiles)
    Assert-True ($fileFieldTargets.Count -eq 1) "file: remote subscription was not mapped"
    Assert-True (
        [string]::Equals(
            (Split-Path -Leaf $fileFieldTargets[0].Path),
            "custom.yaml",
            [StringComparison]::Ordinal
        )
    ) "file: remote subscription targeted leftover {uid}.yaml instead of custom.yaml"
    $uidFileProfiles = Join-Path $fileFieldCase "uid-default"
    New-Item -ItemType Directory -Path $uidFileProfiles -Force | Out-Null
    $uidFileIndex = @"
items:
- uid: R-uid
  type: remote
  name: Uid
"@
    [System.IO.File]::WriteAllText((Join-Path $uidFileProfiles "R-uid.yaml"), "live: true`n")
    $uidFileTargets = @(Get-RemoteSubscriptionTargets $uidFileIndex $uidFileProfiles)
    Assert-True ($uidFileTargets.Count -eq 1) "remote subscription without file: was rejected"
    Assert-True (
        [string]::Equals(
            (Split-Path -Leaf $uidFileTargets[0].Path),
            "R-uid.yaml",
            [StringComparison]::Ordinal
        )
    ) "remote subscription without file: did not use uid.yaml"
    $escapedFileIndex = @"
items:
- uid: R-escape
  type: remote
  name: Escape
  file: ../escape.yaml
"@
    $escapedRejected = $false
    try { Get-RemoteSubscriptionTargets $escapedFileIndex $fileFieldProfiles | Out-Null } catch { $escapedRejected = $true }
    Assert-True $escapedRejected "file: path escape was accepted"
    Assert-True (Test-YamlTunEnabled "tun:`n  enable: true`n") "block tun.enable true was not detected"
    Assert-True (Test-YamlTunEnabled "tun: {enable: true}`n") "flow tun.enable true was not detected"
    Assert-True (Test-YamlTunEnabled "tun: {`n  enable: true`n}`n") "multiline flow tun.enable true was not detected"
    Assert-True (Test-YamlTunEnabled "tun:`n  enable: TRUE`n") "TRUE tun.enable was not detected"
    Assert-True (-not (Test-YamlTunEnabled "tun:`n  enable: false`n")) "tun.enable false was treated as enabled"
    Assert-True (-not (Test-YamlTunEnabled "mode: rule`n")) "missing tun was treated as enabled"

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
    Assert-True ($safeUpdateInstall.ExitCode -eq 1) "safe update fixture install did not report its pending runtime activation; $(Get-TestOutputDiagnostic $safeUpdateInstall.Output)"
    $timeoutSafeUpdateCase = Join-Path $sandbox "safe-update-timeout-case"
    Copy-Item -LiteralPath $safeUpdateCase -Destination $timeoutSafeUpdateCase -Recurse
    $timeoutSafeUpdateProfiles = Join-Path $timeoutSafeUpdateCase "profiles"
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
        $fakeCurlDirectory = Join-Path $sandbox "fake-curl"
        New-Item -ItemType Directory -Path $fakeCurlDirectory -Force | Out-Null
        $fakeCurlPath = Join-Path $fakeCurlDirectory "curl.exe"
        $fakeCurlSource = @'
using System;
public static class FakeCurl {
    public static int Main(string[] args) {
        if (Environment.GetEnvironmentVariable("CLAUDE_EASY_TEST_CURL_IMMEDIATE_SUCCESS") == "1") {
            return 0;
        }
        return 22;
    }
}
'@
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

        $runtimeInstallHome = Join-Path $sandbox "install-runtime-activation-success"
        New-Item -ItemType Directory -Path (Join-Path $runtimeInstallHome "profiles") -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $runtimeInstallHome "config.yaml"),
            "mode: rule`nipv6: true`ntun: null`n"
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $runtimeInstallHome "verge.yaml"),
            "enable_global_hotkey: true`nhotkeys:`n  - reactivate_profiles,CTRL+ALT+SHIFT+F24`nenable_tun_mode: false`n"
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $runtimeInstallHome "profiles.yaml"),
            "items:`n- uid: R-test`n  type: remote`n  option:`n    allow_auto_update: true`n"
        )
        $runtimeInstallDispatchLog = Join-Path $sandbox "install-runtime-activation-success.log"
        $runtimeInstall = Invoke-TestPowerShell $installer @(
            "-AppHome", $runtimeInstallHome,
            "-UsageProfile", "1",
            "-MihomoPath", $fakeCore,
            "-Json"
        ) -SimulateRuntimeRefresh -RuntimeDispatchLogPath $runtimeInstallDispatchLog
        $runtimeInstallJson = Assert-JsonResult $runtimeInstall "install" 0
        Assert-True (
            $runtimeInstallJson.code -eq "installed_common_baseline" -and
            @([System.IO.File]::ReadAllLines($runtimeInstallDispatchLog)).Count -eq 1 -and
            [System.IO.File]::ReadAllLines($runtimeInstallDispatchLog)[0] -ceq "1"
        ) "install did not activate and verify the captured client runtime exactly once"
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
        $null -eq $snapshotManifest.RefreshStartedAt -and
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

    $safeUpdateManifestPath = Join-Path $safeUpdateCase "claude-easy-safe-update.json"
    $missingRefreshStartOutput = & $PowerShellPath -NoLogo -NoProfile -File $installer `
        -AppHome $safeUpdateCase -VerifySafeUpdate -RefreshConfirmed -MihomoPath $fakeCore -Json 2>&1 |
        Out-String
    $missingRefreshStart = [pscustomobject]@{
        Output = $missingRefreshStartOutput
        ExitCode = $LASTEXITCODE
    }
    $missingRefreshStartJson = Assert-JsonResult $missingRefreshStart "install" 1
    Assert-True ($missingRefreshStartJson.code -eq "safe_update_refresh_not_started") `
        "Windows verified a current safe update without a persisted refresh start"
    $delayedManifest = [System.IO.File]::ReadAllText($safeUpdateManifestPath) | ConvertFrom-Json
    $delayedManifest.CreatedAt = [DateTimeOffset]::Now.AddHours(-1).ToString("o")
    [System.IO.File]::WriteAllText(
        $safeUpdateManifestPath,
        (($delayedManifest | ConvertTo-Json -Depth 5) + "`r`n")
    )
    $beginRefresh = Invoke-TestPowerShell $installer @(
        "-AppHome", $safeUpdateCase,
        "-BeginSafeUpdateRefresh",
        "-MihomoPath", $fakeCore,
        "-Json"
    )
    $beginRefreshJson = Assert-JsonResult $beginRefresh "install" 0
    Assert-True ($beginRefreshJson.code -eq "safe_update_refresh_started") `
        "Windows did not persist the actual refresh start"
    $unexpiredManifestText = [System.IO.File]::ReadAllText($safeUpdateManifestPath)
    $expiredManifest = $unexpiredManifestText | ConvertFrom-Json
    $expiredManifest.RefreshStartedAt = [DateTimeOffset]::Now.AddSeconds(-181).ToString("o")
    [System.IO.File]::WriteAllText(
        $safeUpdateManifestPath,
        (($expiredManifest | ConvertTo-Json -Depth 5) + "`r`n")
    )
    $resetAttempt = Invoke-TestPowerShell $installer @(
        "-AppHome", $safeUpdateCase,
        "-VerifySafeUpdate",
        "-RefreshConfirmed",
        "-RefreshStartedAt", [DateTimeOffset]::Now.ToString("o"),
        "-MihomoPath", $fakeCore,
        "-Json"
    )
    $resetAttemptJson = Assert-JsonResult $resetAttempt "install" 64
    Assert-True ($resetAttemptJson.code -eq "invalid_arguments") `
        "Windows allowed the caller to reset the persisted refresh start"
    [System.IO.File]::WriteAllText($safeUpdateManifestPath, $unexpiredManifestText)

    $slowCore = Join-Path $sandbox "mihomo-slow.cmd"
    [System.IO.File]::WriteAllText(
        $slowCore,
        "@echo off`r`nif `"%1`"==`"-v`" (`r`n  echo Mihomo Meta v1.19.27 windows amd64`r`n  exit /b 0`r`n)`r`nping 127.0.0.1 -n 120 >nul`r`nexit /b 0`r`n",
        [System.Text.Encoding]::ASCII
    )
    $timeoutUpdatedFirst = $firstSafeOriginal + "# refreshed before timeout`n"
    $timeoutUpdatedSecond = $secondSafeOriginal + "# refreshed before timeout`n"
    $timeoutScenarios = @(
        [pscustomobject]@{ Name = "expired"; Age = 190; Core = $fakeCore; Delay = 200; FailRestore = $false; Status = "rolled_back"; Code = "safe_update_timeout_rolled_back"; AllowedDispatches = @("1") },
        [pscustomobject]@{ Name = "recovery-pending"; Age = 155; Core = $fakeCore; Delay = 60000; FailRestore = $true; Status = "partial"; Code = "safe_update_timeout_recovery_pending"; AllowedDispatches = @("1,2", "1") }
    )
    foreach ($timeoutScenario in $timeoutScenarios) {
        $timeoutSnapshot = Invoke-TestPowerShell $installer @(
            "-AppHome", $timeoutSafeUpdateCase,
            "-SnapshotProfiles",
            "-MihomoPath", $fakeCore,
            "-Json"
        )
        Assert-JsonResult $timeoutSnapshot "install" 0 | Out-Null
        $timeoutBegin = Invoke-TestPowerShell $installer @(
            "-AppHome", $timeoutSafeUpdateCase,
            "-BeginSafeUpdateRefresh",
            "-MihomoPath", $fakeCore,
            "-Json"
        )
        Assert-JsonResult $timeoutBegin "install" 0 | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $timeoutSafeUpdateProfiles "R-first.yaml"), $timeoutUpdatedFirst
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $timeoutSafeUpdateProfiles "R-second.yml"), $timeoutUpdatedSecond
        )
        $timeoutManifestPath = Join-Path $timeoutSafeUpdateCase "claude-easy-safe-update.json"
        $dispatchLog = Join-Path $sandbox ("timeout-" + $timeoutScenario.Name + ".log")
        $failRestoreDispatch = [bool]$timeoutScenario.FailRestore
        $timeoutVerify = Invoke-TestPowerShell $installer @(
            "-AppHome", $timeoutSafeUpdateCase,
            "-VerifySafeUpdate",
            "-RefreshConfirmed",
            "-MihomoPath", [string]$timeoutScenario.Core,
            "-Json"
        ) -SimulateRuntimeRefresh `
            -FirstRuntimeRefreshDelayMilliseconds ([int]$timeoutScenario.Delay) `
            -FailRestoreRuntimeDispatch:$failRestoreDispatch `
            -RuntimeDispatchLogPath $dispatchLog `
            -RefreshStartedAgeSeconds ([int]$timeoutScenario.Age)
        $timeoutVerifyJson = Assert-JsonResult $timeoutVerify "install" 1
        Assert-True (
            $timeoutVerifyJson.status -eq [string]$timeoutScenario.Status -and
            $timeoutVerifyJson.code -eq [string]$timeoutScenario.Code
        ) (
            "Windows did not report timeout rollback for $($timeoutScenario.Name) " +
            "(status=$($timeoutVerifyJson.status), code=$($timeoutVerifyJson.code), " +
            "summary=$($timeoutVerifyJson.summary_zh), " +
            "messages=$(@($timeoutVerifyJson.messages) -join ';'))"
        )
        Assert-True (
            (Get-Content -LiteralPath (Join-Path $timeoutSafeUpdateProfiles "R-first.yaml") -Raw) -eq
                $firstSafeOriginal -and
            (Get-Content -LiteralPath (Join-Path $timeoutSafeUpdateProfiles "R-second.yml") -Raw) -eq
                $secondSafeOriginal
        ) "Windows did not restore refreshed subscriptions after $($timeoutScenario.Name)"
        $dispatchTrace = (
            ((Get-Content -LiteralPath $dispatchLog -Raw).Trim() -split "`r?`n") -join ","
        )
        $allowedDispatches = @($timeoutScenario.AllowedDispatches | ForEach-Object { [string]$_ })
        Assert-True (
            $allowedDispatches -ccontains $dispatchTrace
        ) (
            "Windows sent the wrong update or recovery activations for $($timeoutScenario.Name) " +
            "(actual=$dispatchTrace; allowed=$($allowedDispatches -join '|'))"
        )
        if ([bool]$timeoutScenario.FailRestore) {
            $pendingRecovery = [System.IO.File]::ReadAllText($timeoutManifestPath) | ConvertFrom-Json
            Assert-True (
                $pendingRecovery.Kind -eq "safe_update_runtime_recovery" -and
                $null -ne $pendingRecovery.RestoreDispatchCommittedFor
            ) "Windows did not retain timeout recovery state after restore failure"
            Remove-Item -LiteralPath $timeoutManifestPath -Force
        } else {
            Assert-True (-not (Test-Path -LiteralPath $timeoutManifestPath)) `
                "Windows retained a completed timeout recovery for $($timeoutScenario.Name)"
        }
    }

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
                "route_verification", "dns_deep_test",
                "webrtc_test", "local_region_fingerprint_test",
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
    $legacyManifestRawText = [System.IO.File]::ReadAllText($legacyManifestPath)
    $legacyManifestSource = $legacyManifestRawText | ConvertFrom-Json
    $legacyProfiles = @(
        foreach ($profile in @($legacyManifestSource.Profiles)) {
            [ordered]@{
                Backup = [string]$profile.Backup
                BeforeSha256 = [string]$profile.BeforeSha256
                File = [string]$profile.File
                Uid = [string]$profile.Uid
            }
        }
    )
    $legacyManifest = [ordered]@{
        CreatedAt = [regex]::Match($legacyManifestRawText, '(?i)"CreatedAt"\s*:\s*"(?<value>[^"\\]*)"').Groups["value"].Value
        Profiles = $legacyProfiles
        Version = 1
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
    $legacyManifestRawText = [System.IO.File]::ReadAllText($legacyManifestPath)
    $legacyManifestSource = $legacyManifestRawText | ConvertFrom-Json
    $legacyBadBackup = [System.Text.Encoding]::UTF8.GetBytes("proxy-groups: [`n")
    $legacyBadBackupSha = Get-BytesSha256 $legacyBadBackup
    $legacyProfiles = @(
        $legacyProfileIndex = 0
        foreach ($profile in @($legacyManifestSource.Profiles)) {
            [ordered]@{
                Backup = [string]$profile.Backup
                BeforeSha256 = if ($legacyProfileIndex -eq 0) {
                    $legacyBadBackupSha
                } else {
                    [string]$profile.BeforeSha256
                }
                File = [string]$profile.File
                Uid = [string]$profile.Uid
            }
            $legacyProfileIndex++
        }
    )
    $legacyManifest = [ordered]@{
        CreatedAt = [regex]::Match($legacyManifestRawText, '(?i)"CreatedAt"\s*:\s*"(?<value>[^"\\]*)"').Groups["value"].Value
        Profiles = $legacyProfiles
        Version = 1
    }
    $legacyFirstProfile = @($legacyManifest.Profiles)[0]
    [System.IO.File]::WriteAllBytes(
        (Join-Path (Join-Path $safeUpdateCase "claude-easy-backups") $legacyFirstProfile.Backup),
        $legacyBadBackup
    )
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
            $rollbackCrashInstallJson = Assert-JsonResult $rollbackCrashInstall "install" 1
            Assert-True (
                $rollbackCrashInstallJson.code -eq "runtime_activation_required"
            ) "rollback crash fixture install without a runtime reported complete"
            $rollbackCrashSnapshot = Invoke-TestPowerShell $rollbackCrashInstaller @(
                "-AppHome", $rollbackCrashHome,
                "-SnapshotProfiles",
                "-MihomoPath", $fakeCore,
                "-Json"
            )
            Assert-JsonResult $rollbackCrashSnapshot "install" 0 | Out-Null
            $rollbackCrashBegin = Invoke-TestPowerShell $rollbackCrashInstaller @(
                "-AppHome", $rollbackCrashHome,
                "-BeginSafeUpdateRefresh",
                "-MihomoPath", $fakeCore,
                "-Json"
            )
            Assert-JsonResult $rollbackCrashBegin "install" 0 | Out-Null
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
        $indexConcurrentManifestBeforeJson = (
            [System.Text.Encoding]::UTF8.GetString($indexConcurrentManifestBefore) |
                ConvertFrom-Json
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
        $indexConcurrentManifestAfterJson = (
            [System.IO.File]::ReadAllText($indexConcurrentManifestPath) |
                ConvertFrom-Json
        )
        Assert-True (
            [long]$indexConcurrentManifestAfterJson.Version -eq 4 -and
            (Test-SafeUpdateActivationRecord $indexConcurrentManifestAfterJson.UpdateDispatchCommittedFor) -and
            (($indexConcurrentManifestAfterJson.Profiles | ConvertTo-Json -Compress -Depth 7) -ceq
                ($indexConcurrentManifestBeforeJson.Profiles | ConvertTo-Json -Compress -Depth 7)) -and
            (($indexConcurrentManifestAfterJson.Runtime | ConvertTo-Json -Compress -Depth 7) -ceq
                ($indexConcurrentManifestBeforeJson.Runtime | ConvertTo-Json -Compress -Depth 7))
        ) "concurrent profiles index change did not preserve the recovery manifest and one-shot dispatch record"
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
        Assert-True ($schemaInstall.ExitCode -eq 1) "safe-update schema fixture install did not defer runtime activation"
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
            $utf8Install.ExitCode -eq 1
        ) "invalid UTF-8 fixture install did not defer runtime activation; $(Get-TestOutputDiagnostic $utf8Install.Output)"
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

    }


    $transactionDir = Join-Path $sandbox "transaction"
    New-Item -ItemType Directory -Path $transactionDir -Force | Out-Null

    if (Test-GroupSelected 'recovery') {

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

        $publicCrashConfig = "ipv6: true`ntun: null`n"
        $publicCrashVerge = "enable_tun_mode: false`n"
        $publicCrashProfilesIndex = "items:`n- uid: R-public-crash`n  type: remote`n  option:`n    allow_auto_update: true`n"

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
        $publicUninstallSetupJson = Assert-JsonResult $publicUninstallSetup "install" 1
        Assert-True (
            $publicUninstallSetupJson.code -eq "runtime_activation_required"
        ) "public uninstall setup without a runtime reported complete"
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
        $publicUninstallClientPath = Join-Path $publicUninstallCrashHome "clash-verge.exe"
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot "System32/ping.exe") -Destination $publicUninstallClientPath
        $publicUninstallClient = Start-Process -FilePath $publicUninstallClientPath -ArgumentList @("-n", "60", "127.0.0.1") -PassThru
        try {
        Assert-True (Test-ClashVergeRunning) "uninstall recovery fixture has no running client"
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
        Assert-True (-not $publicUninstallClient.HasExited) "uninstall recovery stopped the client"
        } finally {
            if (-not $publicUninstallClient.HasExited) { Stop-Process -Id $publicUninstallClient.Id -Force }
            $publicUninstallClient.WaitForExit()
        }

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
                [string]$publicRestoreJournalRecord.RecoveryPolicy -eq "live_client"
            ) "ordinary remote-profile restore did not persist its live-client recovery policy"
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
                Assert-True (Test-ClashVergeRunning) "restore fixture has no running client"
                $publicRestoreRecovery = Invoke-TestPowerShell $publicRestoreInstaller @(
                    "-AppHome", $publicRestoreHome, "-ShowUsageProfile", "-Json"
                )
                Assert-JsonResult $publicRestoreRecovery "install" 0 | Out-Null
                Assert-True ((Get-FileSha256 $publicRestoreTarget) -eq (Get-BytesSha256 $publicRestoreCurrentBytes)) "live recovery did not restore the interrupted bytes"
                Assert-True (-not (Test-Path -LiteralPath $publicRestoreJournal)) "live recovery retained its journal"
                $liveRestore = Invoke-TestPowerShell $publicRestoreInstaller @(
                    "-AppHome", $publicRestoreHome, "-RestoreBackup", (Split-Path -Leaf $publicRestoreBackup),
                    "-ExpectedCurrentSha256", $publicRestoreExpectedHash, "-MihomoPath", $fakeCore, "-Json"
                )
                Assert-JsonResult $liveRestore "install" 0 | Out-Null
                Assert-True ((Get-FileSha256 $publicRestoreTarget) -eq (Get-BytesSha256 $publicRestoreBackupBytes)) "live backup restore did not write the backup"
                Assert-True (-not $publicRestoreRunningClient.HasExited) "backup restore stopped the client"
            } finally {
                if (-not $publicRestoreRunningClient.HasExited) {
                    Stop-Process -Id $publicRestoreRunningClient.Id -Force
                }
                $publicRestoreRunningClient.WaitForExit()
            }

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
                Assert-True (Test-ClashVergeRunning) "preparation fixture has no running client"
                $livePreparationRecovery = Invoke-TestPowerShell $publicPreJournalInstaller @(
                    "-AppHome", $publicPreJournalHome, "-ShowUsageProfile", "-Json"
                )
                Assert-JsonResult $livePreparationRecovery "install" 0 | Out-Null
                Assert-True (-not (Test-Path -LiteralPath $publicPreJournalConfig)) "live preparation recovery retained an empty config"
                Assert-True (-not (Test-Path -LiteralPath $publicPreJournalVerge)) "live preparation recovery retained an empty verge file"
                Assert-True (-not (Test-Path -LiteralPath $publicPreJournalPreparation)) "live preparation recovery retained its record"
                Assert-True (-not $publicPreJournalRunningClient.HasExited) "preparation recovery stopped the client"
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
            $publicPreJournalRecoveryJson = Assert-JsonResult $publicPreJournalRecovery "install" 1
            Assert-True (
                $publicPreJournalRecoveryJson.code -eq "runtime_activation_required"
            ) "next public install did not recover the pre-journal new target"
            $publicPreJournalUsageJson = Get-Content -LiteralPath $publicPreJournalUsage -Raw | ConvertFrom-Json
            Assert-True ([int]$publicPreJournalUsageJson.Profile -eq 3) "recovered install did not replace the empty usage state"
            Assert-True (-not (
                Test-Path -LiteralPath $publicPreJournalPreparation
            )) "recovered install retained the preparation record"
        }

        Invoke-DeferredProbe "legacy recovery while the client runs" {
            $recoveryRaceClient = Join-Path $sandbox "legacy-clash-verge/clash-verge.exe"
            New-Item -ItemType Directory -Path (Split-Path -Parent $recoveryRaceClient) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $env:SystemRoot "System32/ping.exe") -Destination $recoveryRaceClient
            $legacyClient = Start-Process -FilePath $recoveryRaceClient -ArgumentList @("-n", "60", "127.0.0.1") -PassThru
            try {
            Assert-True (Test-ClashVergeRunning) "legacy recovery fixture has no running client"
            $journalRaceHome = Join-Path $sandbox "recovery-journal-client-race-home"
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
            $journalRaceResult = Invoke-TestPowerShell $installer @("-AppHome", $journalRaceHome, "-ShowUsageProfile", "-Json")
            Assert-JsonResult $journalRaceResult "install" 0 | Out-Null
            Assert-True ((Get-FileSha256 $journalRaceTarget) -eq (Get-BytesSha256 $journalRaceOriginal)) "legacy live recovery did not restore config"
            Assert-True ((Get-FileSha256 $journalRaceMissingTarget) -eq (Get-BytesSha256 $journalRaceMissingOriginal)) "legacy live recovery did not restore the deleted file"
            Assert-True (-not (Test-Path -LiteralPath $journalRacePath)) "legacy live recovery retained its journal"

            $preparationRaceHome = Join-Path $sandbox "recovery-preparation-client-race-home"
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
            $preparationRaceResult = Invoke-TestPowerShell $installer @("-AppHome", $preparationRaceHome, "-ShowUsageProfile", "-Json")
            Assert-JsonResult $preparationRaceResult "install" 0 | Out-Null
            foreach ($legacyPath in @($preparationRaceConfig, $preparationRaceVerge, $preparationRacePath)) {
                Assert-True (-not (Test-Path -LiteralPath $legacyPath)) "legacy live preparation recovery retained a target or record"
            }
            Assert-True (-not $legacyClient.HasExited) "legacy recovery stopped the client"
            } finally {
                if (-not $legacyClient.HasExited) { Stop-Process -Id $legacyClient.Id -Force }
                $legacyClient.WaitForExit()
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
            $publicHandoffRecoveryJson = Assert-JsonResult $publicHandoffRecovery "install" 1
            Assert-True (
                $publicHandoffRecoveryJson.code -eq "runtime_activation_required"
            ) "next public install did not recover the journal handoff"
            $publicHandoffUsageJson = Get-Content -LiteralPath $publicHandoffUsage -Raw | ConvertFrom-Json
            Assert-True ([int]$publicHandoffUsageJson.Profile -eq 1) "handoff recovery did not publish a valid usage state"
            Assert-True (-not (
                (Test-Path -LiteralPath $publicHandoffJournal) -or
                (Test-Path -LiteralPath $publicHandoffPreparation)
            )) "handoff recovery retained a transaction record"
        }
    }

    }

    if (Test-GroupSelected 'core') {
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
    Assert-InstallerRejectsScript "constructor-escape-case" "function main(config) { return (() => {}).constructor('return config')(); }`n" "动态执行"
    Assert-InstallerRejectsScript "computed-constructor-literal-case" 'function main(config) { return globalThis["constructor"]("return config")(); }' "动态执行"
    Assert-InstallerRejectsScript "template-eval-case" 'function main(config) { return `${eval(''config'')}`; }' "动态执行"

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

    }

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

Assert-True ($script:executedScenarioCount -gt 0) "Windows installer suite did not execute any scenarios"
exit 0
