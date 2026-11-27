import asyncio
import base64
from contextlib import suppress
import re
import uuid
import fcntl
import hmac
import logging
import os
import time
from pathlib import Path
from aiohttp import web
from .connection import Connection
from .journal import Journal
from .messaging import Messaging
from .media import MAX_BYTES

MAINTENANCE = web.AppKey('maintenance', asyncio.Task)
LAST_PROGRESS = web.AppKey('last_progress', dict)
MAINTENANCE_TIMEOUT = 90
PROGRESS_MAX_AGE = 180


def create_app(directory=None, manager=None):
    os.umask(0o077)
    directory = Path(directory or os.environ.get('MAX_DATA_DIR', '/data'))
    directory.mkdir(parents=True, mode=0o700, exist_ok=True)
    lock = (directory / 'gateway.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    token = os.environ.get('MAX_GATEWAY_TOKEN', '')
    if len(token) < 32:
        lock.close()
        raise RuntimeError('MAX service token is required')
    manager = manager or Connection(directory)

    journal = Journal(directory)
    messaging = Messaging(manager, journal)
    manager.messaging = messaging

    @web.middleware
    async def access(request, handler):
        if request.path != '/health':
            supplied = request.headers.get('Authorization', '').removeprefix('Bearer ')
            if not hmac.compare_digest(token, supplied):
                return web.json_response({'error': 'unauthorized'}, status=401, headers={'Cache-Control': 'no-store'})
        try:
            response = await handler(request)
        except (ValueError, KeyError, TypeError):
            response = web.json_response({'error': 'invalid_or_stale_request'}, status=409)
        except web.HTTPException:
            raise
        except Exception:
            response = web.json_response({'error': 'gateway_unavailable'}, status=503)
        response.headers['Cache-Control'] = 'no-store'
        response.headers['Pragma'] = 'no-cache'
        return response

    app = web.Application(middlewares=[access], client_max_size=29 * 1024 * 1024)
    app[LAST_PROGRESS] = {'at': time.time()}

    async def health(_request):
        progress_age = max(0, time.time() - app[LAST_PROGRESS]['at'])
        healthy = (MAINTENANCE not in app or not app[MAINTENANCE].done()) and progress_age < PROGRESS_MAX_AGE
        return web.json_response({'status': 'ok' if healthy else 'degraded', 'connected': manager.connected, 'poc_only': bool(messaging.allowed_peers) or not messaging.enabled,
                                  'delivery_enabled': messaging.enabled, 'progress_age_seconds': round(progress_age), 'queues': journal.metrics(), 'sync_error': messaging.error}, status=200 if healthy else 503)

    async def status(_request):
        return web.json_response({**manager.snapshot(), 'messages_forwarded': messaging.enabled,
                                  'poc_only': bool(messaging.allowed_peers) or not messaging.enabled})

    async def connect(request):
        step = request.match_info['step']
        data = await request.json()
        if not isinstance(data, dict):
            return web.json_response({'error': 'invalid_request'}, status=422)
        if step == 'start' and not data:
            result = await manager.start()
        elif step == 'password' and set(data) == {'attempt_id', 'password'}:
            result = await manager.password(data['attempt_id'], data['password'])
        elif step == 'cancel' and set(data) == {'attempt_id'}:
            result = await manager.stop(data['attempt_id'])
        else:
            return web.json_response({'error': 'invalid_request'}, status=422)
        return web.json_response(result)

    async def maintain():
        count = 0
        while True:
            try:
                await asyncio.wait_for(manager.retry_restore(), timeout=30)
                await asyncio.wait_for(messaging.tick(), timeout=MAINTENANCE_TIMEOUT)
            except asyncio.TimeoutError:
                messaging.error = 'sync_timeout'
            app[LAST_PROGRESS]['at'] = time.time()
            if count % 600 == 0:
                journal.cleanup()
            count += 1
            await asyncio.sleep(1)

    async def startup(_app):
        _app[LAST_PROGRESS]['at'] = time.time()
        await manager.resume()
        _app[MAINTENANCE] = asyncio.create_task(maintain())

    async def cleanup(_app):
        _app[MAINTENANCE].cancel()
        with suppress(asyncio.CancelledError):
            await _app[MAINTENANCE]
        await manager.stop(persist=False)
        journal.db.close()
        lock.close()

    def require_delivery():
        if not messaging.enabled:
            raise web.HTTPServiceUnavailable()

    async def resolve(request):
        require_delivery()
        data = await request.json()
        phone = data.get('phone') if isinstance(data, dict) else None
        if not isinstance(phone, str) or not re.fullmatch(r'\+[1-9]\d{6,14}', phone):
            return web.json_response({'error': 'invalid_request'}, status=422)
        try:
            result = await messaging.resolve(phone)
        except ValueError:
            return web.json_response({'error': 'recipient_unavailable'}, status=422)
        except Exception:
            return web.json_response({'error': 'recipient_unavailable' if manager.connected else 'channel_unavailable'}, status=422 if manager.connected else 503)
        return web.json_response(result)

    async def send(request):
        require_delivery()
        data = await request.json()
        if not isinstance(data, dict):
            raise ValueError('invalid_request')
        uuid.UUID(data['operation_id'])
        if data.get('channel') != 'max' or not re.fullmatch(r'\d{1,30}', str(data.get('external_user_id', ''))):
            raise ValueError('invalid_identity')
        text = data.get('text', '')
        if not isinstance(text, str) or len(text.encode()) > 100000 or data.get('action', 'send') not in ('send', 'edit'):
            raise ValueError('invalid_message')
        if data.get('reply_to') and not re.fullmatch(r'\d{1,30}', str(data['reply_to'])):
            raise ValueError('invalid_reply')
        attached = data.get('attachments', [])
        if not isinstance(attached, list) or len(attached) > 10:
            raise ValueError('invalid_attachments')
        files = []
        for item in attached:
            content = base64.b64decode(item['data'], validate=True)
            if not content or sum(len(row[1]) for row in files) + len(content) > MAX_BYTES:
                raise ValueError('invalid_attachment_size')
            files.append(({**item, 'filename': Path(item['filename']).name[:150]}, content))
        if len(files) > 1:
            return web.json_response({'state': 'failed', 'error_code': 'attachment_batch_unsupported'})
        if not text and not files:
            raise ValueError('empty_message')
        if data.get('action') == 'edit' and (files or not re.fullmatch(r'\d{1,30}', str(data.get('target_message_id', '')))):
            raise ValueError('invalid_edit')
        if not manager.connected:
            return web.json_response({'state': 'failed', 'error_code': 'channel_unavailable'})
        return web.json_response(await messaging.send(data, files))

    async def diagnostics(_request):
        require_delivery()
        return web.json_response(await messaging.diagnostics())

    async def operation(request):
        require_delivery()
        uuid.UUID(request.match_info['operation_id'])
        return web.json_response(await messaging.operation(request.match_info['operation_id']))

    async def events(_request):
        require_delivery()
        return web.json_response({'events': journal.events()})

    async def acknowledge(request):
        require_delivery()
        journal.ack(int(request.match_info['event_id']))
        return web.json_response({'saved': True})

    async def complete(request):
        require_delivery()
        journal.complete(int(request.match_info['event_id']))
        return web.json_response({'processed': True})

    async def attachment(request):
        require_delivery()
        key = request.match_info['key']
        if not re.fullmatch(r'[0-9a-f]{32}', key):
            raise web.HTTPNotFound()
        file = directory / ('attachment-' + key)
        if not file.is_file():
            raise web.HTTPNotFound()
        return web.FileResponse(file)

    app.add_routes([web.get('/diagnostics', diagnostics), web.post('/resolve', resolve), web.post('/send', send),
                    web.get('/operations/{operation_id}', operation), web.get('/events', events),
                    web.post('/events/{event_id}/ack', acknowledge), web.post('/events/{event_id}/complete', complete),
                    web.get('/attachments/{key}', attachment)])

    app.on_startup.append(startup)
    app.on_cleanup.append(cleanup)
    app.add_routes([web.get('/health', health), web.get('/auth/status', status), web.post('/auth/{step}', connect)])
    return app


if __name__ == '__main__':
    logging.basicConfig(level=logging.CRITICAL)
    web.run_app(create_app(), host='0.0.0.0', port=8092, access_log=None, print=None)
