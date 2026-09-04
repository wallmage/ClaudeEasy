function ConvertTo-NativeArgument([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $slashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($slashes * 2) + 1)))
            [void]$builder.Append('"')
        } else {
            if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)) }
            [void]$builder.Append($character)
        }
        $slashes = 0
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Assert-WindowsCommandScriptArgument([string]$Value) {
    if ($Value -match '[\r\n]' -or $Value -match '["%!^&|<>()]') {
        throw "Mihomo 命令脚本路径或参数包含不支持的命令解释器字符。"
    }
}

function Invoke-Mihomo(
    [string]$CorePath,
    [string[]]$Arguments,
    [int]$TimeoutSeconds = 30
) {
    $nativeArguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $start = New-Object System.Diagnostics.ProcessStartInfo
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and $CorePath -match '(?i)\.(?:cmd|bat)$') {
        Assert-WindowsCommandScriptArgument $CorePath
        $Arguments | ForEach-Object { Assert-WindowsCommandScriptArgument $_ }
        $start.FileName = $env:ComSpec
        $start.Arguments = '/d /v:off /s /c ""' + $CorePath + '" ' + $nativeArguments + '"'
    } else {
        $start.FileName = $CorePath
        $start.Arguments = $nativeArguments
    }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw "无法启动 Mihomo 校验进程。" }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                $terminateTree = {
                    param([int]$ProcessId)
                    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId")
                    foreach ($child in $children) { & $terminateTree ([int]$child.ProcessId) }
                    $target = [System.Diagnostics.Process]::GetProcessById($ProcessId)
                    $target.Kill()
                    $target.Dispose()
                }
                try { & $terminateTree $process.Id } catch { $process.Kill() }
            } else {
                $process.Kill()
            }
            $process.WaitForExit()
            throw "Mihomo 校验超过 $TimeoutSeconds 秒；候选配置无效，原文件保持不变。"
        }
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = (($stdout.Result, $stderr.Result) -join "`n")
        }
    } finally {
        $process.Dispose()
    }
}


function Test-ClashVergeRunning {
    $names = @("clash-verge", "clash-verge-rev", "Clash Verge", "Clash Verge Rev")
    foreach ($name in $names) {
        if ($null -ne (Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1)) { return $true }
    }
    return $false
}

function Get-ClashVergeProcessIdentity {
    $processes = @()
    foreach ($name in @("clash-verge", "clash-verge-rev", "Clash Verge", "Clash Verge Rev")) {
        $processes += @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    }
    $processes = @($processes | Sort-Object Id -Unique)
    if ($processes.Count -ne 1) { throw "无法唯一确认 Clash Verge Rev 客户端进程。" }
    try {
        return [pscustomobject][ordered]@{
            Pid = [int]$processes[0].Id
            StartedUtcTicks = [long]$processes[0].StartTime.ToUniversalTime().Ticks
            SessionId = [int]$processes[0].SessionId
        }
    } catch {
        throw "无法确认 Clash Verge Rev 客户端进程身份。"
    } finally {
        foreach ($process in $processes) { try { $process.Dispose() } catch { } }
    }
}

function Test-ClashVergeProcessIdentity([object]$Identity, [object]$Expected = $null) {
    if ($null -eq $Identity) { return $false }
    $properties = @($Identity.PSObject.Properties.Name | Sort-Object)
    if (($properties -join ",") -cne "Pid,SessionId,StartedUtcTicks" -or
        ($Identity.Pid -isnot [int] -and $Identity.Pid -isnot [long]) -or
        -not ($Identity.StartedUtcTicks -is [long]) -or
        ($Identity.SessionId -isnot [int] -and $Identity.SessionId -isnot [long]) -or
        [long]$Identity.Pid -lt 1 -or [long]$Identity.Pid -gt [int]::MaxValue -or
        [long]$Identity.StartedUtcTicks -lt 1 -or
        [long]$Identity.SessionId -lt 0 -or [long]$Identity.SessionId -gt [int]::MaxValue) {
        return $false
    }
    return $null -eq $Expected -or (
        (Test-ClashVergeProcessIdentity $Expected) -and
        [long]$Identity.Pid -eq [long]$Expected.Pid -and
        [long]$Identity.StartedUtcTicks -eq [long]$Expected.StartedUtcTicks -and
        [long]$Identity.SessionId -eq [long]$Expected.SessionId
    )
}

function Test-MihomoVersionText([string]$Text) {
    $match = [regex]::Match($Text, '(?i)\bv?(\d+)\.(\d+)\.(\d+)\b')
    if (-not $match.Success) { return $false }
    $actual = [version]("{0}.{1}.{2}" -f $match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value)
    $minimum = [version]"1.19.27"
    return $actual.CompareTo($minimum) -ge 0
}

function Test-MihomoVersion([string]$CorePath, [int]$TimeoutSeconds = 30) {
    if ([string]::IsNullOrWhiteSpace($CorePath) -or -not (Test-Path -LiteralPath $CorePath -PathType Leaf)) {
        throw "没有找到可用的 Mihomo 内核。请更新 Clash Verge Rev，或用 -MihomoPath 指定可信的内核路径。"
    }
    $result = Invoke-Mihomo $CorePath @("-v") $TimeoutSeconds
    if ($result.ExitCode -ne 0 -or -not (Test-MihomoVersionText $result.Output)) {
        throw "需要 Mihomo 1.19.27 或更高版本，当前内核版本无法确认或过旧。"
    }
    return $true
}

function Find-MihomoCore([string]$RequestedPath) {
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        if (-not (Test-Path -LiteralPath $RequestedPath -PathType Leaf)) {
            throw "指定的 Mihomo 内核不存在：$RequestedPath"
        }
        return (Resolve-Path -LiteralPath $RequestedPath).Path
    }

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $currentSessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        $runningCandidates = @(
            Get-Process -Name "verge-mihomo" -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq $currentSessionId } |
            ForEach-Object {
                try {
                    if (-not [string]::IsNullOrWhiteSpace($_.Path) -and (Test-Path -LiteralPath $_.Path -PathType Leaf)) {
                        (Resolve-Path -LiteralPath $_.Path).Path
                    }
                } catch {}
            } |
            Sort-Object -Unique
        )
        if ($runningCandidates.Count -gt 1) { throw "当前会话有多个不同的运行中 Mihomo 内核，无法唯一确认。" }
        if ($runningCandidates.Count -eq 1) { return $runningCandidates[0] }
    }

    $installCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $installCandidates += (Join-Path (Join-Path $env:LOCALAPPDATA "Clash Verge") "verge-mihomo.exe")
        $installCandidates += (Join-Path (Join-Path $env:LOCALAPPDATA "Clash Verge") "verge-mihomo-alpha.exe")
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $installCandidates += (Join-Path (Join-Path $env:ProgramFiles "Clash Verge") "verge-mihomo.exe")
        $installCandidates += (Join-Path (Join-Path $env:ProgramFiles "Clash Verge") "verge-mihomo-alpha.exe")
        $installCandidates += (Join-Path (Join-Path $env:ProgramFiles "Clash Verge Rev") "verge-mihomo.exe")
    }
    $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $installCandidates += (Join-Path (Join-Path $programFilesX86 "Clash Verge") "verge-mihomo.exe")
        $installCandidates += (Join-Path (Join-Path $programFilesX86 "Clash Verge") "verge-mihomo-alpha.exe")
        $installCandidates += (Join-Path (Join-Path $programFilesX86 "Clash Verge Rev") "verge-mihomo.exe")
    }
    foreach ($candidate in $installCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Start-MihomoCandidateCleanupWatcher([string]$CandidatePath) {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    $ownerId = [System.Diagnostics.Process]::GetCurrentProcess().Id
    $pathBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($CandidatePath))
    $watcherSource = @"
`$ownerId = $ownerId
`$candidate = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("$pathBase64"))
try { Wait-Process -Id `$ownerId -ErrorAction SilentlyContinue } catch {}
if ([System.IO.Path]::GetFileName(`$candidate) -like ".claude-easy-validate-*.yaml") {
    foreach (`$path in @(`$candidate, (`$candidate + ".staging"))) {
        Remove-Item -LiteralPath `$path -Force -ErrorAction SilentlyContinue
    }
}
"@
    $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($watcherSource))
    $executable = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $executable
    $start.Arguments = "-NoLogo -NoProfile -NonInteractive -EncodedCommand $encodedCommand"
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $watcher = [System.Diagnostics.Process]::Start($start)
    if ($null -eq $watcher) { throw "无法启动候选配置清理进程。" }
    $watcher.Dispose()
}

function Test-MihomoCandidate(
    [string]$CorePath,
    [string]$Text,
    [string]$Directory,
    [DateTime]$AbsoluteDeadline = [DateTime]::MaxValue
) {
    $remaining = [int][Math]::Ceiling([Math]::Min([double]30, [double]($AbsoluteDeadline - [DateTime]::UtcNow).TotalSeconds))
    if ($remaining -lt 1) { throw "safe_update_timeout" }
    Test-MihomoVersion $CorePath $remaining | Out-Null
    $temporary = Join-Path $Directory (".claude-easy-validate-" + [System.IO.Path]::GetRandomFileName() + ".yaml")
    $staging = $temporary + ".staging"
    $stagingStream = $null
    try {
        Start-MihomoCandidateCleanupWatcher $temporary
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
        $stagingStream = New-PrivateFileStream $staging
        $stagingStream.Write($bytes, 0, $bytes.Length)
        $stagingStream.Flush($true)
        $stagingStream.Dispose()
        $stagingStream = $null
        [System.IO.File]::Move($staging, $temporary)
        $remaining = [int][Math]::Ceiling([Math]::Min([double]30, [double]($AbsoluteDeadline - [DateTime]::UtcNow).TotalSeconds))
        if ($remaining -lt 1) { throw "safe_update_timeout" }
        $result = Invoke-Mihomo $CorePath @("-d", $Directory, "-t", "-f", $temporary) $remaining
        if ($result.ExitCode -ne 0) { throw "Mihomo 拒绝了生成的 config.yaml。原文件没有被修改。" }
    } finally {
        if ($null -ne $stagingStream) { $stagingStream.Dispose() }
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Force }
    }
}
