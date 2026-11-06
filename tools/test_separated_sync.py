"""Exercise real sync policy against local bare repositories, never the official remote."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import btr_sources as sources


class SeparatedSyncTests(unittest.TestCase):
    def setUp(self):
        scratch = sources.ROOT / '.scratch'
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='sync-layout-', dir=scratch)
        self.root = Path(self.temp.name)
        self.producer, self.owner, self.remote = (self.root / x for x in ('producer','owner','upstream.git'))
        self.producer.mkdir()
        self.g(self.producer, 'init', '-b', 'main')
        self.put(self.producer, 'lib/contact.dart', b'before\nbridge\nend\n')
        self.put(self.producer, 'lib/other.dart', b'official other\n')
        self.g(self.producer, 'add', '.')
        self.g(self.producer, 'commit', '-m', 'official')
        self.base = self.g(self.producer, 'rev-parse', 'HEAD').strip()
        self.g(self.producer, 'clone', '--bare', str(self.producer), str(self.remote))
        self.g(self.producer, 'clone', str(self.remote), str(self.owner))
        config = dict(schemaVersion=2,upstreamUrl=str(self.remote),upstreamRemote='upstream',upstreamBranch='main',upstreamMirror='codex/upstream-piliplus',acceptedSource='refs/heads/codex/btr-accepted',bootstrapSource='refs/heads/codex/btr-accepted',stableBranch='codex/btr-stable',requiredFeatures=self.base)
        self.put(self.owner, 'tool/btr_upstream.json', json.dumps(config).encode())
        self.put(self.owner, '.gitignore', b'.assembled/\n.scratch/\nevidence/\n.btr-wt/\n')
        self.put(self.owner, 'lib/contact.dart', b'before\nBTR bridge\nend\n')
        self.put(self.owner, 'lib/btr.dart', b'BTR transport\n')
        self.g(self.owner, 'add', '.')
        self.g(self.owner, 'commit', '-m', 'accepted feature fixture')
        self.accepted = self.g(self.owner, 'rev-parse', 'HEAD').strip()
        self.g(self.owner, 'branch', 'codex/btr-accepted')
        self.g(self.owner, 'branch', 'codex/btr-stable')
        patch = self.g(self.owner, 'diff', '--full-index', self.base, self.accepted, '--', 'lib/contact.dart').encode()
        self.g(self.owner, 'switch', '-c', 'codex/separated')
        self.put(self.owner, '.gitattributes', (sources.ROOT / '.gitattributes').read_bytes())
        for name in ('lib/contact.dart','lib/other.dart'):
            self.put(self.owner, 'PiliPlus/' + name, self.g(self.owner, 'show', self.base + ':' + name).encode())
            (self.owner / name).unlink()
        self.put(self.owner, 'BTR/lib/btr.dart', (self.owner / 'lib/btr.dart').read_bytes())
        (self.owner / 'lib/btr.dart').unlink()
        self.put(self.owner, 'tools/legacy/btr_upstream.json', json.dumps(config).encode())
        (self.owner / 'tool/btr_upstream.json').unlink()
        self.put(self.owner, 'integration/patches/contact.patch', patch)
        self.manifest = dict(schemaVersion=1,upstreamCommit=self.base,behaviorBaseline=self.accepted,patches=[dict(target='lib/contact.dart', source='integration/patches/contact.patch', baseBlob=sources.blob(b'before\nbridge\nend\n'))],overlays=[dict(target='lib/btr.dart',source='BTR/lib/btr.dart')],tools=[])
        self.put(self.owner, 'integration/sources.json', json.dumps(self.manifest).encode())
        self.g(self.owner, 'add', '-A')
        self.g(self.owner, 'commit', '-m', 'separate fixture')
        self.source = self.g(self.owner, 'rev-parse', 'HEAD').strip()

    def tearDown(self):
        # All refs and worktrees here belong to this disposable fixture only.
        # tempfile cleanup is confined to its newly allocated absolute directory.
        def writable_then_retry(function, name, error):
            import os, stat
            os.chmod(name, stat.S_IWRITE | stat.S_IREAD)
            function(name)
        import shutil
        shutil.rmtree(self.root, onerror=writable_then_retry)
        self.temp.cleanup()

    def g(self, root, *args):
        return subprocess.check_output(['git','-C',str(root),'-c','core.autocrlf=false','-c','user.name=Fixture','-c','user.email=fixture@local.invalid',*args], stderr=subprocess.PIPE).decode()

    def put(self, root, name, data):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def advance(self, contact=False):
        self.put(self.producer, 'lib/contact.dart' if contact else 'lib/other.dart', b'new official content\n')
        self.put(self.producer, 'lib/new.dart', b'new official file\n')
        self.g(self.producer, 'add', '.')
        self.g(self.producer, 'commit', '-m', 'next official fixture')
        self.g(self.producer, 'push', str(self.remote), 'main')
        return self.g(self.producer, 'rev-parse', 'HEAD').strip()

    def sync(self, explicit=True):
        args = ['pwsh','-NoProfile','-File',str(sources.ROOT/'tools/btr_sync_upstream.ps1'),'-RepositoryRoot',str(self.owner),'-RunId','candidate','-Python',sys.executable]
        if explicit:
            args += ['-SourceRef','codex/separated']
        result = subprocess.run(args, capture_output=True, text=True, encoding='utf-8', errors='replace')
        report = json.loads((self.owner/'evidence/upstream-sync/candidate/sync.json').read_text('utf-8-sig'))
        if result.returncode and report['state'] != 'INTEGRATION_REVIEW_REQUIRED':
            self.fail(result.stdout + result.stderr)
        self.assertEqual(self.g(self.owner,'rev-parse','codex/btr-accepted').strip(), self.accepted)
        self.assertEqual(self.g(self.owner,'rev-parse','codex/btr-stable').strip(), self.accepted)
        return result, report, Path(report['worktree'])

    def test_clean_subtree_update_preserves_ownership_and_ancestry(self):
        upstream = self.advance()
        result, report, candidate = self.sync()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(report['state'], 'MERGED')
        self.assertFalse((candidate/'lib').exists())
        self.assertTrue((candidate/'PiliPlus/lib/new.dart').exists())
        sources.verify(candidate, candidate/'.assembled/upstream-review')
        self.g(candidate,'merge-base','--is-ancestor',self.source,'HEAD')
        self.g(candidate,'merge-base','--is-ancestor',upstream,'HEAD')
        self.assertEqual(self.g(candidate,'status','--porcelain').strip(), '')
        result = subprocess.run(['pwsh','-NoProfile','-File',str(sources.ROOT/'tools/btr_sync_upstream.ps1'),'-RepositoryRoot',str(self.owner),'-SourceRef',report['candidateBranch'],'-RunId','repeat','-Python',sys.executable], capture_output=True, text=True, encoding='utf-8', errors='replace')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        repeat = json.loads((self.owner/'evidence/upstream-sync/repeat/sync.json').read_text('utf-8-sig'))
        self.assertEqual(repeat['state'], 'ALREADY_INTEGRATED')
        self.assertEqual(repeat['candidateCommit'], report['candidateCommit'])
        self.assertEqual(self.g(Path(repeat['worktree']),'status','--porcelain').strip(), '')

    def test_changed_contact_stops_with_merge_evidence(self):
        self.advance(contact=True)
        result, report, candidate = self.sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(report['state'], 'INTEGRATION_REVIEW_REQUIRED')
        self.assertEqual(report['integrationReview'], ['lib/contact.dart'])
        self.g(candidate, 'rev-parse', '--verify', 'MERGE_HEAD')
        self.assertEqual((candidate/'integration/patches/contact.patch').read_bytes(), (self.owner/'integration/patches/contact.patch').read_bytes())
        self.assertFalse((candidate/'.assembled/upstream-review').exists())

    def test_default_retains_accepted_legacy_layout(self):
        self.advance()
        result, report, candidate = self.sync(explicit=False)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(report['sourceCommit'], self.accepted)
        self.assertTrue((candidate/'lib/btr.dart').exists())
        self.assertFalse((candidate/'PiliPlus').exists())
        self.assertFalse((candidate/'integration/sources.json').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
