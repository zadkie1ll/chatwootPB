#!/usr/bin/env python3
"""Secure IP fallback on the already enabled reserve port; isolated ACME state."""
import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
MARKER = '# Managed by corporate Chatwoot IP fallback\n'
IP = '162.248.166.241'
PORT = 18443
WEBROOT = Path('/var/www/pravburo-chatwoot-acme')
CERT_NAME = 'chatwoot-ip'


def run(args, **kwargs):
    subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def acme_command(staging=False, renew=False):
    image = (ROOT / 'infra/certbot-ip.image').read_text().strip()
    assert image.startswith('certbot/certbot@sha256:')
    suffix = '-staging' if staging else ''
    directories = [ROOT / ('secrets/acme-ip' + suffix), ROOT / ('.state/acme-ip-work' + suffix), ROOT / ('.state/acme-ip-logs' + suffix)]
    for directory in directories:
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    command = ['docker', 'run', '--rm', '--pull', 'never', '--network', 'host', '--memory', '256m', '--pids-limit', '64',
               '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--read-only', '--tmpfs', '/tmp']
    for source, target in zip(directories, ['/etc/letsencrypt', '/var/lib/letsencrypt', '/var/log/letsencrypt']):
        command += ['-v', str(source) + ':' + target]
    command += ['-v', str(WEBROOT) + ':/var/www/acme', image]
    if renew:
        return command + ['renew', '--non-interactive', '--cert-name', CERT_NAME]
    command += ['certonly', '--non-interactive', '--agree-tos', '--register-unsafely-without-email', '--keep-until-expiring',
                '--cert-name', CERT_NAME, '--preferred-profile', 'shortlived', '--webroot', '-w', '/var/www/acme', '--ip-address', IP]
    if staging:
        command += ['--staging']
    return command


def configuration(tls=False):
    text = MARKER + f'''server {{
    listen 80;
    server_name {IP};
    access_log off;
    location ^~ /.well-known/acme-challenge/ {{
        root {WEBROOT};
        default_type text/plain;
    }}
    location / {{ return 404; }}
}}
'''
    if not tls:
        return text
    certificates = ROOT / 'secrets/acme-ip/live' / CERT_NAME
    return text + f'''server {{
    listen {PORT} ssl default_server;
    server_name {IP};
    ssl_certificate {certificates}/fullchain.pem;
    ssl_certificate_key {certificates}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    access_log off;
    client_max_body_size 25m;
    add_header Strict-Transport-Security "max-age=31536000" always;
    location /internal/ {{ return 404; }}
    location / {{
        proxy_pass http://127.0.0.1:8088;
        proxy_set_header Accept-Encoding "";
        sub_filter_types application/json;
        sub_filter_once off;
        sub_filter 'https://mess.prav-buro.ru/' 'https://{IP}:{PORT}/';
        sub_filter "hostURL: 'https://mess.prav-buro.ru'" "hostURL: 'https://{IP}:{PORT}'";
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port {PORT};
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $corporate_messenger_upgrade;
        proxy_read_timeout 90s;
        proxy_send_timeout 90s;
    }}
}}
'''


def apply_configuration(text):
    available = Path('/etc/nginx/sites-available/chatwoot-ip-fallback')
    enabled = Path('/etc/nginx/sites-enabled/chatwoot-ip-fallback')
    previous = available.read_text() if available.exists() else None
    assert previous is None or previous.startswith(MARKER)
    assert not enabled.exists() or enabled.is_symlink() and enabled.resolve() == available
    was_enabled = enabled.is_symlink()
    available.write_text(text)
    available.chmod(0o644)
    if not was_enabled:
        enabled.symlink_to(available)
    try:
        run(['nginx', '-t'])
        run(['systemctl', 'reload', 'nginx'])
    except Exception:
        if previous is None:
            available.unlink(missing_ok=True)
        else:
            available.write_text(previous)
        if not was_enabled:
            enabled.unlink(missing_ok=True)
        run(['nginx', '-t'])
        run(['systemctl', 'reload', 'nginx'])
        raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--staging', action='store_true')
    parser.add_argument('--renew', action='store_true')
    options = parser.parse_args()
    assert ROOT == Path('/opt/pravburo-chatwoot')
    ipaddress.IPv4Address(IP)
    os.umask(0o077)
    cert = ROOT / 'secrets/acme-ip/live' / CERT_NAME / 'fullchain.pem'
    if options.renew:
        before = hashlib.sha256(cert.read_bytes()).digest()
        run(acme_command(renew=True))
        if hashlib.sha256(cert.read_bytes()).digest() != before:
            run(['nginx', '-t'])
            run(['systemctl', 'reload', 'nginx'])
        return
    # Never replace an already active trusted IP server with an HTTP-only stage.
    if not cert.exists():
        apply_configuration(configuration())
    run(acme_command(staging=options.staging))
    if options.staging:
        print(json.dumps({'staging_challenge_passed': True, 'untrusted_certificate_not_activated': True}))
        return
    run(['openssl', 'x509', '-in', str(cert), '-noout', '-checkip', IP])
    run(['openssl', 'x509', '-in', str(cert), '-noout', '-checkend', '86400'])
    apply_configuration(configuration(tls=True))
    print(json.dumps({'trusted_ip_fallback': f'https://{IP}:{PORT}', 'system_certbot_unchanged': True}))


if __name__ == '__main__':
    main()
