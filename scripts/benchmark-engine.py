#!/usr/bin/env python3
"""Measure process-per-RPC transport during controlled PTY output, without providers."""
import argparse
import base64
import hashlib
import json
import math
import os
import platform
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def summary(samples):
    values = sorted(samples)
    return {'count': len(values), 'medianMs': values[len(values)//2],
            'p95Ms': values[max(0, math.ceil(len(values)*.95)-1)], 'maxMs': values[-1]}


def benchmark(engine, interval, batches):
    root = Path(tempfile.mkdtemp(prefix='trama benchmark '))
    home, project = root / 'engine home', root / 'controlled project'
    project.mkdir()
    # A fresh allowlist prevents inherited credentials, shell startup hooks and provider paths.
    env = {'HOME': str(root), 'SHELL': '/bin/sh', 'PATH': '/usr/bin:/bin',
           'TMPDIR': str(root), 'TERM': 'xterm-256color', 'LANG': 'C', 'LC_ALL': 'C'}
    engine_copy = root / 'engine under test'
    engine_hash = None
    agent = None
    started = False
    report = None
    timings = {}
    sizes = {}

    def rpc(operation, **kwargs):
        begin = time.perf_counter()
        result = subprocess.run([str(engine_copy), '--request', '--home', str(home)],
            input=json.dumps(dict(operation=operation, **kwargs)).encode(),
            capture_output=True, env=env, cwd=project, timeout=15, check=True)
        elapsed = (time.perf_counter() - begin) * 1000
        # Never print subprocess stderr, which is outside the report contract.
        reply = json.loads(result.stdout)
        if reply.get('protocol') != 1 or not reply.get('ok'):
            raise RuntimeError(f'{operation} RPC failed')
        timings.setdefault(operation, []).append(elapsed)
        sizes.setdefault(operation, []).append(len(result.stdout))
        return reply['result']

    try:
        source_hash = hashlib.sha256(engine.read_bytes()).hexdigest()
        shutil.copy2(engine, engine_copy)
        engine_hash = hashlib.sha256(engine_copy.read_bytes()).hexdigest()
        if source_hash != engine_hash:
            raise RuntimeError('engine changed while creating benchmark copy')
        for _ in range(10):
            rpc('list')
        baseline = timings.pop('list')
        started = True  # A timeout may still have created the holder; finally enumerates this home.
        agent = rpc('start', kind='terminal', cwd=str(project), name='benchmark-shell')['agentId']
        rpc('resize', agentId=agent, rows=100, cols=240)
        for _ in range(10):
            rpc('snapshot', agentId=agent)
        idle = timings.pop('snapshot')
        # 1000 lines of exactly 91 bytes each per batch, excluding PTY CR expansion.
        line = 'TRAMA_LOAD_' + 'x' * 79
        script = project / 'generate output.sh'
        script.write_text("#!/bin/sh\nset -eu\ni=0\nwhile [ \"$i\" -lt " + str(batches) + " ]; do\n"
            + "/usr/bin/awk 'BEGIN {for(i=0;i<1000;i++) print \"" + line + "\"}'\n"
            + "i=$((i+1))\n/bin/sleep 0.1\ndone\nprintf 'TRAMA_%s\\n' BENCHMARK_COMPLETE\n")
        begin = time.perf_counter()
        command = '/bin/sh ' + shlex.quote(str(script)) + '\n'
        rpc('input', agentId=agent, input=base64.b64encode(command.encode()).decode())
        snapshot_bytes = []
        deadline = begin + max(30, batches * .5)
        while True:
            snapshot = rpc('snapshot', agentId=agent)
            data = base64.b64decode(snapshot['data'], validate=True)
            snapshot_bytes.append(len(data))
            rpc('list')
            if b'TRAMA_BENCHMARK_COMPLETE' in data:
                break
            if time.perf_counter() > deadline:
                raise RuntimeError('controlled output completion was not observed before deadline')
            time.sleep(interval)
        elapsed = time.perf_counter() - begin
        rpc('stop', agentId=agent)  # Ensure the holder flushes its buffered operation log.
        replay = rpc('logs', agentId=agent)
        if 'TRAMA_BENCHMARK_COMPLETE' not in replay['text']:
            raise RuntimeError('completion absent from bounded log replay')
        report = dict(schema=1, timestampUTC=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
            host=dict(system=platform.system(), release=platform.release(), machine=platform.machine()),
            engineSHA256=engine_hash,
            workload=dict(batches=batches, linesPerBatch=1000, bytesPerLine=len(line)+1,
                generatedBytes=batches*1000*(len(line)+1), pausePerBatchSeconds=.1,
                pollPauseSeconds=interval, rows=100, cols=240, completionObserved=True),
            elapsedSeconds=elapsed,
            baselineList=summary(baseline), baselineSnapshot=summary(idle),
            loadedList=summary(timings['list']), loadedSnapshot=summary(timings['snapshot']),
            snapshotDecodedBytes=dict(min=min(snapshot_bytes), max=max(snapshot_bytes)),
            rpcMs=timings, rpcEnvelopeBytes=sizes,
            limits=['Includes process spawn, JSON/base64 and holder probe; no Swift client or rendering.',
                    'Sequential list/snapshot pressure; pause adds to request duration; not fixed-rate sampling.',
                    'Viewport snapshots and bounded replay do not prove lossless full-history transport.',
                    'No authenticated providers, usage queries, network requests or visual UX validation.'])
    finally:
        # Discover ONLY our private home even if start timed out before returning an id.
        # Defer late/repeated interrupts until stop, verification and recovery diagnostics
        # finish. An interrupt raised inside finally would otherwise skip the rest of cleanup.
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK,
            {signal.SIGINT, signal.SIGTERM, signal.SIGHUP})
        try:
            cleanup_ok = False
            try:
                agents = rpc('list')['agents'] if started else []
                for record in agents:
                    if record['state'] != 'exited':
                        rpc('stop', agentId=record['id'])
                remaining = rpc('list')['agents'] if started else []
                cleanup_ok = all(record['state'] == 'exited' for record in remaining)
            except Exception:
                pass
            if cleanup_ok:
                shutil.rmtree(root)
            else:
                print(f'Holder cleanup unconfirmed; preserving temporary home: {root}', file=sys.stderr)
                raise RuntimeError('holder cleanup failed; temporary home preserved')
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    report['cleanupConfirmed'] = True
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine', type=Path, default=ROOT / 'Engine/target/debug/trama-engine')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--poll-pause', type=float, default=.05)
    parser.add_argument('--batches', type=int, default=40)
    args = parser.parse_args()
    if not (0 <= args.poll_pause <= 2 and 1 <= args.batches <= 100):
        parser.error('poll pause must be 0..2 seconds and batches 1..100')
    engine = args.engine.resolve(strict=True)
    report = benchmark(engine, args.poll_pause, args.batches)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Preserve earlier evidence if a run fails; publish only after confirmed cleanup.
    with tempfile.NamedTemporaryFile(mode='w', prefix=args.output.name + '.',
            dir=args.output.parent, delete=False) as handle:
        temp = Path(handle.name)
        handle.write(json.dumps(report, indent=2) + '\n')
    try:
        temp.replace(args.output)
    finally:
        temp.unlink(missing_ok=True)
    print(json.dumps({key: report[key] for key in ['elapsedSeconds', 'loadedList', 'loadedSnapshot', 'cleanupConfirmed']}))


if __name__ == '__main__':
    # Terminal hangup must also clean up detached holders. SIGKILL cannot be handled.
    for interrupt in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]:
        signal.signal(interrupt, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt):
        print('Benchmark failed; previous report preserved.', file=sys.stderr)
        sys.exit(1)
