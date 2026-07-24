function Get-JavaScriptAnalysis([string]$Text) {
    $mask = New-Object System.Text.StringBuilder
    $markers = @()
    $state = "code"
    $index = 0
    while ($index -lt $Text.Length) {
        $character = [string]$Text[$index]
        $next = if ($index + 1 -lt $Text.Length) { [string]$Text[$index + 1] } else { "" }

        if ($state -eq "code") {
            if ($character -eq "/" -and $next -eq "/") {
                $finish = $index + 2
                while ($finish -lt $Text.Length -and $Text[$finish] -ne "`r" -and $Text[$finish] -ne "`n") { $finish++ }
                $comment = $Text.Substring($index, $finish - $index).Trim()
                if ($comment -eq "// CLASH PATCH BEGIN" -or $comment -eq "// CLAUDEEASY BEGIN") {
                    $markers += [pscustomobject]@{ Kind = "begin"; Start = $index; End = $finish }
                } elseif ($comment -eq "// CLASH PATCH END" -or $comment -eq "// CLAUDEEASY END") {
                    $markers += [pscustomobject]@{ Kind = "end"; Start = $index; End = $finish }
                }
                while ($index -lt $finish) { [void]$mask.Append(" "); $index++ }
                continue
            }
            if ($character -eq "/" -and $next -eq "*") {
                $finish = $index + 2
                while ($finish + 1 -lt $Text.Length -and -not ($Text[$finish] -eq "*" -and $Text[$finish + 1] -eq "/")) { $finish++ }
                if ($finish + 1 -ge $Text.Length) { throw "JavaScript 块注释没有结束，原脚本没有被修改。" }
                $finish += 2
                while ($index -lt $finish) {
                    $masked = [string]$Text[$index]
                    [void]$mask.Append($(if ($masked -eq "`r" -or $masked -eq "`n") { $masked } else { " " }))
                    $index++
                }
                continue
            }
            if ($character -eq "'") { $state = "single"; [void]$mask.Append(" "); $index++; continue }
            if ($character -eq '"') { $state = "double"; [void]$mask.Append(" "); $index++; continue }
            if ($character -eq '`') { $state = "template"; [void]$mask.Append(" "); $index++; continue }
            [void]$mask.Append($character)
            $index++
            continue
        }

        if ($character -eq "\") {
            [void]$mask.Append(" ")
            $index++
            if ($index -lt $Text.Length) {
                $escaped = [string]$Text[$index]
                [void]$mask.Append($(if ($escaped -eq "`r" -or $escaped -eq "`n") { $escaped } else { " " }))
                $index++
            }
            continue
        }
        if (($state -eq "single" -and $character -eq "'") -or
            ($state -eq "double" -and $character -eq '"') -or
            ($state -eq "template" -and $character -eq '`')) {
            $state = "code"
            [void]$mask.Append(" ")
            $index++
            continue
        }
        if (($state -eq "single" -or $state -eq "double") -and ($character -eq "`r" -or $character -eq "`n")) {
            throw "JavaScript 字符串没有结束，原脚本没有被修改。"
        }
        [void]$mask.Append($(if ($character -eq "`r" -or $character -eq "`n") { $character } else { " " }))
        $index++
    }
    if ($state -ne "code") { throw "JavaScript 字符串没有结束，原脚本没有被修改。" }
    return [pscustomobject]@{ Code = $mask.ToString(); Markers = @($markers) }
}

function Rename-JavaScriptMain([string]$Text, [string]$From, [string]$To) {
    $analysis = Get-JavaScriptAnalysis $Text
    $pattern = '(?m)^\s*function\s+' + [regex]::Escape($From) + '\s*\('
    $matches = [regex]::Matches($analysis.Code, $pattern)
    if ($matches.Count -ne 1) { throw "无法确认原始 main 函数，原脚本没有被修改。" }
    $relative = $matches[0].Value.IndexOf($From, [StringComparison]::Ordinal)
    $nameIndex = $matches[0].Index + $relative
    return $Text.Substring(0, $nameIndex) + $To + $Text.Substring($nameIndex + $From.Length)
}

function Assert-JavaScriptReservedIdentifiers([string]$Text) {
    $analysis = Get-JavaScriptAnalysis $Text
    if ([regex]::IsMatch($analysis.Code, '\b(?:clashPatch[A-Za-z0-9_$]*|CLASH_PATCH_[A-Za-z0-9_$]*|claudeEasy[A-Za-z0-9_$]*|CLAUDE_EASY_[A-Za-z0-9_$]*)\b')) {
        throw "现有脚本使用了 ClaudeEasy 保留标识符，无法安全合并。原脚本没有被修改。"
    }
}

function Assert-JavaScriptDoesNotBindMain([string]$Text) {
    $code = (Get-JavaScriptAnalysis $Text).Code
    $declaration = '(?m)(?:^|[;{}])\s*(?:async\s+)?(?:function|class|var|let|const)\s+main\b'
    $assignment = '(?<![A-Za-z0-9_$.])main\s*='
    if ([regex]::IsMatch($code, $declaration) -or [regex]::IsMatch($code, $assignment)) {
        throw "现有脚本在允许的入口之外不能重新定义 main；原脚本没有被修改。"
    }
}

function Assert-JavaScriptCanCompose([string]$Text) {
    $analysis = Get-JavaScriptAnalysis $Text
    if ([regex]::IsMatch($analysis.Code, '(?m)^\s*async\s+function\s+main\s*\(')) {
        throw "检测到异步 main。Clash Verge Rev 不会等待异步 main 的结果，原脚本没有被修改。"
    }
    $matches = [regex]::Matches($analysis.Code, '(?m)^\s*function\s+main\s*\(')
    if ($matches.Count -ne 1) {
        throw "检测到已有全局扩展脚本，但无法安全合并。原脚本没有被修改，请把提示和 Script.js 截图发回来。"
    }
    Assert-JavaScriptReservedIdentifiers $Text
    $withoutDeclaration = $analysis.Code.Substring(0, $matches[0].Index) + (" " * $matches[0].Length) +
        $analysis.Code.Substring($matches[0].Index + $matches[0].Length)
    Assert-JavaScriptDoesNotBindMain $withoutDeclaration
    if ([regex]::IsMatch($withoutDeclaration, '(?<![A-Za-z0-9_$.])main\s*\(')) {
        throw "现有 main 会递归调用自身，重命名后会误调用 ClaudeEasy main。原脚本没有被修改。"
    }
}

function Build-GlobalScript(
    [string]$EnginePath,
    [string]$TargetPath,
    [int]$UsageProfile,
    [AllowNull()][string]$CurrentText = $null
) {
    if ($UsageProfile -notin @(1, 2, 3)) { throw "用途档位无效。" }
    $engine = Get-Content -LiteralPath $EnginePath -Raw -Encoding UTF8
    $profileMarker = "const CLAUDE_EASY_USAGE_PROFILE = 3;"
    if (-not $engine.Contains($profileMarker)) { throw "全局扩展脚本缺少用途档位标记。" }
    $engine = $engine.Replace($profileMarker, "const CLAUDE_EASY_USAGE_PROFILE = $UsageProfile;")
    $begin = "// CLAUDEEASY BEGIN"
    $end = "// CLAUDEEASY END"
    $prefix = ""
    $suffix = ""

    if ($null -ne $CurrentText) {
        $current = $CurrentText
        $analysis = Get-JavaScriptAnalysis $current
        $beginMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "begin" })
        $endMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "end" })
        if ($beginMarkers.Count -gt 0 -or $endMarkers.Count -gt 0) {
            if ($beginMarkers.Count -ne 1 -or $endMarkers.Count -ne 1 -or $endMarkers[0].Start -lt $beginMarkers[0].Start) {
                throw "检测到不完整或重复的 ClaudeEasy 标记。原脚本没有被修改。"
            }
            $managedBlock = $current.Substring($beginMarkers[0].Start, $endMarkers[0].End - $beginMarkers[0].Start)
            $hasPolicyMarker = $managedBlock.Contains("CLASH PATCH POLICY BEGIN") -or $managedBlock.Contains("CLAUDEEASY POLICY BEGIN")
            $hasTransform = $managedBlock.Contains("function clashPatchTransform") -or $managedBlock.Contains("function claudeEasyTransform")
            if (-not $hasPolicyMarker -or -not $hasTransform) {
                throw "检测到非本工具创建的同名标记。原脚本没有被修改。"
            }
            $prefix = $current.Substring(0, $beginMarkers[0].Start).TrimEnd()
            $suffix = $current.Substring($endMarkers[0].End).Trim()
            if (-not [string]::IsNullOrWhiteSpace($prefix)) {
                $previousMainName = "clashPatchPreviousMain"
                if ((Get-JavaScriptAnalysis $prefix).Code -match '(?m)^\s*function\s+claudeEasyPreviousMain\s*\(') {
                    $previousMainName = "claudeEasyPreviousMain"
                }
                $restoredPrefix = Rename-JavaScriptMain $prefix $previousMainName "main"
                Assert-JavaScriptCanCompose $restoredPrefix
                $prefix = Rename-JavaScriptMain $restoredPrefix "main" "claudeEasyPreviousMain"
            }
            if (-not [string]::IsNullOrWhiteSpace($suffix)) {
                Assert-JavaScriptReservedIdentifiers $suffix
                Assert-JavaScriptDoesNotBindMain $suffix
            }
        } elseif (-not [string]::IsNullOrWhiteSpace($current)) {
            Assert-JavaScriptCanCompose $current
            $prefix = (Rename-JavaScriptMain $current "main" "claudeEasyPreviousMain").TrimEnd()
        }
    }

    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($prefix)) { $parts += $prefix }
    $parts += $begin
    $parts += $engine.Trim()
    $parts += $end
    if (-not [string]::IsNullOrWhiteSpace($suffix)) { $parts += $suffix }
    return ($parts -join "`r`n") + "`r`n"
}
