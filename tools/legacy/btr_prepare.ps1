$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$sdk = Join-Path $repo '.toolchain/flutter'
$cache = Join-Path $repo '.toolchain/pub-cache'
$required = (Get-Content -Raw -LiteralPath (Join-Path $repo '.fvmrc') | ConvertFrom-Json).flutter
if (!(Test-Path -LiteralPath "$sdk/bin/flutter.bat")) { throw "Prepare private Flutter $required in .toolchain/flutter first." }
foreach ($directory in @((Join-Path $repo '.toolchain'), $sdk, $cache)) {
  if ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw 'Patch preparation requires independent candidate SDK/cache, not a shared junction'
  }
}
$version = Get-Content -Raw -LiteralPath "$sdk/bin/cache/flutter.version.json" | ConvertFrom-Json
if ($version.frameworkVersion -ne $required) { throw 'Flutter version does not match .fvmrc' }
$env:PUB_CACHE = $cache
$env:CI = 'true'
$env:GRADLE_USER_HOME = Join-Path $repo '.toolchain/gradle-home'
$env:FLUTTER_ROOT = $sdk
$env:PATH = "$sdk/bin;$env:PATH"
& (Join-Path $PSScriptRoot 'btr_repair_git_cache.ps1')

# The upstream CI requires these exact Flutter and material_ui patches.
# Apply only to this repository's private SDK/cache. No global git config, reset,
# dependency upgrade, or shared-cache deletion from the upstream helper.
$flutterPatches = @('modal_barrier','text_selection','mouse_cursor','image_anim',
 'layout_builder','navigation_drawer','popup_menu','fab','null_safety_for_selectable_region',
 'selectable_region','editable_text','text_field','scroll_position','scrollable',
 'scrollable_gesture','draggable_scrollable_sheet','scaffold','text','text_painter',
 'sliver','refresh_indicator','double_tap_gesture','bottom_sheet_android','scroll_view','navigator')
foreach ($name in $flutterPatches) {
  $patch = Join-Path $repo "lib/scripts/$name.patch"
  & git -C $sdk apply --reverse --check $patch 2>$null
  if ($LASTEXITCODE -eq 0) { continue }
  & git -C $sdk apply --check $patch
  if ($LASTEXITCODE -ne 0) { throw "Patch check failed: $name" }
  & git -C $sdk apply $patch
  if ($LASTEXITCODE -ne 0) { throw "Patch failed: $name" }
  Write-Output "Applied Flutter: $name"
}
$configFile = Join-Path $repo '.dart_tool/package_config.json'
$config = Get-Content -Raw -LiteralPath $configFile | ConvertFrom-Json
$package = $config.packages | Where-Object name -eq 'material_ui'
if (!$package) { throw 'Run flutter pub get --enforce-lockfile with local PUB_CACHE first.' }
$material = Get-Item -LiteralPath ([Uri]::new([Uri]::new($configFile), $package.rootUri).LocalPath)
if (!$material.FullName.StartsWith($cache + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    ($material.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'material_ui must be in independent candidate cache' }
$relative = [IO.Path]::GetRelativePath($repo, $material.FullName).Replace('\','/')
foreach ($name in @('modal_barrier_material','navigation_drawer','popup_menu','fab',
 'text_field','scaffold','refresh_indicator','tabs','bottom_sheet_android')) {
  $patch = Join-Path $repo "lib/scripts/material/$name.patch"
  & git -C $repo apply "--directory=$relative" --reverse --check $patch 2>$null
  if ($LASTEXITCODE -eq 0) { continue }
  & git -C $repo apply "--directory=$relative" --check $patch
  if ($LASTEXITCODE -ne 0) { throw "Material patch check failed: $name" }
  & git -C $repo apply "--directory=$relative" $patch
  if ($LASTEXITCODE -ne 0) { throw "Material patch failed: $name" }
  Write-Output "Applied material_ui: $name"
}
