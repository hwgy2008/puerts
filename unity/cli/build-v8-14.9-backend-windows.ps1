[CmdletBinding()]
param(
    [ValidateRange(1, 32)]
    [int]$Jobs = 4,

    [switch]$Incremental,

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

$backendBuildScript = Join-Path $BackendV8Root "build-v8-14.9-windows.ps1"
$syncScript = Join-Path $cliRoot "sync-v8-14.9-backend-windows.ps1"
foreach ($requiredPath in @($backendBuildScript, $syncScript)) {
    if (!(Test-Path -LiteralPath $requiredPath)) {
        throw "缺少固定构建入口：$requiredPath"
    }
}

$pwsh = (Get-Process -Id $PID).Path
$arguments = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $backendBuildScript,
    "-Jobs",
    $Jobs.ToString()
)
if ($Incremental) {
    $arguments += "-Incremental"
}

& $pwsh @arguments
if ($LASTEXITCODE -ne 0) {
    throw "backend-v8 构建失败，退出码：$LASTEXITCODE"
}

& $pwsh -NoProfile -ExecutionPolicy Bypass `
    -File $syncScript `
    -BackendV8Root $BackendV8Root
if ($LASTEXITCODE -ne 0) {
    throw "backend-v8 产物同步失败，退出码：$LASTEXITCODE"
}

Write-Host "V8 14.9 Maglev On backend 已由 backend-v8 构建并同步到 PuerTS。"
