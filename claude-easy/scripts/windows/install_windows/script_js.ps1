function Get-JavaScriptAnalysis([string]$Text) {
    $mask = New-Object System.Text.StringBuilder
    $markers = @()
    $stringLiterals = @()
    $state = "code"
    $templateExpressionDepths = @()
    $literalStart = -1
    $hasLiteral = $false
    $index = 0
    while ($index -lt $Text.Length) {
        $character = [string]$Text[$index]
        $next = if ($index + 1 -lt $Text.Length) { [string]$Text[$index + 1] } else { "" }

        if ($state -eq "code") {
            if ($character -eq "/" -and $next -eq "/") {
                $finish = $index + 2
                while ($finish -lt $Text.Length -and $Text[$finish] -ne "`r" -and $Text[$finish] -ne "`n") { $finish++ }
                $comment = $Text.Substring($index, $finish - $index).Trim()
                if ($comment -eq "// CLAUDEEASY BEGIN") {
                    $markers += [pscustomobject]@{ Kind = "begin"; Start = $index; End = $finish }
                } elseif ($comment -eq "// CLAUDEEASY END") {
                    $markers += [pscustomobject]@{ Kind = "end"; Start = $index; End = $finish }
                } elseif ($comment -eq "// CLAUDEEASY ORIGINAL BEGIN") {
                    $markers += [pscustomobject]@{ Kind = "original-begin"; Start = $index; End = $finish }
                } elseif ($comment -eq "// CLAUDEEASY ORIGINAL END") {
                    $markers += [pscustomobject]@{ Kind = "original-end"; Start = $index; End = $finish }
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
            if ($templateExpressionDepths.Count -gt 0 -and $character -eq "{") {
                $depthIndex = $templateExpressionDepths.Count - 1
                $templateExpressionDepths[$depthIndex] = [int]$templateExpressionDepths[$depthIndex] + 1
                [void]$mask.Append($character)
                $index++
                continue
            }
            if ($templateExpressionDepths.Count -gt 0 -and $character -eq "}") {
                $depthIndex = $templateExpressionDepths.Count - 1
                $newDepth = [int]$templateExpressionDepths[$depthIndex] - 1
                if ($newDepth -eq 0) {
                    if ($depthIndex -eq 0) {
                        $templateExpressionDepths = @()
                    } else {
                        $templateExpressionDepths = @($templateExpressionDepths[0..($depthIndex - 1)])
                    }
                    $state = "template"
                    [void]$mask.Append(" ")
                } else {
                    $templateExpressionDepths[$depthIndex] = $newDepth
                    [void]$mask.Append($character)
                }
                $index++
                continue
            }
            if ($character -eq "'") {
                $state = "single"
                $literalStart = $index
                $hasLiteral = $true
                [void]$mask.Append(" ")
                $index++
                continue
            }
            if ($character -eq '"') {
                $state = "double"
                $literalStart = $index
                $hasLiteral = $true
                [void]$mask.Append(" ")
                $index++
                continue
            }
            if ($character -eq '`') {
                $state = "template"
                $hasLiteral = $true
                [void]$mask.Append(" ")
                $index++
                continue
            }
            [void]$mask.Append($character)
            $index++
            continue
        }

        if ($state -eq "template") {
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
            if ($character -eq '`') {
                $state = "code"
                [void]$mask.Append(" ")
                $index++
                continue
            }
            if ($character -eq '$' -and $next -eq "{") {
                [void]$mask.Append("  ")
                $templateExpressionDepths += 1
                $state = "code"
                $index += 2
                continue
            }
            [void]$mask.Append($(if ($character -eq "`r" -or $character -eq "`n") { $character } else { " " }))
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
            ($state -eq "double" -and $character -eq '"')) {
            if ($literalStart -ge 0) {
                $stringLiterals += $Text.Substring($literalStart, $index - $literalStart + 1)
            }
            $literalStart = -1
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
    if ($state -ne "code" -or $templateExpressionDepths.Count -gt 0) {
        throw "JavaScript 字符串或模板表达式没有结束，原脚本没有被修改。"
    }
    return [pscustomobject]@{
        Code = $mask.ToString()
        Markers = @($markers)
        StringLiterals = @($stringLiterals)
        HasLiteral = $hasLiteral
    }
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
    if ([regex]::IsMatch($analysis.Code, '\b(?:claudeEasy[A-Za-z0-9_$]*|CLAUDE_EASY_[A-Za-z0-9_$]*)\b')) {
        throw "现有脚本使用了 ClaudeEasy 保留标识符，无法安全合并。原脚本没有被修改。"
    }
}

function Assert-JavaScriptDoesNotUseDynamicCode([string]$Text) {
    $analysis = Get-JavaScriptAnalysis $Text
    $constructorLiteral = @($analysis.StringLiterals | Where-Object {
        $_.Length -ge 2 -and $_.Substring(1, $_.Length - 2) -ceq "constructor"
    }).Count -gt 0
    if ([regex]::IsMatch($analysis.Code, '\b(?:eval|Function)\b|\.\s*constructor\b') -or
        $constructorLiteral) {
        throw "现有脚本使用动态执行或函数构造器，无法与受管入口安全隔离。原脚本没有被修改。"
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

function Assert-JavaScriptDoesNotReferenceMain([string]$Code) {
    if ([regex]::IsMatch(
            $Code,
            '(?<![A-Za-z0-9_$.])main(?![A-Za-z0-9_$])'
        )) {
        throw "现有脚本不能在入口声明之外引用 main；当前安装器无法可靠重命名这些引用，原脚本没有被修改。"
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
    Assert-JavaScriptDoesNotUseDynamicCode $Text
    $withoutDeclaration = $analysis.Code.Substring(0, $matches[0].Index) + (" " * $matches[0].Length) +
        $analysis.Code.Substring($matches[0].Index + $matches[0].Length)
    Assert-JavaScriptDoesNotBindMain $withoutDeclaration
    if ([regex]::IsMatch($withoutDeclaration, '(?<![A-Za-z0-9_$.])main\s*\(')) {
        throw "现有 main 会递归调用自身，重命名后会误调用 ClaudeEasy main。原脚本没有被修改。"
    }
    Assert-JavaScriptDoesNotReferenceMain $withoutDeclaration
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
    $originalBegin = "// CLAUDEEASY ORIGINAL BEGIN"
    $originalEnd = "// CLAUDEEASY ORIGINAL END"
    $previous = ""

    if ($null -ne $CurrentText) {
        $current = $CurrentText
        $analysis = Get-JavaScriptAnalysis $current
        $beginMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "begin" })
        $endMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "end" })
        $originalBeginMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "original-begin" })
        $originalEndMarkers = @($analysis.Markers | Where-Object { $_.Kind -eq "original-end" })
        if ($beginMarkers.Count -gt 0 -or $endMarkers.Count -gt 0) {
            if ($beginMarkers.Count -ne 1 -or $endMarkers.Count -ne 1 -or $endMarkers[0].Start -lt $beginMarkers[0].Start) {
                throw "检测到不完整或重复的 ClaudeEasy 标记。原脚本没有被修改。"
            }
            $managedBlock = $current.Substring($beginMarkers[0].Start, $endMarkers[0].End - $beginMarkers[0].Start)
            if (-not $managedBlock.Contains("CLAUDEEASY POLICY BEGIN") -or -not $managedBlock.Contains("function claudeEasyTransform")) {
                throw "检测到非本工具创建的同名标记。原脚本没有被修改。"
            }

            $outsidePrefix = $current.Substring(0, $beginMarkers[0].Start).Trim()
            $outsideSuffix = $current.Substring($endMarkers[0].End).Trim()
            if ($originalBeginMarkers.Count -gt 0 -or $originalEndMarkers.Count -gt 0) {
                if ($originalBeginMarkers.Count -ne 1 -or $originalEndMarkers.Count -ne 1 -or
                    $originalEndMarkers[0].Start -lt $originalBeginMarkers[0].End -or
                    $originalBeginMarkers[0].Start -lt $beginMarkers[0].Start -or
                    $originalEndMarkers[0].End -gt $endMarkers[0].End) {
                    throw "检测到不完整、重复或越界的原脚本标记。原脚本没有被修改。"
                }
                $embedded = $current.Substring(
                    $originalBeginMarkers[0].End,
                    $originalEndMarkers[0].Start - $originalBeginMarkers[0].End
                ).Trim()
                if (-not [string]::IsNullOrWhiteSpace($embedded)) {
                    $embedded = Rename-JavaScriptMain $embedded "claudeEasyPreviousMain" "main"
                }
                $restoredParts = @($outsidePrefix, $embedded, $outsideSuffix) |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                $restored = ($restoredParts -join "`r`n`r`n")
                if (-not [string]::IsNullOrWhiteSpace($restored)) {
                    Assert-JavaScriptCanCompose $restored
                    $previous = Rename-JavaScriptMain $restored "main" "claudeEasyPreviousMain"
                }
            } else {
                $restoredParts = @($outsidePrefix, $outsideSuffix) |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                $restored = ($restoredParts -join "`r`n`r`n")
                if (-not [string]::IsNullOrWhiteSpace($restored)) {
                    $restored = Rename-JavaScriptMain $restored "claudeEasyPreviousMain" "main"
                    Assert-JavaScriptCanCompose $restored
                    $previous = Rename-JavaScriptMain $restored "main" "claudeEasyPreviousMain"
                }
            }
        } elseif (-not [string]::IsNullOrWhiteSpace($current)) {
            if ($originalBeginMarkers.Count -gt 0 -or $originalEndMarkers.Count -gt 0) {
                throw "检测到没有受管区块的原脚本标记。原脚本没有被修改。"
            }
            Assert-JavaScriptCanCompose $current
            $previous = (Rename-JavaScriptMain $current "main" "claudeEasyPreviousMain").Trim()
        }
    }

    $parts = @()
    $parts += $begin
    $parts += "let claudeEasyInstallManagedMain = (function ("
    $parts += "  claudeEasyRealGlobal,"
    $parts += "  claudeEasyNativeObject,"
    $parts += "  claudeEasyNativeReflect,"
    $parts += "  claudeEasyNativeArray,"
    $parts += "  claudeEasyNativeBoolean,"
    $parts += "  claudeEasyNativeError,"
    $parts += "  claudeEasyNativeFunction,"
    $parts += "  claudeEasyNativeJSON,"
    $parts += "  claudeEasyNativeRegExp,"
    $parts += "  claudeEasyNativeString"
    $parts += ") {"
    $parts += "const globalThis = claudeEasyRealGlobal;"
    $parts += "const Object = claudeEasyNativeObject;"
    $parts += "const Reflect = claudeEasyNativeReflect;"
    $parts += "const Array = claudeEasyNativeArray;"
    $parts += "const Boolean = claudeEasyNativeBoolean;"
    $parts += "const Error = claudeEasyNativeError;"
    $parts += "const JSON = claudeEasyNativeJSON;"
    $parts += "const RegExp = claudeEasyNativeRegExp;"
    $parts += "const String = claudeEasyNativeString;"
    $parts += "const module = claudeEasyRealGlobal.module;"
    $parts += "const claudeEasyGetOwnPropertyDescriptor = claudeEasyNativeObject.getOwnPropertyDescriptor;"
    $parts += "const claudeEasyDefineProperty = claudeEasyNativeObject.defineProperty;"
    $parts += "const claudeEasyObjectIs = claudeEasyNativeObject.is;"
    $parts += "const claudeEasyHasOwnProperty = claudeEasyNativeObject.prototype.hasOwnProperty;"
    $parts += "const claudeEasyOwnKeys = claudeEasyNativeReflect.ownKeys;"
    $parts += "const claudeEasyDeleteProperty = claudeEasyNativeReflect.deleteProperty;"
    $parts += "const claudeEasyApplyFunction = claudeEasyNativeReflect.apply;"
    $parts += "const claudeEasySubjectSnapshots = [];"
    $parts += "const claudeEasyGlobalSnapshots = [];"
    $parts += 'const claudeEasyGlobalNames = ["Object", "Reflect", "Array", "Boolean", "Error", "Function", "JSON", "RegExp", "String"];'
    $parts += "function claudeEasyHasOwn(subject, key) {"
    $parts += "  return claudeEasyApplyFunction(claudeEasyHasOwnProperty, subject, [key]);"
    $parts += "}"
    $parts += "function claudeEasySnapshotSubject(subject) {"
    $parts += '  if ((typeof subject !== "object" || subject === null) && typeof subject !== "function") return;'
    $parts += "  const descriptors = [];"
    $parts += "  const keys = claudeEasyOwnKeys(subject);"
    $parts += "  for (let index = 0; index < keys.length; index += 1) {"
    $parts += "    descriptors[descriptors.length] = [keys[index], claudeEasyGetOwnPropertyDescriptor(subject, keys[index])];"
    $parts += "  }"
    $parts += "  claudeEasySubjectSnapshots[claudeEasySubjectSnapshots.length] = [subject, descriptors];"
    $parts += "}"
    $parts += "for (let claudeEasyGlobalIndex = 0; claudeEasyGlobalIndex < claudeEasyGlobalNames.length; claudeEasyGlobalIndex += 1) {"
    $parts += "  const claudeEasyGlobalName = claudeEasyGlobalNames[claudeEasyGlobalIndex];"
    $parts += "  claudeEasyGlobalSnapshots[claudeEasyGlobalSnapshots.length] = ["
    $parts += "    claudeEasyGlobalName,"
    $parts += "    claudeEasyGetOwnPropertyDescriptor(claudeEasyRealGlobal, claudeEasyGlobalName)"
    $parts += "  ];"
    $parts += "}"
    $parts += "const claudeEasySubjects = ["
    $parts += "  claudeEasyNativeObject, claudeEasyNativeObject.prototype,"
    $parts += "  claudeEasyNativeReflect,"
    $parts += "  claudeEasyNativeArray, claudeEasyNativeArray.prototype,"
    $parts += "  claudeEasyNativeBoolean, claudeEasyNativeBoolean.prototype,"
    $parts += "  claudeEasyNativeError, claudeEasyNativeError.prototype,"
    $parts += "  claudeEasyNativeFunction, claudeEasyNativeFunction.prototype,"
    $parts += "  claudeEasyNativeJSON,"
    $parts += "  claudeEasyNativeRegExp, claudeEasyNativeRegExp.prototype,"
    $parts += "  claudeEasyNativeString, claudeEasyNativeString.prototype"
    $parts += "];"
    $parts += "for (let claudeEasySubjectIndex = 0; claudeEasySubjectIndex < claudeEasySubjects.length; claudeEasySubjectIndex += 1) {"
    $parts += "  claudeEasySnapshotSubject(claudeEasySubjects[claudeEasySubjectIndex]);"
    $parts += "}"
    $parts += "function claudeEasyDescriptorEqual(left, right) {"
    $parts += "  if (!left || !right || left.configurable !== right.configurable || left.enumerable !== right.enumerable) return false;"
    $parts += '  const leftHasValue = claudeEasyHasOwn(left, "value");'
    $parts += '  if (leftHasValue !== claudeEasyHasOwn(right, "value")) return false;'
    $parts += "  if (leftHasValue) {"
    $parts += "    return left.writable === right.writable && claudeEasyObjectIs(left.value, right.value);"
    $parts += "  }"
    $parts += "  return claudeEasyObjectIs(left.get, right.get) && claudeEasyObjectIs(left.set, right.set);"
    $parts += "}"
    $parts += "function claudeEasySnapshotHasKey(descriptors, key) {"
    $parts += "  for (let index = 0; index < descriptors.length; index += 1) {"
    $parts += "    if (claudeEasyObjectIs(descriptors[index][0], key)) return true;"
    $parts += "  }"
    $parts += "  return false;"
    $parts += "}"
    $parts += "function claudeEasyRestoreSubject(snapshot) {"
    $parts += "  const subject = snapshot[0];"
    $parts += "  const descriptors = snapshot[1];"
    $parts += "  const currentKeys = claudeEasyOwnKeys(subject);"
    $parts += "  for (let index = 0; index < currentKeys.length; index += 1) {"
    $parts += "    if (!claudeEasySnapshotHasKey(descriptors, currentKeys[index]) &&"
    $parts += "        !claudeEasyDeleteProperty(subject, currentKeys[index])) {"
    $parts += '      throw new claudeEasyNativeError("ClaudeEasy could not remove intrinsic pollution");'
    $parts += "    }"
    $parts += "  }"
    $parts += "  for (let index = 0; index < descriptors.length; index += 1) {"
    $parts += "    claudeEasyDefineProperty(subject, descriptors[index][0], descriptors[index][1]);"
    $parts += "  }"
    $parts += "  const verifiedKeys = claudeEasyOwnKeys(subject);"
    $parts += "  if (verifiedKeys.length !== descriptors.length) {"
    $parts += '    throw new claudeEasyNativeError("ClaudeEasy intrinsic restoration was incomplete");'
    $parts += "  }"
    $parts += "  for (let index = 0; index < descriptors.length; index += 1) {"
    $parts += "    if (!claudeEasyDescriptorEqual("
    $parts += "      descriptors[index][1],"
    $parts += "      claudeEasyGetOwnPropertyDescriptor(subject, descriptors[index][0])"
    $parts += "    )) {"
    $parts += '      throw new claudeEasyNativeError("ClaudeEasy intrinsic restoration did not verify");'
    $parts += "    }"
    $parts += "  }"
    $parts += "}"
    $parts += "function claudeEasyRestoreIntrinsics() {"
    $parts += "  for (let index = claudeEasySubjectSnapshots.length - 1; index >= 0; index -= 1) {"
    $parts += "    claudeEasyRestoreSubject(claudeEasySubjectSnapshots[index]);"
    $parts += "  }"
    $parts += "  for (let index = 0; index < claudeEasyGlobalSnapshots.length; index += 1) {"
    $parts += "    const name = claudeEasyGlobalSnapshots[index][0];"
    $parts += "    const descriptor = claudeEasyGlobalSnapshots[index][1];"
    $parts += "    if (descriptor) claudeEasyDefineProperty(claudeEasyRealGlobal, name, descriptor);"
    $parts += "    else if (claudeEasyHasOwn(claudeEasyRealGlobal, name) && !claudeEasyDeleteProperty(claudeEasyRealGlobal, name)) {"
    $parts += '      throw new claudeEasyNativeError("ClaudeEasy could not restore a global intrinsic binding");'
    $parts += "    }"
    $parts += "    const restored = claudeEasyGetOwnPropertyDescriptor(claudeEasyRealGlobal, name);"
    $parts += "    if ((descriptor && !claudeEasyDescriptorEqual(descriptor, restored)) || (!descriptor && restored)) {"
    $parts += '      throw new claudeEasyNativeError("ClaudeEasy global intrinsic restoration did not verify");'
    $parts += "    }"
    $parts += "  }"
    $parts += "}"
    $parts += "let claudeEasyPreviousMain = null;"
    $parts += $engine.Trim()
    $parts += "const claudeEasyManagedMain = main;"
    $parts += "let claudeEasyFinalized = false;"
    $parts += "return function (previousMain) {"
    $parts += '  if (claudeEasyFinalized) throw new claudeEasyNativeError("ClaudeEasy managed entry was already finalized");'
    $parts += "  claudeEasyRestoreIntrinsics();"
    $parts += '  if (typeof previousMain === "function") {'
    $parts += "    claudeEasyPreviousMain = function (config, profileName) {"
    $parts += "      try {"
    $parts += "        return claudeEasyApplyFunction(previousMain, undefined, [config, profileName]);"
    $parts += "      } finally {"
    $parts += "        claudeEasyRestoreIntrinsics();"
    $parts += "      }"
    $parts += "    };"
    $parts += "  }"
    $parts += '  claudeEasyDefineProperty(claudeEasyRealGlobal, "main", {'
    $parts += "    get: function () { return claudeEasyManagedMain; },"
    $parts += "    set: function () {},"
    $parts += "    enumerable: true,"
    $parts += "    configurable: false"
    $parts += "  });"
    $parts += "  claudeEasyFinalized = true;"
    $parts += "};"
    $parts += "}("
    $parts += "  this,"
    $parts += "  this.Object,"
    $parts += "  this.Reflect,"
    $parts += "  this.Array,"
    $parts += "  this.Boolean,"
    $parts += "  this.Error,"
    $parts += "  this.Function,"
    $parts += "  this.JSON,"
    $parts += "  this.RegExp,"
    $parts += "  this.String"
    $parts += "));"
    $parts += $originalBegin
    if (-not [string]::IsNullOrWhiteSpace($previous)) { $parts += $previous.Trim() }
    $parts += $originalEnd
    $parts += 'claudeEasyInstallManagedMain(typeof claudeEasyPreviousMain === "function" ? claudeEasyPreviousMain : null);'
    $parts += "claudeEasyInstallManagedMain = null;"
    $parts += $end
    return ($parts -join "`r`n") + "`r`n"
}
