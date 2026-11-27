#!/usr/bin/env python3
"""Local monitoring and limited recovery for this Compose project only."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
STATE = ROOT / '.state/watchdog'
PROJECT = 'pravburo-chatwoot'
RECOVERABLE = ('proxy', 'chatwoot-web', 'chatwoot-worker', 'integration-web',
               'integration-worker', 'integration-crm-worker', 'telegram-gateway',
               'max-gateway', 'openai-proxy')
REQUIRED = ('postgres', 'redis', 'clamav') + RECOVERABLE
FAILURE_THRESHOLD = 3
RESTART_COOLDOWN = 600


def run(args, timeout=30):
    return subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=timeout, check=True).stdout


def recovery_candidate(containers, history, now):
    dependencies_ok = all(containers.get(name, {}).get('health') == 'healthy' for name in ('postgres', 'redis'))
    for name in RECOVERABLE:
        container = containers.get(name, {})
        record = history.setdefault(name, {'failures': 0, 'last_restart': 0})
        unhealthy = container.get('running') and container.get('health') == 'unhealthy'
        record['failures'] = record['failures'] + 1 if unhealthy else 0
    if not dependencies_ok:
        return None
    for name in RECOVERABLE:
        record = history[name]
        if record['failures'] >= FAILURE_THRESHOLD and now - record['last_restart'] >= RESTART_COOLDOWN:
            return name
    return None


def inspect_containers():
    identifiers = run(['docker', 'ps', '-aq', '--filter', 'label=com.docker.compose.project=' + PROJECT]).split()
    if not identifiers:
        return {}
    rows = json.loads(run(['docker', 'inspect', *identifiers]))
    result = {}
    for row in rows:
        labels = row['Config'].get('Labels', {})
        name = labels.get('com.docker.compose.service')
        if labels.get('com.docker.compose.project') != PROJECT or labels.get('com.docker.compose.oneoff', '').lower() == 'true':
            continue
        if name not in REQUIRED:
            continue
        state = row['State']
        result[name] = {'id': row['Id'], 'running': state['Running'], 'health': state.get('Health', {}).get('Status', 'missing'),
                        'restarts': row['RestartCount'], 'oom_killed': state.get('OOMKilled', False)}
    return result


def https_probe(port, domain='mess.prav-buro.ru'):
    try:
        run(['curl', '--fail', '--silent', '--show-error', '--max-time', '8', '--resolve', f'{domain}:{port}:127.0.0.1',
             f'https://{domain}:{port}/health'], timeout=10)
        html = run(['curl', '--fail', '--silent', '--show-error', '--max-time', '8', '--resolve', f'{domain}:{port}:127.0.0.1',
                    f'https://{domain}:{port}/app/login'], timeout=10)
        return '<div id="app">' in html
    except (subprocess.SubprocessError, OSError):
        return False


def pipeline_probe():
    # Read service credentials only inside the existing container. Return metadata only.
    code = """
import json,os,urllib.request
request=urllib.request.Request('http://127.0.0.1:8090/health/details/',headers={'Authorization':'Bearer '+os.environ['INTEGRATION_API_TOKEN']})
d=json.load(urllib.request.urlopen(request,timeout=15))
print(json.dumps({k:d.get(k,{}) for k in ['workers','incoming','outgoing','telegram','max']}))
"""
    try:
        output = run(['bash', 'scripts/compose.sh', 'exec', '-T', 'integration-web', 'python', '-c', code], timeout=25)
        return json.loads(output)
    except (subprocess.SubprocessError, OSError, ValueError):
        return {'unavailable': True}


def issues_for(containers, https, pipeline):
    issues = [name + ':' + containers.get(name, {}).get('health', 'missing') for name in REQUIRED
              if not containers.get(name, {}).get('running') or containers.get(name, {}).get('health') != 'healthy']
    issues.extend('https:' + port for port, healthy in https.items() if not healthy)
    if pipeline.get('unavailable'):
        issues.append('pipeline:unavailable')
    for channel in ('telegram', 'max'):
        state = pipeline.get(channel, {})
        if state.get('connected') is not True:
            issues.append(channel + ':disconnected')
        if state.get('sync_error'):
            issues.append(channel + ':sync_error')
        if state.get('queues', {}).get('unknown_operations', 0) or state.get('queues', {}).get('unknown', 0):
            issues.append(channel + ':uncertain_send')
    for name, state in pipeline.get('workers', {}).items():
        if not state.get('healthy') or state.get('last_success_age') is None or state['last_success_age'] > 300:
            issues.append('worker:' + name)
    for queue in ('incoming', 'outgoing'):
        if pipeline.get(queue, {}).get('oldest_seconds', 0) > 300:
            issues.append(queue + ':delayed')
    return issues


def save_report(report):
    temporary = STATE / 'status.tmp'
    temporary.write_text(json.dumps(report, indent=2) + '\n')
    temporary.replace(STATE / 'status.json')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repair', action='store_true')
    options = parser.parse_args()
    os.umask(0o077)
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if (STATE / 'paused').exists():
            print(json.dumps({'paused': True}))
            return
        saved = STATE / 'status.json'
        history = json.loads(saved.read_text()).get('history', {}) if saved.exists() else {}
        now = time.time()
        containers = inspect_containers()
        https = {str(port): https_probe(port) for port in (443, 18443)}
        certificate = ROOT / 'secrets/acme-ip/live/chatwoot-ip/fullchain.pem'
        if certificate.exists():
            https['ip18443'] = https_probe(18443, '162.248.166.241')
        pipeline = pipeline_probe()
        candidate = recovery_candidate(containers, history, now)
        issues = issues_for(containers, https, pipeline)
        report = {'checked_at': now, 'healthy': not issues, 'issues': issues, 'https': https, 'pipeline': pipeline,
                  'containers': containers, 'history': history, 'restarted': None}
        # One unhealthy application per scan. Persist cooldown before the action
        # so a failed restart or watchdog interruption cannot create a restart loop.
        if options.repair and candidate:
            history[candidate] = {'failures': 0, 'last_restart': now}
            save_report(report)
            try:
                run(['docker', 'restart', '--time', '120', containers[candidate]['id']], timeout=150)
                report['restarted'] = candidate
            except (subprocess.SubprocessError, OSError):
                issues.append(candidate + ':recovery_failed')
        save_report(report)
        print(json.dumps({'healthy': report['healthy'], 'issues': issues, 'restarted': report['restarted']}))


if __name__ == '__main__':
    main()
