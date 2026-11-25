#!/usr/bin/env python3
"""Prepare a NEW stopped server deployment. Never starts or builds containers."""
import os
import secrets
from pathlib import Path
root = Path(__file__).resolve().parents[2]
location = root / '.env'
if location.exists():
    raise SystemExit('Existing .env preserved; no secrets were changed.')
values = {
    'COMPOSE_PROJECT_NAME': 'pravburo-chatwoot', 'SERVER_PREPARED_ONLY': 'true',
    'HTTP_PORT': '8088', 'FRONTEND_URL': 'http://localhost:8088',
    'TELEGRAM_MODE': 'personal', 'CORPORATE_ACCOUNT_ID': '1', 'CORPORATE_INBOX_ID': '1',
    'COMPANY_NAME': 'Corporate Telegram',
    'INITIAL_SUPERVISOR_EMAIL': 'supervisor@example.invalid',
    'INITIAL_TECH_ADMIN_EMAIL': 'admin@example.invalid',
    'CW_IMAGE_NAME': 'corporate-chatwoot-ce:telegram-dev',
}
for key in ['SECRET_KEY_BASE', 'ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY', 'ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY',
            'ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT', 'POSTGRES_ADMIN_PASSWORD', 'CW_DATABASE_PASSWORD',
            'REDIS_PASSWORD', 'INTEGRATION_DB_PASSWORD', 'CW_SERVICE_TOKEN', 'INTEGRATION_API_TOKEN',
            'GATEWAY_TOKEN', 'DJANGO_SECRET_KEY', 'CW_WEBHOOK_SECRET']:
    values[key] = secrets.token_hex(64 if key == 'SECRET_KEY_BASE' else 32)
for key in ['INITIAL_SUPERVISOR_PASSWORD', 'INITIAL_TECH_ADMIN_PASSWORD', 'LAB_USER_PASSWORD']:
    values[key] = secrets.token_hex(24) + 'aA1!'
with os.fdopen(os.open(location, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as output:
    output.write('# Prepared only. Do not start before owner approval and memory upgrade.\n')
    output.write(''.join(f'{key}={value}\n' for key, value in values.items()))
for directory in ['secrets', 'secrets/telegram', 'backups']:
    (root / directory).mkdir(mode=0o700, exist_ok=True)
print('Server .env and private directories prepared. No secrets printed. Nothing started.')
