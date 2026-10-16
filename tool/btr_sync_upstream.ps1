#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$SourceRef,
    [string]$RunId = (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
function InvokeRepoGit([string[]]$Arguments) {
    $output = @(& git -C $repo -c core.longpaths=true @Arguments)
    if ($LASTEXITCODE) { throw "git failed ($LASTEXITCODE): $($Arguments -join ' ')" }
    return $output
}
function Ref([string]$Name) { return @(InvokeRepoGit @('rev-parse', '--verify', "$Name^{commit}"))[0] }
function IsAncestor([string]$Older, [string]$Newer) {
    & git -C $repo merge-base --is-ancestor $Older $Newer
    if ($LASTEXITCODE -gt 1) { throw 'Cannot check ancestry' }
    return $LASTEXITCODE -eq 0
}
if ($RunId -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,47}$') { throw 'Invalid RunId' }
if (@(InvokeRepoGit @('rev-parse', '--show-toplevel'))[0].Replace('\','/') -ne $repo.Replace('\','/')) {
    throw 'RepositoryRoot must be the checkout root'
}
$config = Get-Content -LiteralPath (Join-Path $repo 'tool/btr_upstream.json') -Raw | ConvertFrom-Json
if ($config.schemaVersion -ne 1) { throw 'Unknown sync configuration schema' }
if (!$SourceRef) { $SourceRef = $config.maintenanceBranch }
$source = Ref $SourceRef
$stable = Ref $config.stableBranch
if (!(IsAncestor $config.initialFeatures $source)) {
    throw 'Source does not contain the required BTR feature baseline'
}
$run = Join-Path $repo "evidence/upstream-sync/$RunId"
$candidate = "codex/btr-update-$RunId"
$worktree = Join-Path $repo ".btr-wt/$RunId"
$restoreTag = "btr-pre-sync-$RunId"
foreach ($path in @($run, $worktree)) {
    if (Test-Path -LiteralPath $path) { throw "Refusing to reuse existing path: $path" }
}
foreach ($name in @("refs/heads/$candidate", "refs/tags/$restoreTag")) {
    & git -C $repo show-ref --verify --quiet $name
    if ($LASTEXITCODE -eq 0) { throw "Refusing to reuse existing ref: $name" }
    if ($LASTEXITCODE -ne 1) { throw 'Cannot inspect refs' }
}
New-Item -ItemType Directory -Path $run | Out-Null
$report = [ordered]@{
    schemaVersion=1; state='STARTED'; sourceRef=$SourceRef; sourceCommit=$source
    stableCommit=$stable; upstreamCommit=$null; upstreamBase=$null
    candidateBranch=$candidate; worktree=$worktree; restoreTag=$restoreTag
    candidateCommit=$null; conflicts=@(); deviceAcceptance='UNRESOLVED / NOT RUN'
}
function SaveReport { $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $run 'sync.json') -Encoding utf8 }
InvokeRepoGit @('show-ref') | Set-Content -LiteralPath (Join-Path $run 'refs-before.txt')
InvokeRepoGit @('status', '--porcelain=v1', '-b', '--untracked-files=all') | Set-Content -LiteralPath (Join-Path $run 'owner-status-before.txt')
SaveReport
try {
    # Snapshot the committed source only. Never stash, checkout, clean or add owner files.
    InvokeRepoGit @('tag', $restoreTag, $source) | Out-Null
    $remotes = @(InvokeRepoGit @('remote'))
    if ($config.upstreamRemote -notin $remotes) {
        InvokeRepoGit @('remote', 'add', $config.upstreamRemote, $config.upstreamUrl) | Out-Null
    }
    $url = @(InvokeRepoGit @('remote', 'get-url', $config.upstreamRemote))[0]
    if ($url -cne $config.upstreamUrl) { throw 'Upstream URL differs from configuration; inspect without replacing it' }
    $remoteRef = "refs/remotes/$($config.upstreamRemote)/$($config.upstreamBranch)"
    # No '+', tags or prune: rewritten upstream history must stop for review.
    InvokeRepoGit @('fetch', '--no-tags', $config.upstreamRemote, "refs/heads/$($config.upstreamBranch):$remoteRef") | Out-Null
    $upstream = Ref $remoteRef
    $report.upstreamCommit = $upstream
    $report.upstreamBase = @(InvokeRepoGit @('merge-base', $source, $upstream))[0]
    $mirrorRef = "refs/heads/$($config.upstreamMirror)"
    & git -C $repo show-ref --verify --quiet $mirrorRef
    $mirrorExists = $LASTEXITCODE -eq 0
    if ($LASTEXITCODE -gt 1) { throw 'Cannot inspect upstream mirror' }
    if ($mirrorExists) {
        $oldMirror = Ref $mirrorRef
        if (!(IsAncestor $oldMirror $upstream)) { throw 'Upstream mirror would not fast-forward; review rewritten history' }
        if ($oldMirror -ne $upstream) {
            $worktrees = @(InvokeRepoGit @('worktree', 'list', '--porcelain'))
            if ("branch $mirrorRef" -in $worktrees) { throw 'Upstream mirror is checked out; leave it untouched' }
            InvokeRepoGit @('update-ref', $mirrorRef, $upstream, $oldMirror) | Out-Null
        }
    } else {
        InvokeRepoGit @('update-ref', $mirrorRef, $upstream, ('0' * 40)) | Out-Null
    }
    InvokeRepoGit @('worktree', 'add', '--no-track', '-b', $candidate, $worktree, $source) | Out-Null
    $mergeOutput = @(& git -C $worktree -c core.longpaths=true -c user.name=Codex -c user.email=codex@local.invalid merge --no-ff --no-commit $upstream 2>&1)
    $mergeExit = $LASTEXITCODE
    $mergeOutput | Set-Content -LiteralPath (Join-Path $run 'merge.log')
    if ($mergeExit) {
        $report.conflicts = @(& git -C $worktree diff --name-only --diff-filter=U)
        if ($report.conflicts.Count) { $report.state='CONFLICTS'; SaveReport; throw 'Merge conflicts retained in candidate worktree; Codex must resolve and validate them' }
        throw 'Merge failed; inspect merge.log and candidate worktree'
    }
    & git -C $worktree rev-parse --verify -q MERGE_HEAD *> $null
    if ($LASTEXITCODE -eq 0) {
        & git -C $worktree -c user.name=Codex -c user.email=codex@local.invalid commit -m "Merge PiliPlus upstream $($upstream.Substring(0,12)) into BTR candidate"
        if ($LASTEXITCODE) { throw 'Candidate merge commit failed' }
        $report.state='MERGED'
    } else { $report.state='ALREADY_INTEGRATED' }
    $report.candidateCommit = (& git -C $worktree rev-parse HEAD)
    if (!(IsAncestor $source $report.candidateCommit) -or !(IsAncestor $upstream $report.candidateCommit)) {
        throw 'Candidate lost source or upstream ancestry'
    }
    if ((Ref $config.stableBranch) -ne $stable -or (Ref $SourceRef) -ne $source) { throw 'Source/stable ref changed during sync' }
    SaveReport
    Write-Output "State: $($report.state) (integration only; acceptance pending)"
    Write-Output "Candidate: $candidate"
    Write-Output "Worktree: $worktree"
    Write-Output "Report: $(Join-Path $run 'sync.json')"
} catch {
    if ($report.state -ne 'CONFLICTS') { $report.state='FAILED' }
    $report['error'] = $_.Exception.Message
    SaveReport
    throw
} finally {
    InvokeRepoGit @('status', '--porcelain=v1', '-b', '--untracked-files=all') | Set-Content -LiteralPath (Join-Path $run 'owner-status-after.txt')
}
