#!/usr/bin/env python3
"""Measure local engine RPC peaks with controlled shells and a private home (macOS)."""
import argparse
import base64
import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def run_request(command, request, *, env, cwd, timeout=20):
    # time is a wrapper: killing only it on timeout would orphan the request.
    # Holders deliberately detach; the private request group does not own them.
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, env=env, cwd=cwd, start_new_session=True)
    try:
        stdout, stderr = child.communicate(request, timeout=timeout)
    except BaseException:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.communicate()
        raise
    if child.returncode:
        raise RuntimeError('request process failed')
    return stdout, stderr


def measure(engines, repetitions):
    root = Path(tempfile.mkdtemp(prefix='trama-memory-'))
    home, project = root / 'engine', root / 'project'
    project.mkdir()
    binaries = root / 'binaries'
    binaries.mkdir()
    env = {'HOME': str(root), 'SHELL': '/bin/sh', 'PATH': '/usr/bin:/bin',
           'TMPDIR': str(root), 'TERM': 'xterm-256color', 'LANG': 'C', 'LC_ALL': 'C'}
    copies, hashes = {}, {}
    samples = {label: {} for label in engines}
    started = False
    report = None
    for label, source in engines.items():
        expected = hashlib.sha256(source.read_bytes()).hexdigest()
        target = binaries / label
        shutil.copy2(source, target)
        hashes[label] = hashlib.sha256(target.read_bytes()).hexdigest()
        if hashes[label] != expected:
            raise RuntimeError('binary changed during copy')
        copies[label] = target
    owner = next(iter(copies))

    def rpc(label, operation, sample=None, **kwargs):
        begin = time.perf_counter()
        command = ['/usr/bin/time', '-l', str(copies[label]), '--request', '--home', str(home)]
        stdout, stderr = run_request(command,
            json.dumps(dict(operation=operation, **kwargs)).encode(), env=env, cwd=project)
        elapsed = (time.perf_counter() - begin) * 1000
        reply = json.loads(stdout)
        if reply.get('protocol') != 1 or not reply.get('ok'):
            raise RuntimeError(f'{operation} RPC failed')
        if sample:
            metrics = {}
            for field, title in [('maximumRSSBytes', 'maximum resident set size'),
                                 ('peakFootprintBytes', 'peak memory footprint')]:
                match = re.search(r'^\s*(\d+)\s+' + title + r'\s*$', stderr.decode(), re.M)
                if not match:
                    raise RuntimeError('macOS time memory metric missing')
                metrics[field] = int(match[1])
            metrics['elapsedMs'] = elapsed
            metrics['responseBytes'] = len(stdout)
            samples[label].setdefault(sample, []).append(metrics)
        return reply['result']

    def compare(case, operation, **kwargs):
        # Alternate order per repeat so warm filesystem caches do not favor one binary.
        for index in range(repetitions):
            labels = list(copies)
            if index % 2:
                labels.reverse()
            expected = None
            for label in labels:
                value = rpc(label, operation, sample=case, **kwargs)
                # Live prompts/status can advance between requests; compare the
                # stopped, flushed history whose content is immutable instead.
                if operation == 'logs' and expected is not None and value != expected:
                    raise RuntimeError(f'{case}: binaries returned different results')
                expected = value

    try:
        compare('emptyList', 'list')
        ids = []
        for number in range(6):
            started = True  # Start timeout may still have created a holder.
            ids.append(rpc(owner, 'start', kind='terminal', cwd=str(project),
                           name=f'controlled-shell-{number}')['agentId'])
        compare('sixIdleList', 'list')
        loaded = ids[0]
        rpc(owner, 'resize', agentId=loaded, rows=100, cols=240)
        compare('idleSnapshot', 'snapshot', agentId=loaded)
        line = 'TRAMA_MEMORY_' + 'x' * 224
        script = project / 'load.sh'
        script.write_text("#!/bin/sh\nset -eu\ni=0\nwhile [ \"$i\" -lt 50 ]; do\n"
            + "/usr/bin/awk 'BEGIN {for(i=0;i<200;i++) print \"" + line + "\"}'\n"
            + "i=$((i+1))\n/bin/sleep 0.02\ndone\nprintf 'TRAMA_%s\\n' MEMORY_COMPLETE\n")
        command = '/bin/sh ' + shlex.quote(str(script)) + '\n'
        rpc(owner, 'input', agentId=loaded, input=base64.b64encode(command.encode()).decode())
        deadline = time.monotonic() + 30
        output_samples = []
        while True:
            snapshot = rpc(owner, 'snapshot', sample='outputSnapshot', agentId=loaded)
            data = base64.b64decode(snapshot['data'], validate=True)
            output_samples.append(len(data))
            if b'TRAMA_MEMORY_COMPLETE' in data:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError('controlled output completion not observed')
            time.sleep(.05)
        compare('loadedSnapshot', 'snapshot', agentId=loaded)
        rpc(owner, 'stop', agentId=loaded)  # Flush the operation log before replay.
        compare('loadedLogs', 'logs', agentId=loaded)
        log = rpc(owner, 'logs', agentId=loaded)
        if 'TRAMA_MEMORY_COMPLETE' not in log['text'] or not log['truncated']:
            raise RuntimeError('bounded log does not contain expected completion/truncation')
        report = dict(schema=1, timestampUTC=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
            host=dict(system=platform.system(), release=platform.release(), machine=platform.machine()),
            engineSHA256=hashes, repetitions=repetitions, samples=samples,
            workload=dict(shells=6, rows=100, cols=240, lines=10000,
                          generatedBytes=10000*(len(line)+1), completionObserved=True,
                          loadedSnapshotBytes=max(output_samples)),
            limits=['macOS time -l peak footprint/max RSS measure each request process, not app/holders/CLIs.',
                    'Request duration includes /usr/bin/time instrumentation and process startup.',
                    'Six controlled shells; no credentials, authenticated providers or network requests.',
                    'History equality compares binaries on the same stopped, flushed output.',
                    'One host and workload; sample variation is not a universal RAM guarantee.'])
    finally:
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK,
            {signal.SIGINT, signal.SIGTERM, signal.SIGHUP})
        try:
            cleanup_ok = False
            try:
                records = rpc(owner, 'list')['agents'] if started else []
                for record in records:
                    if record['state'] != 'exited':
                        rpc(owner, 'stop', agentId=record['id'])
                remaining = rpc(owner, 'list')['agents'] if started else []
                cleanup_ok = all(record['state'] == 'exited' for record in remaining)
            except Exception:
                pass
            if not cleanup_ok:
                print(f'Cleanup unconfirmed; private home preserved: {root}', file=sys.stderr)
                raise RuntimeError('holder cleanup failed')
            shutil.rmtree(root)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    report['cleanupConfirmed'] = True
    report['summary'] = {label: {case: {metric: statistics.median(s[metric] for s in values)
        for metric in values[0]} for case, values in cases.items()} for label, cases in samples.items()}
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine', action='append', required=True, metavar='LABEL=PATH')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repetitions', type=int, default=8)
    args = parser.parse_args()
    if not 2 <= args.repetitions <= 30:
        parser.error('repetitions must be 2..30')
    engines = {}
    for item in args.engine:
        label, separator, path = item.partition('=')
        if not separator or not re.fullmatch(r'[a-z][a-z0-9_-]{0,30}', label) or label in engines:
            parser.error('engine needs unique simple LABEL=PATH')
        engines[label] = Path(path).resolve(strict=True)
    report = measure(engines, args.repetitions)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', prefix=args.output.name + '.',
            dir=args.output.parent, delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(json.dumps(report, indent=2) + '\n')
    try:
        temporary.replace(args.output)
    finally:
        temporary.unlink(missing_ok=True)
    print(json.dumps(report['summary'], indent=2))


if __name__ == '__main__':
    for interrupt in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(interrupt, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        reason = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print(f'Memory benchmark failed ({reason}); previous report preserved.', file=sys.stderr)
        sys.exit(1)
