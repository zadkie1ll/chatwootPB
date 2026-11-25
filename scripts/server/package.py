#!/usr/bin/env python3
"""Package source only, excluding secrets, runtime data and Enterprise code."""
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
EXCLUDED = {'.git', '.venv', 'node_modules', '__pycache__', '.pytest_cache',
            'secrets', 'backups', 'storage', '.state', 'test-results', 'playwright-report',
            'enterprise'}


def eligible(relative):
    return (not EXCLUDED.intersection(relative.parts)
            and not any(part == '.env' or part.startswith('.env.') and part != '.env.example'
                        for part in relative.parts)
            and not any(str(relative).endswith(suffix) for suffix in
                        ('.session', '.session-journal', '.session-wal', '.session-shm', '.sqlite3', '.pyc', '.pem', '.key'))
            and not relative.is_absolute() and '..' not in relative.parts)


def main():
    files = []
    for name in ['scripts', 'infra', 'integration', 'gateways', 'docs', 'tests']:
        files.extend(p.relative_to(ROOT) for p in (ROOT / name).rglob('*')
                     if p.is_file() and not p.is_symlink())
    files.extend(Path(name) for name in ['README.md', 'CHATWOOT_CODEX_SPEC.md', 'compose.yaml', '.dockerignore', '.env.example', '.gitignore'])
    tracked = subprocess.check_output(['git', '-C', str(ROOT / 'chatwoot'), 'ls-files', '-co', '--exclude-standard', '-z'])
    files.extend(Path('chatwoot') / name for name in tracked.decode().split('\0') if name)
    files = sorted({p for p in files if eligible(p) and (ROOT / p).is_file() and not (ROOT / p).is_symlink()
                    and not (str(p).startswith('docs/evidence/') and p.suffix != '.json')})
    destination = ROOT / '.state/server-source.tar.gz'
    destination.parent.mkdir(exist_ok=True)
    manifest = {'upstream_commit': 'b2f94636d325a126a67c6c4c808303d8aa8cbeea',
                'kind': 'telegram-pilot-source',
                'files': {str(p): hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in files}}
    with tarfile.open(destination, 'w:gz') as archive:
        for relative in files:
            archive.add(ROOT / relative, arcname=str(relative), recursive=False)
        data = (json.dumps(manifest, indent=2) + '\n').encode()
        info = tarfile.TarInfo('SOURCE-MANIFEST.json')
        info.size = len(data)
        info.mode = 0o644
        archive.addfile(info, io.BytesIO(data))
    print(json.dumps({'archive': str(destination), 'files': len(files), 'bytes': destination.stat().st_size,
                      'sha256': hashlib.sha256(destination.read_bytes()).hexdigest()}))


if __name__ == '__main__':
    main()
