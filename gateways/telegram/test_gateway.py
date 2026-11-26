import os
from pathlib import Path
import tempfile
import unittest
import uuid
from unittest.mock import patch
from unittest.mock import AsyncMock
from types import SimpleNamespace
from datetime import datetime, timezone
from telethon import errors, types
from tg_gateway.driver import PersonalDriver
from aiohttp.test_utils import TestClient, TestServer
from tg_gateway.journal import Journal
from tg_gateway.server import create_app


class GatewayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.environment = patch.dict(os.environ, {'GATEWAY_TOKEN': 't' * 64})
        self.environment.start()
        self.client = TestClient(TestServer(create_app(self.temp.name, 'mock')))
        await self.client.start_server()
        self.headers = {'Authorization': 'Bearer ' + 't' * 64}

    async def asyncTearDown(self):
        await self.client.close()
        self.environment.stop()
        self.temp.cleanup()

    async def test_auth_and_idempotent_send(self):
        payload = {'operation_id': str(uuid.uuid4()), 'external_account_id': 'mock-personal',
                   'external_user_id': '123', 'text': 'Synthetic text', 'attachments': []}
        self.assertEqual((await self.client.post('/send', json=payload)).status, 401)
        first = await (await self.client.post('/send', json=payload, headers=self.headers)).json()
        second = await (await self.client.post('/send', json=payload, headers=self.headers)).json()
        self.assertEqual(first['state'], 'sent')
        self.assertEqual(first['external_message_id'], second['external_message_id'])
        changed = await self.client.post('/send', json={**payload, 'text': 'Different'}, headers=self.headers)
        self.assertEqual(changed.status, 422)

    async def test_receive_persists_until_ack_and_deduplicates(self):
        event = {'external_user_id': '123', 'external_message_id': '50', 'text': 'Synthetic inbound'}
        for _ in range(2):
            self.assertEqual((await self.client.post('/test/incoming', json=event, headers=self.headers)).status, 200)
        events = (await (await self.client.get('/events', headers=self.headers)).json())['events']
        self.assertEqual(len(events), 1)
        again = (await (await self.client.get('/events', headers=self.headers)).json())['events']
        self.assertEqual(events, again)
        await self.client.post('/events/' + str(events[0]['journal_id']) + '/ack', headers=self.headers)
        self.assertEqual((await (await self.client.get('/events', headers=self.headers)).json())['events'], [])


class JournalRecoveryTests(unittest.TestCase):
    def test_restart_does_not_blindly_repeat_an_ambiguous_send(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = Journal(directory)
            payload = {'operation_id': str(uuid.uuid4()), 'external_user_id': '123', 'external_account_id': '1', 'text': 'Synthetic', 'attachments': []}
            journal.begin_operation(payload)
            journal.db.close()
            restored = Journal(directory)
            _, prior = restored.begin_operation(payload)
            self.assertEqual(prior['state'], 'unknown')
            restored.db.close()


class PersonalAuthorizationTests(unittest.IsolatedAsyncioTestCase):
    async def test_telegram_login_service_messages_are_not_journalled(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = SimpleNamespace(save_event=AsyncMock())
            driver = PersonalDriver(directory, journal)
            driver.ready.set()
            event = SimpleNamespace(is_private=True, chat_id=777000, message=SimpleNamespace(),
                                    get_chat=AsyncMock(return_value=SimpleNamespace(id=777000, bot=False)))
            await driver.save_message(event, 'received')
            journal.save_event.assert_not_called()

    async def test_text_reply_uses_stable_random_id_and_voice_uses_voice_note(self):
        with tempfile.TemporaryDirectory() as directory:
            driver = PersonalDriver(directory, None)
            driver.account_id = '1'
            client = AsyncMock()
            client.get_input_entity.return_value = 'synthetic-peer'
            client.return_value = types.UpdateShortSentMessage(id=3, pts=1, pts_count=1, date=datetime.now(timezone.utc))
            client.send_file.return_value = SimpleNamespace(id=4)
            driver.client = client
            data = {'external_account_id': '1', 'external_user_id': '2', 'text': 'Synthetic', 'reply_to': '44'}
            self.assertEqual(await driver.send(data, 123456, []), ['3'])
            request = client.call_args.args[0]
            self.assertEqual(request.random_id, 123456)
            self.assertEqual(request.reply_to.reply_to_msg_id, 44)
            self.assertEqual(await driver.send(data, 123457, [({'filename': 'voice.ogg', 'voice': True}, b'synthetic-audio')]), ['4'])
            self.assertTrue(client.send_file.call_args.kwargs['voice_note'])
            self.assertEqual(client.send_file.call_args.kwargs['reply_to'], 44)

    async def test_code_and_two_factor_flow_never_returns_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            driver = PersonalDriver(directory, None)
            client = SimpleNamespace(connect=AsyncMock(), disconnect=AsyncMock(), is_user_authorized=AsyncMock(return_value=False),
                                     send_code_request=AsyncMock(return_value=SimpleNamespace(phone_code_hash='private-hash')),
                                     sign_in=AsyncMock(side_effect=[errors.SessionPasswordNeededError(None), None]),
                                     get_me=AsyncMock(return_value=SimpleNamespace(id=123)), catch_up=AsyncMock())
            with patch.object(driver, 'build_client', return_value=client):
                self.assertEqual(await driver.auth_start(123, 'a' * 32, '+79990000001'), {'status': 'code_required'})
                self.assertEqual(await driver.auth_verify(code='12345'), {'status': 'password_required'})
                self.assertEqual(await driver.auth_verify(password='synthetic-password'), {'status': 'connected'})
            self.assertEqual(driver.account_id, '123')
            self.assertTrue(driver.ready.is_set())
            self.assertEqual((Path(directory) / 'config.json').stat().st_mode & 0o777, 0o600)
            self.assertIsNone(driver.phone_code_hash)


class ReliabilityTests(unittest.IsolatedAsyncioTestCase):
    def fixture(self, directory, journal):
        from unittest.mock import Mock
        message = SimpleNamespace(id=10, sender_id=2, message='Synthetic PDF', out=False, edit_date=None,
                                  date=datetime.now(timezone.utc), media=SimpleNamespace(ttl_seconds=None), ttl_period=None,
                                  photo=None, document=SimpleNamespace(id=20, size=8),
                                  file=SimpleNamespace(name='synthetic.pdf', mime_type='application/pdf', size=8), voice=False)
        event = SimpleNamespace(is_private=True, chat_id=2, message=message,
                                chat=SimpleNamespace(id=2, first_name='Synthetic', last_name='', phone=None, bot=False),
                                get_chat=AsyncMock(return_value=SimpleNamespace(id=2, first_name='Synthetic', last_name='', phone=None, bot=False)))
        driver = PersonalDriver(directory, journal)
        driver.account_id = '1'
        driver.ready.set()
        driver.client = SimpleNamespace(is_connected=Mock(return_value=True), get_messages=AsyncMock(return_value=message), download_media=AsyncMock())
        return driver, event

    async def test_envelope_survives_restart_then_pdf_is_downloaded_to_exact_private_path(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = Journal(directory)
            driver, event = self.fixture(directory, journal)
            await driver.save_message(event, 'received')
            driver.client.download_media.assert_not_called()
            event.get_chat.assert_not_awaited()
            self.assertEqual(journal.events()[0]['attachment_state'], 'pending')
            journal.db.close()
            journal = Journal(directory)
            driver, _ = self.fixture(directory, journal)
            async def download(message, file):
                from telethon.client.downloads import DownloadMethods
                stream = DownloadMethods._get_proper_filename(file, 'document', '.pdf')
                stream.write(b'%PDF-1.4')
                return stream
            driver.client.download_media.side_effect = download
            await driver.process_media()
            media = [e for e in journal.events() if e['event_type'] == 'media'][0]
            key = media['attachments'][0]['key']
            self.assertEqual((Path(directory) / ('attachment-' + key)).read_bytes(), b'%PDF-1.4')
            self.assertEqual(media['attachment_state'], 'ready')
            journal.db.close()

    async def test_transient_media_failure_remains_pending_and_does_not_hide_text(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = Journal(directory)
            driver, event = self.fixture(directory, journal)
            driver.client.download_media.side_effect = OSError('synthetic temporary failure')
            await driver.save_message(event, 'received')
            await driver.process_media()
            self.assertEqual(journal.events()[0]['text'], 'Synthetic PDF')
            row = journal.db.execute('SELECT * FROM media_jobs').fetchone()
            self.assertEqual(row['state'], 'pending')
            self.assertEqual(row['attempts'], 1)
            self.assertGreater(row['next_attempt'], 0)
            journal.db.close()

    async def test_edits_and_deletes_of_own_messages_are_not_discarded_as_echo(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = Journal(directory)
            op = str(uuid.uuid4())
            journal.begin_operation({'operation_id': op, 'external_user_id': '2', 'text': 'Synthetic'})
            journal.finish(op, 'sent', external_message_ids=['10'])
            event = {'external_account_id': '1', 'external_chat_id': '2', 'external_message_id': '10', 'direction': 'outgoing'}
            journal.save_event({**event, 'event_type': 'edited', 'revision': 'new'})
            journal.save_event({**event, 'event_type': 'deleted', 'revision': ''})
            self.assertEqual({e['event_type'] for e in journal.events()}, {'edited', 'deleted'})
            journal.db.close()

    async def test_ambiguous_events_do_not_block_other_chats(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = Journal(directory)
            op = str(uuid.uuid4())
            journal.begin_operation({'operation_id': op, 'external_user_id': '2', 'text': 'Synthetic'})
            journal.finish(op, 'unknown')
            for n in range(220):
                journal.save_event({'external_account_id': '1', 'external_chat_id': '2', 'external_message_id': str(n), 'direction': 'outgoing', 'event_type': 'received'})
            journal.save_event({'external_account_id': '1', 'external_chat_id': '3', 'external_message_id': '999', 'direction': 'incoming', 'event_type': 'received'})
            found = journal.events() + journal.events()
            self.assertTrue(any(e['external_chat_id'] == '3' for e in found))
            journal.db.close()

    async def test_edit_uses_telegram_edit_not_new_send(self):
        with tempfile.TemporaryDirectory() as directory:
            driver, _ = self.fixture(directory, Journal(directory))
            driver.client.get_input_entity = AsyncMock(return_value='synthetic-peer')
            driver.client.edit_message = AsyncMock(return_value=SimpleNamespace(id=10))
            result = await driver.edit({'external_account_id': '1', 'external_user_id': '2', 'target_message_id': '10', 'text': 'Changed'})
            self.assertEqual(result, ['10'])
            driver.client.edit_message.assert_awaited_once_with('synthetic-peer', 10, 'Changed', parse_mode=None)
            driver.journal.db.close()

    async def test_oversize_stream_is_rejected_before_growing_disk(self):
        from tg_gateway.media import BoundedDownload, DownloadTooLarge, MAX_BYTES
        import io
        output = io.BytesIO()
        stream = BoundedDownload(output)
        stream.size = MAX_BYTES
        with self.assertRaises(DownloadTooLarge):
            stream.write(b'x')
        self.assertEqual(output.getvalue(), b'')
