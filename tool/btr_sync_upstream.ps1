#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$SourceRef,
    [string]$AcceptCandidate,
    [string]$AcceptanceNote,
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
if ($config.schemaVersion -ne 2) { throw 'Unknown sync configuration schema; use the current candidate tooling' }
function HasRef([string]$Name) {
    & git -C $repo show-ref --verify --quiet $Name
    if ($LASTEXITCODE -gt 1) { throw "Cannot inspect ref: $Name" }
    return $LASTEXITCODE -eq 0
}
if ($config.acceptedSource -notlike 'refs/heads/codex/btr-accepted*') { throw 'Invalid accepted-source ref' }
$acceptedExists = HasRef $config.acceptedSource
$accepted = if ($acceptedExists) { Ref $config.acceptedSource } else { Ref $config.bootstrapSource }
if (!(IsAncestor $config.requiredFeatures $accepted)) { throw 'Accepted source lacks required BTR baseline' }
if ($AcceptCandidate) {
    if ($SourceRef -or [string]::IsNullOrWhiteSpace($AcceptanceNote)) { throw 'Acceptance requires a user decision note and no SourceRef' }
    $next = Ref $AcceptCandidate
    if (!(IsAncestor $accepted $next)) { throw 'Accepted source must advance without dropping accepted history' }
    if ((Ref 'HEAD') -ne $next -or @(InvokeRepoGit @('status','--porcelain=v1','--untracked-files=all')).Count) {
        throw 'Run acceptance from the clean, reviewed candidate checkout at its exact commit'
    }
    if ("branch $($config.acceptedSource)" -in @(InvokeRepoGit @('worktree','list','--porcelain'))) { throw 'Accepted source is checked out; leave that worktree untouched' }
    $receipt = Join-Path $repo "evidence/source-acceptance/$RunId.json"
    if (Test-Path -LiteralPath $receipt) { throw 'Acceptance receipt already exists' }
    New-Item -ItemType Directory -Force -Path (Split-Path $receipt) | Out-Null
    $record = @{ previous=$accepted; candidate=$next; note=$AcceptanceNote; state='PREPARED'; deviceAcceptance='Not implied by source acceptance' }
    $record | ConvertTo-Json | Set-Content -LiteralPath $receipt
    $expected = if ($acceptedExists) { $accepted } else { '0' * 40 }
    InvokeRepoGit @('update-ref', $config.acceptedSource, $next, $expected) | Out-Null
    $record.state='ACCEPTED'
    $record | ConvertTo-Json | Set-Content -LiteralPath $receipt
    Write-Output "Accepted maintenance source: $next; recommendation and stable refs unchanged"
    return
}
if ($AcceptanceNote) { throw 'AcceptanceNote requires AcceptCandidate' }
if (!$SourceRef) { $SourceRef = if ($acceptedExists) { $config.acceptedSource } else { $config.bootstrapSource } }
$source = Ref $SourceRef
$stable = Ref $config.stableBranch
if (!(IsAncestor $config.requiredFeatures $source) -or !(IsAncestor $accepted $source)) {
    throw 'Source does not contain the required and accepted BTR feature history'
}
# Always make sibling worktrees under the repository, even when invoked from a candidate.
$common = @(InvokeRepoGit @('rev-parse','--path-format=absolute','--git-common-dir'))[0]
$workspace = Split-Path $common -Parent
$run = Join-Path $repo "evidence/upstream-sync/$RunId"
$candidate = "codex/btr-update-$RunId"
$worktree = Join-Path $workspace ".btr-wt/$RunId"
$restoreTag = "btr-pre-sync-$RunId"
$toolCommit = Ref 'HEAD'
$toolPaths = @('AGENTS.md','tool') + @(InvokeRepoGit @('ls-tree','--name-only',$toolCommit) | Where-Object { $_ -like 'BTR_*.md' })
$carryTools = IsAncestor $source $toolCommit
if (!$carryTools -and !(IsAncestor $toolCommit $source)) { throw 'Tooling and source diverged; review from the current maintenance candidate' }
if ($carryTools -and @(InvokeRepoGit (@('status','--porcelain=v1','--') + $toolPaths)).Count) {
    throw 'Commit current maintenance tooling before syncing'
}
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
    schemaVersion=2; state='STARTED'; sourceRef=$SourceRef; sourceCommit=$source
    acceptedSource=$accepted; requiredFeatures=$config.requiredFeatures
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
    # Carry the current sync policy/tools even when bootstrapping from an older
    # accepted source. The caller must contain that source and have clean tools.
    if ($carryTools) {
    $existingToolPaths = @(& git -C $repo ls-tree --name-only $toolCommit -- @toolPaths)
    & git -C $worktree restore --source=$toolCommit --staged --worktree -- @existingToolPaths
    if ($LASTEXITCODE) { throw 'Cannot carry current maintenance tooling' }
    & git -C $worktree diff --cached --quiet
    if ($LASTEXITCODE -eq 1) {
        & git -C $worktree -c user.name=Codex -c user.email=codex@local.invalid commit -m "Carry maintenance tooling from $toolCommit"
        if ($LASTEXITCODE) { throw 'Cannot commit maintenance tooling' }
    } elseif ($LASTEXITCODE) { throw 'Cannot compare tooling' }
    }
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
