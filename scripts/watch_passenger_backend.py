"""Windows logon supervisor. Never kills listeners or sends TM/payment commands."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import urllib.request


def configuration(directory):
    fields = {}
    for raw in (directory / '.env').read_text(encoding='utf-8-sig').splitlines():
        if '=' in raw and not raw.lstrip().startswith('#'):
            key, value = raw.split('=', 1)
            fields[key.strip()] = value.strip().strip('\'"')
    if fields.get('PORT') != '8788' or fields.get('TM_API_MOCK', '').lower() != 'false':
        raise ValueError('Expected the configured real passenger backend on port 8788')
    if not (directory / 'server.mjs').is_file():
        raise ValueError('Passenger server source is missing')
    # The host gives process environment precedence; do not inherit conflicting settings.
    return {**os.environ, **fields}


def process_alive(pid):
    from ctypes import wintypes
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.OpenProcess(0x1000, False, pid)
    if not handle:
        return ctypes.get_last_error() == 5  # Access denied must not authorize another host.
    try:
        code = wintypes.DWORD()
        return not kernel.GetExitCodeProcess(handle, ctypes.byref(code)) or code.value == 259
    finally:
        kernel.CloseHandle(handle)


def state(directory):
    try:
        with socket.create_connection(('127.0.0.1', 8788), timeout=1):
            occupied = True
    except OSError:
        occupied = False
    worker_alive = False
    worker_pid = None
    try:
        lock = json.loads((directory / 'data/settlement-worker.lock').read_text(encoding='utf-8-sig'))
        worker_pid = int(lock['pid'])
        if worker_pid > 0:
            worker_alive = process_alive(worker_pid)
        else:
            worker_alive = True
    except FileNotFoundError:
        pass
    except (OSError, ValueError, KeyError, TypeError):
        # An unreadable financial-worker lock is not permission to launch a second one.
        worker_alive = True
    healthy = False
    if occupied:
        try:
            with urllib.request.urlopen('http://127.0.0.1:8788/health', timeout=3) as response:
                health = json.load(response)
                healthy = health.get('ok') is True and health.get('mock') is False and health.get('tmApi') == 'ok'
        except (OSError, ValueError):
            pass
    return {'port_occupied': occupied, 'healthy': healthy, 'worker_alive': worker_alive,
            'worker_pid': worker_pid, 'may_start': not occupied and not worker_alive}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backend', required=True, type=Path)
    parser.add_argument('--private', required=True, type=Path)
    parser.add_argument('--node', required=True, type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    directory = args.backend.resolve(strict=True)
    private = args.private.resolve(strict=True)
    node = args.node.resolve(strict=True)
    environment = configuration(directory)
    if args.check:
        print(json.dumps(state(directory)))
        return
    import msvcrt
    with (private / 'passenger-supervisor.lock').open('a+b') as lock:
        lock.seek(0, 2)
        if lock.tell() == 0:
            lock.write(b'0')
            lock.flush()
        lock.seek(0)
        try:
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError:
            return
        next_start = 0
        child = None
        while True:
            # Never start a second child merely because the first is still initializing.
            if child is None or child.poll() is not None:
                current = state(directory)
                if current['may_start'] and time.monotonic() >= next_start:
                    next_start = time.monotonic() + 60
                    # Rotate only our startup logs; existing service/audit logs remain intact.
                    with (private / 'passenger-host.stdout.log').open('wb') as out, (private / 'passenger-host.stderr.log').open('wb') as err:
                        child = subprocess.Popen([str(node), str(directory / 'server.mjs')], cwd=directory,
                                                 env=environment, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                                 creationflags=subprocess.CREATE_NO_WINDOW)
            time.sleep(15)


if __name__ == '__main__':
    main()
