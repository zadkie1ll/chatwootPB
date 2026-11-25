#!/usr/bin/env python3
"""Add one nginx vhost and certificate; validate DNS before any mutations."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import time
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[2]
MARKER = '# Managed by corporate Chatwoot configure-domain.py'


def run(*args):
    subprocess.run(list(args), check=True, cwd=ROOT, umask=0o022 if args[0] == 'certbot' else -1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('domain')
    parser.add_argument('--expected-ip', default='162.248.166.241')
    options = parser.parse_args()
    domain = options.domain.lower()
    if not re.fullmatch(r'[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?', domain) or '..' in domain or '.' not in domain:
        parser.error('Invalid domain')
    try:
        addresses = {entry[4][0] for entry in socket.getaddrinfo(domain, 443, type=socket.SOCK_STREAM)}
    except socket.gaierror:
        raise SystemExit(f'DNS is not ready: add A {domain} -> {options.expected_ip}; no configuration changed.')
    if addresses != {options.expected_ip}:
        raise SystemExit(f'DNS must point only to {options.expected_ip}; check A/AAAA records. No configuration changed.')
    os.umask(0o077)
    os.chdir(ROOT)
    available = Path('/etc/nginx/sites-available') / ('chatwoot-' + domain)
    enabled = Path('/etc/nginx/sites-enabled') / available.name
    if enabled.is_symlink() and enabled.resolve() != available:
        raise SystemExit('Refusing to replace another nginx site')
    if enabled.exists() and not enabled.is_symlink():
        raise SystemExit('Refusing to replace an existing nginx configuration')
    previous = available.read_text() if available.exists() else None
    if previous is not None and not previous.startswith(MARKER):
        raise SystemExit('Refusing to overwrite an unmanaged nginx site')
    previously_enabled = enabled.is_symlink()
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    backup = ROOT / 'backups' / ('domain-' + stamp)
    backup.mkdir(parents=True, mode=0o700)
    shutil.copy2(ROOT / '.env', backup / '.env')
    if previous is not None:
        (backup / 'nginx.conf').write_text(previous)
    Path('/var/www/pravburo-chatwoot-acme/.well-known/acme-challenge').mkdir(parents=True, mode=0o755, exist_ok=True)
    # nginx workers need to traverse the new public ACME directory.
    for folder in ['/var/www/pravburo-chatwoot-acme', '/var/www/pravburo-chatwoot-acme/.well-known', '/var/www/pravburo-chatwoot-acme/.well-known/acme-challenge']:
        os.chmod(folder, 0o755)
    templates = ROOT / 'infra/nginx'
    try:
        if not Path('/etc/letsencrypt/live', domain, 'fullchain.pem').exists():
            available.write_text((templates / 'public-http.conf.template').read_text().replace('__DOMAIN__', domain))
            if not previously_enabled:
                enabled.symlink_to(available)
            run('nginx', '-t')
            run('systemctl', 'reload', 'nginx')
            run('certbot', 'certonly', '--webroot', '-w', '/var/www/pravburo-chatwoot-acme',
                '-d', domain, '--cert-name', domain, '--non-interactive', '--agree-tos',
                '--deploy-hook', '/usr/sbin/nginx -t && /bin/systemctl reload nginx')
        available.write_text((templates / 'public-https.conf.template').read_text().replace('__DOMAIN__', domain))
        if not enabled.is_symlink():
            enabled.symlink_to(available)
        run('nginx', '-t')
        run('systemctl', 'reload', 'nginx')
    except BaseException:
        if previous is not None:
            available.write_text(previous)
        else:
            available.unlink(missing_ok=True)
        if not previously_enabled:
            enabled.unlink(missing_ok=True)
        run('nginx', '-t')
        run('systemctl', 'reload', 'nginx')
        raise
    values = dict(line.split('=', 1) for line in (ROOT / '.env').read_text().splitlines() if line and not line.startswith('#'))
    values['FRONTEND_URL'] = 'https://' + domain
    (ROOT / '.env').write_text('# Private server configuration\n' + ''.join(k + '=' + v + '\n' for k, v in values.items()))
    run('bash', 'scripts/compose.sh', 'up', '-d', '--no-build', '--no-deps', '--force-recreate', 'chatwoot-web', 'chatwoot-worker', 'proxy')
    for attempt in range(60):
        try:
            with urlopen('https://' + domain + '/health', timeout=5) as response:
                if response.status == 200:
                    break
        except OSError:
            time.sleep(1)
    else:
        raise SystemExit('HTTPS configured, but health check did not become ready; inspect project services.')
    report = {'domain': domain, 'https_health': 200, 'certificate': 'Let’s Encrypt', 'frontend_url': values['FRONTEND_URL']}
    (ROOT / 'docs/evidence/server-https.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
