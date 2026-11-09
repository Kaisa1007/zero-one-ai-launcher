[CmdletBinding()]
param([string] $Dotnet, [switch] $Probe)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$projectWork = Join-Path $repo 'work'
New-Item -ItemType Directory -Force -Path $projectWork | Out-Null
if (!$Dotnet) {
    $Dotnet = Join-Path $projectWork 'dotnet\dotnet.exe'
    if (!(Test-Path -LiteralPath $Dotnet)) { $Dotnet = 'dotnet.exe' }
}
$env:DOTNET_CLI_HOME = Join-Path $projectWork 'dotnet-home'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE = 'true'
$env:NUGET_PACKAGES = Join-Path $projectWork 'nuget'
$env:NUGET_HTTP_CACHE_PATH = Join-Path $projectWork 'nuget-http-cache'
$env:TEMP = $projectWork
$env:TMP = $projectWork
if ($Probe) {
    $project = Join-Path $PSScriptRoot 'CodexPipeProbe\CodexPipeProbe.csproj'
    $offlineFeed = Join-Path $projectWork 'offline-feed'
    New-Item -ItemType Directory -Force -Path $offlineFeed | Out-Null
    & $Dotnet build $project -c Release "-p:RestoreSources=$offlineFeed" -p:NuGetAudit=false "-p:BaseOutputPath=$projectWork\probe\bin\" "-p:BaseIntermediateOutputPath=$projectWork\probe\obj\"
    exit $LASTEXITCODE
}
$project = Join-Path $PSScriptRoot 'ZeroOneLauncher\ZeroOneLauncher.csproj'
$msbuild = @(
    '-p:RestoreSources=https://api.nuget.org/v3/index.json',
    "-p:BaseOutputPath=$projectWork\windows\bin\",
    "-p:BaseIntermediateOutputPath=$projectWork\windows\obj\"
)
$out = Join-Path $repo 'outputs\Windows'
& $Dotnet publish $project -c Release -o $out @msbuild
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Output "Windows launcher: $out\ZeroOneLauncher.exe"
