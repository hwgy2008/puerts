import crypto from 'crypto';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import childProcess from 'child_process';

const backendRoot = path.resolve(process.argv[2] ?? '');
const headersOnly = process.argv.includes('--headers-only');
const ndkRootOption = process.argv.indexOf('--ndk-root');
const ndkRoot = ndkRootOption >= 0 ? fs.realpathSync(path.resolve(process.argv[ndkRootOption + 1])) : null;
const expected = {
    'armeabi-v7a': { cliArch: 'armv7', cpu: 'arm', backendDirectory: 'armeabi-v7a', ndkTriple: 'arm-linux-androideabi', pointerCompression: false },
    'arm64-v8a': { cliArch: 'arm64', cpu: 'arm64', backendDirectory: 'arm64-v8a', ndkTriple: 'aarch64-linux-android', pointerCompression: true },
    'x86_64': { cliArch: 'x64', cpu: 'x64', backendDirectory: 'x64', ndkTriple: 'x86_64-linux-android', pointerCompression: true },
};
const expectedBuilderFiles = {
    injectionScript: { path: 'node-script/add_arraybuffer_new_without_stl.js', contentSha256LfNormalized: 'abd8fcf485c0f06e896a720b48ce3d9456f83402cd5a0cc5fce28a2d472c3326' },
    gitPatchScript: { path: 'node-script/do-gitpatch.js', contentSha256LfNormalized: '2c79d33303fef73be9c9a2242ef01866c03726c5242ee629ae990c78f3965c70' },
    libcxxSymbolMap: { path: 'v8_14_9_android_libcxx_redefinitions.txt', contentSha256LfNormalized: '86fcf1ca519c8abc2f4246604b52deb699de26c3a1e3594f531bcc9d89de9609' },
    wee8Patch: { path: 'patches/enable_wee8_v14.9.207.39.patch', contentSha256LfNormalized: 'a5a2b7e990662e86e665c2d6d6019666297147f74e3cbc1dc06f460fdf8e6598' },
    armv7Script: { path: 'android_armv7.sh', contentSha256LfNormalized: 'bc4b9bbdd035e4105a2bc22b79a39b5454b0ebf5ea7c075b52506df886acf9d3' },
    arm64Script: { path: 'android_armv8.sh', contentSha256LfNormalized: 'b7598176b606c58f5a22e8a43e4c142588a3b8a9b119f9949744c6679bb79836' },
    x64Script: { path: 'android_x64.sh', contentSha256LfNormalized: 'c347a03ee30a9fe033abcc3522f9d53b715dde998de61390b046c2cfcc1f653a' },
};
const expectedBuilderByAbi = {
    'armeabi-v7a': {
        commit: '00a2af73b38a766abc803a8fbb2e9b8be5ef6f49',
        packageScriptSha256: '3b2735254e8b5520a89541f1aa710646e0304e5a3adb9c3019d3bafb3c7758e6',
        symbolRenameScriptSha256: '4b3fa53e27cf2b32474ae8006d5e8227ea37d2cbfac276dd822b41ed626d9791',
    },
    'arm64-v8a': {
        commit: '827879a89cf90826eebdc68e36389b10511e0805',
        packageScriptSha256: 'd86a700e6cfab85e79c512cab661b25a7287cdf6580c7bae9f137103758d004f',
        symbolRenameScriptSha256: '4b3fa53e27cf2b32474ae8006d5e8227ea37d2cbfac276dd822b41ed626d9791',
        arm64ScriptSha256: 'd17cc6de34681f6ab0073d72842d8e41fe2c61260cb8e29e952aee8f570cc48f',
        x64ScriptSha256: '409bfe8329417aa180316be1634009b4f8cbe6d053ae3991e3eb3ca11e8c7de8',
    },
    'x86_64': {
        commit: '827879a89cf90826eebdc68e36389b10511e0805',
        packageScriptSha256: 'd86a700e6cfab85e79c512cab661b25a7287cdf6580c7bae9f137103758d004f',
        symbolRenameScriptSha256: '4b3fa53e27cf2b32474ae8006d5e8227ea37d2cbfac276dd822b41ed626d9791',
        arm64ScriptSha256: 'd17cc6de34681f6ab0073d72842d8e41fe2c61260cb8e29e952aee8f570cc48f',
        x64ScriptSha256: '409bfe8329417aa180316be1634009b4f8cbe6d053ae3991e3eb3ca11e8c7de8',
    },
};
const allowedV8Changes = new Set([
    'BUILD.gn',
    'DEPS',
    'include/libplatform/libplatform.h',
    'include/v8-inspector.h',
    'include/v8.h',
    'src/api/api.cc',
    'src/inspector/v8-inspector-impl.cc',
    'src/libplatform/default-platform.cc',
]);
const cliDirectory = path.dirname(fileURLToPath(import.meta.url));
const backendConfig = JSON.parse(fs.readFileSync(path.join(cliDirectory, 'backends.json'), 'utf8'))['v8_14.9.207.39'];

function fail(message) {
    throw new Error(message);
}

function sha256File(file) {
    return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function hashTree(root) {
    const files = [];
    function visit(current) {
        for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
            const fullPath = path.join(current, entry.name);
            if (entry.isDirectory()) visit(fullPath);
            else files.push(fullPath);
        }
    }
    visit(root);
    files.sort((a, b) => a.localeCompare(b, 'en'));
    const hash = crypto.createHash('sha256');
    for (const file of files) {
        hash.update(path.relative(root, file).replaceAll('\\', '/'));
        hash.update('\0');
        hash.update(fs.readFileSync(file));
        hash.update('\0');
    }
    return hash.digest('hex');
}

function readExternalSymbolInventory(llvmNm, archive) {
    const output = childProcess.execFileSync(llvmNm,
        ['--extern-only', '--format=posix', archive], {
            encoding: 'utf8',
            maxBuffer: 128 * 1024 * 1024,
        });
    const all = new Set();
    const strong = new Set();
    for (const line of output.split(/\r?\n/)) {
        const match = line.match(/^(\S+)\s+([A-Za-z?])(?:\s|$)/);
        if (!match) continue;
        all.add(match[1]);
        if (/^[ABCDGIRST]$/.test(match[2])) strong.add(match[1]);
    }
    return { all, strong };
}

function getNdkClangIdentity(version) {
    const match = version.match(/^Android \((\d+), .*?based on (r[0-9a-f]+)\) clang version ([0-9.]+) \([^)]* ([0-9a-f]{40})\)$/);
    if (!match) fail(`无法解析 NDK clang 身份：${version}`);
    return match.slice(1).join('/');
}

function getNdkFingerprint(root, ndkTriple) {
    const sourcePropertiesPath = path.join(root, 'source.properties');
    const sourceProperties = fs.readFileSync(sourcePropertiesPath, 'utf8');
    if (!/^Pkg\.Revision\s*=\s*28\.2\.13676358\s*$/m.test(sourceProperties)) {
        fail(`Android NDK 必须为 28.2.13676358：${root}`);
    }
    const host = process.platform === 'win32' ? 'windows-x86_64' : 'linux-x86_64';
    const toolchain = path.join(root, 'toolchains', 'llvm', 'prebuilt', host);
    const clang = path.join(toolchain, 'bin', process.platform === 'win32' ? 'clang++.exe' : 'clang++');
    const libcxxHeaders = path.join(toolchain, 'sysroot', 'usr', 'include', 'c++', 'v1');
    const targetSysroot = path.join(toolchain, 'sysroot', 'usr', 'lib', ndkTriple);
    return {
        revision: '28.2.13676358',
        sourcePropertiesSha256: sha256File(sourcePropertiesPath),
        ndkClangVersion: childProcess.execFileSync(clang, ['--version'], { encoding: 'utf8' }).split(/\r?\n/, 1)[0],
        libcxxHeadersSha256: hashTree(libcxxHeaders),
        targetSysrootSha256: hashTree(targetSysroot),
    };
}

if (!fs.existsSync(backendRoot)) fail(`backend 不存在：${backendRoot}`);
const includeRoot = path.join(backendRoot, 'Inc');
const v8Header = fs.readFileSync(path.join(includeRoot, 'v8.h'), 'utf8');
for (const marker of [
    '#define HAS_ARRAYBUFFER_NEW_WITHOUT_STL 1',
    '#define V8_HAS_WRAP_API_WITHOUT_STL 1',
    'ArrayBuffer_Get_Data',
]) {
    if (!v8Header.includes(marker)) fail(`Android backend 头文件缺少 ${marker}`);
}
const platformHeader = fs.readFileSync(path.join(includeRoot, 'libplatform', 'libplatform.h'), 'utf8');
for (const marker of ['NewDefaultPlatform_Without_Stl', 'DeletePlatform_Without_Stl']) {
    if (!platformHeader.includes(marker)) fail(`Android backend 平台头文件缺少 ${marker}`);
}

const headerHash = hashTree(includeRoot);
if (headersOnly) {
    console.log(JSON.stringify({ backendRoot, headerSha256: headerHash, result: 'PASS' }));
    process.exit(0);
}
let commonV8DiffSha256 = null;
let commonCompilerFingerprint = null;
let commonNdkFingerprint = null;
for (const [abi, abiExpected] of Object.entries(expected)) {
    const manifestPath = path.join(backendRoot, 'Build', 'Android', abi, 'manifest.json');
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    if (manifest.v8Version !== '14.9.207.39' ||
        manifest.v8Commit !== '1ae0b7625dee6d0aa6664f95ec4638bedb7cdad8') {
        fail(`${abi} V8 版本或 commit 不匹配`);
    }
    if (manifest.platform !== 'android' || manifest.abi !== abi ||
        manifest.backendAbiDirectory !== abiExpected.backendDirectory || manifest.targetCpu !== abiExpected.cpu) {
        fail(`${abi} 平台映射不匹配`);
    }
    if (manifest.minSdk !== 23 || manifest.ndk?.revision !== '28.2.13676358' ||
        manifest.ndk?.v8DepsCipdVersion !== '2@30.0.14608247' ||
        manifest.ndk?.v8MountPath !== 'third_party/android_toolchain/ndk' ||
        manifest.ndk?.v8MountResolvesToExternalNdk !== true) {
        fail(`${abi} Android API/NDK 不匹配`);
    }
    for (const hashName of ['sourcePropertiesSha256', 'libcxxHeadersSha256', 'targetSysrootSha256']) {
        if (!/^[0-9a-f]{64}$/.test(manifest.ndk?.[hashName] ?? '')) fail(`${abi} NDK ${hashName} 无效`);
    }
    if (typeof manifest.ndk?.ndkClangVersion !== 'string' || !manifest.ndk.ndkClangVersion.includes('clang version')) {
        fail(`${abi} NDK clang 版本指纹无效`);
    }
    if (manifest.depotToolsCommit !== 'e051c661c3785286de8623547e3a1574b989a428') {
        fail(`${abi} depot_tools 版本不匹配`);
    }
    const expectedBuilder = expectedBuilderByAbi[abi];
    if (manifest.builder?.commit !== expectedBuilder.commit || manifest.builder?.cleanWorktree !== true) {
        fail(`${abi} backend-v8 构建仓库溯源无效`);
    }
    const abiBuilderFiles = {
        ...expectedBuilderFiles,
        packageScript: {
            path: 'node-script/package_v8_14_9_android.js',
            contentSha256LfNormalized: expectedBuilder.packageScriptSha256,
        },
        symbolRenameScript: {
            path: 'rename_symbols_posix.sh',
            contentSha256LfNormalized: expectedBuilder.symbolRenameScriptSha256,
        },
    };
    if (expectedBuilder.arm64ScriptSha256) {
        abiBuilderFiles.arm64Script = {
            path: 'android_armv8.sh',
            contentSha256LfNormalized: expectedBuilder.arm64ScriptSha256,
        };
    }
    if (expectedBuilder.x64ScriptSha256) {
        abiBuilderFiles.x64Script = {
            path: 'android_x64.sh',
            contentSha256LfNormalized: expectedBuilder.x64ScriptSha256,
        };
    }
    for (const [name, expectedFile] of Object.entries(abiBuilderFiles)) {
        const actualFile = manifest.builder.files?.[name];
        if (actualFile?.path !== expectedFile.path ||
            actualFile?.contentSha256LfNormalized !== expectedFile.contentSha256LfNormalized) {
            fail(`${abi} backend-v8 构建输入 ${name} 不是已审核版本`);
        }
    }
    const changedFiles = manifest.v8SourcePatch?.changedFiles;
    if (!Array.isArray(changedFiles) || changedFiles.length === 0 ||
        changedFiles.some((file) => !allowedV8Changes.has(file))) {
        fail(`${abi} V8 源码修改清单越界`);
    }
    for (const required of [...allowedV8Changes].filter((file) => file !== 'DEPS')) {
        if (!changedFiles.includes(required)) fail(`${abi} V8 源码修改清单缺少 ${required}`);
    }
    const diffSha256 = manifest.v8SourcePatch?.diffSha256 ?? '';
    if (!/^[0-9a-f]{64}$/.test(diffSha256)) fail(`${abi} V8 源码补丁哈希无效`);
    if (commonV8DiffSha256 === null) commonV8DiffSha256 = diffSha256;
    else if (diffSha256 !== commonV8DiffSha256) fail(`${abi} V8 源码补丁与其他 ABI 不一致`);

    const compiler = manifest.compiler ?? {};
    if (compiler.kind !== 'Chromium clang++' ||
        compiler.commandPath !== 'third_party/llvm-build/Release+Asserts/bin/clang++' ||
        !/^third_party\/llvm-build\/Release\+Asserts\/bin\/clang(?:\+\+)?$/.test(compiler.resolvedPath ?? '') ||
        typeof compiler.version !== 'string' || !compiler.version.includes('clang version') ||
        !/^[0-9a-f]{64}$/.test(compiler.sha256 ?? '')) {
        fail(`${abi} 实际 backend 编译器溯源无效`);
    }
    const targetPattern = abi === 'armeabi-v7a'
        ? /^arm(?:v7a)?-linux-androideabi(?:23)?$/
        : new RegExp(`^${abiExpected.ndkTriple}(?:23)?$`);
    if (!Array.isArray(compiler.targetTriples) || !compiler.targetTriples.some((item) => targetPattern.test(item))) {
        fail(`${abi} 实际 backend 目标三元组无效`);
    }
    if ((!Array.isArray(compiler.androidApiDefines) || !compiler.androidApiDefines.includes('23')) &&
        !compiler.targetTriples.some((item) => item.endsWith('23'))) {
        fail(`${abi} 实际 backend 编译参数未证明 API 23`);
    }
    if (!Array.isArray(compiler.sysroots) ||
        !compiler.sysroots.some((item) => item.replaceAll('\\', '/').includes('third_party/android_toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/sysroot'))) {
        fail(`${abi} 实际 backend sysroot 不是固定外部 NDK`);
    }
    if (!Array.isArray(compiler.resolvedSysrootsRelativeToNdk) ||
        !compiler.resolvedSysrootsRelativeToNdk.includes('toolchains/llvm/prebuilt/linux-x86_64/sysroot')) {
        fail(`${abi} backend sysroot 的真实路径没有落入外部 NDK r28c`);
    }
    const compilerFingerprint = `${compiler.version}\n${compiler.sha256}`;
    if (commonCompilerFingerprint === null) commonCompilerFingerprint = compilerFingerprint;
    else if (compilerFingerprint !== commonCompilerFingerprint) fail(`${abi} Chromium clang 与其他 ABI 不一致`);
    const ndkFingerprint = [
        manifest.ndk.sourcePropertiesSha256,
        manifest.ndk.ndkClangVersion,
        manifest.ndk.libcxxHeadersSha256,
    ].join('\n');
    if (commonNdkFingerprint === null) commonNdkFingerprint = ndkFingerprint;
    else if (ndkFingerprint !== commonNdkFingerprint) fail(`${abi} NDK 公共工具链与其他 ABI 不一致`);
    const features = manifest.features ?? {};
    for (const enabled of [
        'maglev',
        'sparkplug',
        'turbofan',
        'customLibcxx',
        'allocatorSymbolsIsolated',
        'libcxxStrongSymbolsIsolated',
        'wholeArchiveLinkProbe',
    ]) {
        if (features[enabled] !== true) fail(`${abi} 未开启 ${enabled}`);
    }
    for (const disabled of ['sandbox', 'webAssembly', 'externalStartupData', 'i18n', 'temporal']) {
        if (features[disabled] !== false) fail(`${abi} ${disabled} 配置不符合固定方案`);
    }
    if (features.pointerCompression !== abiExpected.pointerCompression ||
        features.pointerCompressionSharedCage !== abiExpected.pointerCompression) {
        fail(`${abi} 指针压缩配置不匹配`);
    }
    if (abiExpected.pointerCompression &&
        (features.partitionAlloc !== false || features.allocatorShim !== false)) {
        fail(`${abi} 必须关闭 standalone PartitionAlloc 与 allocator shim`);
    }
    if (ndkRoot) {
        const localNdk = getNdkFingerprint(ndkRoot, abiExpected.ndkTriple);
        for (const name of ['revision', 'sourcePropertiesSha256', 'libcxxHeadersSha256', 'targetSysrootSha256']) {
            if (manifest.ndk[name] !== localNdk[name]) fail(`${abi} consumer NDK ${name} 与 backend 不一致`);
        }
        if (getNdkClangIdentity(manifest.ndk.ndkClangVersion) !== getNdkClangIdentity(localNdk.ndkClangVersion)) {
            fail(`${abi} consumer NDK clang 身份与 backend 不一致`);
        }
    }
    const library = path.join(backendRoot, ...manifest.files.library.path.split('/'));
    if (sha256File(library) !== manifest.files.library.sha256) fail(`${abi} libwee8.a 哈希不匹配`);
    if (ndkRoot) {
        const host = process.platform === 'win32' ? 'windows-x86_64' : 'linux-x86_64';
        const toolchain = path.join(ndkRoot, 'toolchains', 'llvm', 'prebuilt', host);
        const llvmNm = path.join(toolchain, 'bin', process.platform === 'win32' ? 'llvm-nm.exe' : 'llvm-nm');
        const ndkLibcxx = path.join(toolchain, 'sysroot', 'usr', 'lib', abiExpected.ndkTriple, 'libc++_static.a');
        const backendSymbols = readExternalSymbolInventory(llvmNm, library);
        const ndkSymbols = readExternalSymbolInventory(llvmNm, ndkLibcxx);
        const overlaps = [...backendSymbols.strong]
            .filter((symbol) => ndkSymbols.strong.has(symbol))
            .sort();
        if (overlaps.length !== 0) {
            fail(`${abi} libwee8.a 与 consumer NDK libc++ 存在强符号冲突：\n${overlaps.join('\n')}`);
        }
        for (const symbol of ['__real_realpath', '__real_getcwd', '__wrap_realpath', '__wrap_getcwd']) {
            if (backendSymbols.all.has(symbol)) fail(`${abi} libwee8.a 意外包含 allocator shim 符号：${symbol}`);
        }
    }
    const snapshotTool = manifest.files.snapshotTool;
    const expectedSnapshotPath = `Bin/Android/${abiExpected.backendDirectory}/mksnapshot`;
    if (snapshotTool?.path !== expectedSnapshotPath ||
        !/(^|\/)mksnapshot$/.test(snapshotTool?.sourcePath ?? '') ||
        !Number.isSafeInteger(snapshotTool?.size) || snapshotTool.size <= 0 ||
        !/^[0-9a-f]{64}$/.test(snapshotTool?.sha256 ?? '')) {
        fail(`${abi} snapshot tool 清单无效`);
    }
    const snapshotFile = path.join(backendRoot, ...snapshotTool.path.split('/'));
    if (fs.statSync(snapshotFile).size !== snapshotTool.size ||
        sha256File(snapshotFile) !== snapshotTool.sha256) {
        fail(`${abi} mksnapshot 文件与清单不匹配`);
    }
    const configuredLibraries = backendConfig?.config?.['link-libraries']?.android?.[abiExpected.cliArch] ?? [];
    if (configuredLibraries.length !== 1 || configuredLibraries[0].replace(/^\//, '') !== manifest.files.library.path) {
        fail(`${abi} backends.json 链接路径与 manifest 不一致`);
    }
    if (headerHash !== manifest.files.headers.sha256) fail(`${abi} 头文件树哈希不匹配`);
    for (const metadata of ['gnArgs', 'buildConfig', 'toolchain']) {
        const item = manifest.files[metadata];
        const file = path.join(backendRoot, ...item.path.split('/'));
        if (sha256File(file) !== item.sha256) fail(`${abi} ${metadata} 哈希不匹配`);
    }
}

console.log(JSON.stringify({
    backendRoot,
    headerSha256: headerHash,
    abis: Object.keys(expected),
    result: 'PASS',
}));
