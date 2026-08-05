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
function Invoke-Mihomo(
    [string]$CorePath,
    [string[]]$Arguments,
    [int]$TimeoutSeconds = 30
) {
    $nativeArguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $start = New-Object System.Diagnostics.ProcessStartInfo
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and $CorePath -match '(?i)\.(?:cmd|bat)$') {
        $start.FileName = $env:ComSpec
        $start.Arguments = '/d /s /c ""' + $CorePath + '" ' + $nativeArguments + '"'
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

function Test-MihomoVersionText([string]$Text) {
    $match = [regex]::Match($Text, '(?i)\bv?(\d+)\.(\d+)\.(\d+)\b')
    if (-not $match.Success) { return $false }
    $actual = [version]("{0}.{1}.{2}" -f $match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value)
    $minimum = [version]"1.19.27"
    return $actual.CompareTo($minimum) -ge 0
}

function Test-MihomoVersion([string]$CorePath) {
    if ([string]::IsNullOrWhiteSpace($CorePath) -or -not (Test-Path -LiteralPath $CorePath -PathType Leaf)) {
        throw "没有找到可用的 Mihomo 内核。请更新 Clash Verge Rev，或用 -MihomoPath 指定可信的内核路径。"
    }
    $result = Invoke-Mihomo $CorePath @("-v")
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

function Test-MihomoCandidate([string]$CorePath, [string]$Text, [string]$Directory) {
    Test-MihomoVersion $CorePath | Out-Null
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
        $result = Invoke-Mihomo $CorePath @("-d", $Directory, "-t", "-f", $temporary)
        if ($result.ExitCode -ne 0) { throw "Mihomo 拒绝了生成的 config.yaml。原文件没有被修改。" }
    } finally {
        if ($null -ne $stagingStream) { $stagingStream.Dispose() }
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Force }
    }
}
