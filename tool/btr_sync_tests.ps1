#Requires -Version 7.0
# Local disposable Git fixtures only. Never changes production refs or uses the network.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path $repo ('evidence/sync-tests-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $scratch | Out-Null
function G([string]$Path, [string[]]$Arguments) {
    $result = @(& git -C $Path -c user.name=Fixture -c user.email=fixture@local.invalid @Arguments)
    if ($LASTEXITCODE) { throw "Fixture git failed: $($Arguments -join ' ')" }
    return $result
}
function Assert([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message }; Write-Output "PASS: $Message" }
function Commit([string]$Path, [string]$Message) { G $Path @('add', 'shared.txt', '.gitignore', 'tool'); G $Path @('commit', '-m', $Message) | Out-Null }
$producer = Join-Path $scratch 'producer'
$owner = Join-Path $scratch 'owner'
New-Item -ItemType Directory -Path $producer | Out-Null
G $producer @('init', '-b', 'main') | Out-Null
New-Item -ItemType Directory -Path (Join-Path $producer 'tool') | Out-Null
".btr-wt/`nevidence/" | Set-Content -LiteralPath (Join-Path $producer '.gitignore')
'base' | Set-Content -LiteralPath (Join-Path $producer 'shared.txt')
'fixture' | Set-Content -LiteralPath (Join-Path $producer 'tool/fixture.txt')
Commit $producer 'base'
$base = @(G $producer @('rev-parse', 'HEAD'))[0]
$remote = Join-Path $scratch 'upstream.git'
& git clone --bare $producer $remote
if ($LASTEXITCODE) { throw 'Cannot create local bare fixture' }
& git clone $remote $owner
if ($LASTEXITCODE) { throw 'Cannot create owner fixture' }
G $owner @('switch', '-c', 'codex/fixture-tools') | Out-Null
G $owner @('branch', 'codex/btr-maintenance', $base) | Out-Null
$config = @{schemaVersion=2;upstreamUrl=$remote;upstreamRemote='upstream';upstreamBranch='main';upstreamMirror='codex/upstream-piliplus';bootstrapSource='refs/tags/trial';acceptedSource='refs/heads/codex/btr-accepted';stableBranch='codex/btr-stable';requiredFeatures=$base}
$config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $owner 'tool/btr_upstream.json')
Commit $owner 'BTR tooling'
G $owner @('branch', 'codex/btr-stable') | Out-Null
$source = @(G $owner @('rev-parse', 'HEAD'))[0]
G $owner @('tag','trial',$source) | Out-Null
G $producer @('remote', 'add', 'upstream', $remote) | Out-Null
'upstream change' | Set-Content -LiteralPath (Join-Path $producer 'shared.txt')
Commit $producer 'new upstream'
G $producer @('push', 'upstream', 'main') | Out-Null
'dirty tracked owner work' | Set-Content -LiteralPath (Join-Path $owner 'shared.txt')
'untracked owner work' | Set-Content -LiteralPath (Join-Path $owner 'personal.txt')
$statusBefore = @(G $owner @('status', '--porcelain=v1')) -join "`n"
$script = Join-Path $PSScriptRoot 'btr_sync_upstream.ps1'
& $script -RepositoryRoot $owner -RunId 'clean'
$r = Get-Content -LiteralPath (Join-Path $owner 'evidence/upstream-sync/clean/sync.json') -Raw | ConvertFrom-Json
Assert ($r.state -eq 'MERGED') 'automatic non-conflicting merge'
Assert ((@(G $owner @('status', '--porcelain=v1')) -join "`n") -ceq $statusBefore) 'dirty tracked and untracked owner files unchanged'
Assert (@(G $owner @('rev-parse', 'codex/btr-stable'))[0] -eq $source) 'stable ref unchanged'
Assert ($r.sourceCommit -eq $source) 'default uses accepted trial rather than older maintenance branch'
Assert (@(G $owner @('rev-parse', 'codex/btr-maintenance'))[0] -eq $base) 'older maintenance ref unchanged'
& $script -RepositoryRoot $owner -RunId 'unaccepted-default'
$unaccepted = Get-Content -LiteralPath (Join-Path $owner 'evidence/upstream-sync/unaccepted-default/sync.json') -Raw | ConvertFrom-Json
Assert ($unaccepted.sourceCommit -eq $source) 'an unaccepted candidate never becomes the default source'
& $script -RepositoryRoot $owner -SourceRef $r.candidateBranch -RunId 'repeat'
$repeat = Get-Content -LiteralPath (Join-Path $owner 'evidence/upstream-sync/repeat/sync.json') -Raw | ConvertFrom-Json
Assert ($repeat.state -eq 'ALREADY_INTEGRATED') 'repeated sync from candidate does not replay BTR changes'
Assert ($repeat.candidateCommit -eq $r.candidateCommit) 'no extra merge when upstream already integrated'
$collision = $false
try { & $script -RepositoryRoot $owner -RunId 'repeat' } catch { $collision=$true }
Assert $collision 'existing run evidence and branch cannot be overwritten'
$conflictPath = Join-Path $scratch 'conflicting-btr'
G $owner @('worktree','add','-b','codex/conflicting-btr',$conflictPath,$source) | Out-Null
'BTR change on same line' | Set-Content -LiteralPath (Join-Path $conflictPath 'shared.txt')
Commit $conflictPath 'conflicting BTR'
$conflict = $false
try { & $script -RepositoryRoot $owner -SourceRef 'codex/conflicting-btr' -RunId 'conflict' } catch { $conflict=$true }
$cr = Get-Content -LiteralPath (Join-Path $owner 'evidence/upstream-sync/conflict/sync.json') -Raw | ConvertFrom-Json
Assert ($conflict -and $cr.state -eq 'CONFLICTS' -and 'shared.txt' -in $cr.conflicts) 'conflict is retained and reported for Codex'
Assert (@(G $cr.worktree @('diff','--name-only','--diff-filter=U')).Count -eq 1) 'unmerged index remains available'
$acceptanceMissing = $false
try { & $script -RepositoryRoot $r.worktree -AcceptCandidate HEAD -RunId 'missing-note' } catch { $acceptanceMissing=$true }
Assert $acceptanceMissing 'acceptance requires explicit decision note'
& $script -RepositoryRoot $r.worktree -AcceptCandidate HEAD -AcceptanceNote 'Fixture user accepted candidate as maintenance source only' -RunId 'accept'
Assert (@(G $owner @('rev-parse','codex/btr-accepted'))[0] -eq $r.candidateCommit) 'accepted maintenance source advances separately'
& $script -RepositoryRoot $r.worktree -RunId 'accepted-next'
$next = Get-Content -LiteralPath (Join-Path $r.worktree 'evidence/upstream-sync/accepted-next/sync.json') -Raw | ConvertFrom-Json
Assert ($next.sourceCommit -eq $r.candidateCommit) 'next default sync inherits accepted candidate'
Assert ($next.worktree -eq (Join-Path $owner '.btr-wt/accepted-next')) 'candidate invocation creates sibling worktree'
$oldSource = $false
try { & $script -RepositoryRoot $r.worktree -SourceRef trial -RunId 'old-source' } catch { $oldSource=$true }
Assert $oldSource 'explicit older source cannot drop accepted fixes'
Assert (@(G $owner @('rev-parse','codex/btr-stable'))[0] -eq $source) 'source acceptance does not promote stable'
$beforeRemote = @(G $owner @('rev-parse','refs/remotes/upstream/main'))[0]
# Simulate a server-side rewrite via CAS on the disposable bare fixture only.
G $remote @('update-ref','refs/heads/main',$base,$beforeRemote) | Out-Null
$rewrite = $false
try { & $script -RepositoryRoot $owner -RunId 'rewrite' } catch { $rewrite=$true }
Assert $rewrite 'rewritten upstream fails without forcing history'
Assert (@(G $owner @('rev-parse','refs/remotes/upstream/main'))[0] -eq $beforeRemote) 'rejected fetch preserves prior upstream ref'
Write-Output "All sync safety scenarios passed. Fixtures retained at $scratch"
