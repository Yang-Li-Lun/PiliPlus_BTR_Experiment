#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Compose','Verify','Setup','Core','Settings','Analyze','Native','VerifiedWrite','Build')][string]$Task,
    [string]$Python = 'python',
    [string]$Output = '.assembled/app',
    [string]$SeedRoot,
    [string]$AndroidSdk,
    [string]$JavaHome,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')][string]$BuildId,
    [switch]$ShortIpcPath
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$app = [IO.Path]::GetFullPath((Join-Path $repo $Output))
$sourceTool = Join-Path $PSScriptRoot 'btr_sources.py'
function CheckExit([string]$Message) { if ($LASTEXITCODE) { throw "$Message (exit $LASTEXITCODE)" } }
if ($Task -eq 'Compose') {
    & $Python $sourceTool compose --output $Output
    CheckExit 'Composition failed'
    return
}
& $Python $sourceTool verify --output $Output
CheckExit 'Composition verification failed'
if ($Task -eq 'Verify') { return }
if ($Task -eq 'Setup') {
    if (!$SeedRoot) { throw 'Setup requires SeedRoot in the same repository' }
    $seed = (Resolve-Path -LiteralPath $SeedRoot).Path
    $common = & git -C $repo rev-parse --path-format=absolute --git-common-dir
    CheckExit 'Cannot locate candidate repository'
    $seedCommon = & git -C $seed rev-parse --path-format=absolute --git-common-dir
    CheckExit 'Cannot locate seed repository'
    if ($common -ne $seedCommon -or $seed -eq $app) { throw 'Seed must be another checkout of the same repository' }
    $target = Join-Path $app '.toolchain'
    if (Test-Path -LiteralPath $target) { throw 'Toolchain already exists; inspect without overwriting' }
    $inputs = @('.fvmrc','pubspec.yaml','pubspec.lock') + @(Get-ChildItem -LiteralPath (Join-Path $app 'lib/scripts') -Filter '*.patch' -Recurse | ForEach-Object { [IO.Path]::GetRelativePath($app, $_.FullName) })
    foreach ($file in $inputs) {
        $other = Join-Path $seed $file
        # Git's Windows checkout may use CRLF in the seed; compare the exact
        # UTF-8 content after newline normalization, without rewriting either.
        if (!(Test-Path -LiteralPath $other) -or [IO.File]::ReadAllText((Join-Path $app $file)).Replace("`r`n","`n") -cne [IO.File]::ReadAllText($other).Replace("`r`n","`n")) { throw "Toolchain input mismatch: $file; prepare an independent SDK/cache" }
    }
    $required = (Get-Content -Raw -LiteralPath (Join-Path $app '.fvmrc') | ConvertFrom-Json).flutter
    $actual = (Get-Content -Raw -LiteralPath (Join-Path $seed '.toolchain/flutter/bin/cache/flutter.version.json') | ConvertFrom-Json).frameworkVersion
    if ($required -ne $actual) { throw 'Seed Flutter version mismatch' }
    foreach ($name in @('flutter','pub-cache','gradle-home','btr-debug.keystore')) {
        if (!(Test-Path -LiteralPath (Join-Path $seed ".toolchain/$name"))) { throw "Missing seed asset: $name" }
    }
    New-Item -ItemType Directory -Path $target | Out-Null
    foreach ($name in @('flutter','pub-cache','gradle-home')) {
        New-Item -ItemType Junction -Path (Join-Path $target $name) -Target (Join-Path $seed ".toolchain/$name") | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $seed '.toolchain/btr-debug.keystore') -Destination $target
    foreach ($file in @('android/gradlew','android/gradlew.bat','android/gradle/wrapper/gradle-wrapper.jar')) {
        $destination = Join-Path $app $file
        if (!(Test-Path -LiteralPath $destination)) { Copy-Item -LiteralPath (Join-Path $seed $file) -Destination $destination }
    }
    @{seed=$seed;flutter=$required;inputs=$inputs;sourceFingerprint=(Get-Content -Raw -LiteralPath (Join-Path $app '.btr-composition.json') | ConvertFrom-Json).sourceFingerprint} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $target 'reuse.json')
    $env:PUB_CACHE = Join-Path $app '.toolchain/pub-cache'
    $env:CI = 'true'
    Push-Location $app
    try { & "$app/.toolchain/flutter/bin/flutter.bat" pub get --offline --enforce-lockfile; CheckExit 'Locked package resolution failed' } finally { Pop-Location }
    return
}
$env:PUB_CACHE = Join-Path $app '.toolchain/pub-cache'
$env:CI = 'true'
Push-Location $app
try {
    switch ($Task) {
        'Core' { & pwsh -NoProfile -File "$app/tool/btr_test.ps1" }
        'Settings' { & pwsh -NoProfile -File "$app/tool/btr_diagnostics_flutter_test.ps1" -IncludeSettings }
        'Analyze' { & "$app/.toolchain/flutter/bin/flutter.bat" analyze --no-pub --no-fatal-infos lib test }
        'Native' { & "$app/.toolchain/flutter/bin/flutter.bat" test --no-pub test/btr/audio_task_removed_flutter.dart }
        'VerifiedWrite' {
            if (!$JavaHome) { throw 'JavaHome is required' }
            & pwsh -NoProfile -File "$app/tool/btr_verified_write_test.ps1" -JavaHome $JavaHome
        }
        'Build' {
            if (!$BuildId -or !$AndroidSdk -or !$JavaHome) { throw 'Build requires unique BuildId, AndroidSdk and JavaHome' }
            $artifactDir = Join-Path $repo "build/btr-candidates/$BuildId"
            if (Test-Path -LiteralPath $artifactDir) { throw 'Artifact directory already exists; never overwrite an existing APK' }
            $dirty = @(& git -C $repo status --porcelain=v1 --untracked-files=all)
            CheckExit 'Cannot inspect source status'
            if ($dirty.Count) { throw 'Commit the candidate before recording an APK source commit' }
            $sourceCommit = & git -C $repo rev-parse HEAD
            CheckExit 'Cannot identify source commit'
            & pwsh -NoProfile -File "$app/tool/btr_build.ps1" -AndroidSdk $AndroidSdk -JavaHome $JavaHome -BuildId $BuildId -DeviceTest -ShortIpcPath:$ShortIpcPath
            CheckExit 'ARM64 DEV build failed'
            $apk = Join-Path $app 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk'
            if (!(Test-Path -LiteralPath $apk)) { throw 'Expected ARM64 APK missing' }
            New-Item -ItemType Directory -Path $artifactDir | Out-Null
            $destination = Join-Path $artifactDir "PiliPlus-BTR-$BuildId-dev-arm64-v8a.apk"
            Copy-Item -LiteralPath $apk -Destination $destination
            $manifest = Get-Content -Raw -LiteralPath (Join-Path $repo 'integration/sources.json') | ConvertFrom-Json
            $receipt = Get-Content -Raw -LiteralPath (Join-Path $app '.btr-composition.json') | ConvertFrom-Json
            @{state='LOCAL_UNACCEPTED_CANDIDATE';sourceCommit=$sourceCommit;upstreamCommit=$manifest.upstreamCommit;behaviorBaseline=$manifest.behaviorBaseline;buildId=$BuildId;sourceFingerprint=$receipt.sourceFingerprint;apk=$destination;sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLower();bytes=(Get-Item -LiteralPath $destination).Length;deviceValidation='NOT RUN'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $artifactDir 'artifact.json')
        }
    }
    CheckExit "$Task failed"
} finally { Pop-Location }
