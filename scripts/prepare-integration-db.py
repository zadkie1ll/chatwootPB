#!/usr/bin/env python3
"""Initialize the dedicated integration DB in the existing synthetic PostgreSQL instance."""
import os
import subprocess
from pathlib import Path
root = Path(__file__).resolve().parent.parent
values = dict(line.split('=', 1) for line in (root / '.env').read_text().splitlines() if line and not line.startswith('#'))
environment = {**os.environ, 'INTEGRATION_DB_PASSWORD': values['INTEGRATION_DB_PASSWORD']}
check = subprocess.run(['bash', 'scripts/compose.sh', 'exec', '-T', 'postgres', 'psql', '-U', 'postgres', '-d', 'postgres', '-tAc',
                        "SELECT datname FROM pg_database WHERE datname='integration_lab'"], cwd=root, capture_output=True, text=True, check=True)
if check.stdout.strip() == 'integration_lab':
    print('Integration DB already exists; unchanged.')
else:
    script = (root / 'infra/postgres/02-integration.sh').read_text().split("<<'SQL'\n", 1)[1].rsplit('\nSQL', 1)[0]
    subprocess.run(['bash', 'scripts/compose.sh', 'exec', '-T', '-e', 'INTEGRATION_DB_PASSWORD', 'postgres', 'psql', '-U', 'postgres',
                    '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'], input=script, text=True, cwd=root, env=environment, check=True)
