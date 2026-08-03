[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release", "All")]
    [string]$Configuration = "Debug",

    [switch]$Incremental,

    [string]$BackendV8Root,

    [string]$ArtifactRoot,

    [ValidatePattern('^14\.\d+\.\d+$')]
    [string]$MsvcToolsetVersion = "14.44.35207",

    [Parameter(DontShow)]
    [string]$SmokeDll
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$V8Version = "14.9.207.39"
$V8Commit = "1ae0b7625dee6d0aa6664f95ec4638bedb7cdad8"
$ExpectedV8SourceChanges = @(
    "BUILD.gn",
    "include/libplatform/libplatform.h",
    "include/v8-inspector.h",
    "include/v8.h",
    "src/api/api.cc",
    "src/inspector/v8-inspector-impl.cc",
    "src/libplatform/default-platform.cc"
)

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    & $FilePath @ArgumentList | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage，退出码：$LASTEXITCODE"
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

function Assert-ExpectedV8SourceChanges {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$Stage
    )

    $status = @(& git -C $SourceRoot status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0) {
        throw "无法在${Stage}检查 V8 源码状态。"
    }
    $actual = @($status | ForEach-Object { $_.Substring(3).Replace("\", "/") } | Sort-Object -Unique)
    $expected = @($ExpectedV8SourceChanges | Sort-Object -Unique)
    $difference = @(Compare-Object -ReferenceObject $expected -DifferenceObject $actual)
    if ($difference.Count -ne 0) {
        throw "V8 源码在${Stage}不符合 PuerTS 补丁白名单：$($difference | Out-String)"
    }
}

function Import-VisualStudioEnvironment {
    param(
        [Parameter(Mandatory)][string]$VcVarsAll,
        [Parameter(Mandatory)][string]$ToolsetVersion
    )

    $toolsetFamily = ($ToolsetVersion -split "\.")[0..1] -join "."
    $command = '"' + $VcVarsAll + '" x64 -vcvars_ver=' + $toolsetFamily + ' >nul && set'
    $lines = & $env:ComSpec /d /s /c $command
    if ($LASTEXITCODE -ne 0) {
        throw "初始化 Visual Studio x64 环境失败。"
    }

    foreach ($line in $lines) {
        $separator = $line.IndexOf("=")
        if ($separator -gt 0) {
            $name = $line.Substring(0, $separator)
            $value = $line.Substring($separator + 1)
            [Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }

    if ($env:VCToolsVersion.TrimEnd("\") -ne $ToolsetVersion) {
        throw "实际 MSVC 工具集为 $($env:VCToolsVersion)，要求 $ToolsetVersion。"
    }
}

function Resolve-Toolchain {
    param(
        [Parameter(Mandatory)][string]$BackendRoot,
        [Parameter(Mandatory)][string]$ToolsetVersion
    )

    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (!(Test-Path -LiteralPath $vswhere)) {
        throw "找不到 vswhere.exe。"
    }

    $instances = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json |
        ConvertFrom-Json
    $instance = $instances |
        Sort-Object { [version]$_.installationVersion } -Descending |
        Select-Object -First 1
    if (!$instance) {
        throw "找不到带 MSVC x64 工具链的 Visual Studio。"
    }

    $visualStudioRoot = $instance.installationPath
    $msvcRoot = Join-Path $visualStudioRoot "VC\Tools\MSVC\$ToolsetVersion"
    $cmake = Join-Path $visualStudioRoot "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
    $dumpbin = Join-Path $msvcRoot "bin\Hostx64\x64\dumpbin.exe"
    $vcVarsAll = Join-Path $visualStudioRoot "VC\Auxiliary\Build\vcvarsall.bat"

    $checkoutRoot = Join-Path $BackendRoot ".build\v8-14.9-win"
    $v8SourceRoot = Join-Path $checkoutRoot "v8"
    $ninja = Join-Path $checkoutRoot "depot_tools\ninja.bat"
    $clangCl = Join-Path $v8SourceRoot "third_party\llvm-build\Release+Asserts\bin\clang-cl.exe"
    $lldLink = Join-Path $v8SourceRoot "third_party\llvm-build\Release+Asserts\bin\lld-link.exe"
    $libcxxBuildtoolsInclude = Join-Path $v8SourceRoot "buildtools\third_party\libc++"
    $libcxxInclude = Join-Path $v8SourceRoot "third_party\libc++\src\include"
    $libcxxSourceRoot = Join-Path $v8SourceRoot "third_party\libc++\src"

    foreach ($requiredPath in @(
        $msvcRoot,
        $cmake,
        $dumpbin,
        $vcVarsAll,
        $v8SourceRoot,
        $ninja,
        $clangCl,
        $lldLink,
        $libcxxBuildtoolsInclude,
        $libcxxInclude,
        (Join-Path $libcxxSourceRoot ".git")
    )) {
        if (!(Test-Path -LiteralPath $requiredPath)) {
            throw "缺少固定工具链输入：$requiredPath"
        }
    }

    Import-VisualStudioEnvironment -VcVarsAll $vcVarsAll -ToolsetVersion $ToolsetVersion

    $actualCommit = (& git -C $v8SourceRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $V8Commit) {
        throw "V8 源码 commit 不匹配：$actualCommit"
    }
    Assert-ExpectedV8SourceChanges -SourceRoot $v8SourceRoot -Stage "PuerTS 构建前"

    [PSCustomObject]@{
        CMake = $cmake
        Dumpbin = $dumpbin
        ClangCl = $clangCl
        LldLink = $lldLink
        Ninja = $ninja
        V8SourceRoot = $v8SourceRoot
        LibcxxBuildtoolsInclude = $libcxxBuildtoolsInclude
        LibcxxInclude = $libcxxInclude
        LibcxxRevision = (& git -C $libcxxSourceRoot rev-parse HEAD).Trim()
        VisualStudioVersion = $instance.installationVersion
        VisualStudioPath = $visualStudioRoot
        MsvcToolsetVersion = $ToolsetVersion
    }
}

function Invoke-PuertsSmoke {
    param([Parameter(Mandatory)][string]$DllPath)

    $resolvedDll = (Resolve-Path -LiteralPath $DllPath).Path
    $escapedDll = $resolvedDll.Replace("\", "\\")
    $typeName = "PuertsNativeSmoke_" + [Guid]::NewGuid().ToString("N")
    $source = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

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
    private static extern IntPtr GetStringFromResult(IntPtr result, out int length);

    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl)]
    private static extern void ResetResult(IntPtr result);

    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    private static extern bool IdleNotificationDeadline(IntPtr isolate, double deadlineInSeconds);

    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr GetJSStackTrace(IntPtr isolate, out int length);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void NativeFunctionCallback(
        IntPtr plugin, IntPtr info, IntPtr self, int parameterCount, long userData);

    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    private static extern void SetGlobalFunction(
        IntPtr plugin, string name, NativeFunctionCallback callback, long data);

    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr GetV8FFIApi();

    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr pesapi_get_env(IntPtr apis, IntPtr info);

    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr pesapi_get_arg(IntPtr apis, IntPtr info, int index);

    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr pesapi_get_value_string_utf8(
        IntPtr apis, IntPtr env, IntPtr value, IntPtr buffer, ref UIntPtr bufferSize);

    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr pesapi_get_value_string_utf16(
        IntPtr apis, IntPtr env, IntPtr value, IntPtr buffer, ref UIntPtr bufferSize);

    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr pesapi_create_binary(
        IntPtr apis, IntPtr env, IntPtr buffer, UIntPtr bufferSize);

    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl)]
    private static extern void pesapi_add_return(IntPtr apis, IntPtr info, IntPtr value);

    private static readonly string[] Utf8Expected =
    {
        "Game.json",
        "\u672B\u5C3E\u4E2D\u6587",
        "emoji\uD83D\uDE00",
        "x\0y",
        "",
        "A",
        new string('a', 65536) + "\u7EC8"
    };

    private static readonly string[] Utf8Expressions =
    {
        "'Game.json'",
        "'\\u672B\\u5C3E\\u4E2D\\u6587'",
        "'emoji\\uD83D\\uDE00'",
        "'x\\u0000y'",
        "''",
        "'A'",
        "('a'.repeat(65536) + '\\u7EC8')"
    };

    private static readonly NativeFunctionCallback Utf8ProbeCallback = ProbeUtf8;
    private static readonly NativeFunctionCallback BinaryProbeCallback = ProbeBinary;
    private static int utf8ProbeIndex;
    private static string utf8ProbeFailure;
    private static int binaryProbeIndex;
    private static string binaryProbeFailure;
    private static readonly int[] BinaryLengths = { 0, 1, 15, 16, 17, 926, 2048, 65535 };

    private static void AssertBytesEqual(byte[] expected, byte[] actual, string stage)
    {
        if (expected.Length != actual.Length)
        {
            throw new InvalidOperationException(stage + " 字节长度不一致。");
        }
        for (int index = 0; index < expected.Length; ++index)
        {
            if (expected[index] != actual[index])
            {
                throw new InvalidOperationException(
                    stage + " 在字节 " + index + " 处不一致：" +
                    expected[index] + " != " + actual[index] + "。");
            }
        }
    }

    private static void ProbeUtf8(
        IntPtr plugin, IntPtr info, IntPtr self, int parameterCount, long userData)
    {
        try
        {
            if (utf8ProbeFailure != null)
            {
                return;
            }
            if (parameterCount != 1 || utf8ProbeIndex >= Utf8Expected.Length)
            {
                throw new InvalidOperationException("PESAPI UTF-8 探针调用次数或参数数量错误。");
            }

            IntPtr apis = GetV8FFIApi();
            IntPtr env = pesapi_get_env(apis, info);
            IntPtr value = pesapi_get_arg(apis, info, 0);
            UIntPtr requiredSize = UIntPtr.Zero;
            pesapi_get_value_string_utf8(apis, env, value, IntPtr.Zero, ref requiredSize);

            byte[] expected = Encoding.UTF8.GetBytes(Utf8Expected[utf8ProbeIndex]);
            if (requiredSize.ToUInt64() != (ulong)expected.Length)
            {
                throw new InvalidOperationException(
                    "PESAPI UTF-8 查询长度错误：" + requiredSize.ToUInt64() +
                    " != " + expected.Length + "。");
            }

            int allocationSize = expected.Length + 2;
            IntPtr buffer = Marshal.AllocHGlobal(allocationSize);
            try
            {
                for (int index = 0; index < allocationSize; ++index)
                {
                    Marshal.WriteByte(buffer, index, 0xA5);
                }

                UIntPtr capacity = new UIntPtr((uint)expected.Length);
                IntPtr returned = pesapi_get_value_string_utf8(
                    apis, env, value, buffer, ref capacity);
                if (returned != buffer)
                {
                    throw new InvalidOperationException("PESAPI UTF-8 写入没有返回调用方缓冲区。");
                }
                if (capacity.ToUInt64() != (ulong)expected.Length)
                {
                    throw new InvalidOperationException("PESAPI UTF-8 改变了既有 bufsize 语义。");
                }

                byte[] actual = new byte[expected.Length];
                if (actual.Length > 0)
                {
                    Marshal.Copy(buffer, actual, 0, actual.Length);
                }
                AssertBytesEqual(expected, actual, "PESAPI UTF-8 精确容量写入");

                if (Marshal.ReadByte(buffer, expected.Length) != 0xA5 ||
                    Marshal.ReadByte(buffer, expected.Length + 1) != 0xA5)
                {
                    throw new InvalidOperationException("PESAPI UTF-8 精确容量写入越界或错误追加了终止符。");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }

            UIntPtr requiredUtf16Size = UIntPtr.Zero;
            pesapi_get_value_string_utf16(
                apis, env, value, IntPtr.Zero, ref requiredUtf16Size);
            if (requiredUtf16Size.ToUInt64() != (ulong)Utf8Expected[utf8ProbeIndex].Length)
            {
                throw new InvalidOperationException("PESAPI UTF-16 查询长度错误。");
            }

            int utf16Bytes = checked((Utf8Expected[utf8ProbeIndex].Length + 1) * 2);
            IntPtr utf16Buffer = Marshal.AllocHGlobal(utf16Bytes);
            try
            {
                for (int index = 0; index < utf16Bytes; ++index)
                {
                    Marshal.WriteByte(utf16Buffer, index, 0xA5);
                }
                UIntPtr utf16Capacity = new UIntPtr((uint)Utf8Expected[utf8ProbeIndex].Length);
                IntPtr returnedUtf16 = pesapi_get_value_string_utf16(
                    apis, env, value, utf16Buffer, ref utf16Capacity);
                if (returnedUtf16 != utf16Buffer ||
                    utf16Capacity.ToUInt64() != (ulong)Utf8Expected[utf8ProbeIndex].Length)
                {
                    throw new InvalidOperationException("PESAPI UTF-16 返回值或容量语义错误。");
                }
                for (int index = 0; index < Utf8Expected[utf8ProbeIndex].Length; ++index)
                {
                    ushort actualCodeUnit = unchecked((ushort)Marshal.ReadInt16(utf16Buffer, index * 2));
                    if (actualCodeUnit != Utf8Expected[utf8ProbeIndex][index])
                    {
                        throw new InvalidOperationException(
                            "PESAPI UTF-16 在 code unit " + index + " 处不一致。");
                    }
                }
                if (Marshal.ReadByte(utf16Buffer, Utf8Expected[utf8ProbeIndex].Length * 2) != 0xA5 ||
                    Marshal.ReadByte(utf16Buffer, Utf8Expected[utf8ProbeIndex].Length * 2 + 1) != 0xA5)
                {
                    throw new InvalidOperationException("PESAPI UTF-16 精确容量写入越界。");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(utf16Buffer);
            }

            ++utf8ProbeIndex;
        }
        catch (Exception exception)
        {
            utf8ProbeFailure = exception.ToString();
        }
    }

    private static byte GetBinaryByte(int sampleIndex, int byteIndex)
    {
        return unchecked((byte)(sampleIndex * 37 + byteIndex * 13 + 11));
    }

    private static void ProbeBinary(
        IntPtr plugin, IntPtr info, IntPtr self, int parameterCount, long userData)
    {
        IntPtr source = IntPtr.Zero;
        try
        {
            if (binaryProbeFailure != null)
            {
                return;
            }
            if (parameterCount != 0 || binaryProbeIndex >= BinaryLengths.Length)
            {
                throw new InvalidOperationException("PESAPI Binary 探针调用次数或参数数量错误。");
            }

            int length = BinaryLengths[binaryProbeIndex];
            if (length > 0)
            {
                source = Marshal.AllocHGlobal(length);
                for (int index = 0; index < length; ++index)
                {
                    Marshal.WriteByte(source, index, GetBinaryByte(binaryProbeIndex, index));
                }
            }

            IntPtr apis = GetV8FFIApi();
            IntPtr env = pesapi_get_env(apis, info);
            IntPtr value = pesapi_create_binary(
                apis, env, source, new UIntPtr((uint)length));
            if (value == IntPtr.Zero)
            {
                throw new InvalidOperationException("pesapi_create_binary 返回空值。");
            }

            if (length > 0)
            {
                for (int index = 0; index < length; ++index)
                {
                    Marshal.WriteByte(source, index, 0xDD);
                }
                Marshal.FreeHGlobal(source);
                source = IntPtr.Zero;
            }

            pesapi_add_return(apis, info, value);
            ++binaryProbeIndex;
        }
        catch (Exception exception)
        {
            binaryProbeFailure = exception.ToString();
        }
        finally
        {
            if (source != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(source);
            }
        }
    }

    private static void VerifyPesapiBinaryCopy(IntPtr isolate)
    {
        binaryProbeIndex = 0;
        binaryProbeFailure = null;
        SetGlobalFunction(isolate, "__puertsBinaryProbe", BinaryProbeCallback, 0);

        string script = "(() => { const lengths = [0,1,15,16,17,926,2048,65535];" +
            "for (let sample = 0; sample < lengths.length; ++sample) {" +
            "const bytes = new Uint8Array(__puertsBinaryProbe());" +
            "if (bytes.length !== lengths[sample]) throw new Error('binary length ' + sample);" +
            "for (let index = 0; index < bytes.length; ++index) {" +
            "const expected = (sample * 37 + index * 13 + 11) & 255;" +
            "if (bytes[index] !== expected) throw new Error('binary byte ' + sample + ':' + index);" +
            "}} return 1; })()";
        IntPtr result = Eval(isolate, script, "puerts-pesapi-binary-copy-smoke.js");
        if (result == IntPtr.Zero || GetResultType(result) != 4 ||
            Math.Abs(GetNumberFromResult(result) - 1.0) > double.Epsilon)
        {
            throw new InvalidOperationException("PESAPI Binary 复制语义 Smoke 执行失败。");
        }
        ResetResult(result);

        if (binaryProbeFailure != null)
        {
            throw new InvalidOperationException(binaryProbeFailure);
        }
        if (binaryProbeIndex != BinaryLengths.Length)
        {
            throw new InvalidOperationException("PESAPI Binary Smoke 未执行全部样本。");
        }
    }

    private static void VerifyPesapiUtf8(IntPtr isolate)
    {
        utf8ProbeIndex = 0;
        utf8ProbeFailure = null;
        SetGlobalFunction(isolate, "__puertsUtf8Probe", Utf8ProbeCallback, 0);

        string script = string.Empty;
        for (int index = 0; index < Utf8Expressions.Length; ++index)
        {
            script += "__puertsUtf8Probe(" + Utf8Expressions[index] + ");";
        }
        IntPtr result = Eval(isolate, script, "puerts-pesapi-utf8-smoke.js");
        if (result == IntPtr.Zero)
        {
            throw new InvalidOperationException("PESAPI UTF-8 Smoke 执行失败。");
        }
        ResetResult(result);

        if (utf8ProbeFailure != null)
        {
            throw new InvalidOperationException(utf8ProbeFailure);
        }
        if (utf8ProbeIndex != Utf8Expected.Length)
        {
            throw new InvalidOperationException("PESAPI UTF-8 Smoke 未执行全部样本。");
        }
    }

    private static void VerifyCStringResults(IntPtr isolate)
    {
        for (int index = 0; index < Utf8Expressions.Length; ++index)
        {
            IntPtr result = Eval(isolate, Utf8Expressions[index], "puerts-cstring-utf8-smoke.js");
            if (result == IntPtr.Zero || GetResultType(result) != 8)
            {
                throw new InvalidOperationException("C 字符串 UTF-8 Smoke 没有返回 String。");
            }

            try
            {
                byte[] expected = Encoding.UTF8.GetBytes(Utf8Expected[index]);
                int length;
                IntPtr nativeString = GetStringFromResult(result, out length);
                if (nativeString == IntPtr.Zero || length != expected.Length)
                {
                    throw new InvalidOperationException("C 字符串 UTF-8 长度错误。");
                }

                byte[] actual = new byte[length];
                if (actual.Length > 0)
                {
                    Marshal.Copy(nativeString, actual, 0, actual.Length);
                }
                AssertBytesEqual(expected, actual, "C 字符串 UTF-8 写入");
                if (Marshal.ReadByte(nativeString, length) != 0)
                {
                    throw new InvalidOperationException("C 字符串 UTF-8 缺少结尾终止符。");
                }
            }
            finally
            {
                ResetResult(result);
            }
        }
    }

    public static void Run()
    {
        if (GetApiLevel() != 35)
        {
            throw new InvalidOperationException("GetApiLevel 不是 35。");
        }

        for (int cycle = 0; cycle < 20; ++cycle)
        {
            IntPtr isolate = CreateJSEngine(0);
            if (isolate == IntPtr.Zero)
            {
                throw new InvalidOperationException("CreateJSEngine 返回空指针。");
            }

            try
            {
                IntPtr result = Eval(isolate, "21 * 2", "puerts-build-smoke.js");
                if (result == IntPtr.Zero || GetResultType(result) != 4)
                {
                    throw new InvalidOperationException("Eval 没有返回 Number。");
                }
                if (Math.Abs(GetNumberFromResult(result) - 42.0) > double.Epsilon)
                {
                    throw new InvalidOperationException("Eval 结果不是 42。");
                }
                ResetResult(result);

                VerifyPesapiUtf8(isolate);
                VerifyPesapiBinaryCopy(isolate);
                VerifyCStringResults(isolate);

                if (!IdleNotificationDeadline(isolate, 0.0))
                {
                    throw new InvalidOperationException("IdleNotificationDeadline 未返回 true。");
                }

                int stackLength;
                IntPtr stack = GetJSStackTrace(isolate, out stackLength);
                if (stack == IntPtr.Zero || stackLength < 0)
                {
                    throw new InvalidOperationException("GetJSStackTrace 返回无效结果。");
                }
            }
            finally
            {
                DestroyJSEngine(isolate);
            }
        }
    }
}
"@

    $compiledTypes = @(Add-Type -TypeDefinition $source -Language CSharp -PassThru)
    $smokeType = $compiledTypes | Where-Object { $_.FullName -eq $typeName } | Select-Object -First 1
    if (!$smokeType) {
        throw "Smoke 主类型编译后未找到：$typeName"
    }
    $smokeType::Run()
    Write-Host "Smoke 通过：$resolvedDll"
}

function Invoke-ConfigurationBuild {
    param(
        [Parameter(Mandatory)][ValidateSet("Debug", "Release")][string]$Name,
        [Parameter(Mandatory)]$Toolchain,
        [Parameter(Mandatory)][string]$NativeSource,
        [Parameter(Mandatory)][string]$BackendRoot,
        [Parameter(Mandatory)][string]$OutputRoot
    )

    $isDebug = $Name -eq "Debug"
    $suffix = if ($isDebug) { "_debug" } else { "" }
    $buildDirectory = Join-Path $NativeSource "build_win_x64_v8_14.9.207.39$suffix"
    $artifactDirectory = Join-Path $OutputRoot $Name

    Assert-PathUnderRoot -Path $buildDirectory -Root $NativeSource
    Assert-PathUnderRoot -Path $artifactDirectory -Root $OutputRoot
    if (!$Incremental -and (Test-Path -LiteralPath $buildDirectory)) {
        Invoke-Checked $Toolchain.CMake @("-E", "remove_directory", $buildDirectory) "清理 $Name 构建目录失败"
    }
    if (Test-Path -LiteralPath $artifactDirectory) {
        Invoke-Checked $Toolchain.CMake @("-E", "remove_directory", $artifactDirectory) "清理 $Name 产物目录失败"
    }
    New-Item -ItemType Directory -Force -Path $buildDirectory, $artifactDirectory | Out-Null

    $definitions = @(
        "CR_LIBCXX_REVISION=$($Toolchain.LibcxxRevision)",
        "V8_94_OR_NEWER",
        "V8_ARRAY_BUFFER_INTERNAL_FIELD_COUNT=0",
        "V8_ARRAY_BUFFER_VIEW_INTERNAL_FIELD_COUNT=0",
        "V8_PROMISE_INTERNAL_FIELD_COUNT=0",
        "V8_USE_DEFAULT_HASHER_SECRET=true",
        "V8_COMPRESS_POINTERS",
        "V8_COMPRESS_POINTERS_IN_SHARED_CAGE",
        "V8_31BIT_SMIS_ON_64BIT_ARCH",
        "V8_DEPRECATION_WARNINGS",
        "V8_IMMINENT_DEPRECATION_WARNINGS",
        "V8_HAVE_TARGET_OS",
        "V8_TARGET_OS_WIN",
        "_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS",
        "_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE",
        "_LIBCPP_INSTRUMENTED_WITH_ASAN=0"
    )
    if ($isDebug) {
        $definitions += @("WITH_INSPECTOR")
    }

    $cxxFlags = @(
        "/utf-8",
        "/Zc:__cplusplus",
        "/Zc:twoPhase",
        "/bigobj",
        "/EHsc",
        "/GR",
        "/MT",
        "/WX",
        "/Brepro",
        "-fmsc-version=1934",
        "-I$($Toolchain.LibcxxBuildtoolsInclude)",
        "-I$($Toolchain.LibcxxInclude)"
    ) -join " "
    $cFlags = "/utf-8 /MT /WX /Brepro -fmsc-version=1934"

    $configureArguments = @(
        "-S", $NativeSource,
        "-B", $buildDirectory,
        "-G", "Ninja",
        "-DCMAKE_MAKE_PROGRAM=$($Toolchain.Ninja)",
        "-DCMAKE_C_COMPILER=$($Toolchain.ClangCl)",
        "-DCMAKE_CXX_COMPILER=$($Toolchain.ClangCl)",
        "-DCMAKE_LINKER=$($Toolchain.LldLink)",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
        "-DCMAKE_CXX_STANDARD=20",
        "-DCMAKE_CXX_STANDARD_REQUIRED=ON",
        "-DCMAKE_C_FLAGS=$cFlags",
        "-DCMAKE_CXX_FLAGS=$cxxFlags",
        "-DCMAKE_SHARED_LINKER_FLAGS=/BREPRO",
        "-DBACKEND_DEFINITIONS=$($definitions -join ';')",
        "-DBACKEND_LIB_NAMES=/Lib/Win64/wee8.lib;/Lib/Win64/libc++.lib;/Lib/Win64/clang_rt.builtins-x86_64.lib",
        "-DBACKEND_INC_NAMES=/Inc",
        "-DWITH_WEBSOCKET=$(if ($isDebug) { 1 } else { 0 })",
        "-DWITH_SYMBOLS=OFF",
        "-DJS_ENGINE=v8_14.9.207.39"
    )
    Invoke-Checked $Toolchain.CMake $configureArguments "$Name CMake 配置失败"

    $cachePath = Join-Path $buildDirectory "CMakeCache.txt"
    $ninjaPath = Join-Path $buildDirectory "build.ninja"
    $cache = Get-Content -Raw -LiteralPath $cachePath
    $ninja = Get-Content -Raw -LiteralPath $ninjaPath
    foreach ($requiredText in @(
        $Toolchain.ClangCl,
        $Toolchain.LldLink,
        $Toolchain.LibcxxBuildtoolsInclude,
        $Toolchain.LibcxxInclude,
        "libc++.lib",
        "clang_rt.builtins-x86_64.lib",
        "CR_LIBCXX_REVISION=$($Toolchain.LibcxxRevision)",
        "_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS",
        "_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE",
        "_LIBCPP_INSTRUMENTED_WITH_ASAN=0",
        "V8_COMPRESS_POINTERS",
        "V8_COMPRESS_POINTERS_IN_SHARED_CAGE"
    )) {
        $normalizedRequiredText = $requiredText.Replace("\", "/")
        $normalizedCache = $cache.Replace("\", "/")
        $normalizedNinja = $ninja.Replace("\", "/")
        if (
            $normalizedCache -notmatch [regex]::Escape($normalizedRequiredText) -and
            $normalizedNinja -notmatch [regex]::Escape($normalizedRequiredText)
        ) {
            throw "$Name 生成结果缺少固定配置：$requiredText"
        }
    }
    if ($ninja -match "\bV8_ENABLE_SANDBOX\b") {
        throw "$Name 意外启用了 V8 Sandbox。"
    }

    Invoke-Checked $Toolchain.CMake @("--build", $buildDirectory, "--parallel") "$Name 编译失败"

    $dll = Join-Path $buildDirectory "puerts.dll"
    if (!(Test-Path -LiteralPath $dll)) {
        $dll = Get-ChildItem -LiteralPath $buildDirectory -Filter "puerts.dll" -Recurse |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if (!$dll -or !(Test-Path -LiteralPath $dll)) {
        throw "$Name 未生成 puerts.dll。"
    }

    foreach ($extension in @("dll", "lib", "exp", "pdb")) {
        $source = Join-Path (Split-Path -Parent $dll) "puerts.$extension"
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination $artifactDirectory -Force
        }
    }

    $artifactDll = Join-Path $artifactDirectory "puerts.dll"
    $exportsFile = Join-Path $artifactDirectory "exports.txt"
    $dependenciesFile = Join-Path $artifactDirectory "dependencies.txt"
    & $Toolchain.Dumpbin /NOLOGO /EXPORTS $artifactDll |
        Set-Content -LiteralPath $exportsFile -Encoding utf8
    if ($LASTEXITCODE -ne 0) {
        throw "$Name 导出表读取失败。"
    }
    & $Toolchain.Dumpbin /NOLOGO /DEPENDENTS $artifactDll |
        Set-Content -LiteralPath $dependenciesFile -Encoding utf8
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
    Invoke-Checked $pwsh @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $PSCommandPath,
        "-SmokeDll", $artifactDll
    ) "$Name 原生 smoke 失败"

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
        NativeCodegen = "Release"
        Inspector = $isDebug
        WebSocket = $isDebug
        Runtime = "MultiThreaded"
        PointerCompression = $true
        Sandbox = $false
        ArtifactDirectory = $artifactDirectory
        Files = @($files)
    }
}

if ($SmokeDll) {
    Invoke-PuertsSmoke -DllPath $SmokeDll
    exit 0
}

$scriptPath = (Resolve-Path -LiteralPath $PSCommandPath).Path
$cliRoot = Split-Path -Parent $scriptPath
$unityRoot = Split-Path -Parent $cliRoot
$repositoryRoot = Split-Path -Parent $unityRoot
$ugitRoot = Split-Path -Parent $repositoryRoot
$nativeSource = Join-Path $unityRoot "native_src"

if (!$BackendV8Root) {
    $BackendV8Root = Join-Path $ugitRoot "backend-v8"
}
$BackendV8Root = [IO.Path]::GetFullPath($BackendV8Root)
$backendRoot = Join-Path $nativeSource ".backends\v8_14.9.207.39"
$backendLibrary = Join-Path $backendRoot "Lib\Win64\wee8.lib"
$backendCxxRuntimeLibrary = Join-Path $backendRoot "Lib\Win64\libc++.lib"
$backendClangBuiltinsLibrary = Join-Path $backendRoot "Lib\Win64\clang_rt.builtins-x86_64.lib"
$backendHeader = Join-Path $backendRoot "Inc\v8-version.h"
$backendManifestPath = Join-Path $BackendV8Root ".build\artifacts\v8_14.9.207.39\manifest.json"

foreach ($requiredPath in @(
    $nativeSource,
    $backendLibrary,
    $backendCxxRuntimeLibrary,
    $backendClangBuiltinsLibrary,
    $backendHeader,
    $backendManifestPath
)) {
    if (!(Test-Path -LiteralPath $requiredPath)) {
        throw "缺少构建输入：$requiredPath"
    }
}

$backendManifest = Get-Content -Raw -LiteralPath $backendManifestPath | ConvertFrom-Json
$manifestSourceChanges = @($backendManifest.V8SourceChanges | Sort-Object -Unique)
$sourceChangesDifference = @(
    Compare-Object `
        -ReferenceObject @($ExpectedV8SourceChanges | Sort-Object -Unique) `
        -DifferenceObject $manifestSourceChanges
)
if (
    $backendManifest.V8Version -ne $V8Version -or
    $backendManifest.V8Commit -ne $V8Commit -or
    $backendManifest.BackendTarget -ne "wee8" -or
    $backendManifest.BackendCompatibility -ne "PuerTSWithoutStl" -or
    $backendManifest.V8SourceModified -ne $true -or
    $backendManifest.Compiler -ne "clang-cl" -or
    $backendManifest.CxxStandardLibrary -ne "Chromium libc++" -or
    $backendManifest.PointerCompression -ne $true -or
    $backendManifest.SharedCage -ne $true -or
    $backendManifest.Sandbox -ne $false -or
    $backendManifest.Maglev -ne $true -or
    $sourceChangesDifference.Count -ne 0
) {
    throw "backend-v8 manifest 与 V8 14.9 指针压缩构建契约不一致。"
}
$backendHash = (Get-FileHash -LiteralPath $backendLibrary -Algorithm SHA256).Hash
if ($backendHash -ne $backendManifest.Library.Sha256) {
    throw "PuerTS backend 中的 wee8.lib 与 backend-v8 manifest 哈希不一致。"
}
$backendCxxRuntimeHash = (Get-FileHash -LiteralPath $backendCxxRuntimeLibrary -Algorithm SHA256).Hash
if ($backendCxxRuntimeHash -ne $backendManifest.CxxRuntimeLibrary.Sha256) {
    throw "PuerTS backend 中的 libc++.lib 与 backend-v8 manifest 哈希不一致。"
}
$backendClangBuiltinsHash = (Get-FileHash -LiteralPath $backendClangBuiltinsLibrary -Algorithm SHA256).Hash
if ($backendClangBuiltinsHash -ne $backendManifest.ClangBuiltinsLibrary.Sha256) {
    throw "PuerTS backend 中的 clang builtins 与 backend-v8 manifest 哈希不一致。"
}

if (!$ArtifactRoot) {
    $ArtifactRoot = Join-Path $unityRoot "build-artifacts\v8_14.9.207.39\Windows\x86_64"
}
$ArtifactRoot = [IO.Path]::GetFullPath($ArtifactRoot)
New-Item -ItemType Directory -Force -Path $ArtifactRoot | Out-Null

$toolchain = Resolve-Toolchain -BackendRoot $BackendV8Root -ToolsetVersion $MsvcToolsetVersion
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $ArtifactRoot "build-$timestamp.log"
Start-Transcript -LiteralPath $logPath | Out-Null

try {
    $names = if ($Configuration -eq "All") { @("Release", "Debug") } else { @($Configuration) }
    $results = foreach ($name in $names) {
        Write-Host "开始构建 Windows x64 $name（V8 指针压缩开启）"
        Invoke-ConfigurationBuild `
            -Name $name `
            -Toolchain $toolchain `
            -NativeSource $nativeSource `
            -BackendRoot $backendRoot `
            -OutputRoot $ArtifactRoot
    }

    Assert-ExpectedV8SourceChanges -SourceRoot $toolchain.V8SourceRoot -Stage "PuerTS 构建后"

    $manifest = [PSCustomObject]@{
        SchemaVersion = 2
        GeneratedAt = (Get-Date).ToString("o")
        V8Version = $V8Version
        V8Commit = $V8Commit
        BackendTarget = "wee8"
        BackendCompatibility = "PuerTSWithoutStl"
        BackendLibrarySha256 = $backendHash
        CxxRuntimeLibrarySha256 = $backendCxxRuntimeHash
        ClangBuiltinsLibrarySha256 = $backendClangBuiltinsHash
        V8Compiler = "clang-cl"
        PuertsCompiler = "clang-cl"
        CxxStandardLibrary = "Chromium libc++"
        LibcxxRevision = $toolchain.LibcxxRevision
        LibcxxHardeningMode = "EXTENSIVE"
        MsvcToolsetVersion = $MsvcToolsetVersion
        VisualStudioVersion = $toolchain.VisualStudioVersion
        PointerCompression = $true
        SharedCage = $true
        Sandbox = $false
        Maglev = $true
        WarningsAsErrors = $true
        ReproducibleBuild = $true
        V8SourceClean = $false
        V8SourceModified = $true
        V8SourceChanges = $ExpectedV8SourceChanges
        Configurations = @($results)
    }
    $manifestPath = Join-Path $ArtifactRoot "manifest.json"
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8

    Write-Host "PuerTS V8 14.9 指针压缩版构建与 smoke 验证完成。"
    Write-Host "产物目录：$ArtifactRoot"
    Write-Host "清单：$manifestPath"
}
finally {
    Stop-Transcript | Out-Null
}
