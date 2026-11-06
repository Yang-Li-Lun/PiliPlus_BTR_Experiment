"""Compose pinned PiliPlus + BTR + reviewed integration, using only Git and Python stdlib.

Generated application directories are disposable inputs to Flutter, never an editing
surface. No network, ref updates, SDK mutation, device access or implicit cleanup.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess


ROOT = Path(__file__).resolve().parent.parent


def git(root, *args, data=None):
    return subprocess.check_output(
        ['git', '-C', str(root), '-c', 'core.longpaths=true', '-c', 'core.autocrlf=false', *args], input=data
    )


def blob(data):
    return hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()


def path_at(root, name):
    p = PurePosixPath(name)
    if not name or '\\' in name or ':' in name or p.is_absolute() or any(
        x in ('', '.', '..') for x in name.split('/')
    ) or any(x.lower() == '.git' for x in p.parts):
        raise ValueError(f'Unsafe relative path: {name}')
    result = root.joinpath(*p.parts)
    current = result
    while current != root:
        if current.is_symlink() or (hasattr(current, 'is_junction') and current.is_junction()):
            raise ValueError(f'Source/output link not allowed: {current}')
        current = current.parent
    return result


def tree(root, ref):
    entries = {}
    for row in git(root, 'ls-tree', '-rz', ref).split(b'\0'):
        if not row:
            continue
        meta, path = row.split(b'\t', 1)
        mode, kind, oid = meta.decode().split()
        if kind != 'blob' or mode not in ('100644', '100755'):
            raise ValueError('Only ordinary source files are supported: ' + path.decode())
        entries[path.decode()] = (mode, oid)
    return entries


def files_under(root):
    return {p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file()}


def inputs(root):
    manifest = json.loads((root / 'integration/sources.json').read_text('utf-8'))
    if manifest['schemaVersion'] != 1:
        raise ValueError('Unknown source schema')
    upstream = manifest['upstreamCommit']
    if len(upstream) != 40 or git(root, 'rev-parse', upstream + '^{commit}').decode().strip() != upstream:
        raise ValueError('Upstream must be a pinned full commit')
    expected = tree(root, upstream)
    if files_under(root / 'PiliPlus') != set(expected):
        raise ValueError('PiliPlus inventory differs from pinned upstream')
    output, ownership, hashes, modes = {}, {}, {}, {}
    for name, (mode, oid) in expected.items():
        data = path_at(root, 'PiliPlus/' + name).read_bytes()
        if blob(data) != oid:
            raise ValueError('Official source changed: ' + name)
        output[name], ownership[name], hashes['PiliPlus/' + name], modes[name] = data, 'PiliPlus', oid, mode
    claimed = set()
    for entry in manifest['patches']:
        name, source = entry['target'], entry['source']
        path_at(root, name)
        if not source.startswith('integration/patches/') or name in claimed or name not in output:
            raise ValueError('Invalid/duplicate patch target: ' + name)
        if blob(output[name]) != entry['baseBlob']:
            raise ValueError('Patch base requires review: ' + name)
        patch = path_at(root, source).read_bytes()
        # A patch has exactly one declared existing-file target. Reject additions,
        # renames and cross-file writes before git apply can touch the output.
        lines = patch.decode('utf-8').splitlines()
        if [x for x in lines if x.startswith('diff --git ')] != [f'diff --git a/{name} b/{name}']:
            raise ValueError('Patch changes an undeclared path: ' + source)
        if [x for x in lines if x.startswith('--- ')] != ['--- a/' + name] or [x for x in lines if x.startswith('+++ ')] != ['+++ b/' + name]:
            raise ValueError('Patch must modify its declared text file: ' + source)
        claimed.add(name)
        hashes[source], ownership[name] = blob(patch), 'Integration patch'
    for section, prefix in (('overlays', None), ('tools', 'tools/')):
        for entry in manifest[section]:
            name, source = entry['target'], entry['source']
            path_at(root, name)
            if (prefix and not source.startswith(prefix)) or (not prefix and not source.startswith(('BTR/', 'integration/overlay/'))):
                raise ValueError('Invalid owner: ' + source)
            if name in output or name.casefold() in {x.casefold() for x in output}:
                raise ValueError('Overlay cannot overwrite an official/owned file: ' + name)
            data = path_at(root, source).read_bytes()
            output[name], hashes[source], modes[name] = data, blob(data), '100644'
            ownership[name] = 'BTR' if source.startswith('BTR/') else ('Tools' if prefix else 'Integration adapter')
    owned = {x['source'] for x in manifest['overlays']}
    actual = {'BTR/' + p for p in files_under(root / 'BTR')}
    actual |= {'integration/overlay/' + p for p in files_under(root / 'integration/overlay')}
    if owned != actual:
        raise ValueError('Unlisted or missing owned source files')
    patches = {'integration/patches/' + p for p in files_under(root / 'integration/patches')}
    if patches != {x['source'] for x in manifest['patches']}:
        raise ValueError('Unlisted or missing integration patches')
    fingerprint = hashlib.sha256(json.dumps({'manifest': manifest, 'hashes': hashes}, sort_keys=True).encode()).hexdigest()
    return manifest, output, ownership, fingerprint, modes


def compose(root, destination):
    manifest, output, ownership, fingerprint, modes = inputs(root)
    # Output is always a fresh child of this candidate; never overwrite a build,
    # a source tree, a junction, or an existing/partial composition.
    relative = destination.relative_to(root).as_posix()
    path_at(root, relative)
    if relative.split('/')[0] not in ('.assembled', '.scratch') or destination.exists():
        raise ValueError('Use a new output under .assembled or .scratch; existing output is preserved')
    destination.mkdir(parents=True)
    for name, data in output.items():
        target = path_at(destination, name)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        if modes[name] == '100755' and os.name != 'nt':
            target.chmod(0o755)
    # An isolated Git marker prevents git apply from discovering the owner worktree
    # and interpreting paths relative to its top level. It is not a new repository.
    marker = destination / '.git'
    marker.mkdir()
    (marker / 'HEAD').write_text('ref: refs/heads/composition\n')
    (marker / 'objects').mkdir()
    (marker / 'refs').mkdir()
    try:
        for entry in manifest['patches']:
            patch = str(root / entry['source'])
            git(destination, 'apply', '--check', '--whitespace=nowarn', patch)
            git(destination, 'apply', '--whitespace=nowarn', patch)
    finally:
        (marker / 'HEAD').unlink()
        (marker / 'objects').rmdir()
        (marker / 'refs').rmdir()
        marker.rmdir()
    receipt = dict(schemaVersion=1, sourceFingerprint=fingerprint,
                   upstreamCommit=manifest['upstreamCommit'],
                   files={name: {'blob': blob(path_at(destination, name).read_bytes()), 'owner': owner}
                          for name, owner in sorted(ownership.items())})
    (destination / '.btr-composition.json').write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'output': str(destination), 'files': len(receipt['files']), 'sourceFingerprint': fingerprint}))
    return receipt


def verify(root, destination, baseline=False):
    manifest, output, _, fingerprint, _ = inputs(root)
    receipt = json.loads((destination / '.btr-composition.json').read_text('utf-8'))
    if receipt['sourceFingerprint'] != fingerprint or set(receipt['files']) != set(output):
        raise ValueError('Stale composition: create a fresh output after source changes')
    for name, record in receipt['files'].items():
        if blob(path_at(destination, name).read_bytes()) != record['blob']:
            raise ValueError('Generated source was edited: ' + name)
    for directory in ('lib', 'test', 'android/app/src'):
        extra = {directory + '/' + n for n in files_under(destination / directory)} - set(receipt['files'])
        extra.discard('android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java')
        if extra:
            raise ValueError('Unlisted generated application source: ' + ', '.join(sorted(extra)))
    if baseline:
        expected = tree(root, manifest['behaviorBaseline'])
        paths = {n for n in expected if n.startswith(('lib/', 'android/', 'test/', 'third_party/')) or n in ('pubspec.yaml', 'pubspec.lock', '.fvmrc')}
        actual = {n for n in receipt['files'] if n.startswith(('lib/', 'android/', 'test/', 'third_party/')) or n in ('pubspec.yaml', 'pubspec.lock', '.fvmrc')}
        if paths != actual:
            raise ValueError('Application inventory differs from behavior baseline')
        for name in paths:
            if receipt['files'][name]['blob'] != expected[name][1]:
                raise ValueError('Behavior baseline differs: ' + name)
        print(f'PASS: {len(paths)} application/test/lock inputs identical to {manifest["behaviorBaseline"]}')
    print(f'PASS: {len(receipt["files"])} composed files; official tree and owned source inventory verified')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['compose', 'verify'])
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--output', default='.assembled/app')
    parser.add_argument('--baseline', action='store_true')
    args = parser.parse_args()
    root = args.root.resolve()
    destination = path_at(root, args.output)
    if args.command == 'compose':
        compose(root, destination)
    else:
        verify(root, destination, args.baseline)


if __name__ == '__main__':
    main()
