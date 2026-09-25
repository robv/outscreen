#!/usr/bin/env python3
"""Explicit, guarded real-display test. Never run by make test."""
import argparse
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path

parser = argparse.ArgumentParser(description='Briefly switch off the built-in display, then restore it.')
parser.add_argument('--run', action='store_true', help='Required: authorizes a real display change')
parser.add_argument('--app', default='/Applications/Outscreen.app/Contents/MacOS/Outscreen')
parser.add_argument('--seconds', type=int, default=8)
args = parser.parse_args()
if not args.run or not 1 <= args.seconds <= 15:
    parser.error('Supply --run and --seconds between 1 and 15.')

def status():
    return json.loads(subprocess.check_output([args.app, '--status'], timeout=5, text=True))

def change(value, builtin_id):
    result = subprocess.run([args.app, '--set', value, '--builtin-id', str(builtin_id)], timeout=18, text=True, capture_output=True)
    print(result.stdout.strip() or result.stderr.strip(), flush=True)
    result.check_returncode()

before = status()
assert before['builtinActive'] and before['canDisable'] and before['externalCount'] > 0, before
builtin_id = before['builtinID']
with tempfile.TemporaryDirectory(prefix='outscreen-smoke-') as temp:
    ready = Path(temp) / 'ready'
    guardian = subprocess.Popen([args.app, '--guardian', str(os.getpid()), '--builtin-id', str(builtin_id), '--ready-file', str(ready)])
    try:
        deadline = time.monotonic() + 4
        while not ready.exists() and time.monotonic() < deadline and guardian.poll() is None:
            time.sleep(.05)
        assert ready.exists() and guardian.poll() is None, 'Recovery guardian failed to start'
        change('off', builtin_id)
        off = status()
        print('AFTER_OFF=' + json.dumps(off), flush=True)
        assert not off['builtinActive'] and off['externalCount'] > 0, off
        print(f'TEST WINDOW: {args.seconds}s for emergency restore shortcut; automatic backup follows.', flush=True)
        deadline = time.monotonic() + args.seconds
        while time.monotonic() < deadline:
            if status()['builtinActive']:
                print('RESTORED_DURING_TEST_WINDOW=true', flush=True)
                break
            time.sleep(.25)
    finally:
        # Keep the guardian until recovery has actually succeeded.
        change('on', builtin_id)
        restored = status()
        print('AFTER_RESTORE=' + json.dumps(restored), flush=True)
        assert restored['builtinActive'], restored
        guardian.terminate()
        try:
            guardian.wait(timeout=3)
        except subprocess.TimeoutExpired:
            guardian.kill()
    print('PASS: real display off and restore, external display stayed active.', flush=True)
