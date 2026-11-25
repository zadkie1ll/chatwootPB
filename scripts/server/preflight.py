#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[2]
memory = {}
for line in Path('/proc/meminfo').read_text().splitlines():
    key, value = line.split(':', 1)
    memory[key] = int(value.strip().split()[0])
report = {
    'total_mib': memory['MemTotal'] // 1024,
    'available_mib': memory['MemAvailable'] // 1024,
    'minimum_total_mib': 7600,
    'minimum_available_mib': 4096,
    'memory_ready': memory['MemTotal'] >= 7600 * 1024 and memory['MemAvailable'] >= 4096 * 1024,
}
subprocess.run(['bash', 'scripts/compose.sh', 'config', '--quiet'], cwd=root, check=True)
report['compose_valid'] = True
print(json.dumps(report, indent=2))
raise SystemExit(0 if report['memory_ready'] else 2)
