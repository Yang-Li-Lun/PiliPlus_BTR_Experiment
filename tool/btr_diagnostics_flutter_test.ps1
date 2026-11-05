#Requires -Version 7.0
param([switch]$IncludeSettings)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$env:PUB_CACHE = Join-Path $repo '.toolchain/pub-cache'
$env:CI = 'true'
$flutter = Join-Path $repo '.toolchain/flutter/bin/flutter.bat'
$harness = Join-Path $repo 'tool/btr_tests/.dart_tool/diagnostics-flutter'
New-Item -ItemType Directory -Path $harness -Force | Out-Null
# An isolated channel-contract harness avoids unrelated cnativeapi host assets.
# It runs the actual production exporter with a mock channel, not Android SAF.
$lock = Get-Content -Raw -LiteralPath (Join-Path $repo 'pubspec.lock')
function LockedVersion([string]$Name) {
    $match = [regex]::Match($lock, "(?ms)^  ${Name}:\r?\n.*?^    version: `"([^`"]+)`"")
    if (!$match.Success) { throw "Missing locked package version: $Name" }
    return $match.Groups[1].Value
}
$filePicker = LockedVersion 'file_picker'
$pathProvider = LockedVersion 'path_provider'
$settingsDependency = ''
if ($IncludeSettings) {
    # Reuse the already patched, locked Material UI package from this checkout.
    $appConfigPath = Join-Path $repo '.dart_tool/package_config.json'
    $appConfig = Get-Content -Raw -LiteralPath $appConfigPath | ConvertFrom-Json
    $material = $appConfig.packages | Where-Object name -eq 'material_ui'
    if (!$material) { throw 'Resolve the locked app packages before settings UI tests' }
    $materialPath = [Uri]::new([Uri]::new($appConfigPath), $material.rootUri).LocalPath.Replace('\','/')
    $settingsDependency = "  material_ui:`n    path: '$materialPath'"
}
@"
name: btr_diagnostic_channel_tests
publish_to: none
environment:
  sdk: '>=3.13.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
  file_picker: $filePicker
  path_provider: $pathProvider
$settingsDependency
dev_dependencies:
  flutter_test:
    sdk: flutter
"@ | Set-Content -LiteralPath (Join-Path $harness 'pubspec.yaml') -Encoding utf8
Push-Location $harness
try {
    & $flutter pub get --offline
    if ($LASTEXITCODE) { throw 'Isolated Flutter dependencies unavailable in existing cache' }
    $path = Join-Path $harness '.dart_tool/package_config.json'
    $config = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    $config.packages += [pscustomobject]@{
        name = 'PiliPlus'
        rootUri = [Uri]::new($repo + '/').AbsoluteUri
        packageUri = 'lib/'
        languageVersion = '3.13'
    }
    $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding utf8
    $cases = @((Join-Path $repo 'test/btr/diagnostics_export_flutter.dart'))
    if ($IncludeSettings) { $cases += Join-Path $repo 'test/btr/settings_page_flutter.dart' }
    & $flutter test --no-pub @cases
    exit $LASTEXITCODE
} finally { Pop-Location }
