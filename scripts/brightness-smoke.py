#!/usr/bin/env python3
"""Explicit reversible native-brightness roundtrip; never part of make test."""
import argparse
import json
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--run', action='store_true')
parser.add_argument('--app', default='/Applications/Outscreen.app/Contents/MacOS/Outscreen')
args = parser.parse_args()
if not args.run:
    parser.error('--run is required; this briefly changes monitor brightness')

def invoke(*arguments):
    return json.loads(subprocess.check_output([args.app, *arguments], text=True, timeout=5))

before = invoke('--brightness-status')
original = before['brightness']
changed = min(1, original + 0.0625) if original < .95 else original - .0625
try:
    print('BEFORE=' + json.dumps(before), flush=True)
    invoke('--brightness-set', str(changed))
    time.sleep(.3)
    after = invoke('--brightness-status')
    print('CHANGED=' + json.dumps(after), flush=True)
    assert after['displayID'] == before['displayID']
    assert abs(after['brightness'] - changed) < .015, 'Brightness write did not read back'
finally:
    current = invoke('--brightness-status')
    if current['displayID'] != before['displayID']:
        raise RuntimeError('Monitor changed during test; refusing to apply the old value to a different display')
    invoke('--brightness-set', str(original))
    time.sleep(.3)
    restored = invoke('--brightness-status')
    print('RESTORED=' + json.dumps(restored), flush=True)
    assert abs(restored['brightness'] - original) < .015
print('PASS: native external brightness change and restoration', flush=True)
