#!/usr/bin/env python3
"""Prepare an idle MAX pilot. No account login or messaging is performed."""
from pathlib import Path
import os
import secrets

ROOT = Path(__file__).resolve().parents[2]
location = ROOT / '.env'
values = dict(line.split('=', 1) for line in location.read_text().splitlines() if line and not line.startswith('#'))
values['MAX_GATEWAY_TOKEN'] = values.get('MAX_GATEWAY_TOKEN') or secrets.token_hex(32)
profiles = list(dict.fromkeys([p for p in values.get('COMPOSE_PROFILES', '').split(',') if p] + ['max-poc']))
values['COMPOSE_PROFILES'] = ','.join(profiles)
(ROOT / 'secrets/max').mkdir(parents=True, mode=0o700, exist_ok=True)
os.chmod(ROOT / 'secrets/max', 0o700)
location.write_text('# Private configuration\n' + ''.join(k + '=' + v + '\n' for k, v in values.items()))
location.chmod(0o600)
print('MAX pilot configured; no account connected and no messages sent.')
