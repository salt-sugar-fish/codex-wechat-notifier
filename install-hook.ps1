param(
    [string]$InstallRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$codexDir = Join-Path $env:USERPROFILE '.codex'
$hooksPath = Join-Path $codexDir 'hooks.json'
$backupDir = Join-Path $InstallRoot 'backups'
$notifyScript = Join-Path $InstallRoot 'notify.ps1'

if (-not (Test-Path -LiteralPath $notifyScript)) {
    throw "找不到通知脚本：$notifyScript"
}
if (-not (Test-Path -LiteralPath $codexDir)) {
    New-Item -ItemType Directory -Path $codexDir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
}

if (Test-Path -LiteralPath $hooksPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item -LiteralPath $hooksPath -Destination (Join-Path $backupDir "hooks-$stamp.json")
    $document = Get-Content -Raw -LiteralPath $hooksPath | ConvertFrom-Json
}
else {
    $document = [pscustomobject]@{
        description = 'User lifecycle hooks.'
        hooks = [pscustomobject]@{}
    }
}

if ($null -eq $document.hooks) {
    $document | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force
}

$escapedScript = $notifyScript.Replace('"', '\"')
$command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $escapedScript
$newHandler = [pscustomobject]@{
    type = 'command'
    command = $command
    async = $false
    timeout = 20
}
$newGroup = [pscustomobject]@{
    hooks = @($newHandler)
}

$existingGroups = @()
if ($null -ne $document.hooks.Stop) {
    foreach ($group in @($document.hooks.Stop)) {
        $isOurGroup = $false
        foreach ($handler in @($group.hooks)) {
            if ([string]$handler.command -eq $command) {
                $isOurGroup = $true
            }
        }
        if (-not $isOurGroup) { $existingGroups += $group }
    }
}
$document.hooks | Add-Member -NotePropertyName Stop -NotePropertyValue @($existingGroups + $newGroup) -Force

$json = $document | ConvertTo-Json -Depth 20
[IO.File]::WriteAllText($hooksPath, $json, [Text.UTF8Encoding]::new($false))
Write-Host "Codex Stop Hook 已写入：$hooksPath" -ForegroundColor Green
Write-Host '请重启 Codex，并在首次提示时检查、信任这个 Hook。' -ForegroundColor Yellow
