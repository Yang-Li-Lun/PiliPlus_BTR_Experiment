param(
    [Parameter(Mandatory)][string]$AndroidSdk,
    [Parameter(Mandatory)][string]$JavaHome,
    [switch]$ShortIpcPath,
    [switch]$DeviceTest,
    [ValidatePattern('^[A-Za-z0-9._-]+$')][string]$BuildId = 'unidentified'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$env:PUB_CACHE = Join-Path $repo '.toolchain/pub-cache'
$env:GRADLE_USER_HOME = Join-Path $repo '.toolchain/gradle-home'
$env:ANDROID_USER_HOME = Join-Path $repo '.toolchain/android-user'
$env:ANDROID_HOME = $AndroidSdk
$env:ANDROID_SDK_ROOT = $AndroidSdk
$env:JAVA_HOME = $JavaHome
$env:CI = 'true'
$env:FLUTTER_NATIVE_ASSETS = 'true'
$env:PATH = "$JavaHome/bin;" + $env:PATH
if ($ShortIpcPath) {
    $ipc = Join-Path $repo '.ipc'
    New-Item -ItemType Directory -Path $ipc -Force | Out-Null
    $env:JAVA_TOOL_OPTIONS = "-Djdk.net.unixdomain.tmpdir=$ipc"
}
$key = Join-Path $repo '.toolchain/btr-debug.keystore'
if (!(Test-Path -LiteralPath $key)) {
    throw 'Existing DEV signing key required; prepare candidate toolchain without replacing signing identity'
}
Push-Location $repo
try {
    $deviceArgs = @()
    if ($DeviceTest) { $deviceArgs += '--dart-define=BTR_DEVICE_TEST=true' }
    & "$repo/.toolchain/flutter/bin/flutter.bat" build apk --release --target-platform android-arm64 --split-per-abi --android-project-arg dev=1 --android-project-arg android.builder.sdkDownload=false "--dart-define=BTR_BUILD_ID=$BuildId" @deviceArgs --no-pub
    exit $LASTEXITCODE
} finally { Pop-Location }
