#!/usr/bin/env python3
"""Opt-in live test of the app's normal controller and restoration paths."""
import argparse
import json
import os
import signal
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--run', action='store_true')
parser.add_argument('--mode', choices=['quit', 'shortcut', 'crash'], required=True)
args = parser.parse_args()
if not args.run:
    parser.error('--run is required; this test changes real displays')
app = '/Applications/Outscreen.app/Contents/MacOS/Outscreen'

def command(*args):
    result = subprocess.run([app, *args], text=True, capture_output=True, timeout=18)
    result.check_returncode()
    return result.stdout

def status():
    return json.loads(command('--status'))

def wait_for(active, seconds=8):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        current = status()
        assert current['externalCount'] > 0, 'External monitor disconnected during test'
        if current['builtinActive'] == active:
            return current
        time.sleep(.2)
    raise AssertionError(f'Display did not become active={active}')

before = status()
assert before['builtinActive'] and before['canDisable'], before
try:
    print(command('--toggle').strip(), flush=True)
    off = wait_for(False)
    print('APP_TOGGLE_OFF=' + json.dumps(off), flush=True)
    if args.mode == 'quit':
        print(command('--quit').strip(), flush=True)
    elif args.mode == 'crash':
        # Exact executable with no arguments identifies only the menu process.
        pid = int(subprocess.check_output(['pgrep', '-fx', app], text=True).strip())
        os.kill(pid, signal.SIGKILL)
        print('Simulated menu-process crash; guardian must restore.', flush=True)
    else:
        print('PRESS Control-Option-Command-R NOW (15 second window).', flush=True)
    restored = wait_for(True, 15 if args.mode == 'shortcut' else 10)
    print('APP_RESTORED=' + json.dumps(restored), flush=True)
    print(f'PASS: app toggle and {args.mode} restoration.', flush=True)
finally:
    # Independent last-resort command always restores after a failed test.
    print(command('--restore').strip(), flush=True)
