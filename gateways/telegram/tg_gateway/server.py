import asyncio
from contextlib import suppress
import base64
import fcntl
import hmac
import json
import logging
import os
import re
import time
import uuid
from pathlib import Path
from aiohttp import web
from telethon import errors
from .journal import Journal
from .driver import PersonalDriver, MAX_BYTES


@web.middleware
async def authenticate(request, handler):
    if request.path == '/health':
        return await handler(request)
    expected = os.environ.get('GATEWAY_TOKEN', '')
    supplied = request.headers.get('Authorization', '').removeprefix('Bearer ')
    if len(expected) < 32 or not hmac.compare_digest(expected, supplied):
        raise web.HTTPUnauthorized()
    try:
        return await handler(request)
    except (ValueError, KeyError):
        return web.json_response({'error': 'invalid_request'}, status=422)


def create_app(directory=None, mode=None):
    os.umask(0o077)
    directory = Path(directory or os.environ.get('TELEGRAM_DATA_DIR', '/data'))
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_file = (directory / 'gateway.lock').open('a')
    fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    journal = Journal(directory)
    mode = mode or os.environ.get('TELEGRAM_MODE', 'personal')
    app = web.Application(middlewares=[authenticate], client_max_size=28 * 1024 * 1024)
    app['journal'], app['mode'], app['lock'] = journal, mode, lock_file
    driver = PersonalDriver(directory, journal)
    app['driver'] = driver

    async def health(request):
        healthy = not app['maintenance'].done()
        return web.json_response({'status': 'ok' if healthy else 'degraded', 'mode': mode, 'connected': mode == 'mock' or driver.connected, 'queues': journal.metrics()}, status=200 if healthy else 503)

    async def resolve(request):
        data = await request.json()
        phone = data['phone']
        if not re.fullmatch(r'\+[1-9]\d{6,14}', phone):
            raise ValueError('invalid_phone')
        if mode == 'mock':
            if phone.endswith('0000'):
                return web.json_response({'error': 'recipient_unavailable'}, status=422)
            result = {'external_account_id': 'mock-personal', 'external_user_id': phone[1:], 'name': 'Synthetic Telegram ' + phone[-4:]}
        else:
            if not driver.account_id:
                return web.json_response({'error': 'channel_unavailable'}, status=503)
            if journal.retry_after():
                return web.json_response({'error': 'channel_unavailable'}, status=503)
            try:
                result = await driver.resolve(phone)
            except errors.FloodWaitError as error:
                journal.pause(error.seconds)
                return web.json_response({'error': 'channel_unavailable'}, status=503)
            except (errors.RPCError, ValueError):
                return web.json_response({'error': 'recipient_unavailable'}, status=422)
        return web.json_response(result)

    async def send(request):
        data = await request.json()
        uuid.UUID(data['operation_id'])
        if not re.fullmatch(r'\d{1,30}', str(data['external_user_id'])) or len(data.get('text', '')) > 100000:
            raise ValueError('invalid_message')
        files = []
        total_size = 0
        for item in data.get('attachments', []):
            content = base64.b64decode(item['data'], validate=True)
            total_size += len(content)
            if total_size > MAX_BYTES or not content:
                raise ValueError('attachment_size')
            files.append(({**item, 'filename': Path(item['filename']).name[:150]}, content))
        if not data.get('text') and not files and data.get('action') != 'edit':
            raise ValueError('empty_message')
        if mode != 'mock' and not driver.account_id:
            return web.json_response({'state': 'failed', 'error_code': 'channel_unavailable'})
        action = data.get('action', 'send')
        if action not in ('send', 'edit'):
            raise ValueError('invalid_action')
        if action == 'edit' and (files or not re.fullmatch(r'\d{1,30}', str(data.get('target_message_id', '')))):
            raise ValueError('invalid_edit')
        random_id, prior = journal.begin_operation(data)
        if prior:
            return web.json_response(prior)
        if journal.retry_after():
            seconds = journal.retry_after()
            return web.json_response(journal.finish(data['operation_id'], 'retry', retry_after=seconds, retry_at=time.time() + seconds))
        try:
            if mode == 'mock':
                ids = [str(data['target_message_id'])] if action == 'edit' else [journal.next_mock_id()]
            elif action == 'edit':
                ids = await driver.edit(data)
            else:
                ids = await driver.send(data, random_id, files)
            result = journal.finish(data['operation_id'], 'sent', external_message_id=ids[0], external_message_ids=ids)
        except errors.FloodWaitError as error:
            journal.pause(error.seconds)
            result = journal.finish(data['operation_id'], 'retry', retry_after=error.seconds, retry_at=time.time() + error.seconds)
        except (errors.UserPrivacyRestrictedError, errors.UserIsBlockedError, errors.PeerIdInvalidError, errors.ChatWriteForbiddenError, errors.MessageAuthorRequiredError, errors.MessageEditTimeExpiredError, errors.MessageIdInvalidError, errors.BadRequestError):
            result = journal.finish(data['operation_id'], 'failed', error_code='recipient_unavailable')
        except (errors.RPCError, OSError, asyncio.TimeoutError, RuntimeError, ValueError):
            # An exception is not proof that the external send did not happen.
            result = journal.finish(data['operation_id'], 'unknown', error_code='send_outcome_unknown')
        return web.json_response(result)

    async def operation(request):
        uuid.UUID(request.match_info['operation_id'])
        operation_id = request.match_info['operation_id']
        payload = journal.edit_payload(operation_id)
        if payload and driver.connected:
            try:
                message = await driver.client.get_messages(int(payload['external_user_id']), ids=int(payload['target_message_id']))
                if message and message.message == payload['text']:
                    journal.finish(operation_id, 'sent', external_message_id=str(message.id), external_message_ids=[str(message.id)])
            except (errors.RPCError, OSError, asyncio.TimeoutError):
                pass
        return web.json_response(journal.operation(operation_id))

    async def auth_status(request):
        return web.json_response({'status': 'mock' if mode == 'mock' else 'connected' if driver.connected else 'disconnected'})

    async def authorize(request):
        if mode != 'personal':
            raise web.HTTPConflict()
        data = await request.json()
        try:
            if request.match_info['step'] == 'start':
                api_id, api_hash, phone = int(data['api_id']), data['api_hash'], data['phone']
                if api_id <= 0 or not re.fullmatch(r'[a-fA-F0-9]{32}', api_hash) or not re.fullmatch(r'\+[1-9]\d{6,14}', phone):
                    raise ValueError('invalid_credentials')
                result = await driver.auth_start(api_id, api_hash, phone)
            elif request.match_info['step'] == 'code':
                if not re.fullmatch(r'\d{4,8}', data['code']):
                    raise ValueError('invalid_code')
                result = await driver.auth_verify(code=data['code'])
            elif request.match_info['step'] == 'password':
                if not isinstance(data['password'], str) or not 1 <= len(data['password']) <= 256:
                    raise ValueError('invalid_password')
                result = await driver.auth_verify(password=data['password'])
            else:
                raise web.HTTPNotFound()
            return web.json_response(result)
        except errors.FloodWaitError as error:
            return web.json_response({'status': 'wait', 'retry_after': error.seconds}, status=429)
        except errors.RPCError:
            return web.json_response({'error': 'authorization_failed'}, status=422)
        except (OSError, asyncio.TimeoutError):
            return web.json_response({'error': 'channel_unavailable'}, status=503)

    async def receive(request):
        return web.json_response({'events': journal.events()})

    async def ack(request):
        journal.ack(int(request.match_info['event_id']))
        return web.json_response({'saved': True})

    async def complete(request):
        journal.complete(int(request.match_info['event_id']))
        return web.json_response({'processed': True})

    async def attachment(request):
        key = request.match_info['key']
        if not re.fullmatch(r'[0-9a-f]{32}', key):
            raise web.HTTPNotFound()
        location = directory / ('attachment-' + key)
        if not location.is_file():
            raise web.HTTPNotFound()
        return web.FileResponse(location, headers={'Cache-Control': 'no-store'})

    async def mock_incoming(request):
        if mode != 'mock':
            raise web.HTTPNotFound()
        data = await request.json()
        attached = []
        for fixture in data.pop('fixture_files', []):
            content = base64.b64decode(fixture['data'], validate=True)
            if not 0 < len(content) <= MAX_BYTES:
                raise ValueError('fixture_size')
            key = uuid.uuid4().hex
            (directory / ('attachment-' + key)).write_bytes(content)
            attached.append({'key': key, 'filename': Path(fixture['filename']).name, 'content_type': fixture['content_type'], 'size': len(content)})
        if attached:
            data['attachments'] = attached
        data.setdefault('external_message_id', journal.next_mock_id())
        data.setdefault('external_account_id', 'mock-personal')
        data.setdefault('external_chat_id', data['external_user_id'])
        data.setdefault('channel', 'telegram')
        data.setdefault('direction', 'incoming')
        data.setdefault('event_type', 'received')
        data.setdefault('revision', '')
        data.setdefault('origin', 'external')
        journal.save_event(data)
        return web.json_response({'saved': True})

    async def maintain():
        count = 0
        while True:
            try:
                if mode != 'mock':
                    if not driver.connected and count % 10 == 0:
                        if driver.client:
                            await driver.client.disconnect()
                        await asyncio.wait_for(driver.connect(), timeout=30)
                    await driver.process_media()
                    await driver.poll_reads()
                if count % 60 == 0:
                    journal.cleanup()
            except (OSError, errors.RPCError, asyncio.TimeoutError):
                pass  # Durable jobs stay pending; health exposes connection/queue state.
            count += 1
            await asyncio.sleep(1)

    async def start(application):
        application['maintenance'] = asyncio.create_task(maintain())

    async def cleanup(application):
        application['maintenance'].cancel()
        with suppress(asyncio.CancelledError):
            await application['maintenance']
        if driver.client:
            await driver.client.disconnect()
        journal.db.close()
        lock_file.close()

    app.on_startup.append(start)
    app.on_cleanup.append(cleanup)
    app.add_routes([web.get('/health', health), web.post('/resolve', resolve), web.post('/send', send),
                    web.get('/auth/status', auth_status), web.post('/auth/{step}', authorize),
                    web.get('/operations/{operation_id}', operation), web.get('/events', receive),
                    web.post('/events/{event_id}/ack', ack), web.post('/events/{event_id}/complete', complete), web.get('/attachments/{key}', attachment),
                    web.post('/test/incoming', mock_incoming)])
    return app


if __name__ == '__main__':
    logging.basicConfig(level=logging.CRITICAL)
    web.run_app(create_app(), host='0.0.0.0', port=8091, access_log=None, print=None)
