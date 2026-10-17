#Requires -Version 7.0
param([Parameter(Mandatory)][string]$JavaHome)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$cache = Join-Path $repo '.toolchain/gradle-home/caches/modules-2/files-2.1'
function CachedJar([string]$module, [string]$version) {
    $path = Join-Path $cache "$module/$version"
    $jar = Get-ChildItem -LiteralPath $path -Recurse -Filter '*.jar' | Select-Object -First 1
    if (!$jar) { throw "Missing existing Kotlin test dependency: $module $version" }
    return $jar.FullName
}
$stdlib = CachedJar 'org.jetbrains.kotlin/kotlin-stdlib' '2.4.0'
$jars = @(
    (CachedJar 'org.jetbrains.kotlin/kotlin-compiler-embeddable' '2.4.0'),
    $stdlib,
    (CachedJar 'org.jetbrains.kotlin/kotlin-script-runtime' '2.4.0'),
    (CachedJar 'org.jetbrains.kotlin/kotlin-reflect' '1.6.10'),
    (CachedJar 'org.jetbrains/annotations' '13.0'),
    (CachedJar 'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm' '1.8.0')
)
$output = Join-Path $repo 'tool/btr_tests/.dart_tool/verified-write'
New-Item -ItemType Directory -Path $output -Force | Out-Null
& "$JavaHome/bin/java.exe" -cp ($jars -join ';') org.jetbrains.kotlin.cli.jvm.K2JVMCompiler `
    -no-stdlib -no-reflect -jvm-target 17 -classpath "$stdlib;$($jars[4])" -d "$output/cases.jar" `
    (Join-Path $repo 'android/app/src/main/kotlin/com/example/piliplus/BtrVerifiedWrite.kt') `
    (Join-Path $PSScriptRoot 'btr_tests/verified_write_test.kt')
if ($LASTEXITCODE) { throw 'Production I/O verifier JVM test compilation failed' }
& "$JavaHome/bin/java.exe" -cp "$output/cases.jar;$stdlib" com.example.piliplus.Verified_write_testKt $output
exit $LASTEXITCODE
