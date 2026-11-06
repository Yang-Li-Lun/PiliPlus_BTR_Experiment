"""Local disposable source-composition regression tests; no SDK or network."""
import contextlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import btr_sources as sources


class CompositionTests(unittest.TestCase):
    def setUp(self):
        scratch = sources.ROOT / '.scratch'
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='sources-', dir=scratch)
        self.root = Path(self.temp.name)
        self.g('init', '-b', 'main')
        self.put('lib/player.dart', b'official\n')
        self.g('add', '.')
        self.g('commit', '-m', 'official')
        self.base = self.g('rev-parse', 'HEAD').decode().strip()
        self.put('lib/player.dart', b'integrated\n')
        self.put('lib/btr.dart', b'BTR\n')
        self.g('add', '.')
        self.g('commit', '-m', 'behavior baseline')
        self.baseline = self.g('rev-parse', 'HEAD').decode().strip()
        self.put('PiliPlus/lib/player.dart', b'official\n')
        self.put('BTR/lib/btr.dart', b'BTR\n')
        self.put('integration/patches/player.patch', self.g('diff', '--full-index', self.base, self.baseline, '--', 'lib/player.dart'))
        self.manifest = dict(schemaVersion=1, upstreamCommit=self.base, behaviorBaseline=self.baseline,
                             patches=[dict(target='lib/player.dart', source='integration/patches/player.patch', baseBlob=sources.blob(b'official\n'))],
                             overlays=[dict(target='lib/btr.dart', source='BTR/lib/btr.dart')], tools=[])
        self.save()

    def tearDown(self):
        self.temp.cleanup()

    def g(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), '-c', 'core.autocrlf=false', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@local.invalid', *args], stderr=subprocess.STDOUT)

    def put(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def save(self):
        self.put('integration/sources.json', json.dumps(self.manifest).encode())

    def compose(self, name='app'):
        target = self.root / '.assembled' / name
        with contextlib.redirect_stdout(io.StringIO()):
            sources.compose(self.root, target)
        return target

    def test_reproducible_baseline_and_ownership(self):
        a, b = self.compose(), self.compose('second')
        self.assertEqual((a / '.btr-composition.json').read_bytes(), (b / '.btr-composition.json').read_bytes())
        sources.verify(self.root, a, baseline=True)
        receipt = json.loads((a / '.btr-composition.json').read_text())
        self.assertEqual(receipt['files']['lib/player.dart']['owner'], 'Integration patch')
        self.assertEqual(receipt['files']['lib/btr.dart']['owner'], 'BTR')

    def test_official_mutation_fails_before_output(self):
        self.put('PiliPlus/lib/player.dart', b'changed\n')
        with self.assertRaisesRegex(ValueError, 'Official source changed'):
            self.compose()
        self.assertFalse((self.root / '.assembled').exists())

    def test_unlisted_official_or_owned_file(self):
        self.put('BTR/hidden.dart', b'hidden')
        with self.assertRaisesRegex(ValueError, 'Unlisted'):
            self.compose()
        (self.root / 'BTR/hidden.dart').unlink()
        self.put('PiliPlus/hidden.dart', b'hidden')
        with self.assertRaisesRegex(ValueError, 'inventory'):
            self.compose()

    def test_overlay_cannot_replace_official(self):
        self.manifest['overlays'][0]['target'] = 'lib/player.dart'
        self.save()
        with self.assertRaisesRegex(ValueError, 'overwrite'):
            self.compose()

    def test_duplicate_and_case_collision(self):
        self.manifest['overlays'].append(dict(target='LIB/BTR.dart', source='BTR/lib/btr.dart'))
        self.save()
        with self.assertRaisesRegex(ValueError, 'overwrite'):
            self.compose()

    def test_patch_base_and_undeclared_path(self):
        self.manifest['patches'][0]['baseBlob'] = '0' * 40
        self.save()
        with self.assertRaisesRegex(ValueError, 'base requires review'):
            self.compose()
        self.manifest['patches'][0]['baseBlob'] = sources.blob(b'official\n')
        self.save()
        path = self.root / 'integration/patches/player.patch'
        path.write_bytes(path.read_bytes().replace(b'b/lib/player.dart', b'b/lib/other.dart'))
        with self.assertRaisesRegex(ValueError, 'undeclared'):
            self.compose()

    def test_unsafe_paths(self):
        for name in ('../escape', '/escape', 'C:/escape', '.git/config', 'x/../escape', 'x\\escape'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                sources.path_at(self.root, name)

    def test_existing_output_and_source_target_refused(self):
        self.compose()
        with self.assertRaisesRegex(ValueError, 'existing output'):
            self.compose()
        with self.assertRaises(ValueError):
            sources.compose(self.root, self.root / 'BTR')

    def test_stale_composition_and_edited_output(self):
        output = self.compose()
        self.put('BTR/lib/btr.dart', b'edit\n')
        with self.assertRaisesRegex(ValueError, 'Stale'):
            sources.verify(self.root, output)
        self.put('BTR/lib/btr.dart', b'BTR\n')
        (output / 'lib/btr.dart').write_text('output edit')
        with self.assertRaisesRegex(ValueError, 'Generated source was edited'):
            sources.verify(self.root, output)

    def test_behavior_change_cannot_claim_equivalence(self):
        self.put('BTR/lib/btr.dart', b'new behavior\n')
        output = self.compose()
        with self.assertRaisesRegex(ValueError, 'baseline differs'):
            sources.verify(self.root, output, baseline=True)

    def test_extra_generated_source_is_rejected(self):
        output = self.compose()
        (output / 'lib/unlisted.dart').write_text('extra behavior')
        with self.assertRaisesRegex(ValueError, 'Unlisted generated'):
            sources.verify(self.root, output)


if __name__ == '__main__':
    unittest.main(verbosity=2)
