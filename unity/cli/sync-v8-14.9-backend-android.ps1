[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateCount(3, 3)]
    [string[]] $ArtifactRoot,

    [string] $PuertsRoot = 'D:\UGit\puerts-Unity_v2.2.3',
    [string] $Ndk = 'D:\Android\Sdk\ndk\28.2.13676358'
)

$ErrorActionPreference = 'Stop'
$backend = Join-Path $PuertsRoot 'unity\native_src\.backends\v8_14.9.207.39'
$verify = Join-Path $PSScriptRoot 'verify-v8-14.9-android-backend.mjs'
$aggregate = Join-Path $PuertsRoot 'unity\.staging\v8-14.9-android-aggregate'
$candidate = Join-Path $PuertsRoot 'unity\.staging\v8-14.9-backend-candidate'
$backup = "$backend.previous"

if (!(Test-Path -LiteralPath $verify)) { throw "校验脚本不存在：$verify" }
if (!(Test-Path -LiteralPath (Join-Path $Ndk 'source.properties'))) { throw "固定 NDK 不存在：$Ndk" }
if (!(Test-Path -LiteralPath $backend) -and (Test-Path -LiteralPath $backup)) {
    Move-Item -LiteralPath $backup -Destination $backend
}
elseif ((Test-Path -LiteralPath $backend) -and (Test-Path -LiteralPath $backup)) {
    throw "backend 与恢复备份同时存在，拒绝猜测应保留哪份：$backend / $backup"
}
if (!(Test-Path -LiteralPath $backend)) { throw "目标 backend 不存在：$backend" }

foreach ($temporary in @($aggregate, $candidate)) {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
New-Item -ItemType Directory -Path $aggregate -Force | Out-Null

try {
    foreach ($source in $ArtifactRoot) {
        $resolved = (Resolve-Path -LiteralPath $source).Path
        foreach ($relative in @('Inc', 'Lib', 'Bin', 'Build')) {
            $sourcePath = Join-Path $resolved $relative
            if (!(Test-Path -LiteralPath $sourcePath)) { continue }
            $destinationPath = Join-Path $aggregate $relative
            New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
            Copy-Item -Path (Join-Path $sourcePath '*') -Destination $destinationPath -Recurse -Force
        }
    }

    & node $verify $aggregate --ndk-root $Ndk
    if ($LASTEXITCODE -ne 0) { throw 'Android backend 聚合校验失败' }

    $currentHeaderHash = ((& node $verify $backend --headers-only) | ConvertFrom-Json).headerSha256
    $newHeaderHash = ((& node $verify $aggregate --headers-only) | ConvertFrom-Json).headerSha256
    if ($currentHeaderHash -ne $newHeaderHash) {
        throw '现有 Windows backend 与 Android backend 头文件树不一致，拒绝混用'
    }

    Copy-Item -LiteralPath $backend -Destination $candidate -Recurse
    foreach ($relative in @('Lib\Android', 'Bin\Android', 'Build\Android')) {
        $sourcePath = Join-Path $aggregate $relative
        $destinationPath = Join-Path $candidate $relative
        if (Test-Path -LiteralPath $destinationPath) {
            Remove-Item -LiteralPath $destinationPath -Recurse -Force
        }
        New-Item -ItemType Directory -Path (Split-Path $destinationPath -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse -Force
    }

    & node $verify $candidate --ndk-root $Ndk
    if ($LASTEXITCODE -ne 0) { throw '候选 Android backend 校验失败' }

    Move-Item -LiteralPath $backend -Destination $backup
    try {
        Move-Item -LiteralPath $candidate -Destination $backend
        & node $verify $backend --ndk-root $Ndk
        if ($LASTEXITCODE -ne 0) { throw '发布后的 Android backend 校验失败' }
    }
    catch {
        if (Test-Path -LiteralPath $backend) {
            Remove-Item -LiteralPath $backend -Recurse -Force
        }
        Move-Item -LiteralPath $backup -Destination $backend
        throw
    }
    Remove-Item -LiteralPath $backup -Recurse -Force
}
finally {
    foreach ($temporary in @($aggregate, $candidate)) {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}

Write-Host 'V8 14.9 Android 三 ABI backend 已同步；Windows 产物未修改。' -ForegroundColor Green
