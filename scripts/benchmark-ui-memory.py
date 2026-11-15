#!/usr/bin/env python3
"""Measure the real native UI in fresh processes, using six private shell sessions only.

Build the harness as documented in --help. Never opens the user's engine home.
"""
import argparse
import hashlib
import json
import platform
import shutil
import signal
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_scenario(engine, harness, mode):
    root = Path(tempfile.mkdtemp(prefix='trama ui memory '))
    home = root / 'engine home'
    project = root / 'controlled project'
    project.mkdir()
    copied_engine = root / 'engine under test'
    shutil.copy2(engine, copied_engine)
    if digest(copied_engine) != digest(engine):
        raise RuntimeError('Engine changed during private copy')
    env = {'HOME': str(root), 'SHELL': '/bin/sh', 'PATH': '/usr/bin:/bin',
           'TMPDIR': str(root), 'TERM': 'xterm-256color', 'LANG': 'C', 'LC_ALL': 'C'}
    result = None
    started = False
    ui = None

    def rpc(operation, **kwargs):
        call = subprocess.run([str(copied_engine), '--request', '--home', str(home)],
            input=json.dumps(dict(operation=operation, **kwargs)).encode(),
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd=project, env=env, timeout=20, check=True)
        reply = json.loads(call.stdout)
        if reply.get('protocol') != 1 or not reply.get('ok'):
            raise RuntimeError(f'{operation} RPC failed')
        return reply['result']

    try:
        for index in range(6):
            started = True  # A timed-out start may have created a durable holder.
            agent = rpc('start', kind='terminal', cwd=str(project), name=f'memory-shell-{index}')['agentId']
            rpc('resize', agentId=agent, rows=40, cols=120)
        # 40,000 fixed lines / shell; 3.64 MB before PTY CR expansion, plus marker.
        line = 'TRAMA_LOAD_' + 'x' * 79
        (project / 'generate-output.sh').write_text(
            '#!/bin/sh\nset -eu\ni=0\nwhile [ "$i" -lt 40 ]; do\n'
            + "/usr/bin/awk 'BEGIN {for(i=0;i<1000;i++) print \"" + line + "\"}'\n"
            + 'i=$((i+1))\n/bin/sleep 0.1\ndone\nprintf "TRAMA_%s\\n" MEMORY_COMPLETE\n')
        report = root / 'report.json'
        # Child uses a native UI but receives the same sanitized provider environment.
        ui = subprocess.Popen([str(harness), str(copied_engine), str(root), mode, str(report)],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, cwd=project)
        stdout, _ = ui.communicate(timeout=180)
        if ui.returncode != 0:
            raise RuntimeError(f'UI harness failed ({mode}, exit {ui.returncode}); no user data was read')
        result = json.loads(report.read_text())
        expected = {'list': 0, 'terminal': 1, 'grid': 6, 'grid2': 2, 'cycles': 0}[mode]
        if result.get('expectedTerminalViews') != expected or result.get('mode') != mode:
            raise RuntimeError('Harness does not support the requested scenario; rebuild it')
        if result.get('visibleWindow') is not True:
            raise RuntimeError('The benchmark window was closed or hidden during the study')
        groups = {}
        for sample in result['samples']:
            groups.setdefault(sample['phase'], []).append(sample)
        result['summary'] = {phase: {
            'sampleCount': len(items),
            'medianFootprintBytes': statistics.median(item['footprintBytes'] for item in items),
            'maximumFootprintBytes': max(item['footprintBytes'] for item in items),
            'cpuSecondsDelta': items[-1]['cpuSeconds'] - items[0]['cpuSeconds'],
            'terminalViewCounts': sorted(set(item['terminalViews'] for item in items)),
        } for phase, items in groups.items()}
    finally:
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM, signal.SIGHUP})
        try:
            if ui is not None and ui.poll() is None:
                ui.terminate()
                try:
                    ui.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    ui.kill()
                    ui.wait()
            cleanup = False
            try:
                agents = rpc('list')['agents'] if started else []
                for agent in agents:
                    if agent['state'] != 'exited':
                        rpc('stop', agentId=agent['id'])
                cleanup = all(agent['state'] == 'exited' for agent in rpc('list')['agents']) if started else True
            finally:
                if cleanup:
                    shutil.rmtree(root)
                else:
                    print(f'Cleanup could not be confirmed; isolated home preserved: {root}', flush=True)
                    raise RuntimeError('Private shell cleanup failed')
            if result is not None:
                result['cleanupConfirmed'] = cleanup
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog='Build: swift build -c release --jobs 2 -Xswiftc -enable-testing; then swiftc -O -parse-as-library -swift-version 6 -I .build/arm64-apple-macosx/release/Modules scripts/benchmark-ui-memory.swift -Xlinker -filelist -Xlinker .build/arm64-apple-macosx/release/Trama.product/Objects.LinkFileList -o .build/memory-study/ui-memory')
    parser.add_argument('--engine', type=Path, required=True)
    parser.add_argument('--harness', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--modes', nargs='+', choices=['list', 'terminal', 'grid', 'grid2', 'cycles'], default=['list', 'terminal', 'grid', 'grid2', 'cycles'])
    parser.add_argument('--repetitions', type=int, default=1)
    args = parser.parse_args()
    if not 1 <= args.repetitions <= 10:
        parser.error('--repetitions must be between 1 and 10')
    def interrupted(signum, frame):
        raise InterruptedError('Memory study interrupted')
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    engine, harness = args.engine.resolve(), args.harness.resolve()
    engine_hash, harness_hash = digest(engine), digest(harness)
    results = []
    for repetition in range(args.repetitions):
        # Reverse alternating passes to reduce systematic ordering effects.
        for mode in args.modes if repetition % 2 == 0 else list(reversed(args.modes)):
            print(f'Measuring native UI: {mode} (run {repetition + 1})', flush=True)
            result = run_scenario(engine, harness, mode)
            result['repetition'] = repetition + 1
            results.append(result)
            print('  median MiB: ' + ', '.join(
                f"{phase}={result['summary'][phase]['medianFootprintBytes']/1048576:.2f}"
                for phase in ('idle', 'output', 'settled')), flush=True)
            if digest(engine) != engine_hash or digest(harness) != harness_hash:
                raise RuntimeError('Input binaries changed during study')
    report = dict(schema=1, timestampUTC=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        host=dict(system=platform.system(), release=platform.release(), machine=platform.machine()),
        engineSHA256=engine_hash, harnessSHA256=harness_hash,
        comparablePhases=['warmup', 'idle', 'output', 'settled', 'inactive'],
        workload=dict(shells=6, linesPerShell=40000, generatedBytesPerShell=3640000,
                      windowPoints=[1440, 900], sampleIntervalSeconds=.25), scenarios=results)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + '.tmp')
    temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    temporary.replace(args.output)
    print(f'Completed {len(results)} scenarios; isolated shell cleanup confirmed.', flush=True)


if __name__ == '__main__':
    main()
