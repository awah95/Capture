#!/usr/bin/env python3
"""Opt-in real S1 probe and AppKit termination check using a built candidate app.
Uses isolated model files; never installs the app or opens normal composition.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, default=repo / 'build/dd/Build/Products/Debug/Captur.app/Contents/MacOS/Captur')
parser.add_argument('--model-directory', type=Path, default=repo / 'build/s1/model')
args = parser.parse_args()
fixtures = [{'id': 'normal', 'transcript': 'hello there'}] + [
    {'id': f'partial-{index}', 'transcript': text}
    for index, text in enumerate(['send the report […] on thursday', '[…] the second half', 'um […] uh'])
]
if not args.app.is_file():
    parser.error('Build a candidate app first or supply --app')
with tempfile.TemporaryDirectory(prefix='captur-shutdown-') as scratch:
    fixture_file = Path(scratch) / 'fixtures.json'
    fixture_file.write_text(json.dumps(fixtures))
    result = subprocess.run([
        str(args.app.resolve()), '--probe-cleanup', 'localS1Mini',
        '--model-directory', str(args.model_directory.resolve()), '--fixtures', str(fixture_file)
    ], cwd=repo, capture_output=True, text=True, timeout=120)
log = repo / 'build/s1-native-shutdown.log'
log.parent.mkdir(parents=True, exist_ok=True)
log.write_text(result.stdout + '\n' + result.stderr)
rows = []
for line in result.stdout.splitlines():
    try:
        rows.append(json.loads(line))
    except json.JSONDecodeError:
        pass
outputs = {row['id']: row.get('output') for row in rows if 'id' in row}
ok = (result.returncode == 0 and not any('error' in row for row in rows)
      and bool(outputs.get('normal'))
      and all(outputs.get(row['id']) == row['transcript'] for row in fixtures[1:]))
print(f'APPKIT_EXIT: {result.returncode}; diagnostics: {log.relative_to(repo)}')
print('NATIVE_CLEAN: ' + str(outputs.get('normal')))
print('PARTIAL_TRANSCRIPTS: ' + ('preserved' if ok else 'FAILED'))
if not ok:
    raise SystemExit(1)
