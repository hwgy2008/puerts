[CmdletBinding()]
param(
    [string] $PuertsRoot = 'D:\UGit\puerts-Unity_v2.2.3',
    [string] $Ndk = 'D:\Android\Sdk\ndk\28.2.13676358',
    [string] $CMakeBin = 'D:\Android\Sdk\cmake\3.31.6\bin',
    [ValidateSet('Debug', 'Release')]
    [string] $BuildKind = 'Debug',
    [string] $ArtifactRoot = ''
)

$ErrorActionPreference = 'Stop'
$backendName = 'v8_14.9.207.39'
$backendAlias = 'v8_14.9'
$Arch = @('armv7', 'arm64', 'x64')
$abiMap = @{ armv7 = 'armeabi-v7a'; arm64 = 'arm64-v8a'; x64 = 'x86_64' }
$elfClass = @{ armv7 = 'ELF32'; arm64 = 'ELF64'; x64 = 'ELF64' }
$elfMachine = @{ armv7 = 'ARM'; arm64 = 'AArch64'; x64 = 'Advanced Micro Devices X86-64' }
$targetTriple = @{ armv7 = 'armv7-none-linux-androideabi23'; arm64 = 'aarch64-none-linux-android23'; x64 = 'x86_64-none-linux-android23' }

function Require-Path([string] $Path, [string] $Description) {
    if (!(Test-Path -LiteralPath $Path)) { throw "$Description 不存在：$Path" }
}

function Get-NormalizedTextSha256([string] $Path) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $sha.Dispose()
    }
}

$nativeSrc = Join-Path $PuertsRoot 'unity\native_src'
$backendRoot = Join-Path $nativeSrc ".backends\$backendName"
$cmake = Join-Path $CMakeBin 'cmake.exe'
$ninja = Join-Path $CMakeBin 'ninja.exe'
$sourceProperties = Join-Path $Ndk 'source.properties'
$readElf = Join-Path $Ndk 'toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-readelf.exe'
$strings = Join-Path $Ndk 'toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-strings.exe'
$nm = Join-Path $Ndk 'toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-nm.exe'
$verifyBackend = Join-Path $PSScriptRoot 'verify-v8-14.9-android-backend.mjs'
$nodeModules = Join-Path $PuertsRoot 'unity\node_modules'
$unityRoot = Join-Path $PuertsRoot 'unity'
$packageLock = Join-Path $unityRoot 'package-lock.json'
$inspectorBuild = $BuildKind -eq 'Debug'
$artifactName = if ($inspectorBuild) { 'v8-14.9-android-debug' } else { 'v8-14.9-android-release' }
if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    $ArtifactRoot = Join-Path $unityRoot "artifacts\$artifactName"
}
$expectedArtifactParent = [IO.Path]::GetFullPath((Join-Path $unityRoot 'artifacts'))
$resolvedArtifactRoot = [IO.Path]::GetFullPath($ArtifactRoot)
if ([IO.Path]::GetDirectoryName($resolvedArtifactRoot) -ne $expectedArtifactParent -or
    [IO.Path]::GetFileName($resolvedArtifactRoot) -ne $artifactName) {
    throw "ArtifactRoot 必须精确为 $expectedArtifactParent\$artifactName"
}
$stagingRoot = "$resolvedArtifactRoot.staging"
$backupRoot = "$resolvedArtifactRoot.previous"
if (!(Get-Command node -ErrorAction SilentlyContinue)) { throw 'node 不在 PATH' }
if (!(Get-Command npm -ErrorAction SilentlyContinue)) { throw 'npm 不在 PATH' }
if (!(Get-Command git -ErrorAction SilentlyContinue)) { throw 'git 不在 PATH' }
$requiredPaths = @(
    [pscustomobject]@{ Path = $nativeSrc; Description = 'PuerTS native_src' },
    [pscustomobject]@{ Path = $backendRoot; Description = 'V8 backend' },
    [pscustomobject]@{ Path = $cmake; Description = 'CMake' },
    [pscustomobject]@{ Path = $ninja; Description = 'Ninja' },
    [pscustomobject]@{ Path = $sourceProperties; Description = 'NDK source.properties' },
    [pscustomobject]@{ Path = $readElf; Description = 'llvm-readelf' },
    [pscustomobject]@{ Path = $strings; Description = 'llvm-strings' },
    [pscustomobject]@{ Path = $nm; Description = 'llvm-nm' },
    [pscustomobject]@{ Path = $verifyBackend; Description = 'backend 校验脚本' },
    [pscustomobject]@{ Path = $packageLock; Description = 'Unity CLI package-lock.json' }
)
foreach ($required in $requiredPaths) { Require-Path $required.Path $required.Description }

$puertsCommit = (& git -C $PuertsRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $puertsCommit -notmatch '^[0-9a-f]{40}$') { throw '无法读取 PuerTS commit' }
$puertsTree = (& git -C $PuertsRoot rev-parse 'HEAD^{tree}').Trim()
if ($LASTEXITCODE -ne 0 -or $puertsTree -notmatch '^[0-9a-f]{40}$') { throw '无法读取 PuerTS tree' }
& git -C $PuertsRoot diff --quiet HEAD --
if ($LASTEXITCODE -ne 0) { throw 'PuerTS 有未提交的 tracked 修改，拒绝发布 Android SO' }
$untracked = @(& git -C $PuertsRoot ls-files --others --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw '无法读取 PuerTS 未跟踪文件' }
$unexpectedUntracked = @($untracked | Where-Object {
    $_ -notmatch '^unity/build-v8-14\.9-pc-debug\.(?:stderr|stdout)\.log$' -and
    $_ -notmatch '^unity/artifacts/v8-14\.9-android-(?:debug|release)(?:/|$)'
})
if ($unexpectedUntracked.Count -gt 0) {
    throw "PuerTS 存在可能影响构建的未跟踪文件：$($unexpectedUntracked -join ', ')"
}
$puertsInputFiles = @(
    'unity/cli/backends.json',
    'unity/cli/make.mjs',
    'unity/cli/build-v8-14.9-android.ps1',
    'unity/cli/verify-v8-14.9-android-backend.mjs',
    'unity/native_src/CMakeLists.txt',
    'unity/native_src/Inc/DataTransfer.h',
    'unity/native_src/Inc/TypeInfo.hpp',
    'unity/native_src/Inc/V8Compatibility.h',
    'unity/native_src/Inc/V8Utils.h',
    'unity/native_src/Src/BackendEnv.cpp',
    'unity/native_src/Src/CppObjectMapper.cpp',
    'unity/native_src/Src/JSEngine.cpp',
    'unity/native_src/Src/JSFunction.cpp',
    'unity/native_src/Src/PesapiV8Impl.cpp',
    'unity/native_src/Src/PluginImpl.cpp',
    'unity/native_src/Src/Puerts.cpp',
    'unity/v8cc/CMakeLists.txt',
    'unreal/Puerts/Source/JsEnv/Private/PromiseRejectCallback.hpp',
    'unreal/Puerts/Source/JsEnv/Private/V8InspectorImpl.cpp',
    'unreal/Puerts/Source/JsEnv/Private/WebSocketImpl.cpp'
)
$puertsInputHashes = [ordered]@{}
foreach ($relative in $puertsInputFiles) {
    $inputPath = Join-Path $PuertsRoot $relative
    Require-Path $inputPath "PuerTS 固定构建输入 $relative"
    $puertsInputHashes[$relative] = Get-NormalizedTextSha256 $inputPath
}

$ndkProperties = Get-Content -Raw -LiteralPath $sourceProperties
if ($ndkProperties -notmatch '(?m)^Pkg\.Revision\s*=\s*28\.2\.13676358\s*$') {
    throw '该固定构建仅接受 Android NDK 28.2.13676358（r28c）'
}

& node $verifyBackend $backendRoot --ndk-root $Ndk
if ($LASTEXITCODE -ne 0) { throw 'V8 14.9 Android backend 校验失败' }

if (!(Test-Path -LiteralPath $nodeModules)) {
    Push-Location $unityRoot
    try {
        & npm ci
        if ($LASTEXITCODE -ne 0) { throw 'Unity CLI npm ci 失败' }
    }
    finally {
        Pop-Location
    }
}

$env:ANDROID_NDK = $Ndk
$env:ANDROID_NDK_HOME = $Ndk
$env:PATH = "$CMakeBin;$env:PATH"
if (!(Test-Path -LiteralPath $resolvedArtifactRoot) -and (Test-Path -LiteralPath $backupRoot)) {
    Move-Item -LiteralPath $backupRoot -Destination $resolvedArtifactRoot
}
elseif ((Test-Path -LiteralPath $resolvedArtifactRoot) -and (Test-Path -LiteralPath $backupRoot)) {
    throw "正式产物与恢复备份同时存在，拒绝猜测应保留哪份：$resolvedArtifactRoot / $backupRoot"
}
if (Test-Path -LiteralPath $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

Push-Location $nativeSrc
try {
    foreach ($archName in $Arch) {
        $abi = $abiMap[$archName]
        $arguments = @(
            '../cli/index.js', 'make',
            '--platform', 'android',
            '--arch', $archName,
            '--backend', $backendAlias,
            '--config', 'Release',
            '--websocket', $(if ($inspectorBuild) { '1' } else { '0' }),
            '--rebuild'
        )
        if ($inspectorBuild) {
            $arguments += '--with_inspector'
        }
        & node @arguments
        if ($LASTEXITCODE -ne 0) { throw "$abi 编译失败" }

        $buildDirectory = Join-Path $nativeSrc "build_android_${archName}_${backendName}"
        $buildRules = Join-Path $buildDirectory 'build.ninja'
        $toolchainRules = Join-Path $buildDirectory 'CMakeFiles\rules.ninja'
        $cmakeCache = Join-Path $buildDirectory 'CMakeCache.txt'
        Require-Path $buildRules "$abi Ninja 构建规则"
        Require-Path $toolchainRules "$abi Ninja 工具链规则"
        Require-Path $cmakeCache "$abi CMakeCache.txt"
        $buildGraph = Get-Content -Raw -LiteralPath $buildRules
        $toolchain = Get-Content -Raw -LiteralPath $toolchainRules
        $cache = Get-Content -Raw -LiteralPath $cmakeCache
        $normalizedNdk = $Ndk.Replace('\', '/')
        if ($cache.Replace('\', '/') -notmatch [regex]::Escape($normalizedNdk)) {
            throw "$abi CMake cache 未绑定固定 NDK：$Ndk"
        }
        if ($cache -notmatch '(?m)^ANDROID_PLATFORM(?::[^=]+)?=android-23\s*$' -or
            $cache -notmatch '(?m)^ANDROID_STL(?::[^=]+)?=c\+\+_static\s*$') {
            throw "$abi CMake cache 的 API 23/c++_static 配置不匹配"
        }
        if ($toolchain -notmatch [regex]::Escape("--target=$($targetTriple[$archName])")) {
            throw "$abi 编译命令未使用 API 23 target triple"
        }
        if ($buildGraph -notmatch '(?m)(?:^|\s)-static-libstdc\+\+(?:\s|$)') {
            throw "$abi 工具链规则未启用静态 C++ 运行库"
        }
        if ($buildGraph -notmatch '(?m)(?:^|\s)-Wl,--exclude-libs,libwee8\.a(?:\s|$)') {
            throw "$abi 未隐藏 V8 后端静态库符号（缺 -Wl,--exclude-libs,libwee8.a）"
        }
        foreach ($definition in @('V8_TARGET_OS_ANDROID')) {
            $definitionToken = [regex]::Escape("-D$definition")
            if ($buildGraph -notmatch "(?m)(?:^|\s)$definitionToken(?:\s|$)") {
                throw "$abi 未带编译定义 $definition"
            }
        }
        foreach ($definition in @('WITH_INSPECTOR', 'WITH_WEBSOCKET')) {
            $definitionToken = [regex]::Escape("-D$definition")
            $present = $buildGraph -match "(?m)(?:^|\s)$definitionToken(?:\s|$)"
            if ($inspectorBuild -and !$present) { throw "$abi Debug 缺少编译定义 $definition" }
            if (!$inspectorBuild -and $present) { throw "$abi Release 意外包含编译定义 $definition" }
        }
        $compressionDefinitions = @('V8_COMPRESS_POINTERS', 'V8_COMPRESS_POINTERS_IN_SHARED_CAGE', 'V8_31BIT_SMIS_ON_64BIT_ARCH')
        foreach ($definition in $compressionDefinitions) {
            $definitionToken = [regex]::Escape("-D$definition")
            $present = $buildGraph -match "(?m)(?:^|\s)$definitionToken(?:\s|$)"
            if ($archName -eq 'armv7' -and $present) { throw "armeabi-v7a 意外包含 $definition" }
            if ($archName -ne 'armv7' -and !$present) { throw "$abi 缺少 $definition" }
        }

        $builtSo = Join-Path $PuertsRoot "unity\Assets\core\upm\Plugins\Android\libs\$abi\libpuerts.so"
        Require-Path $builtSo "$abi libpuerts.so"
        $header = (& $readElf -h $builtSo) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $header -notmatch [regex]::Escape($elfClass[$archName]) -or
            $header -notmatch [regex]::Escape($elfMachine[$archName])) {
            throw "$abi ELF 架构校验失败"
        }
        $dynamic = (& $readElf -d $builtSo) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "$abi ELF 动态段读取失败" }
        if ($dynamic -match 'libc\+\+_shared\.so') {
            throw "$abi 意外依赖 libc++_shared.so；固定方案要求 c++_static"
        }
        $nmOutput = & $nm -D --defined-only $builtSo
        if ($LASTEXITCODE -ne 0) { throw "$abi 动态符号表读取失败" }
        $exportedSymbols = @($nmOutput | ForEach-Object { ($_ -split '\s+', 3)[2] } | Where-Object { $_ })
        if ($exportedSymbols.Count -eq 0) { throw "$abi 动态符号表为空" }
        $leakedBackendSymbols = @($exportedSymbols | Where-Object { $_ -like '_ZN2v8*' -or $_ -like '_ZNK2v8*' })
        if ($leakedBackendSymbols.Count -gt 0) {
            throw "$abi 导出了 $($leakedBackendSymbols.Count) 个 V8 内部符号，后端符号隐藏未生效"
        }
        if ($exportedSymbols.Count -gt 8000) {
            throw "$abi 导出符号数 $($exportedSymbols.Count) 超出上限 8000，疑似后端符号隐藏失效"
        }
        $pesapiExports = @($exportedSymbols | Where-Object { $_ -like 'pesapi_*' })
        if ($pesapiExports.Count -lt 90) {
            throw "$abi pesapi 导出入口仅 $($pesapiExports.Count) 个，低于预期，符号隐藏范围过宽"
        }
        foreach ($requiredExport in @('__cxa_throw', '__gxx_personality_v0', '__dynamic_cast', '__emutls_get_address')) {
            if ($exportedSymbols -notcontains $requiredExport) {
                throw "$abi 缺少必须保留的 C++ ABI 导出符号 $requiredExport"
            }
        }
        $inspectorText = (& $strings $builtSo) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "$abi 字符串表读取失败" }
        $inspectorEndpointMarkers = @('Sec-WebSocket-Key', 'webSocketDebuggerUrl', '/json/list')
        if ($inspectorBuild) {
            foreach ($marker in @('Runtime.enable', 'Debugger.enable') + $inspectorEndpointMarkers) {
                if ($inspectorText -notmatch [regex]::Escape($marker)) {
                    throw "$abi Debug 缺少 Inspector 特征串 $marker"
                }
            }
        }
        else {
            foreach ($marker in $inspectorEndpointMarkers) {
                if ($inspectorText -match [regex]::Escape($marker)) {
                    throw "$abi Release 意外包含 Inspector 端点特征串 $marker"
                }
            }
        }

        $destinationDirectory = Join-Path $stagingRoot $abi
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        $destination = Join-Path $destinationDirectory 'libpuerts.so'
        Copy-Item -LiteralPath $builtSo -Destination $destination -Force
        $backendManifestPath = Join-Path $backendRoot "Build\Android\$abi\manifest.json"
        $backendManifest = Get-Content -Raw -LiteralPath $backendManifestPath | ConvertFrom-Json
        $manifest = [ordered]@{
            schemaVersion = 1
            v8Version = '14.9.207.39'
            abi = $abi
            buildType = if ($inspectorBuild) { 'ReleaseOptimizedWithInspector' } else { 'Release' }
            ndkRevision = '28.2.13676358'
            minSdk = 23
            maglev = $true
            pointerCompression = ($archName -ne 'armv7')
            partitionAlloc = $false
            allocatorShim = $false
            inspector = $inspectorBuild
            webSocket = $inspectorBuild
            backendSymbolsHidden = $true
            exportedDynamicSymbols = $exportedSymbols.Count
            pesapiExports = $pesapiExports.Count
            backendManifestSha256 = (Get-FileHash -LiteralPath $backendManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
            backendLibrarySha256 = $backendManifest.files.library.sha256
            backendHeadersSha256 = $backendManifest.files.headers.sha256
            puertsCommit = $puertsCommit
            puertsTree = $puertsTree
            cmakeCacheSha256 = (Get-FileHash -LiteralPath $cmakeCache -Algorithm SHA256).Hash.ToLowerInvariant()
            ninjaRulesSha256 = (Get-FileHash -LiteralPath $buildRules -Algorithm SHA256).Hash.ToLowerInvariant()
            ninjaToolchainRulesSha256 = (Get-FileHash -LiteralPath $toolchainRules -Algorithm SHA256).Hash.ToLowerInvariant()
            sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
            size = (Get-Item -LiteralPath $destination).Length
        }
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $destinationDirectory 'manifest.json') -Encoding utf8
    }
}
finally {
    Pop-Location
}

$abiManifests = [ordered]@{}
foreach ($archName in $Arch) {
    $abi = $abiMap[$archName]
    $abiManifestPath = Join-Path $stagingRoot "$abi\manifest.json"
    Require-Path $abiManifestPath "$abi SO 清单"
    $abiManifests[$abi] = (Get-FileHash -LiteralPath $abiManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
}
[ordered]@{
    schemaVersion = 1
    v8Version = '14.9.207.39'
    scheme = 'B'
    completeAbiSet = @('armeabi-v7a', 'arm64-v8a', 'x86_64')
    puertsCommit = $puertsCommit
    puertsTree = $puertsTree
    puertsInputsLfNormalizedSha256 = $puertsInputHashes
    manifests = $abiManifests
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stagingRoot 'manifest.json') -Encoding utf8

if (Test-Path -LiteralPath $backupRoot) {
    Remove-Item -LiteralPath $backupRoot -Recurse -Force
}
if (Test-Path -LiteralPath $resolvedArtifactRoot) {
    Move-Item -LiteralPath $resolvedArtifactRoot -Destination $backupRoot
}
try {
    Move-Item -LiteralPath $stagingRoot -Destination $resolvedArtifactRoot
}
catch {
    if (Test-Path -LiteralPath $backupRoot) {
        Move-Item -LiteralPath $backupRoot -Destination $resolvedArtifactRoot
    }
    throw
}
if (Test-Path -LiteralPath $backupRoot) {
    Remove-Item -LiteralPath $backupRoot -Recurse -Force
}

Write-Host "方案 B 三 ABI（含 armeabi-v7a）$BuildKind 构建与静态校验完成，产物仅位于：$resolvedArtifactRoot" -ForegroundColor Green
