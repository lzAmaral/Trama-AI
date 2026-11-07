#!/usr/bin/env python3
"""Controlled-tool tests: no real signing identity, provider or Apple request is used."""
import importlib.util
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / file)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class Tools(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='trama scripts spaces ')
        self.root = Path(self.tmp.name)
        (self.root / 'scripts').mkdir()
        for name in ['package-app.sh', 'publish-directory.py', 'distribute-app.sh']:
            shutil.copy2(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        self.bin = self.root / 'fake tools'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'], FIXTURE=str(self.root))
        self.tool('codesign', '#!/bin/sh\n[ "${FAIL_SIGN:-}" != 1 ]\n')

    def tearDown(self):
        self.tmp.cleanup()

    def tool(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)

    def run_script(self, name, *args, **env):
        return subprocess.run([str(self.root / 'scripts' / name), *args], env=dict(self.env, **env), capture_output=True)

    def app(self, path):
        (path / 'Contents/MacOS').mkdir(parents=True)
        (path / 'Contents/MacOS/Trama').write_text('main')
        (path / 'Contents/MacOS/trama-engine').write_text('engine')
        return path

    def test_failed_publish_restores_previous_directory(self):
        publisher = module('publisher', 'scripts/publish-directory.py')
        old, new = self.root / 'existing app', self.root / 'new app'
        old.mkdir(); new.mkdir()
        (old / 'sentinel').write_text('original')
        rename = os.rename
        def fail(source, dest):
            if Path(source) == new:
                raise OSError('injected rename failure')
            return rename(source, dest)
        with patch.object(publisher.os, 'rename', side_effect=fail):
            with self.assertRaises(OSError):
                publisher.publish(new, old)
        self.assertEqual((old / 'sentinel').read_text(), 'original')
        self.assertTrue(new.exists())

    def test_double_publish_failure_preserves_backup_outside_staging(self):
        publisher = module('publisher_double', 'scripts/publish-directory.py')
        stage = self.root / 'staging'
        stage.mkdir()
        new, old = stage / 'new app', self.root / 'existing app'
        new.mkdir(); old.mkdir()
        (old / 'sentinel').write_text('original')
        rename = os.rename
        def fail(source, dest):
            if Path(dest) == old:
                raise OSError('injected publish and rollback failure')
            return rename(source, dest)
        with patch.object(publisher.os, 'rename', side_effect=fail):
            with self.assertRaises(OSError):
                publisher.publish(new, old)
        shutil.rmtree(stage)  # Simulate the shell trap after failure.
        backups = list(self.root.glob('existing app.previous.*/artifact/sentinel'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), 'original')

    def test_publish_rejects_file_destination(self):
        publisher = module('publisher_file', 'scripts/publish-directory.py')
        new, old = self.root / 'new app', self.root / 'existing file'
        new.mkdir(); old.write_text('preserved')
        with self.assertRaises(ValueError):
            publisher.publish(new, old)
        self.assertEqual(old.read_text(), 'preserved')

    def test_notice_output_rejects_unknown_files_and_symlinks(self):
        notices = module('notices', 'scripts/generate-notices.py')
        out = self.root / 'notice output'
        out.mkdir()
        marker = out / 'user data'
        marker.write_text('preserve')
        with self.assertRaises((ValueError, OSError)):
            notices.write_output(out, {'inventory.json': b'{}'})
        self.assertEqual(marker.read_text(), 'preserve')
        link = self.root / 'notice symlink'
        link.symlink_to(out, target_is_directory=True)
        with self.assertRaises(ValueError):
            notices.write_output(link, {})
        with self.assertRaises(ValueError):
            notices.write_output(ROOT, {})

    def test_notice_write_failure_preserves_generation_and_allows_retry(self):
        notices = module('notices_atomic', 'scripts/generate-notices.py')
        out = self.root / 'notice output'
        old, new = 'texts/' + 'a' * 64 + '.txt', 'texts/' + 'b' * 64 + '.txt'
        def inventory(name):
            return json.dumps({'schema': 1, 'packages': [{'notices': [{'text': name}]}]}).encode()
        notices.write_output(out, {'inventory.json': inventory(old), old: b'old text'})
        before = {p.relative_to(out): p.read_bytes() for p in out.rglob('*') if p.is_file()}
        files = {'inventory.json': inventory(new), new: b'new text'}
        write = Path.write_bytes
        def fail(path, data):
            if path.name == Path(new).name:
                raise OSError('injected disk write failure')
            return write(path, data)
        with patch.object(Path, 'write_bytes', fail):
            with self.assertRaises(OSError):
                notices.write_output(out, files)
        self.assertEqual({p.relative_to(out): p.read_bytes() for p in out.rglob('*') if p.is_file()}, before)
        self.assertEqual(list(self.root.glob('notice output.stage.*')), [])
        notices.write_output(out, files)
        self.assertEqual({p.relative_to(out).as_posix(): p.read_bytes() for p in out.rglob('*') if p.is_file()}, files)

    def prepare_package(self):
        (self.root / '.build/fake bin/SwiftTerm_SwiftTerm.bundle').mkdir(parents=True)
        (self.root / '.build/fake bin/Trama').write_text('main')
        (self.root / 'Engine/target/debug').mkdir(parents=True)
        (self.root / 'Engine/target/debug/trama-engine').write_text('engine')
        (self.root / 'ThirdPartyNotices').mkdir()
        (self.root / 'ThirdPartyNotices/license').write_text('notice')
        (self.root / 'scripts/Info.plist').write_text('plist')
        cargo = self.root / 'scripts/cargo-local.sh'
        cargo.write_text('#!/bin/sh\nexit 0\n'); cargo.chmod(0o755)
        self.tool('swift', '#!/bin/sh\ncase "$*" in *--show-bin-path*) printf "%s/.build/fake bin\\n" "$FIXTURE";; esac\n')
        previous = self.root / '.build/Trama.app'
        previous.mkdir()
        (previous / 'sentinel').write_text('original')
        return previous

    def test_package_failure_preserves_previous_bundle(self):
        previous = self.prepare_package()
        result = self.run_script('package-app.sh', FAIL_SIGN='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((previous / 'sentinel').read_text(), 'original')
        self.assertEqual(list((self.root / '.build').glob('package.*')), [])

    def test_package_success_with_spaces_contains_resources_notices(self):
        bundle = self.prepare_package()
        result = self.run_script('package-app.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((bundle / 'Contents/Resources/SwiftTerm_SwiftTerm.bundle').is_dir())
        self.assertEqual((bundle / 'Contents/Resources/ThirdPartyNotices/license').read_text(), 'notice')
        self.assertFalse((bundle / 'sentinel').exists())

    def test_package_custom_output_preserves_default_bundle(self):
        previous = self.prepare_package()
        result = self.run_script('package-app.sh', '--output', '.build/validation path/Test.app')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((previous / 'sentinel').read_text(), 'original')
        self.assertTrue((self.root / '.build/validation path/Test.app/Contents/MacOS/Trama').exists())

    def test_package_rejects_outputs_outside_build_and_nested_bundle(self):
        for output in ['/tmp/Unrelated.app', '.build/Trama.app/nested.app', '.build/invalid']:
            result = self.run_script('package-app.sh', '--output', output)
            self.assertEqual(result.returncode, 2, output)
        self.assertFalse((self.root / '.build').exists())

    def test_distribution_requires_explicit_identity_before_tools(self):
        self.tool('codesign', '#!/bin/sh\ntouch "$FIXTURE/unexpected-sign"\n')
        result = self.run_script('distribute-app.sh')
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.root / 'unexpected-sign').exists())

    def test_distribution_failure_preserves_source_and_previous_artifact(self):
        source = self.app(self.root / 'source app')
        previous = self.root / '.build/distribution'
        previous.mkdir(parents=True)
        (previous / 'sentinel').write_text('previous distribution')
        result = self.run_script('distribute-app.sh', '--app', str(source), '--identity',
                                 'Developer ID Application: Test Fixture (FAKE)', FAIL_SIGN='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((source / 'Contents/MacOS/Trama').read_text(), 'main')
        self.assertEqual((previous / 'sentinel').read_text(), 'previous distribution')
        self.assertNotIn(b'FAKE', result.stdout + result.stderr)
        self.assertEqual(list((self.root / '.build').glob('distribution-stage.*')), [])

    def test_notarization_rejection_preserves_previous_and_hides_profile(self):
        source = self.app(self.root / 'source app')
        previous = self.root / '.build/distribution'
        previous.mkdir(parents=True)
        (previous / 'sentinel').write_text('old')
        self.tool('xcrun', '#!/bin/sh\nprintf \'{"status":"Invalid"}\\n\'\n')
        result = self.run_script('distribute-app.sh', '--app', str(source), '--identity',
            'Developer ID Application: Test Fixture (FAKE)', '--notarize', '--keychain-profile', 'private-profile')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((previous / 'sentinel').read_text(), 'old')
        self.assertNotIn(b'private-profile', result.stdout + result.stderr)

    def test_notarized_fixture_staples_before_final_archive(self):
        source = self.app(self.root / 'source app')
        self.tool('xcrun', '''#!/bin/sh
case "$1 $2" in
 'notarytool submit') printf '{"status":"Accepted"}\\n' ;;
 'stapler staple') touch "$3/stapled-fixture" ;;
 'stapler validate') test -f "$3/stapled-fixture" ;;
esac
''')
        result = self.run_script('distribute-app.sh', '--app', str(source), '--identity',
            'Developer ID Application: Test Fixture (FAKE)', '--notarize', '--keychain-profile', 'private-profile')
        self.assertEqual(result.returncode, 0, result.stderr)
        import zipfile
        with zipfile.ZipFile(self.root / '.build/distribution/Trama.zip') as archive:
            self.assertIn('Trama.app/stapled-fixture', archive.namelist())
        self.assertFalse((source / 'stapled-fixture').exists())

    def test_benchmark_preserves_temporary_home_when_stop_fails(self):
        bench = module('benchmark', 'scripts/benchmark-engine.py')
        private = self.root / 'benchmark private'
        private.mkdir()
        def rpc_fixture(command, **kwargs):
            request = json.loads(kwargs['input'])
            operation = request['operation']
            import base64
            payload = {'list': {'agents': [{'id': 1, 'state': 'running'}]},
                'start': {'agentId': 1}, 'resize': {}, 'input': {},
                'snapshot': {'data': base64.b64encode(b'TRAMA_BENCHMARK_COMPLETE').decode()},
                'logs': {'text': 'TRAMA_BENCHMARK_COMPLETE'}}
            reply = {'protocol': 1, 'ok': operation != 'stop', 'result': payload.get(operation, {})}
            return subprocess.CompletedProcess(command, 0, json.dumps(reply).encode(), b'')
        with patch.object(bench.tempfile, 'mkdtemp', return_value=str(private)), \
                patch.object(bench.subprocess, 'run', side_effect=rpc_fixture):
            with self.assertRaisesRegex(RuntimeError, 'cleanup failed'):
                bench.benchmark(ROOT / 'scripts/benchmark-engine.py', 0, 1)
        self.assertTrue((private / 'controlled project/generate output.sh').exists())

    def test_benchmark_signals_stop_private_holder_or_preserve_home_on_failure(self):
        # Run the real CLI entry point, intercepting only RPC and the private temp path.
        # No sidecar or holder is started; the parent sends an OS signal while input waits.
        fixture = r'''
import json, runpy, subprocess, sys, time
from pathlib import Path
from unittest.mock import patch
root, repo, fail, phase = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3] == 'fail', sys.argv[4]
private = root / 'private home'
private.mkdir()
started, state = False, 'running'
def rpc(command, **kwargs):
    global started, state
    op = json.loads(kwargs['input'])['operation']
    with (root / 'operations').open('a') as handle:
        handle.write(op + '\n')
    if op == 'start':
        started = True
        if phase == 'cleanup': raise RuntimeError('uncertain start result')
    if op == 'list' and started and phase == 'cleanup' and not (root / 'ready').exists():
        (root / 'ready').touch()
        while not (root / 'release').exists(): time.sleep(.01)
    if op == 'input':
        (root / 'ready').touch()
        time.sleep(30)
    if op == 'stop' and not fail: state = 'exited'
    payload = {'list': {'agents': [{'id': 1, 'state': state}] if started else []},
        'start': {'agentId': 1}, 'resize': {}, 'snapshot': {'data': 'aWRsZQ=='}}
    reply = {'protocol': 1, 'ok': not (op == 'stop' and fail), 'result': payload.get(op, {})}
    return subprocess.CompletedProcess(command, 0, json.dumps(reply).encode(), b'')
sys.argv = [str(repo / 'scripts/benchmark-engine.py'), '--engine',
    str(repo / 'scripts/benchmark-engine.py'), '--output', str(root / 'report.json')]
with patch('tempfile.mkdtemp', return_value=str(private)), patch('subprocess.run', side_effect=rpc):
    runpy.run_path(str(repo / 'scripts/benchmark-engine.py'), run_name='__main__')
'''
        cases = [(s, False, phase) for s in [signal.SIGHUP, signal.SIGTERM, signal.SIGINT]
            for phase in ['input', 'cleanup']]
        cases += [(signal.SIGHUP, True, phase) for phase in ['input', 'cleanup']]
        for signum, fail, phase in cases:
            with self.subTest(signal=signum, cleanup_fails=fail, phase=phase):
                root = self.root / f'signal {signum} {fail} {phase}'
                root.mkdir()
                (root / 'report.json').write_text('previous evidence')
                child = subprocess.Popen([sys.executable, '-c', fixture, str(root), str(ROOT),
                    'fail' if fail else 'ok', phase], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    deadline = time.monotonic() + 10
                    while not (root / 'ready').exists() and child.poll() is None and time.monotonic() < deadline:
                        time.sleep(.01)
                    self.assertTrue((root / 'ready').exists(), 'RPC fixture did not reach input')
                    child.send_signal(signum)
                    if phase == 'cleanup':
                        (root / 'release').touch()
                    _, error = child.communicate(timeout=10)
                    self.assertEqual(child.returncode, 1, error)
                    self.assertIn('stop', (root / 'operations').read_text().splitlines())
                    self.assertEqual((root / 'private home').exists(), fail)
                    self.assertEqual(b'preserving temporary home' in error, fail)
                    self.assertEqual((root / 'report.json').read_text(), 'previous evidence')
                finally:
                    if child.poll() is None:
                        child.kill()
                    child.communicate()

    def test_collected_notices_are_hashed_and_missing_windows_excluded_on_mac(self):
        import hashlib
        data = json.loads((ROOT / 'ThirdPartyNotices/generated/inventory.json').read_text())
        self.assertGreater(len(data['packages']), 100)
        for p in data['packages']:
            if not p['notices']:
                self.assertEqual(p['cargoTargets'], [])
            for notice in p['notices']:
                content = (ROOT / 'ThirdPartyNotices/generated' / notice['text']).read_bytes()
                self.assertEqual(hashlib.sha256(content).hexdigest(), notice['sha256'])


if __name__ == '__main__':
    unittest.main()
