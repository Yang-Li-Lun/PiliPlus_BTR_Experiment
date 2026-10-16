#Requires -Version 7.0
param([Parameter(Mandatory)][string]$SeedRoot)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$seed = (Resolve-Path -LiteralPath $SeedRoot).Path
if ($seed -eq $repo) { throw 'Seed must be a different checkout of this project' }
$candidateCommon = (& git -C $repo rev-parse --path-format=absolute --git-common-dir)
$seedCommon = (& git -C $seed rev-parse --path-format=absolute --git-common-dir)
if ($LASTEXITCODE -or $candidateCommon -ne $seedCommon) { throw 'Seed must belong to the same Git repository' }
$target = Join-Path $repo '.toolchain'
if (Test-Path -LiteralPath $target) { throw 'Candidate toolchain exists; inspect it without overwriting' }
# Cache/SDK reuse is allowed only with identical locked inputs and patch files.
$inputs = @('.fvmrc', 'pubspec.yaml', 'pubspec.lock') + @(& git -C $repo ls-files 'lib/scripts/*.patch' 'lib/scripts/material/*.patch')
foreach ($file in $inputs) {
    $a = Join-Path $repo $file
    $b = Join-Path $seed $file
    if (!(Test-Path -LiteralPath $b) -or (Get-FileHash -LiteralPath $a).Hash -ne (Get-FileHash -LiteralPath $b).Hash) {
        throw "Toolchain inputs differ: $file. Prepare an independent candidate SDK/cache for the new locked inputs."
    }
}
$sdk = Join-Path $seed '.toolchain/flutter'
$version = Get-Content -LiteralPath (Join-Path $sdk 'bin/cache/flutter.version.json') -Raw | ConvertFrom-Json
$required = (Get-Content -LiteralPath (Join-Path $repo '.fvmrc') -Raw | ConvertFrom-Json).flutter
if ($version.frameworkVersion -ne $required) { throw 'Seed Flutter version differs from .fvmrc' }
foreach ($name in @('flutter', 'pub-cache', 'gradle-home')) {
    if (!(Test-Path -LiteralPath (Join-Path $seed ".toolchain/$name"))) { throw "Missing seed toolchain: $name" }
}
$key = Join-Path $seed '.toolchain/btr-debug.keystore'
if (!(Test-Path -LiteralPath $key)) { throw 'Missing existing DEV signing key; do not silently replace signing identity' }
New-Item -ItemType Directory -Path $target | Out-Null
foreach ($name in @('flutter', 'pub-cache', 'gradle-home')) {
    New-Item -ItemType Junction -Path (Join-Path $target $name) -Target (Join-Path $seed ".toolchain/$name") | Out-Null
}
Copy-Item -LiteralPath $key -Destination (Join-Path $target 'btr-debug.keystore')
foreach ($file in @('android/gradlew', 'android/gradlew.bat', 'android/gradle/wrapper/gradle-wrapper.jar')) {
    if (!(Test-Path -LiteralPath (Join-Path $repo $file)) -and (Test-Path -LiteralPath (Join-Path $seed $file))) {
        Copy-Item -LiteralPath (Join-Path $seed $file) -Destination (Join-Path $repo $file)
    }
}
@{ seed=$seed; flutter=$required; inputs=$inputs; signingKeySHA256=(Get-FileHash -LiteralPath $key).Hash } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $target 'reuse.json') -Encoding utf8
Write-Output 'Reused matching private SDK and dependency caches; copied existing DEV key. Build outputs remain in candidate.'
Write-Output 'Do not run SDK/cache patch helpers through these junctions. Changed SDK/lock/patch inputs require an independent toolchain.'
