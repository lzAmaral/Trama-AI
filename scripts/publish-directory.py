#!/usr/bin/env python3
"""Publish staging on the same filesystem; preserve a recoverable backup if rollback fails."""
import os
import shutil
import signal
import sys
import tempfile
from pathlib import Path


def publish(source, destination):
    source, destination = Path(source).absolute(), Path(destination).absolute()
    if (not source.is_dir() or source.is_symlink() or destination.is_symlink()
            or (destination.exists() and not destination.is_dir())):
        raise ValueError('Expected real staging and destination directories')
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError('Staging and destination must be separate directories')
    # Backup lives OUTSIDE staging, whose caller may remove it even after a failure.
    backup_root = Path(tempfile.mkdtemp(prefix=destination.name + '.previous.', dir=destination.parent))
    backup = backup_root / 'artifact'
    blocked = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP}
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
    try:
        had_previous = destination.exists()
        if had_previous:
            os.rename(destination, backup)
        try:
            os.rename(source, destination)
        except BaseException:
            if had_previous:
                try:
                    os.rename(backup, destination)
                except BaseException:
                    print(f'Publication and rollback failed; previous artifact preserved at: {backup}', file=sys.stderr)
                    raise
            raise
    finally:
        # Never delete a backup left by a failed rollback.
        if not backup.exists():
            backup_root.rmdir()
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    if backup.exists():
        shutil.rmtree(backup_root)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('Usage: publish-directory.py STAGED_DIRECTORY DESTINATION')
    publish(sys.argv[1], sys.argv[2])
