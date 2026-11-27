#!/usr/bin/env python3
"""Install only this application's startup and watchdog units."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
assert root == Path('/opt/pravburo-chatwoot')
assert 'COMPOSE_PROJECT_NAME=pravburo-chatwoot' in (root / '.env').read_text()
units = ['pravburo-chatwoot.service', 'pravburo-chatwoot-watchdog.service', 'pravburo-chatwoot-watchdog.timer']
ip_certificate = root / 'secrets/acme-ip/live/chatwoot-ip/fullchain.pem'
if ip_certificate.exists():
    units += ['pravburo-chatwoot-ip-renew.service', 'pravburo-chatwoot-ip-renew.timer']
for name in units:
    target = Path('/etc/systemd/system') / name
    if target.exists():
        assert target.read_text().startswith('# Managed by corporate Chatwoot'), 'Unmanaged unit: ' + name
    target.write_text((root / 'infra/systemd' / name).read_text())
    target.chmod(0o644)
subprocess.run(['systemd-analyze', 'verify', *['/etc/systemd/system/' + name for name in units]], check=True)
subprocess.run(['systemctl', 'daemon-reload'], check=True)
subprocess.run(['systemctl', 'enable', 'pravburo-chatwoot.service'], check=True)
subprocess.run(['systemctl', 'enable', '--now', 'pravburo-chatwoot-watchdog.timer'], check=True)
if ip_certificate.exists():
    subprocess.run(['systemctl', 'enable', '--now', 'pravburo-chatwoot-ip-renew.timer'], check=True)
# Do not re-run startup against the already running stack during installation.
subprocess.run(['systemctl', 'start', 'pravburo-chatwoot-watchdog.service'], check=True)
