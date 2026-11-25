#!/usr/bin/env python3
"""Run real runtime and HTTP/socket diagnostics without persisting secrets in reports."""
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

root = Path(__file__).resolve().parent.parent
runtime = subprocess.run(
    ['bash', 'scripts/compose.sh', 'exec', '-T', 'chatwoot-web', 'bundle', 'exec', 'rails', 'runner', '/lab/runtime.rb'],
    cwd=root, capture_output=True, text=True,
)
record = None
for line in runtime.stdout.splitlines():
    try:
        candidate = json.loads(line)
    except json.JSONDecodeError:
        continue
    if isinstance(candidate, dict) and candidate.get('kind') == 'stage-1-runtime':
        record = candidate
if record is None:
    print('Runtime probe produced no diagnostic JSON. Inspect local container logs; output was not published.')
    sys.exit(1)
record['executed_at'] = datetime.now(timezone.utc).isoformat()
(root / 'docs/evidence/stage-1-runtime.json').write_text(json.dumps(record, indent=2) + '\n')
if runtime.returncode or not record.get('all_passed'):
    print('Runtime diagnostics failed. See docs/evidence/stage-1-runtime.json.')
    sys.exit(1)
print('Runtime diagnostics: PASS')
subprocess.run(['node', 'tests/baseline/check.mjs'], cwd=root, check=True)
