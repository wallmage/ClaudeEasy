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
    } finally {
try {
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    if (Test-GroupSelected 'core') {
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

        if (Test-GroupSelected 'core') {

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


        }
    }
    if (Test-GroupSelected 'core') {
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


            $renamedMutexCase = Join-Path $sandbox "app-home-mutex-renamed"
            $renameBlocked = $false
            try { [System.IO.Directory]::Move($mutexCase, $renamedMutexCase) } catch { $renameBlocked = $true }
            Assert-True $renameBlocked "AppHome could be renamed while its mutation lock was held"
            Assert-True (-not (Test-Path -LiteralPath $renamedMutexCase)) "AppHome rename created a second mutation-lock identity"

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

Copy-Item -LiteralPath $installerModuleRoot -Destination $brokenWindows -Recurse
$corruptContractText = "function Broken-ClaudeEasyContract {`r`n"
[System.IO.File]::WriteAllText((Join-Path $brokenWindows "result_contract.ps1"), $corruptContractText)
[System.IO.File]::WriteAllText((Join-Path $brokenPackageRoot "result_contract.ps1"), $corruptContractText)
$corruptContractHomeBefore = Get-TreeContentSnapshot $jsonShowCase
$corruptInstallContract = Assert-JsonResult (Invoke-TestPowerShell $brokenInstaller @(
    "-AppHome", $jsonShowCase, "-Json"
)) "install" 6
Assert-True ($corruptInstallContract.code -eq "incomplete_package") "corrupt result contract did not report incomplete_package"
Assert-True ((Get-TreeContentSnapshot $jsonShowCase) -ceq $corruptContractHomeBefore) "corrupt result contract changed AppHome"

    $corruptModulePackageParent = Join-Path $sandbox "corrupt-module-package"
    New-Item -ItemType Directory -Path $corruptModulePackageParent -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root "claude-easy") -Destination $corruptModulePackageParent -Recurse
    $corruptModulePackage = Join-Path $corruptModulePackageParent "claude-easy"
    $corruptModuleScripts = Join-Path $corruptModulePackage "scripts"
    $corruptModuleCommon = Join-Path (Join-Path $corruptModuleScripts "windows/install_windows") "common.ps1"
    $corruptModuleCommonText = [System.IO.File]::ReadAllText($corruptModuleCommon)
    [System.IO.File]::WriteAllText($corruptModuleCommon, $corruptModuleCommonText)
[System.IO.File]::WriteAllText(
    $corruptModuleCommon,
    $corruptModuleCommonText.Replace("function Write-Info", "function Missing-Write-Info")
)
$missingApiHome = Join-Path $sandbox "missing-api-Write-Info"
New-Item -ItemType Directory -Path $missingApiHome -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $missingApiHome "keep.txt"), "unchanged")
$missingApiBefore = Get-TreeContentSnapshot $missingApiHome
$missingApiResult = Assert-JsonResult (Invoke-TestPowerShell (Join-Path $corruptModuleScripts "install_windows.ps1") @(
    "-AppHome", $missingApiHome, "-Json"
)) "install" 6
Assert-True ($missingApiResult.code -eq "incomplete_package") "missing Write-Info did not report incomplete_package"
Assert-True ((Get-TreeContentSnapshot $missingApiHome) -ceq $missingApiBefore) "missing Write-Info changed AppHome"
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
        [System.IO.File]::WriteAllBytes(
            (Join-Path $invalidLightCase ".claude-easy.lock"),
            [byte[]]@()
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
    [System.IO.File]::WriteAllBytes(
        (Join-Path $invalidSafeUpdateStateCase ".claude-easy.lock"),
        [byte[]]@()
    )
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
                "agent_connectivity_verification", "route_verification", "dns_deep_test",
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

    }

    if (Test-GroupSelected 'core') {

    if ($onWindows) {
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
        $crashWriteRecoveryLock = Enter-AppHomeMutationLock $crashWriteHome
        Exit-AppHomeMutationLock $crashWriteRecoveryLock
        Assert-True ((Get-Content -LiteralPath $crashWriteFirstPath -Raw) -eq "first-original") "next operation did not recover a write interrupted by process death"
        Assert-True ((Get-Content -LiteralPath $crashWriteSecondPath -Raw) -eq "second-original") "write recovery changed an untouched transaction target"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $crashWriteHome ".claude-easy-transaction.json"))) "write recovery left a stale transaction journal"


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


    }

    if (Test-GroupSelected 'core') {

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
