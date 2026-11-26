import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace as NS
from unittest.mock import AsyncMock
from telethon import types
from tg_gateway.media import custom_emojis, receive


class MediaTests(unittest.IsolatedAsyncioTestCase):
    async def test_custom_emoji_offsets_keep_utf16_units(self):
        message = NS(entities=[types.MessageEntityCustomEmoji(offset=2, length=2, document_id=123)])
        self.assertEqual(custom_emojis(message), [{'offset': 2, 'length': 2, 'document_id': '123'}])

    async def test_tgs_emoji_downloads_preview_not_executable_animation(self):
        doc = types.Document(id=123, access_hash=1, file_reference=b'', date=datetime.now(timezone.utc),
            mime_type='application/x-tgsticker', size=99, dc_id=1, attributes=[])
        client = AsyncMock(return_value=[doc])
        async def download(asset, file, **options):
            self.assertEqual(options, {'thumb': -1})
            file.write(b'synthetic-preview')
        client.download_media.side_effect = download
        message = NS(photo=None, document=None, entities=[types.MessageEntityCustomEmoji(offset=0, length=2, document_id=123)])
        with tempfile.TemporaryDirectory() as directory:
            result = await receive(client, message, directory)
            self.assertEqual(result[0]['emoji_document_id'], '123')
            self.assertEqual(result[0]['content_type'], 'image/jpeg')
            self.assertEqual((Path(directory) / ('attachment-' + result[0]['key'])).read_bytes(), b'synthetic-preview')

    async def test_failed_download_does_not_leave_partial_files(self):
        message = NS(photo=object(), document=None, entities=[], file=NS(mime_type='image/jpeg', name=None))
        client = NS(download_media=AsyncMock(side_effect=OSError('synthetic')))
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(OSError):
                await receive(client, message, directory)
            self.assertEqual(list(Path(directory).iterdir()), [])


class ReadReceiptTests(unittest.IsolatedAsyncioTestCase):
    async def test_poll_uses_the_peer_outbox_watermark(self):
        from tg_gateway.driver import PersonalDriver
        from tg_gateway.journal import Journal
        with tempfile.TemporaryDirectory() as directory:
            journal = Journal(directory)
            driver = PersonalDriver(directory, journal)
            driver.account_id = '10'
            journal.db.execute('INSERT INTO sent_messages VALUES(?,?)', ('20', '101'))
            journal.db.commit()
            client = AsyncMock(return_value=NS(dialogs=[NS(peer=types.PeerUser(20), read_outbox_max_id=101)]))
            client.is_connected = lambda: True
            client.get_input_entity.return_value = types.InputPeerUser(20, 42)
            driver.client = client
            await driver.poll_reads()
            receipts = journal.events()
            self.assertEqual(len(receipts), 1)
            self.assertEqual(receipts[0]['event_type'], 'read')
            self.assertEqual(receipts[0]['external_message_id'], '101')
            self.assertEqual(journal.db.execute('SELECT count(*) FROM message_index').fetchone()[0], 0)
            journal.db.close()

    async def test_own_read_actions_do_not_mark_outgoing_messages_read(self):
        from tg_gateway.driver import PersonalDriver
        from tg_gateway.journal import Journal
        with tempfile.TemporaryDirectory() as directory:
            journal = Journal(directory)
            driver = PersonalDriver(directory, journal)
            driver.account_id = '10'
            driver.ready.set()
            await driver.on_read(NS(outbox=False, contents=False, chat_id=20, max_id=101))
            self.assertEqual(journal.events(), [])
            journal.db.close()


class UsernameLookupTests(unittest.IsolatedAsyncioTestCase):
    async def test_resolves_a_user_without_fabricating_a_phone(self):
        from tg_gateway.driver import PersonalDriver
        from tg_gateway.journal import Journal
        with tempfile.TemporaryDirectory() as directory:
            journal = Journal(directory)
            driver = PersonalDriver(directory, journal)
            driver.account_id = '10'
            driver.client = NS(get_entity=AsyncMock(return_value=types.User(id=20, first_name='Synthetic', bot=True)))
            result = await driver.resolve('@sample_bot')
            self.assertEqual(result['external_user_id'], '20')
            self.assertIsNone(result['phone'])
            self.assertTrue(result['is_bot'])
            journal.db.close()
