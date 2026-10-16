$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$env:PUB_CACHE = Join-Path $repo '.toolchain/pub-cache'
$dart = Join-Path $repo '.toolchain/flutter/bin/cache/dart-sdk/bin/dart.exe'
$harness = Join-Path $PSScriptRoot 'btr_tests'
Push-Location $harness
try {
    & $dart pub get
    if ($LASTEXITCODE) { throw 'Test runner dependency resolution failed' }
    $configPath = Join-Path $harness '.dart_tool/package_config.json'
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $baseUri = [Uri]::new($configPath)
    foreach ($package in $config.packages) {
        $package.rootUri = [Uri]::new($baseUri, $package.rootUri).AbsoluteUri
    }
    $config.packages += [pscustomobject]@{
        name = 'PiliPlus'
        rootUri = [Uri]::new($repo + '/').AbsoluteUri
        packageUri = 'lib/'
        languageVersion = '3.13'
    }
    $isolatedConfig = Join-Path $harness '.dart_tool/core_package_config.json'
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $isolatedConfig -Encoding utf8
    $testPackage = $config.packages | Where-Object name -eq 'test'
    $runner = [Uri]::new([Uri]($testPackage.rootUri.TrimEnd('/') + '/'), 'bin/test.dart').LocalPath
    # Production Dart files are resolved directly from the checkout. The harness
    # excludes unrelated Flutter/native app dependencies; no source is copied.
    & $dart "--packages=$isolatedConfig" $runner (Join-Path $repo 'test/btr') --reporter expanded
    exit $LASTEXITCODE
} finally { Pop-Location }
