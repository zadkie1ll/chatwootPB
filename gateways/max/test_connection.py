import asyncio
import json
import os
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
from aiohttp.test_utils import TestClient, TestServer
from max_gateway.connection import Connection, ManualLoginRequired, sdk_client
from max_gateway.server import create_app


class FakeClient:
    def __init__(self, manager, allow_auth):
        self.manager, self.allow_auth = manager, allow_auth
        self.is_connected = False
        self.me = None
        self.closed = asyncio.Event()

    async def start(self):
        if not self.allow_auth and not self.manager.control().get('authenticated'):
            raise ManualLoginRequired()
        self.is_connected = True
        if self.allow_auth:
            await self.manager.show_qr('https://max.example.invalid/synthetic-secret-qr')
            password = await self.manager.get_password()
            if password != 'synthetic-password':
                raise RuntimeError('Do not leak synthetic-password or synthetic-secret-qr')
        self.me = object()
        self.manager.authenticated()
        await self.closed.wait()

    async def close(self):
        self.is_connected = False
        self.closed.set()


class ConnectionTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = TemporaryDirectory()
        self.connection = Connection(self.temp.name, factory=FakeClient)

    async def asyncTearDown(self):
        await self.connection.stop(persist=False)
        self.temp.cleanup()

    async def tick(self):
        for _ in range(4):
            await asyncio.sleep(0)

    async def test_sdk_can_renew_a_revoked_token_only_during_explicit_login(self):
        client = sdk_client(self.connection, True)
        try:
            self.assertTrue(client.extra_config.relogin)
            self.assertFalse(client.extra_config.telemetry)
            await client._router.on_start_handlers[0](client)
            self.assertFalse(client.extra_config.relogin)
            self.assertTrue(client.extra_config.reconnect)
        finally:
            await client.close()

    async def test_restore_client_never_prompts_for_new_credentials(self):
        client = sdk_client(self.connection, False)
        try:
            self.assertFalse(client.extra_config.relogin)
            with self.assertRaises(ManualLoginRequired):
                await client._auth_flow.authenticate(None)
        finally:
            await client.close()

    async def test_connected_requires_authenticated_profile_not_open_socket(self):
        await self.connection.start()
        await self.tick()
        self.assertEqual(self.connection.snapshot()['status'], 'password_required')
        self.assertFalse(self.connection.connected)
        attempt = self.connection.attempt_id
        await self.connection.password(attempt, 'synthetic-password')
        await self.tick()
        self.assertTrue(self.connection.connected)
        self.assertNotIn('synthetic-password', json.dumps(self.connection.snapshot()))
        self.assertIsNone(self.connection.snapshot()['qr_image'])

    async def test_reopened_socket_is_not_authenticated_until_start_callback(self):
        await self.connection.start()
        await self.tick()
        await self.connection.password(self.connection.attempt_id, 'synthetic-password')
        await self.tick()
        self.assertTrue(self.connection.connected)
        self.connection.state = 'reconnecting'
        self.assertFalse(self.connection.connected)
        self.assertEqual(self.connection.snapshot()['status'], 'reconnecting')
        self.connection.authenticated()
        self.assertTrue(self.connection.connected)

    async def test_qr_is_locally_rendered_and_cleared_when_password_is_requested(self):
        await self.connection.show_qr('synthetic-secret-qr')
        image = self.connection.snapshot()['qr_image']
        self.assertTrue(image.startswith('data:image/svg+xml;base64,'))
        self.assertNotIn('synthetic-secret-qr', json.dumps(self.connection.snapshot()))
        task = asyncio.create_task(self.connection.get_password())
        await self.tick()
        self.assertIsNone(self.connection.snapshot()['qr_image'])
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task

    async def test_stale_browser_attempt_cannot_submit_or_cancel_new_login(self):
        await self.connection.start()
        await self.tick()
        with self.assertRaises(ValueError):
            await self.connection.password('old-attempt', 'synthetic-password')
        with self.assertRaises(ValueError):
            await self.connection.stop('old-attempt')
        self.assertEqual(self.connection.state, 'password_required')

    async def test_restart_restores_saved_session_without_requesting_qr_or_password(self):
        await self.connection.start()
        await self.tick()
        await self.connection.password(self.connection.attempt_id, 'synthetic-password')
        await self.tick()
        await self.connection.stop(persist=False)
        restored = Connection(self.temp.name, factory=FakeClient)
        try:
            await restored.resume()
            await self.tick()
            self.assertTrue(restored.connected)
            self.assertFalse(restored.client.allow_auth)
        finally:
            await restored.stop(persist=False)

    async def test_operator_stop_prevents_automatic_resume(self):
        await self.connection.start()
        await self.tick()
        await self.connection.stop(self.connection.attempt_id)
        await self.connection.resume()
        self.assertIsNone(self.connection.task)
        self.assertEqual(self.connection.state, 'disconnected')

    async def test_finished_connection_is_restored_without_interactive_login(self):
        self.connection.save_control(enabled=True, authenticated=True)
        await self.connection.resume()
        await self.tick()
        self.connection.client.closed.set()
        await self.tick()
        self.assertFalse(self.connection.connected)
        await self.connection.retry_restore()
        await self.tick()
        self.assertTrue(self.connection.connected)
        self.assertFalse(self.connection.client.allow_auth)

    async def test_restore_failures_are_backed_off_and_revoked_sessions_wait_for_operator(self):
        self.connection.save_control(enabled=True, authenticated=True)
        calls = []
        class BrokenClient(FakeClient):
            async def start(client):
                calls.append(client.allow_auth)
                raise OSError('Synthetic connection failure')
        self.connection.factory = BrokenClient
        await self.connection.retry_restore()
        await self.tick()
        await self.connection.retry_restore()
        self.assertEqual(calls, [False])
        self.connection.next_restore_at = 0
        self.connection.error = 'login_required'
        await self.connection.retry_restore()
        self.assertEqual(calls, [False])

    async def test_disabled_connection_does_not_restore_in_maintenance_loop(self):
        self.connection.save_control(enabled=False, authenticated=True)
        await self.connection.retry_restore()
        self.assertIsNone(self.connection.task)

    async def test_sdk_error_details_are_not_exposed(self):
        await self.connection.start()
        await self.tick()
        await self.connection.password(self.connection.attempt_id, 'wrong-password')
        await self.tick()
        self.assertEqual(self.connection.state, 'error')
        self.assertEqual(self.connection.error, 'connection_failed')
        self.assertNotIn('synthetic-password', json.dumps(self.connection.snapshot()))


class ApiTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = TemporaryDirectory()
        self.env = patch.dict(os.environ, {'MAX_GATEWAY_TOKEN': 't' * 64})
        self.env.start()
        self.connection = Connection(self.temp.name, factory=FakeClient)
        self.client = TestClient(TestServer(create_app(self.temp.name, self.connection)))
        await self.client.start_server()
        self.headers = {'Authorization': 'Bearer ' + 't' * 64}

    async def asyncTearDown(self):
        await self.client.close()
        self.env.stop()
        self.temp.cleanup()

    async def test_anonymous_health_has_no_authentication_material(self):
        response = await self.client.get('/health')
        data = await response.json()
        self.assertEqual(data['status'], 'ok')
        self.assertFalse(data['connected'])
        self.assertFalse(data['delivery_enabled'])
        self.assertNotIn('qr_image', data)
        self.assertEqual((await self.client.get('/auth/status')).status, 401)
        self.assertIsNone(self.connection.task)

    async def test_stalled_sync_is_unhealthy_even_when_http_server_is_alive(self):
        from max_gateway.server import LAST_PROGRESS
        import time
        self.client.server.app[LAST_PROGRESS]['at'] = time.time() - 181
        response = await self.client.get('/health')
        self.assertEqual(response.status, 503)
        self.assertEqual((await response.json())['status'], 'degraded')

    async def test_authenticated_status_is_not_cacheable(self):
        response = await self.client.get('/auth/status', headers=self.headers)
        self.assertEqual(response.status, 200)
        self.assertEqual(response.headers['Cache-Control'], 'no-store')
        self.assertIsNone(self.connection.task)

    async def test_repeated_start_does_not_create_parallel_sessions(self):
        first = await (await self.client.post('/auth/start', headers=self.headers, json={})).json()
        second = await (await self.client.post('/auth/start', headers=self.headers, json={})).json()
        self.assertEqual(first['attempt_id'], second['attempt_id'])
        self.assertEqual((await self.client.post('/auth/password', headers=self.headers,
                                               json={'attempt_id': 'stale', 'password': 'never-log-this'})).status, 409)

    async def test_auth_only_mode_disables_delivery_endpoints(self):
        self.assertEqual((await self.client.post('/send', headers=self.headers, json={})).status, 503)
        self.assertEqual((await self.client.get('/events', headers=self.headers)).status, 503)


if __name__ == '__main__':
    unittest.main()
