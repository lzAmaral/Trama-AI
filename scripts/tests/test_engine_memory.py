"""Memory benchmark safety: private fixtures, uncertain starts and request groups."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'benchmark-engine-memory.py'
spec = importlib.util.spec_from_file_location('engine_memory', SOURCE)
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class EngineMemoryTests(unittest.TestCase):
    def fake_engine(self, folder, mode='ok', log_text='TRAMA_MEMORY_COMPLETE'):
        binary, events = folder / f'fake-{mode}', folder / f'events-{mode}'
        binary.write_text(f'''#!{sys.executable}
import base64, json, os, pathlib, sys
assert "TRAMA_BENCHMARK_TEST_SECRET" not in os.environ
home = pathlib.Path(sys.argv[sys.argv.index('--home') + 1])
home.mkdir(parents=True, exist_ok=True)
state_file = home / 'fixture.json'
records = json.loads(state_file.read_text()) if state_file.exists() else []
request = json.load(sys.stdin)
op = request['operation']
with open({str(events)!r}, 'a') as output: output.write(op + '\\n')
result = {{}}
if op == 'list': result = {{'agents': records, 'sessions': []}}
elif op == 'start':
    agent = {{'id': len(records) + 1, 'state': 'idle'}}
    records.append(agent)
    state_file.write_text(json.dumps(records))
    if {mode!r} == 'uncertain': sys.exit(1)
    result = {{'agentId': agent['id']}}
elif op == 'stop':
    if {mode!r} == 'cleanup-fails': sys.exit(1)
    for agent in records:
        if agent['id'] == request['agentId']: agent['state'] = 'exited'
elif op == 'snapshot':
    result = {{'data':base64.b64encode(b'TRAMA_MEMORY_COMPLETE').decode(), 'rows':100, 'cols':240}}
elif op == 'logs': result = {{'text': {log_text!r}, 'truncated': True}}
state_file.write_text(json.dumps(records))
print(json.dumps({{'protocol':1, 'ok':True, 'result':result}}))
''')
        binary.chmod(0o700)
        return binary, events

    def private_root(self, folder):
        root = folder / 'private-root'
        root.mkdir()
        return root

    def test_benchmark_uses_private_environment_and_cleans_six_fixture_agents(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            binary, events = self.fake_engine(folder)
            root = self.private_root(folder)
            with patch.object(benchmark.tempfile, 'mkdtemp', return_value=str(root)), \
                    patch.dict(os.environ, {'TRAMA_BENCHMARK_TEST_SECRET': 'fixture-only'}):
                # Label used to collide with the engine home before binaries/ isolation.
                result = benchmark.measure({'engine': binary}, 2)
            self.assertTrue(result['cleanupConfirmed'])
            self.assertEqual(events.read_text().splitlines().count('stop'), 6)
            self.assertFalse(root.exists())

    def test_uncertain_start_still_discovers_and_stops_created_record(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            binary, events = self.fake_engine(folder, 'uncertain')
            root = self.private_root(folder)
            with patch.object(benchmark.tempfile, 'mkdtemp', return_value=str(root)):
                with self.assertRaisesRegex(RuntimeError, 'request process failed'):
                    benchmark.measure({'baseline': binary}, 2)
            self.assertIn('stop', events.read_text().splitlines())
            self.assertFalse(root.exists())

    def test_failed_cleanup_preserves_home(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            binary, _ = self.fake_engine(folder, 'cleanup-fails')
            root = self.private_root(folder)
            with patch.object(benchmark.tempfile, 'mkdtemp', return_value=str(root)), \
                    patch('sys.stderr'):
                with self.assertRaisesRegex(RuntimeError, 'holder cleanup failed'):
                    benchmark.measure({'baseline': binary}, 2)
            self.assertTrue(root.exists())
            records = json.loads((root / 'engine/fixture.json').read_text())
            self.assertTrue(any(record['state'] != 'exited' for record in records))

    def test_different_history_is_rejected_and_cleanup_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            baseline, events = self.fake_engine(folder)
            candidate, _ = self.fake_engine(folder, 'changed', 'TRAMA_MEMORY_COMPLETE changed')
            root = self.private_root(folder)
            with patch.object(benchmark.tempfile, 'mkdtemp', return_value=str(root)):
                with self.assertRaisesRegex(RuntimeError, 'different results'):
                    benchmark.measure({'baseline': baseline, 'candidate': candidate}, 2)
            self.assertEqual(events.read_text().splitlines().count('stop'), 6)
            self.assertFalse(root.exists())

    def test_timeout_kills_wrapper_and_its_request_descendant(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            marker = folder / 'orphan-completed'
            code = f'import time,pathlib; time.sleep(.8); pathlib.Path({str(marker)!r}).touch()'
            command = ['/usr/bin/time', '-l', sys.executable, '-c', code]
            with self.assertRaises(subprocess.TimeoutExpired):
                benchmark.run_request(command, b'', env={'PATH': '/usr/bin:/bin'}, cwd=folder, timeout=.1)
            time.sleep(.9)
            self.assertFalse(marker.exists(), 'the engine descendant survived its wrapper timeout')

    def test_signal_kills_request_group_before_unwinding(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            marker, ready = folder / 'orphan-completed', folder / 'ready'
            code = f'import time,pathlib; pathlib.Path({str(ready)!r}).touch(); time.sleep(.8); pathlib.Path({str(marker)!r}).touch()'
            driver = f'''
import importlib.util, signal, sys
spec = importlib.util.spec_from_file_location('memory', {str(SOURCE)!r})
memory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(memory)
signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
try:
    memory.run_request(['/usr/bin/time', '-l', {sys.executable!r}, '-c', {code!r}], b'',
        env={{'PATH':'/usr/bin:/bin'}}, cwd={str(folder)!r})
except KeyboardInterrupt:
    sys.exit(0)
'''
            process = subprocess.Popen([sys.executable, '-c', driver], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(ready.exists())
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=5), 0)
                time.sleep(.9)
                self.assertFalse(marker.exists())
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()


if __name__ == '__main__':
    unittest.main()
