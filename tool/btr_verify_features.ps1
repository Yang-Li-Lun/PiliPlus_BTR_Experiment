#Requires -Version 7.0
param([Parameter(Mandatory)][string]$BtrRef, [Parameter(Mandatory)][string]$UpstreamRef)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
function InvokeRepoGit([string[]]$Arguments) {
    $output = @(& git -C $repo @Arguments)
    if ($LASTEXITCODE) { throw "git failed: $($Arguments -join ' ')" }
    return $output
}
foreach ($ref in @($BtrRef, $UpstreamRef)) {
    & git -C $repo merge-base --is-ancestor $ref HEAD
    if ($LASTEXITCODE) { throw "Missing candidate ancestry: $ref" }
}
$base = @(InvokeRepoGit @('merge-base', $BtrRef, $UpstreamRef))[0]
$custom = @(InvokeRepoGit @('diff', '--name-only', $base, $BtrRef, '--', 'lib', 'android', 'test/btr', 'pubspec.yaml', 'pubspec.lock'))
$upstream = @(InvokeRepoGit @('diff', '--name-only', $base, $UpstreamRef))
$shared = @()
$identical = 0
foreach ($file in $custom) {
    if ($file -in $upstream) { $shared += $file; continue }
    & git -C $repo diff --quiet $BtrRef HEAD -- $file
    if ($LASTEXITCODE) { throw "Unexplained change to BTR file untouched by upstream: $file" }
    $identical++
}
# Structural tripwires, not semantic/device acceptance. Review shared files and run tests.
$checks = @{
    'lib/services/btr/transport.dart'=@('class BtrTransport', 'BtrNetwork.validate', 'close\(')
    'lib/services/btr/network.dart'=@('HttpHeaders.ifRangeHeader', 'static int validate')
    'lib/services/btr/policy.dart'=@('ali', 'BtrMode')
    'lib/services/btr/settings.dart'=@('btrSettingsV2', '128')
    'lib/services/btr/playback.dart'=@('BtrPlayback', 'prepare\(', 'close\(')
    'lib/pages/setting/pages/btr_experiment.dart'=@('Btr', '線程')
    'lib/pages/setting/widgets/btr_monitor.dart'=@('Btr', 'Timer')
    'lib/pages/setting/models/play_settings.dart'=@('BtrExperimentPage')
    'lib/pages/video/widgets/header_control.dart'=@('BtrExperimentPage')
    'lib/pages/video/controller.dart'=@('videoCandidates', 'audioCandidates')
    'lib/plugin/pl_player/controller.dart'=@('BtrPlayback.prepare', '_taskScope.close', 'previousBtr\?\.close', 'session\?\.seek', 'retirePlayerRequests')
    'lib/services/btr/proxy_capacity.dart'=@('activeLimit = 4;', 'responseLimit = 8;')
    'lib/services/btr/scheduler.dart'=@('resourceLimit = 16;')
    'lib/plugin/pl_player/view/view.dart'=@('BtrMonitor')
    'lib/services/audio_handler.dart'=@('onTaskRemoved', 'PlaybackTaskScope.closeAll')
    'lib/services/playback_task_scope.dart'=@('class PlaybackTaskScope', 'closeAll')
    'lib/services/player_disposal.dart'=@('disposePlaybackPlayer')
    'android/app/src/main/kotlin/com/example/piliplus/MainActivity.kt'=@('AudioServicePlugin.getFlutterEngine', 'FlutterActivity')
    'android/app/build.gradle.kts'=@('com.example.piliplus.btr.experiment', 'PiliPlus BTR DEV')
    'android/app/src/main/AndroidManifest.xml'=@('btr_network_security')
}
foreach ($file in $checks.Keys) {
    $content = Get-Content -LiteralPath (Join-Path $repo $file) -Raw
    foreach ($pattern in $checks[$file]) {
        if ($content -notmatch $pattern) { throw "BTR structural check failed: $file / $pattern" }
    }
}
Write-Output "BTR files byte-equivalent to source: $identical"
Write-Output "Shared integration files requiring code review: $($shared -join ', ')"
Write-Output 'BTR structural checks PASS; run Dart tests, analysis and APK validation; device acceptance remains UNRESOLVED.'
