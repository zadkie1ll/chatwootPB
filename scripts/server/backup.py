#!/usr/bin/env python3
"""Consistent private backup with a short writer pause; optional isolated DB restore probe."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
COMPOSE = ['bash', str(ROOT / 'scripts/compose.sh')]
WRITERS = ['proxy', 'chatwoot-web', 'chatwoot-worker', 'integration-web', 'integration-worker', 'integration-crm-worker', 'telegram-gateway']


def call(*args, **kwargs):
    return subprocess.run(COMPOSE + list(args), cwd=ROOT, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--verify-restore', action='store_true')
    options = parser.parse_args()
    os.umask(0o077)
    config = json.loads(subprocess.check_output(COMPOSE + ['config', '--format', 'json'], cwd=ROOT))
    running = subprocess.check_output(COMPOSE + ['ps', '--services', '--status', 'running'], cwd=ROOT, text=True).splitlines()
    pause = [service for service in WRITERS if service in running]
    destination = ROOT / 'backups' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    destination.mkdir(parents=True, mode=0o700)
    report = {'databases': {}, 'restore_verified': False}
    try:
        if pause:
            call('stop', *pause, stdout=subprocess.DEVNULL)
        for name in ['chatwoot_lab', 'integration_lab']:
            with (destination / (name + '.dump')).open('wb') as output:
                call('exec', '-T', 'postgres', 'pg_dump', '-U', 'postgres', '-Fc', '-d', name, stdout=output)
        shutil.copy2(ROOT / '.env', destination / '.env')
        with tarfile.open(destination / 'telegram.tar.gz', 'w:gz') as archive:
            archive.add(ROOT / 'secrets/telegram', arcname='telegram')
        for name in ['chatwoot_storage', 'redis_data']:
            volume_name = config['volumes'][name]['name']
            location = subprocess.check_output(['docker', 'volume', 'inspect', '-f', '{{.Mountpoint}}', volume_name], text=True).strip()
            with tarfile.open(destination / (name + '.tar.gz'), 'w:gz') as archive:
                archive.add(location, arcname=name)
        if options.verify_restore:
            for name in ['chatwoot_lab', 'integration_lab']:
                probe = 'restore_probe_' + uuid.uuid4().hex
                call('exec', '-T', 'postgres', 'createdb', '-U', 'postgres', probe)
                try:
                    with (destination / (name + '.dump')).open('rb') as data:
                        call('exec', '-T', 'postgres', 'pg_restore', '-U', 'postgres', '--exit-on-error', '--no-owner', '-d', probe, stdin=data, stdout=subprocess.DEVNULL)
                    result = subprocess.check_output(COMPOSE + ['exec', '-T', 'postgres', 'psql', '-U', 'postgres', '-d', probe, '-Atc', "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'"], cwd=ROOT, text=True)
                    report['databases'][name] = {'restored_public_tables': int(result)}
                finally:
                    call('exec', '-T', 'postgres', 'dropdb', '-U', 'postgres', probe)
            report['restore_verified'] = True
        for name in ['telegram.tar.gz', 'chatwoot_storage.tar.gz', 'redis_data.tar.gz']:
            with tarfile.open(destination / name) as archive:
                for member in archive:
                    if member.isfile():
                        source = archive.extractfile(member)
                        while source.read(1024 * 1024):
                            pass
        report['file_archives_readable'] = True
        (destination / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    finally:
        if pause:
            call('start', *pause, stdout=subprocess.DEVNULL)
    print(json.dumps({'backup': str(destination), **report}, indent=2))


if __name__ == '__main__':
    main()
