import fcntl
import hmac
import logging
import os
from pathlib import Path
from aiohttp import web
from .connection import Connection


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

    @web.middleware
    async def access(request, handler):
        if request.path != '/health':
            supplied = request.headers.get('Authorization', '').removeprefix('Bearer ')
            if not hmac.compare_digest(token, supplied):
                return web.json_response({'error': 'unauthorized'}, status=401, headers={'Cache-Control': 'no-store'})
        try:
            response = await handler(request)
        except ValueError:
            response = web.json_response({'error': 'invalid_or_stale_request'}, status=409)
        except web.HTTPException:
            raise
        except Exception:
            response = web.json_response({'error': 'gateway_unavailable'}, status=503)
        response.headers['Cache-Control'] = 'no-store'
        response.headers['Pragma'] = 'no-cache'
        return response

    app = web.Application(middlewares=[access], client_max_size=4096)

    async def health(_request):
        return web.json_response({'status': 'ok', 'connected': manager.connected, 'poc_only': True})

    async def status(_request):
        return web.json_response(manager.snapshot())

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

    async def startup(_app):
        await manager.resume()

    async def cleanup(_app):
        await manager.stop(persist=False)
        lock.close()

    app.on_startup.append(startup)
    app.on_cleanup.append(cleanup)
    app.add_routes([web.get('/health', health), web.get('/auth/status', status), web.post('/auth/{step}', connect)])
    return app


if __name__ == '__main__':
    logging.basicConfig(level=logging.CRITICAL)
    web.run_app(create_app(), host='0.0.0.0', port=8092, access_log=None, print=None)
