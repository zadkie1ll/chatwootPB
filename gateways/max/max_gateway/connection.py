import asyncio
import base64
from contextlib import suppress
import io
import json
import logging
import time
from pathlib import Path
import uuid

import qrcode
from qrcode.image.svg import SvgPathImage


class ManualLoginRequired(Exception):
    pass


class RestoreOnly:
    async def authenticate(self, _app):
        raise ManualLoginRequired()


def sdk_client(manager, allow_auth):
    from pymax import ExtraConfig, QrAuthFlow, WebClient
    # Never use the SDK console providers: they would disclose the QR in logs
    # or wait for a password on server stdin.
    flow = QrAuthFlow(manager, password_provider=manager) if allow_auth else RestoreOnly()
    client = WebClient(work_dir=str(manager.directory), session_name='session.sqlite3', auth_flow=flow,
                       extra_config=ExtraConfig(log_level='CRITICAL', telemetry=False, relogin=allow_auth,
                                                reconnect=not allow_auth, reconnect_delay=5,
                                                request_timeout=20, password_max_attempts=3))
    sdk_log = logging.getLogger('pymax')
    sdk_log.handlers = [logging.NullHandler()]
    sdk_log.propagate = False

    @client.on_start()
    async def connected(_client):
        client.extra_config.reconnect = True
        # Re-login is allowed only while the operator is actively connecting.
        # A later revoked session must not start a new QR flow by itself.
        client.extra_config.relogin = False
        manager.authenticated()

    @client.on_disconnect()
    async def disconnected(*_args, **_kwargs):
        manager.state = 'reconnecting'
        manager.qr_image = None

    if manager.messaging:
        manager.messaging.register(client)
    return client


class Connection:
    def __init__(self, directory, factory=sdk_client):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, mode=0o700, exist_ok=True)
        self.factory = factory
        self.messaging = None
        self.state = 'disconnected'
        self.error = None
        self.qr_image = None
        self.attempt_id = None
        self.password_attempts = 0
        self.passwords = asyncio.Queue(maxsize=1)
        self.lock = asyncio.Lock()
        self.client = None
        self.task = None
        self.next_restore_at = 0
        self.restore_failures = 0

    def control(self):
        location = self.directory / 'control.json'
        return json.loads(location.read_text()) if location.exists() else {}

    def save_control(self, **values):
        values = {**self.control(), **values}
        target = self.directory / 'control.json'
        temporary = self.directory / ('control-' + uuid.uuid4().hex)
        temporary.write_text(json.dumps(values))
        temporary.chmod(0o600)
        temporary.replace(target)

    @property
    def connected(self):
        return bool(self.state == 'connected' and self.client and self.client.is_connected
                    and self.client.me is not None and self.task and not self.task.done())

    def snapshot(self):
        connected = self.connected
        state = 'connected' if connected else ('reconnecting' if self.state == 'connected' else self.state)
        return {'status': state, 'connected': connected, 'attempt_id': self.attempt_id,
                'qr_image': self.qr_image if state == 'qr_required' else None,
                'password_attempts': self.password_attempts, 'error': self.error,
                'poc_only': True, 'messages_forwarded': False}

    async def show_qr(self, qr_url):
        qr = qrcode.make(qr_url, image_factory=SvgPathImage, box_size=8, border=4)
        output = io.BytesIO()
        qr.save(output)
        self.qr_image = 'data:image/svg+xml;base64,' + base64.b64encode(output.getvalue()).decode()
        self.state = 'qr_required'

    async def get_password(self, _hint=None):
        self.qr_image = None
        self.password_attempts += 1
        self.state = 'password_required'
        return await asyncio.wait_for(self.passwords.get(), timeout=180)

    def authenticated(self):
        self.state = 'connected'
        self.restore_failures = 0
        self.error = None
        self.qr_image = None
        self.save_control(enabled=True, authenticated=True)

    async def start(self, allow_auth=True):
        async with self.lock:
            if self.task and not self.task.done():
                return self.snapshot()
            if self.client:
                await self.client.close()
            self.state, self.error, self.qr_image = 'starting', None, None
            self.attempt_id = str(uuid.uuid4())
            self.password_attempts = 0
            self.passwords = asyncio.Queue(maxsize=1)
            self.save_control(enabled=True)
            self.task = asyncio.create_task(self.run(allow_auth))
            return self.snapshot()

    async def run(self, allow_auth):
        try:
            self.client = self.factory(self, allow_auth)
            await self.client.start()
            self.state = 'disconnected'
        except asyncio.CancelledError:
            raise
        except ManualLoginRequired:
            self.state, self.error = 'disconnected', 'login_required'
        except Exception:
            # SDK exceptions can contain protocol payloads; never log or relay
            # their text, tracebacks, account identity or credentials.
            self.state, self.error = 'error', 'connection_failed'
        finally:
            self.qr_image = None
            if self.client:
                with suppress(Exception):
                    await self.client.close()
            while not self.passwords.empty():
                self.passwords.get_nowait()

    async def resume(self):
        saved = self.control()
        if saved.get('enabled') and saved.get('authenticated'):
            await self.start(allow_auth=False)

    async def retry_restore(self):
        if self.task and not self.task.done():
            return
        if self.error == 'login_required' or time.time() < self.next_restore_at:
            return
        self.next_restore_at = time.time() + 30
        saved = self.control()
        if not saved.get('enabled') or not saved.get('authenticated'):
            return
        self.restore_failures += 1
        self.next_restore_at = time.time() + min(300, 5 * 2 ** min(self.restore_failures, 6))
        await self.start(allow_auth=False)

    async def password(self, attempt_id, value):
        if attempt_id != self.attempt_id or self.state != 'password_required':
            raise ValueError('stale_attempt')
        if not isinstance(value, str) or not 1 <= len(value) <= 256 or self.passwords.full():
            raise ValueError('invalid_password')
        self.passwords.put_nowait(value)
        self.state = 'authenticating'
        return self.snapshot()

    async def stop(self, attempt_id=None, persist=True):
        async with self.lock:
            if persist and attempt_id != self.attempt_id:
                raise ValueError('stale_attempt')
            if self.task:
                self.task.cancel()
                with suppress(asyncio.CancelledError):
                    await self.task
            if self.client:
                with suppress(Exception):
                    await self.client.close()
            self.task, self.client = None, None
            self.state, self.error, self.qr_image = 'disconnected', None, None
            if persist:
                self.save_control(enabled=False)
            return self.snapshot()
