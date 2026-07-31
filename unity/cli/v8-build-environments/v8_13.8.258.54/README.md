# PuerTS 2.2.3 / V8 13.8.258.54 集成环境

PuerTS 基线是 `Unity_v2.2.3` 标签（`070c6ae9a8e8e669d2e3882e0e0815309b2d156c`）。V8 backend 的源码准备和编译已迁移到同级仓库 `D:\UGit\backend-v8`，PuerTS 仓库只保留跨版本 API 兼容、backend 同步和 DLL 构建。

## 两仓固定关系

| 项目 | 固定值 |
|---|---|
| backend-v8 commit | `bd0af0482f820c7d6142e95ab8ff69648b0ae293` |
| backend-v8 tag | `V8_13.8.258.54__260731` |
| V8 commit | `c6ef3038bf3c5c4d7cbfd17424e078606225e985` |
| V8 版本 | `13.8.258.54` |
| backend 模式 | Windows x64、静态 `wee8.lib`、Maglev On |

`backend-v8` 保存完整 V8 补丁、GN 参数、实际配置和验证 manifest；此目录保留 PuerTS DLL 构建证据。

## 固定命令

在 `D:\UGit\puerts-Unity_v2.2.3` 根目录执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File unity\cli\build-v8-13.8-backend-windows.ps1 -Jobs 4
pwsh -NoProfile -ExecutionPolicy Bypass -File unity\cli\build-v8-13.8-windows.ps1 -Configuration Debug
```

第一条会委托同级 `backend-v8` 编译，并在版本、Maglev、指针压缩、Sandbox、哈希均校验通过后同步到 `.backends`。第二条会重建 Debug DLL，并执行导出表、动态依赖和独立进程 smoke。

## 2026-07-31 完整重建结果

- 全量重建 backend 成功；新旧 `wee8.lib` 均为 167,140,130 字节，SHA256 均为 `A1C024B298C149230F36CDAF496F6F1A3DEDA58A6837E2AC67B2E4276C7F9880`，逐字节一致。
- PuerTS Debug DLL 重建、Inspector/WebSocket 配置检查、导出表检查、动态依赖检查和 smoke 全部通过。
- 新旧 DLL 均为 19,957,248 字节，导出表和依赖表一致。
- 新 DLL SHA256 为 `C7E5851128967DD154135CA344BAA6844AB6E242E0A37AC30239CFE8A7ACD3BB`；旧 DLL SHA256 为 `22E791CA18EA53DFC5B35E8ECFF5A985108BC68CD6FA64B955F1CEFC2001646B`。
- 两个 DLL 只有 6 个字节不同，位于 `0x128～0x12A` 和 `0x1243474～0x1243476`。`dumpbin /HEADERS` 已确认这两处是同一个 COFF 构建时间戳及其调试目录副本；代码、数据、大小、导出和依赖没有其他字节差异。

因此 DLL 的运行代码一致，原始 SHA256 不同仅由非确定性链接时间戳导致，不能把 raw hash 当作本次失败。

## 状态边界

- 当前固定配置：Maglev On；Pointer Compression、V8 Sandbox、External Startup Data、ICU、WebAssembly、cppgc Caged Heap 均为 Off。
- Maglev Off manifest 仅作为历史对照，不再是默认构建。
- Android 13.8 尚未编译验证。本机存在 NDK r28c 只能说明环境已安装，不能宣称 Android backend 或 `libpuerts.so` 已完成。
