"""Failure-path tests for isolated memory studies; never launch a holder or UI."""
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]


class MemoryStudyCleanupTests(unittest.TestCase):
    def exercise_uncertain_start(self, stop_fails):
        spec = importlib.util.spec_from_file_location(
            'ui_memory_study', ROOT / 'scripts/benchmark-ui-memory.py')
        study = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(study)
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary)
            private = fixture / 'private study'
            private.mkdir()
            engine = fixture / 'controlled engine'
            engine.write_bytes(b'fixture, never executed')
            unrelated = fixture / 'unrelated session'
            unrelated.write_text('preserve')
            calls = []
            alive = False

            def rpc(arguments, *, input, env, cwd, **kwargs):
                nonlocal alive
                self.assertEqual(Path(arguments[-1]), private / 'engine home')
                self.assertEqual(Path(cwd), private / 'controlled project')
                self.assertEqual(env['HOME'], str(private))
                self.assertEqual(env['PATH'], '/usr/bin:/bin')
                self.assertNotIn('ANTHROPIC_API_KEY', env)
                request = json.loads(input)
                operation = request['operation']
                calls.append(operation)
                if operation == 'start':
                    self.assertEqual(request['kind'], 'terminal')
                    alive = True  # The operation happened before its reply was lost.
                    raise subprocess.TimeoutExpired(arguments, 20)
                if operation == 'stop':
                    self.assertEqual(request['agentId'], 1)
                    if stop_fails:
                        raise RuntimeError('controlled stop failure')
                    alive = False
                    result = {}
                elif operation == 'list':
                    result = {'agents': [{'id': 1, 'state': 'idle' if alive else 'exited'}]}
                else:
                    self.fail('Unexpected RPC: ' + operation)
                return subprocess.CompletedProcess(arguments, 0, json.dumps(
                    {'protocol': 1, 'ok': True, 'result': result}).encode())

            with mock.patch.object(study.tempfile, 'mkdtemp', return_value=str(private)), \
                    mock.patch.object(study.subprocess, 'run', side_effect=rpc), \
                    mock.patch.object(study.subprocess, 'Popen') as launch_ui, \
                    mock.patch.dict('os.environ', {'ANTHROPIC_API_KEY': 'fixture-not-a-secret'}):
                if stop_fails:
                    with self.assertRaisesRegex(RuntimeError, 'Private shell cleanup failed'):
                        study.run_scenario(engine, fixture / 'unused harness', 'list')
                else:
                    with self.assertRaises(subprocess.TimeoutExpired):
                        study.run_scenario(engine, fixture / 'unused harness', 'list')
                launch_ui.assert_not_called()
            self.assertEqual(calls, ['start', 'list', 'stop'] if stop_fails else
                             ['start', 'list', 'stop', 'list'])
            self.assertEqual(private.exists(), stop_fails)
            self.assertEqual(unrelated.read_text(), 'preserve')

    def test_uncertain_start_is_stopped_before_removing_private_home(self):
        self.exercise_uncertain_start(stop_fails=False)

    def test_failed_stop_preserves_private_home_for_recovery(self):
        self.exercise_uncertain_start(stop_fails=True)


if __name__ == '__main__':
    unittest.main()
