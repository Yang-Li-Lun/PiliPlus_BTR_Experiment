$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$gitCache = [IO.Path]::GetFullPath((Join-Path $repo '.toolchain/pub-cache/git'))
$inventory = @()
foreach ($entry in Get-ChildItem -LiteralPath $gitCache -Directory) {
    if (!(Test-Path -LiteralPath (Join-Path $entry.FullName '.git'))) { continue }
    $target = [IO.Path]::GetFullPath($entry.FullName)
    if (!$target.StartsWith($gitCache + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Git cache target escaped the private cache'
    }
    $missing = @(git -C $target -c core.longpaths=true ls-files --deleted)
    if ($LASTEXITCODE) { throw 'Cannot inspect private dependency checkout' }
    foreach ($file in $missing) {
        if (Test-Path -LiteralPath (Join-Path $target $file)) { throw "Refusing to overwrite existing file: $file" }
    }
    if ($missing.Count) {
        $inventory += [pscustomobject]@{ Repo=$entry.Name; Commit=(git -C $target rev-parse HEAD); Missing=$missing }
        # Restore only absent files from the dependency's already locked HEAD.
        # core.longpaths is per-command; no global Git configuration is changed.
        foreach ($file in $missing) {
            & git -C $target -c core.longpaths=true restore --source=HEAD --worktree -- $file
            if ($LASTEXITCODE) { throw "Restore failed: $file" }
        }
        $remaining = @(git -C $target -c core.longpaths=true ls-files --deleted)
        if ($remaining.Count) { throw 'Dependency still has missing files' }
        Write-Output "Restored $($missing.Count) missing locked files in $($entry.Name)"
    }
}
if ($inventory.Count) {
    $evidence = Join-Path $repo 'evidence'
    New-Item -ItemType Directory -Force -Path $evidence | Out-Null
    $inventory | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $evidence ('git-cache-restoration-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')) -Encoding utf8
}
