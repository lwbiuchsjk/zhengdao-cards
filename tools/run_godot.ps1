# 功能：统一调用本项目约定的 Godot 可执行文件。
# 说明：固定 Godot 路径，并将调用参数原样透传，避免每次会话重复说明路径。

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$GodotArgs
)

$ErrorActionPreference = "Stop"

# 说明：从 tools/local_env.json 读取本机 Godot 路径，避免硬编码。
$localEnvPath = Join-Path $PSScriptRoot "local_env.json"
if (-not (Test-Path $localEnvPath)) {
    throw "local_env.json not found: $localEnvPath`nPlease copy tools/local_env.example.json to tools/local_env.json and fill in your local paths."
}
$localEnv = Get-Content $localEnvPath -Raw | ConvertFrom-Json
$godotExe = $localEnv.godot_exe

if (-not $godotExe) {
    throw "godot_exe is missing or empty in $localEnvPath`nPlease add godot_exe to your tools/local_env.json (see tools/local_env.example.json)."
}

if (-not (Test-Path $godotExe)) {
    throw "Godot executable not found: $godotExe"
}

# 说明：默认补齐项目路径，避免在仓库根目录外调用时找不到 project.godot。
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$finalArgs = @("--path", $projectRoot)

if ($GodotArgs) {
    $finalArgs += $GodotArgs
}

& $godotExe @finalArgs
$exitCode = $LASTEXITCODE

if ($null -ne $exitCode) {
    exit $exitCode
}
