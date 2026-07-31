[CmdletBinding()]
param(
    [string]$BackendV8Root
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptPath = (Resolve-Path -LiteralPath $PSCommandPath).Path
$cliRoot = Split-Path -Parent $scriptPath
$unityRoot = Split-Path -Parent $cliRoot
$repositoryRoot = Split-Path -Parent $unityRoot
$ugitRoot = Split-Path -Parent $repositoryRoot

if (!$BackendV8Root) {
    $BackendV8Root = Join-Path $ugitRoot "backend-v8"
}
$BackendV8Root = [IO.Path]::GetFullPath($BackendV8Root)

$version = "13.8.258.54"
$artifactRoot = Join-Path $BackendV8Root ".build\artifacts\v8_13.8.258.54"
$manifestPath = Join-Path $artifactRoot "manifest.json"
$sourceLibrary = Join-Path $artifactRoot "Lib\Win64\wee8.lib"
$sourceHeaders = Join-Path $artifactRoot "Inc"
$sourceBinaries = Join-Path $artifactRoot "Bin\Win64"
$destinationRoot = Join-Path $unityRoot "native_src\.backends\v8_13.8.258.54"

foreach ($requiredPath in @($manifestPath, $sourceLibrary, $sourceHeaders)) {
    if (!(Test-Path -LiteralPath $requiredPath)) {
        throw "缺少 backend-v8 构建产物：$requiredPath"
    }
}

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ($manifest.V8Version -ne $version) {
    throw "backend V8 版本不匹配：$($manifest.V8Version)"
}
if ($manifest.Maglev -ne $true) {
    throw "backend 并非 Maglev On，拒绝同步。"
}
if ($manifest.PointerCompression -ne $false -or $manifest.Sandbox -ne $false) {
    throw "backend 的 Pointer Compression 或 Sandbox 开关不匹配。"
}

$actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceLibrary).Hash
if ($actualHash -ne $manifest.Library.Sha256) {
    throw "backend wee8.lib 哈希与 manifest 不一致。"
}

$destinationLibraryDirectory = Join-Path $destinationRoot "Lib\Win64"
$destinationHeaders = Join-Path $destinationRoot "Inc"
$destinationBinaries = Join-Path $destinationRoot "Bin\Win64"
New-Item -ItemType Directory -Force -Path `
    $destinationLibraryDirectory, $destinationHeaders, $destinationBinaries | Out-Null

Copy-Item -LiteralPath $sourceLibrary `
    -Destination (Join-Path $destinationLibraryDirectory "wee8.lib") -Force
Copy-Item -Path (Join-Path $sourceHeaders "*") `
    -Destination $destinationHeaders -Recurse -Force
if (Test-Path -LiteralPath $sourceBinaries) {
    Copy-Item -Path (Join-Path $sourceBinaries "*") `
        -Destination $destinationBinaries -Recurse -Force
}

$destinationLibrary = Join-Path $destinationLibraryDirectory "wee8.lib"
$destinationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $destinationLibrary).Hash
if ($destinationHash -ne $actualHash) {
    throw "同步后的 wee8.lib 哈希不一致。"
}

Write-Host "V8 13.8 Maglev On backend 同步完成。"
Write-Host "来源：$sourceLibrary"
Write-Host "目标：$destinationLibrary"
Write-Host "SHA256：$destinationHash"
