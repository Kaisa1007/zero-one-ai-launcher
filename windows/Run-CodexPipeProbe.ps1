[CmdletBinding()]
param(
    [string] $CodexExe,
    [switch] $SelfTest
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$repo = Split-Path -Parent $PSScriptRoot
$probe = Join-Path $repo 'work\probe\bin\Release\net8.0-windows\CodexPipeProbe.exe'
if (!(Test-Path -LiteralPath $probe -PathType Leaf)) {
    throw "找不到 $probe。请先按 windows\README.md 构建管道探针。"
}

if ($SelfTest) {
    if ($CodexExe) { throw '-SelfTest 和 -CodexExe 不能一起使用。' }
    & $probe --selftest
    exit $LASTEXITCODE
}

if (!$CodexExe) {
    $package = Get-AppxPackage -Name 'OpenAI.Codex' |
        Sort-Object Version -Descending | Select-Object -First 1
    if (!$package) {
        throw '找不到 OpenAI.Codex 注册包。请用 -CodexExe 指定桌面版的实际 .exe 路径。'
    }
    $manifest = Get-AppxPackageManifest -Package $package.PackageFullName
    $entry = $manifest.Package.Applications.Application |
        Where-Object Id -eq 'App' | Select-Object -First 1
    if (!$entry.Executable) {
        throw '注册包清单缺少 App 可执行入口。请用 -CodexExe 指定桌面版的实际 .exe 路径。'
    }
    $CodexExe = Join-Path $package.InstallLocation $entry.Executable
    Write-Output "[discovery] package=$($package.Name) version=$($package.Version) entry=$($entry.Id)"
}

& $probe --codex-exe $CodexExe --repo $repo
exit $LASTEXITCODE
