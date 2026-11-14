#!/usr/bin/env python3
"""Collect notices from locked, locally cached sources; never accesses the network."""
import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NOTICE = re.compile(r"^(licen[cs]e|copying|notice|copyright|authors)([. _-]|$)", re.I)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run(args):
    return subprocess.check_output(args, cwd=ROOT)


def collect():
    metadata = json.loads(run([str(ROOT / 'scripts/cargo-local.sh'), 'metadata',
        '--locked', '--offline', '--format-version', '1', '--manifest-path', 'Engine/Cargo.toml']))
    # Cargo metadata covers every target and dev/build dependency, conservatively.
    packages, blobs = [], {}
    targets = {}
    for target in ['aarch64-apple-darwin', 'x86_64-apple-darwin']:
        selected = json.loads(run([str(ROOT / 'scripts/cargo-local.sh'), 'metadata', '--locked',
            '--offline', '--format-version', '1', '--manifest-path', 'Engine/Cargo.toml',
            '--filter-platform', target]))
        targets[target] = {node['id'] for node in selected['resolve']['nodes']}
    lock = (ROOT / 'Engine/Cargo.lock').read_text()
    for p in sorted(metadata['packages'], key=lambda p: (p['name'], p['version'])):
        if p['source'] is None:
            continue  # Trama itself
        source = p['source']
        entry = dict(ecosystem='cargo', name=p['name'], version=p['version'],
                     license=p['license'], repository=p['repository'], source=source)
        entry['cargoTargets'] = [target for target, ids in targets.items() if p['id'] in ids]
        folder = Path(p['manifest_path']).parent
        if source.startswith('registry+'):
            # Cargo.lock is the authority for the archive checksum, not mutable cache metadata.
            block = next(b for b in lock.split('[[package]]')
                         if f'name = "{p["name"]}"\n' in b and f'version = "{p["version"]}"\n' in b)
            match = re.search(r'^checksum = "([a-f0-9]+)"$', block, re.M)
            if not match:
                raise ValueError('registry package lacks a locked checksum')
            entry['archiveSHA256'] = match[1]
            entry['archiveURL'] = f'https://static.crates.io/crates/{p["name"]}/{p["name"]}-{p["version"]}.crate'
        else:
            revision = source.rsplit('#', 1)[-1]
            actual = run(['git', '-C', str(folder), 'rev-parse', 'HEAD']).decode().strip()
            if actual != revision:
                raise ValueError(f'checkout revision mismatch: {p["name"]}')
        add_notices(entry, folder, p.get('license_file'), blobs)
        packages.append(entry)
    swift_licenses = {'swiftterm': 'MIT', 'swift-argument-parser': 'Apache-2.0'}
    for pin in json.loads((ROOT / 'Package.resolved').read_bytes())['pins']:
        if pin['identity'] not in swift_licenses:
            raise ValueError(f'Unreviewed Swift license: {pin["identity"]}')
        folder = ROOT / '.build/checkouts' / ('SwiftTerm' if pin['identity'] == 'swiftterm' else pin['identity'])
        revision = pin['state']['revision']
        actual = run(['git', '-C', str(folder), 'rev-parse', 'HEAD']).decode().strip()
        if actual != revision:
            raise ValueError(f'checkout revision mismatch: {pin["identity"]}')
        entry = dict(ecosystem='swift', name=pin['identity'], version=pin['state'].get('version'),
                     revision=revision, repository=pin['location'], source=pin['location'] + '#' + revision,
                     license=swift_licenses[pin['identity']])
        add_notices(entry, folder, None, blobs)
        packages.append(entry)
    inventory = dict(schema=1,
        scope='All locked Cargo external packages (including optional, build, dev and other platforms) and Swift pins; not a linked-binary audit or legal certification.',
        inputs={p: digest((ROOT / p).read_bytes()) for p in ['Engine/Cargo.lock', 'Package.resolved']},
        packages=packages,
        missing=[f'{p["ecosystem"]}:{p["name"]}@{p.get("version") or p.get("revision")}' for p in packages if not p['notices']])
    files = {'inventory.json': (json.dumps(inventory, indent=2, ensure_ascii=False) + '\n').encode()}
    files.update({'texts/' + h + '.txt': data for h, data in blobs.items()})
    return inventory, files


def add_notices(entry, folder, license_file, blobs):
    files = {p for p in folder.rglob('*') if p.is_file() and '.git' not in p.parts and NOTICE.match(p.name)}
    if license_file:
        candidate = Path(license_file)
        if not candidate.is_absolute():
            candidate = folder / candidate
        files.add(candidate)
    entry['notices'] = []
    for path in sorted(files):
        # Refuse symlinks escaping the source checkout.
        relative = path.resolve().relative_to(folder.resolve()).as_posix()
        data = path.read_bytes()
        h = digest(data)
        blobs[h] = data
        entry['notices'].append(dict(sourcePath=relative, sha256=h, text='texts/' + h + '.txt'))
    entry['status'] = 'texts-collected' if files else 'missing-texts'


def write_output(destination, files):
    destination = destination.absolute()
    if destination.is_symlink() or destination.resolve() == ROOT or destination.resolve() in ROOT.parents:
        raise ValueError('Unsafe notice output directory')
    existing = set()
    if destination.exists():
        if not destination.is_dir():
            raise ValueError('Notice output is not a directory')
        paths = list(destination.rglob('*'))
        if any(p.is_symlink() for p in paths):
            raise ValueError('Symlinks are not permitted in generated output')
        existing = {p.relative_to(destination).as_posix() for p in paths if p.is_file()}
        if existing:
            prior = json.loads((destination / 'inventory.json').read_bytes())
            if prior.get('schema') != 1 or not isinstance(prior.get('packages'), list):
                raise ValueError('Unrecognized generated inventory')
            owned = {'inventory.json'}
            for package in prior['packages']:
                for notice in package['notices']:
                    name = notice['text']
                    if not re.fullmatch(r'texts/[a-f0-9]{64}\.txt', name):
                        raise ValueError('Unsafe file in prior generated inventory')
                    owned.add(name)
            if existing - owned:
                raise ValueError('Output contains files not owned by prior inventory; refusing to overwrite')
    # Build the complete generation beside the destination. A failed write must never
    # replace its inventory or leave stale texts unowned and block a subsequent retry.
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=destination.name + '.stage.',
            dir=destination.parent) as temporary:
        stage = Path(temporary) / 'artifact'
        stage.mkdir()
        for name, data in files.items():
            dest = stage / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
        subprocess.run([sys.executable, str(ROOT / 'scripts/publish-directory.py'),
            str(stage), str(destination)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Fail on drift OR missing texts; never writes.')
    parser.add_argument('--target', choices=['aarch64-apple-darwin', 'x86_64-apple-darwin'],
                        help='With --check, require texts only for this conservative target graph plus Swift pins.')
    parser.add_argument('--output', type=Path, default=ROOT / 'ThirdPartyNotices/generated')
    args = parser.parse_args()
    inventory, files = collect()
    if args.check:
        actual = {p.relative_to(args.output).as_posix(): p.read_bytes() for p in args.output.rglob('*') if p.is_file()}
        if actual != files:
            print('Notice output differs; run scripts/generate-notices.py', file=sys.stderr)
            return 1
    else:
        write_output(args.output, files)
    print(f'{len(inventory["packages"])} external packages; {len(files)-1} distinct notice texts; {len(inventory["missing"])} missing')
    for name in inventory['missing']:
        print('MISSING: ' + name, file=sys.stderr)
    missing = [p for p in inventory['packages'] if not p['notices'] and
               (not args.target or p['ecosystem'] == 'swift' or args.target in p['cargoTargets'])]
    if args.target:
        print(f'{args.target}: {len(missing)} missing texts (includes build/dev graph; not a linker map)')
    return 1 if args.check and missing else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'Notice collection failed: {error}', file=sys.stderr)
        sys.exit(1)
