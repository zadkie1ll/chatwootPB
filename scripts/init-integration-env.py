#!/usr/bin/env python3
"""Extend the synthetic lab environment without overwriting any existing secret."""
import json
import os
import secrets
from pathlib import Path
root = Path(__file__).resolve().parent.parent
values = dict(line.split('=', 1) for line in (root / '.env').read_text().splitlines() if line and not line.startswith('#'))
fixture = json.loads((root / 'secrets/baseline.json').read_text())
for key in ['CW_SERVICE_TOKEN', 'INTEGRATION_API_TOKEN', 'GATEWAY_TOKEN', 'DJANGO_SECRET_KEY', 'INTEGRATION_DB_PASSWORD']:
    values.setdefault(key, secrets.token_hex(32))
values.setdefault('CORPORATE_ACCOUNT_ID', str(fixture['account_id']))
values.setdefault('CORPORATE_INBOX_ID', str(fixture['inbox_id']))
values.setdefault('TELEGRAM_MODE', 'mock')
(root / '.env').write_text('# Synthetic local lab only. Never commit.\n' + ''.join(f'{key}={value}\n' for key, value in values.items()))
os.chmod(root / '.env', 0o600)
(root / 'secrets/telegram').mkdir(mode=0o700, parents=True, exist_ok=True)
print('Integration credentials generated locally; Telegram mode is explicit mock. No credentials printed.')
