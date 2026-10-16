param(
    [Parameter(Mandatory)][string]$AndroidSdk,
    [Parameter(Mandatory)][string]$JavaHome,
    [switch]$ShortIpcPath
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
    & "$JavaHome/bin/keytool.exe" -genkeypair -keystore $key -storepass android -keypass android -alias androiddebugkey -dname 'CN=BTR Experiment Dev,O=Local Experiment,C=TW' -keyalg RSA -keysize 2048 -validity 10000
    if ($LASTEXITCODE) { throw 'Local development key generation failed' }
}
Push-Location $repo
try {
    & "$repo/.toolchain/flutter/bin/flutter.bat" build apk --release --target-platform android-arm64 --split-per-abi --android-project-arg dev=1 --android-project-arg android.builder.sdkDownload=false --no-pub
    exit $LASTEXITCODE
} finally { Pop-Location }
