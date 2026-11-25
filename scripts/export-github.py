#!/usr/bin/env python3
"""Export a flat CE source tree for GitHub; never export runtime data or Git history."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('server_package', ROOT / 'scripts/server/package.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


def private_values():
    values = set()
    env = ROOT / '.env'
    if env.exists():
        for line in env.read_text().splitlines():
            if line and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                if any(word in key for word in ('PASSWORD', 'TOKEN', 'SECRET', 'ENCRYPTION', 'API_HASH')) and len(value) >= 12:
                    values.add(value.encode())
    for filename in (ROOT / 'secrets').glob('*access.txt'):
        values.update(value.encode() for value in re.findall(r'^Пароль: (.+)$', filename.read_text(), re.M) if len(value) >= 12)
    baseline = ROOT / 'secrets/baseline.json'
    if baseline.exists():
        def collect(item):
            if isinstance(item, dict):
                for key, value in item.items():
                    if isinstance(value, str) and any(word in key.lower() for word in ('token', 'password', 'secret')) and len(value) >= 12:
                        values.add(value.encode())
                    collect(value)
            elif isinstance(item, list):
                for value in item:
                    collect(value)
        collect(json.loads(baseline.read_text()))
    return values


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--destination', default=str(ROOT / '.state/github-export'))
    args = parser.parse_args()
    destination = Path(args.destination).resolve()
    if destination.exists() and any(destination.iterdir()):
        raise SystemExit('Export destination must be empty; existing repositories are never overwritten')
    destination.mkdir(parents=True, exist_ok=True)
    files = [p.relative_to(ROOT) for name in ('scripts', 'infra', 'integration', 'gateways', 'docs', 'tests')
             for p in (ROOT / name).rglob('*') if p.is_file() and not p.is_symlink()]
    files.extend(Path(name) for name in ('README.md', 'CHATWOOT_CODEX_SPEC.md', 'compose.yaml', '.dockerignore', '.env.example', '.gitignore'))
    tracked = subprocess.check_output(['git', '-C', str(ROOT / 'chatwoot'), 'ls-files', '-co', '--exclude-standard', '-z'])
    files.extend(Path('chatwoot') / name for name in tracked.decode().split('\0') if name)
    # Public upstream CA certificate is source, not a private key.
    ca = Path('chatwoot/config/rds-ca-2019-root.pem')
    files = sorted({p for p in files if (package.eligible(p) or p == ca)
                    and not str(p).startswith('docs/evidence/')
                    and (ROOT / p).is_file() and not (ROOT / p).is_symlink()})
    known = private_values()
    unsafe = re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|https://[^/\s]+\.bitrix24\.ru/rest/\d+/[a-zA-Z0-9]{8,}')
    rejected = []
    for relative in files:
        data = (ROOT / relative).read_bytes()
        if any(secret in data for secret in known) or unsafe.search(data):
            rejected.append(str(relative))
    if rejected:
        raise SystemExit('Export blocked: possible secrets in ' + ', '.join(rejected))
    for relative in files:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, target)
    shutil.copy2(ROOT / 'chatwoot/LICENSE', destination / 'LICENSE')
    evidence = destination / 'docs/evidence'
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / 'README.md').write_text('Operational evidence, screenshots, staff details and deployment reports in JSON are kept outside GitHub. References to those artifacts in historical documents refer to the private working copy. Re-run the supplied tests to generate your own evidence.\n')
    ignore = destination / '.gitignore'
    text = ignore.read_text().replace('# Independent upstream checkout; future fork changes require their own Git history.\n/chatwoot/\n', '')
    ignore.write_text(text + '\n# Export contains ordinary CE files, without the upstream nested Git checkout.\n/chatwoot/.git/\n/chatwoot/enterprise/\n/chatwoot/spec/enterprise/\n/docs/evidence/*\n!/docs/evidence/README.md\n')
    (destination / 'SOURCE-ORIGIN.json').write_text(json.dumps({
        'upstream_repository': 'https://github.com/chatwoot/chatwoot',
        'upstream_commit': 'b2f94636d325a126a67c6c4c808303d8aa8cbeea',
        'edition': 'Community Edition', 'enterprise_included': False,
        'runtime_secrets_included': False, 'operational_evidence_included': False,
        'kind': 'source snapshot with corporate modifications; not upstream Git history'}, indent=2) + '\n')
    print(json.dumps({'destination': str(destination), 'source_files': len(files),
                      'known_secret_matches': 0, 'enterprise_included': False, 'operational_evidence_included': False}))


if __name__ == '__main__':
    main()
