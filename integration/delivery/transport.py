import os
import httpx


def cw(method, path, **kwargs):
    response = httpx.request(method, os.environ['CHATWOOT_INTERNAL_URL'] + '/internal/corporate' + path,
                             headers={'Authorization': 'Bearer ' + os.environ['CW_SERVICE_TOKEN']}, timeout=20, **kwargs)
    response.raise_for_status()
    return {} if response.status_code == 204 else response.json()


def gateway(method, path, **kwargs):
    response = httpx.request(method, os.environ['TELEGRAM_GATEWAY_URL'] + path,
                             headers={'Authorization': 'Bearer ' + os.environ['GATEWAY_TOKEN']}, timeout=25, **kwargs)
    response.raise_for_status()
    return response.json()
