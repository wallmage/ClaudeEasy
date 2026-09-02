param(
    [string]$InstallRoot = ""
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\")).Path
}
$repoUrl = "https://github.com/wallmage/ClaudeEasy.git"
$marker = Join-Path $InstallRoot ".source-revision"
$remoteLine = & git ls-remote $repoUrl HEAD | Select-Object -First 1
if ($LASTEXITCODE -ne 0 -or [string]$remoteLine -notmatch '^([0-9a-f]{40})\s') {
    throw "skill_update_check_failed"
}
$remoteSha = $Matches[1]
if ((Test-Path -LiteralPath $marker -PathType Leaf) -and
    ([System.IO.File]::ReadAllText($marker).Trim() -ceq $remoteSha)) {
    Write-Output "skill_up_to_date"
    exit 0
}
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-easy-skill-" + [Guid]::NewGuid().ToString("N"))
try {
    & git clone --quiet --depth 1 $repoUrl (Join-Path $temporary "repo")
    if ($LASTEXITCODE -ne 0) { throw "skill_update_check_failed" }
    $source = Join-Path (Join-Path $temporary "repo") "claude-easy"
    & robocopy.exe $source $InstallRoot /MIR /XD .git /R:1 /W:1 | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "skill_update_check_failed" }
    [System.IO.File]::WriteAllText($marker, "$remoteSha`r`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-Output "skill_updated"
} finally {
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
