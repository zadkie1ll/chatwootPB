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


def gateway_configuration(channel='telegram'):
    if channel == 'telegram':
        return os.environ['TELEGRAM_GATEWAY_URL'], os.environ['GATEWAY_TOKEN']
    if channel == 'max' and os.environ.get('MAX_DELIVERY_ENABLED') == 'true':
        return os.environ['MAX_GATEWAY_URL'], os.environ['MAX_GATEWAY_TOKEN']
    raise ValueError('unsupported_channel')


def channel_gateway(channel, method, path, **kwargs):
    # Keep the established Telegram transport and its callers compatible.
    if channel == 'telegram':
        return gateway(method, path, **kwargs)
    url, token = gateway_configuration(channel)
    response = httpx.request(method, url + path, headers={'Authorization': 'Bearer ' + token}, timeout=25, **kwargs)
    response.raise_for_status()
    return response.json()


def enabled_channels():
    return ['telegram', 'max'] if os.environ.get('MAX_DELIVERY_ENABLED') == 'true' else ['telegram']
