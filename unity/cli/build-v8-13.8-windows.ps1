[CmdletBinding()]
param(
    [ValidateSet("All", "Debug", "Release")]
    [string]$Configuration = "All",

    [switch]$Incremental,

    [string]$ArtifactRoot,

    [Parameter(DontShow)]
    [string]$SmokeDll
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-PuertsSmoke {
    param([Parameter(Mandatory)][string]$DllPath)

    $resolvedDll = (Resolve-Path -LiteralPath $DllPath).Path
    $escapedDll = $resolvedDll.Replace("\", "\\")
    $typeName = "PuertsNativeSmoke_" + [Guid]::NewGuid().ToString("N")
    $source = @"
using System;
using System.Runtime.InteropServices;

public static class $typeName
{
    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int GetApiLevel();

    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr CreateJSEngine(int backend);

    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl)]
    private static extern void DestroyJSEngine(IntPtr isolate);

    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    private static extern IntPtr Eval(IntPtr isolate, string code, string path);

    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int GetResultType(IntPtr result);

    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl)]
    private static extern double GetNumberFromResult(IntPtr result);

    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl)]
    private static extern void ResetResult(IntPtr result);

    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl)]
    private static extern bool IdleNotificationDeadline(IntPtr isolate, double deadlineInSeconds);

    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr GetJSStackTrace(IntPtr isolate, out int length);

    public static void Run()
    {
        if (GetApiLevel() != 35)
        {
            throw new InvalidOperationException("GetApiLevel 不是 35。");
        }

        IntPtr isolate = CreateJSEngine(0);
        if (isolate == IntPtr.Zero)
        {
            throw new InvalidOperationException("CreateJSEngine 返回空指针。");
        }

        try
        {
            IntPtr result = Eval(isolate, "21 * 2", "puerts-build-smoke.js");
            if (result == IntPtr.Zero)
            {
                throw new InvalidOperationException("Eval 返回空指针。");
            }

            if (GetResultType(result) != 4)
            {
                throw new InvalidOperationException("Eval 结果不是 Number。");
            }

            double number = GetNumberFromResult(result);
            if (Math.Abs(number - 42.0) > double.Epsilon)
            {
                throw new InvalidOperationException("Eval 结果不是 42。");
            }

            ResetResult(result);

            if (!IdleNotificationDeadline(isolate, 0.0))
            {
                throw new InvalidOperationException("V8 13.8 的 IdleNotificationDeadline 兼容分支未返回 true。");
            }

            int stackLength;
            IntPtr stack = GetJSStackTrace(isolate, out stackLength);
            if (stack == IntPtr.Zero || stackLength < 0)
            {
                throw new InvalidOperationException("GetJSStackTrace 返回了无效结果。");
            }
        }
        finally
        {
            DestroyJSEngine(isolate);
        }
    }
}
"@

    $smokeType = Add-Type -TypeDefinition $source -Language CSharp -PassThru
    $smokeType::Run()
    Write-Host "Smoke 通过: $resolvedDll"
}

if ($SmokeDll) {
    Invoke-PuertsSmoke -DllPath $SmokeDll
    exit 0
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    & $FilePath @ArgumentList | ForEach-Object { Write-Host $_ }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$FailureMessage，退出码：$exitCode"
    }
}

function Resolve-VisualStudioToolchain {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (!(Test-Path -LiteralPath $vswhere)) {
        throw "找不到 vswhere.exe。"
    }

    $instances = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json |
        ConvertFrom-Json
    if (!$instances) {
        throw "找不到带 MSVC x64 工具链的 Visual Studio。"
    }

    $instance = $instances |
        Sort-Object { [version]$_.installationVersion } -Descending |
        Select-Object -First 1
    $major = ([version]$instance.installationVersion).Major
    $generatorYears = @{
        16 = "2019"
        17 = "2022"
        18 = "2026"
    }
    if (!$generatorYears.ContainsKey($major)) {
        throw "未配置 Visual Studio $major 对应的 CMake 生成器。"
    }

    $cmake = Join-Path $instance.installationPath "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
    if (!(Test-Path -LiteralPath $cmake)) {
        throw "Visual Studio 自带 CMake 不存在：$cmake"
    }

    $generator = "Visual Studio $major $($generatorYears[$major])"
    $cmakeHelp = (& $cmake --help | Out-String)
    if ($cmakeHelp -notmatch [regex]::Escape($generator)) {
        throw "$cmake 不支持生成器 $generator。"
    }

    $msvcRoot = Join-Path $instance.installationPath "VC\Tools\MSVC"
    $msvc = Get-ChildItem -LiteralPath $msvcRoot -Directory |
        Sort-Object { [version]$_.Name } -Descending |
        Select-Object -First 1
    if (!$msvc) {
        throw "找不到 MSVC 工具链目录。"
    }

    $dumpbin = Join-Path $msvc.FullName "bin\Hostx64\x64\dumpbin.exe"
    if (!(Test-Path -LiteralPath $dumpbin)) {
        throw "找不到 dumpbin.exe：$dumpbin"
    }

    [PSCustomObject]@{
        CMake = $cmake
        Dumpbin = $dumpbin
        Generator = $generator
        VisualStudioVersion = $instance.installationVersion
        VisualStudioPath = $instance.installationPath
    }
}

function Assert-PathUnderRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $absolutePath = [IO.Path]::GetFullPath($Path).TrimEnd("\")
    $absoluteRoot = [IO.Path]::GetFullPath($Root).TrimEnd("\") + "\"
    if (!$absolutePath.StartsWith($absoluteRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝清理根目录之外的路径：$absolutePath"
    }
}

function Invoke-ConfigurationBuild {
    param(
        [Parameter(Mandatory)][ValidateSet("Debug", "Release")]
        [string]$Name,
        [Parameter(Mandatory)]$Toolchain,
        [Parameter(Mandatory)][string]$NativeSource,
        [Parameter(Mandatory)][string]$BackendRoot,
        [Parameter(Mandatory)][string]$OutputRoot
    )

    $isDebug = $Name -eq "Debug"
    $cmakeConfiguration = "Release"
    $buildSuffix = if ($isDebug) { "_debug" } else { "" }
    $buildDirectory = Join-Path $NativeSource "build_win_x64_v8_13.8.258.54$buildSuffix"
    $artifactDirectory = Join-Path $OutputRoot $Name

    Assert-PathUnderRoot -Path $buildDirectory -Root $NativeSource
    Assert-PathUnderRoot -Path $artifactDirectory -Root $OutputRoot
    if (!$Incremental -and (Test-Path -LiteralPath $buildDirectory)) {
        Invoke-Checked -FilePath $Toolchain.CMake `
            -ArgumentList @("-E", "remove_directory", $buildDirectory) `
            -FailureMessage "清理 $Name 构建目录失败"
    }
    if (Test-Path -LiteralPath $artifactDirectory) {
        Invoke-Checked -FilePath $Toolchain.CMake `
            -ArgumentList @("-E", "remove_directory", $artifactDirectory) `
            -FailureMessage "清理 $Name 产物目录失败"
    }

    New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null

    $definitions = if ($isDebug) {
        "V8_94_OR_NEWER;WITH_INSPECTOR"
    } else {
        "V8_94_OR_NEWER"
    }
    $websocket = if ($isDebug) { "1" } else { "0" }
    $symbols = "OFF"

    $configureArguments = @(
        "-S", $NativeSource,
        "-B", $buildDirectory,
        "-G", $Toolchain.Generator,
        "-A", "x64",
        "-DBACKEND_DEFINITIONS=$definitions",
        "-DBACKEND_LIB_NAMES=/Lib/Win64/wee8.lib",
        "-DBACKEND_INC_NAMES=/Inc",
        "-DWITH_WEBSOCKET=$websocket",
        "-DWITH_SYMBOLS=$symbols",
        "-DJS_ENGINE=v8_13.8.258.54",
        "-DCMAKE_BUILD_TYPE=$cmakeConfiguration"
    )
    Invoke-Checked -FilePath $Toolchain.CMake `
        -ArgumentList $configureArguments `
        -FailureMessage "$Name CMake 配置失败"

    $projectFile = Join-Path $buildDirectory "puerts.vcxproj"
    if (!(Test-Path -LiteralPath $projectFile)) {
        throw "$Name 未生成 puerts.vcxproj。"
    }
    $projectText = Get-Content -Raw -LiteralPath $projectFile
    if ($isDebug) {
        if ($projectText -notmatch "\bWITH_INSPECTOR\b" -or $projectText -notmatch "\bWITH_WEBSOCKET\b") {
            throw "Debug 缺少 WITH_INSPECTOR 或 WITH_WEBSOCKET 编译定义。"
        }
    } elseif ($projectText -match "\bWITH_INSPECTOR\b" -or $projectText -match "\bWITH_WEBSOCKET\b") {
        throw "Release 意外包含 WITH_INSPECTOR 或 WITH_WEBSOCKET 编译定义。"
    }

    Invoke-Checked -FilePath $Toolchain.CMake `
        -ArgumentList @("--build", $buildDirectory, "--config", $cmakeConfiguration, "--parallel") `
        -FailureMessage "$Name 编译失败"

    $binaryDirectory = Join-Path $buildDirectory $cmakeConfiguration
    $dll = Join-Path $binaryDirectory "puerts.dll"
    if (!(Test-Path -LiteralPath $dll)) {
        throw "$Name 未生成 puerts.dll：$dll"
    }

    foreach ($extension in @("dll", "lib", "exp", "pdb")) {
        $source = Join-Path $binaryDirectory "puerts.$extension"
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination $artifactDirectory -Force
        }
    }

    $artifactDll = Join-Path $artifactDirectory "puerts.dll"
    $exportsFile = Join-Path $artifactDirectory "exports.txt"
    $dependenciesFile = Join-Path $artifactDirectory "dependencies.txt"
    & $Toolchain.Dumpbin /NOLOGO /EXPORTS $artifactDll | Set-Content -LiteralPath $exportsFile -Encoding utf8
    if ($LASTEXITCODE -ne 0) {
        throw "$Name 导出表读取失败。"
    }
    & $Toolchain.Dumpbin /NOLOGO /DEPENDENTS $artifactDll | Set-Content -LiteralPath $dependenciesFile -Encoding utf8
    if ($LASTEXITCODE -ne 0) {
        throw "$Name 依赖表读取失败。"
    }

    $exports = Get-Content -Raw -LiteralPath $exportsFile
    foreach ($requiredExport in @(
        "CreateJSEngine",
        "DestroyJSEngine",
        "Eval",
        "GetResultType",
        "GetNumberFromResult",
        "ResetResult",
        "GetJSStackTrace",
        "GetApiLevel"
    )) {
        if ($exports -notmatch "(?m)\b$([regex]::Escape($requiredExport))\b") {
            throw "$Name 缺少导出：$requiredExport"
        }
    }

    $dependencies = Get-Content -Raw -LiteralPath $dependenciesFile
    if ($dependencies -match "(?im)^\s*(v8|wee8|libc\+\+)[^\s]*\.(dll|so)\s*$") {
        throw "$Name 出现不允许的动态 V8/C++ 运行库依赖：$($Matches[0].Trim())"
    }

    $pwsh = (Get-Process -Id $PID).Path
    Invoke-Checked -FilePath $pwsh `
        -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $PSCommandPath,
            "-SmokeDll", $artifactDll
        ) `
        -FailureMessage "$Name 原生 smoke 失败"

    $files = Get-ChildItem -LiteralPath $artifactDirectory -File |
        Where-Object { $_.Extension -in @(".dll", ".lib", ".exp", ".pdb") } |
        ForEach-Object {
            [PSCustomObject]@{
                Name = $_.Name
                Length = $_.Length
                Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
        }

    [PSCustomObject]@{
        Name = $Name
        CMakeConfiguration = $cmakeConfiguration
        Inspector = $isDebug
        WebSocket = $isDebug
        Symbols = $false
        Runtime = "MultiThreaded"
        ArtifactDirectory = $artifactDirectory
        Files = @($files)
    }
}

$scriptPath = (Resolve-Path -LiteralPath $PSCommandPath).Path
$cliRoot = Split-Path -Parent $scriptPath
$unityRoot = Split-Path -Parent $cliRoot
$nativeSource = Join-Path $unityRoot "native_src"
$backendRoot = Join-Path $nativeSource ".backends\v8_13.8.258.54"
$backendLibrary = Join-Path $backendRoot "Lib\Win64\wee8.lib"
$backendHeader = Join-Path $backendRoot "Inc\v8-version.h"

foreach ($requiredPath in @($nativeSource, $backendLibrary, $backendHeader)) {
    if (!(Test-Path -LiteralPath $requiredPath)) {
        throw "缺少构建输入：$requiredPath"
    }
}

$node = Get-Command node -ErrorAction Stop
$nodeVersionText = (& $node.Source --version).Trim().TrimStart("v")
if ([version]$nodeVersionText -lt [version]"16.0.0") {
    throw "Node.js 版本必须不低于 16，当前为 $nodeVersionText。"
}

if (!$ArtifactRoot) {
    $ArtifactRoot = Join-Path $unityRoot "build-artifacts\v8_13.8.258.54\Windows\x86_64"
}
$ArtifactRoot = [IO.Path]::GetFullPath($ArtifactRoot)
New-Item -ItemType Directory -Path $ArtifactRoot -Force | Out-Null

$toolchain = Resolve-VisualStudioToolchain
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $ArtifactRoot "build-$timestamp.log"
Start-Transcript -LiteralPath $logPath | Out-Null

try {
    $names = if ($Configuration -eq "All") {
        @("Release", "Debug")
    } else {
        @($Configuration)
    }

    $results = foreach ($name in $names) {
        Write-Host "开始构建 Windows x64 $name"
        Invoke-ConfigurationBuild `
            -Name $name `
            -Toolchain $toolchain `
            -NativeSource $nativeSource `
            -BackendRoot $backendRoot `
            -OutputRoot $ArtifactRoot
    }

    $manifest = [PSCustomObject]@{
        SchemaVersion = 1
        GeneratedAt = (Get-Date).ToString("o")
        V8Version = "13.8.258.54"
        BackendLibrary = [PSCustomObject]@{
            Path = $backendLibrary
            Length = (Get-Item -LiteralPath $backendLibrary).Length
            Sha256 = (Get-FileHash -LiteralPath $backendLibrary -Algorithm SHA256).Hash
        }
        Toolchain = [PSCustomObject]@{
            VisualStudioVersion = $toolchain.VisualStudioVersion
            VisualStudioPath = $toolchain.VisualStudioPath
            Generator = $toolchain.Generator
            CMakeVersion = ((& $toolchain.CMake --version)[0] -replace "^cmake version\s+", "")
            NodeVersion = $nodeVersionText
        }
        Configurations = @($results)
    }
    $manifestPath = Join-Path $ArtifactRoot "manifest.json"
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8

    Write-Host "Windows 双配置构建与 smoke 验证完成。"
    Write-Host "产物目录：$ArtifactRoot"
    Write-Host "清单：$manifestPath"
}
finally {
    Stop-Transcript | Out-Null
}
