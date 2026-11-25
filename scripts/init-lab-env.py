#!/usr/bin/env python3
"""Generate local-only synthetic lab credentials, refusing existing files."""
import os
import secrets
from pathlib import Path

root = Path(__file__).resolve().parent.parent
keys = [
    'SECRET_KEY_BASE', 'ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY',
    'ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY', 'ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT',
    'POSTGRES_ADMIN_PASSWORD', 'CW_DATABASE_PASSWORD', 'REDIS_PASSWORD',
]
values = {key: secrets.token_hex(64 if key == 'SECRET_KEY_BASE' else 32) for key in keys}
values['LAB_USER_PASSWORD'] = secrets.token_hex(24) + 'aA1!'
with os.fdopen(os.open(root / '.env', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as output:
    output.write('# Synthetic local lab only. Never commit or share this file.\n')
    output.write(''.join(f'{key}={value}\n' for key, value in values.items()))
(root / 'secrets').mkdir(mode=0o700, exist_ok=True)
print('Generated .env (0600) and secrets/. No credentials printed.')
