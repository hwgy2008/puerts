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
    wee8Patch: { path: 'patches/enable_wee8_v14.9.207.39.patch', contentSha256LfNormalized: 'a5a2b7e990662e86e665c2d6d6019666297147f74e3cbc1dc06f460fdf8e6598' },
    armv7Script: { path: 'android_armv7.sh', contentSha256LfNormalized: '7cd8cdffa834ce3e01e690d318658afa2d150861256367c3651f068e2d614fc0' },
    arm64Script: { path: 'android_armv8.sh', contentSha256LfNormalized: 'aaef73742d93a2a67a69d496b45ff5fd9f3ef034492350c9c4a5fcc445bbf4b8' },
    x64Script: { path: 'android_x64.sh', contentSha256LfNormalized: 'a851b9b614f206f6aadf93a54a9f5c5fc4671d54449aad8769f78473b2bd8039' },
};
const expectedBuilderByAbi = {
    'armeabi-v7a': {
        commit: 'c0217135f0a0d1df6fe9b19905812885af5dde2e',
        packageScriptSha256: '92d86edd9b05a2c7feb6b75a88ea7057431a093671b4a50bfcb4313a584bae34',
        symbolRenameScriptSha256: '73605b46470453a08571a8213169dad770e583ed0832e07cd28d98ee3e38cb57',
    },
    'arm64-v8a': {
        commit: 'afb00d0dad9bf475de086ecb29b9a3e49e02d760',
        packageScriptSha256: '65494569b83f3af98f216bb725e5837efe34dfb7594e7b1919fb329aabf43225',
        symbolRenameScriptSha256: 'e7bc4b54cff1630dd4b359bef936655395a9996baf056f7bcf03fe7cb3fb9f14',
    },
    'x86_64': {
        commit: 'afb00d0dad9bf475de086ecb29b9a3e49e02d760',
        packageScriptSha256: '65494569b83f3af98f216bb725e5837efe34dfb7594e7b1919fb329aabf43225',
        symbolRenameScriptSha256: 'e7bc4b54cff1630dd4b359bef936655395a9996baf056f7bcf03fe7cb3fb9f14',
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
    for (const enabled of ['maglev', 'sparkplug', 'turbofan', 'customLibcxx', 'allocatorSymbolsIsolated']) {
        if (features[enabled] !== true) fail(`${abi} 未开启 ${enabled}`);
    }
    for (const disabled of ['sandbox', 'webAssembly', 'externalStartupData', 'i18n', 'temporal']) {
        if (features[disabled] !== false) fail(`${abi} ${disabled} 配置不符合固定方案`);
    }
    if (features.pointerCompression !== abiExpected.pointerCompression ||
        features.pointerCompressionSharedCage !== abiExpected.pointerCompression) {
        fail(`${abi} 指针压缩配置不匹配`);
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
