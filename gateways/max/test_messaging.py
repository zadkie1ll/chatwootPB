import asyncio
import json
import os
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace as NS
import unittest
from unittest.mock import AsyncMock, patch
import uuid

from max_gateway.journal import Journal
from max_gateway.messaging import Messaging
from max_gateway import sdk, media
from pymax.types.domain import Message


def message(**values):
    return Message(id=values.pop('id', 101), chat_id=values.pop('chat_id', 30), sender=values.pop('sender', 20),
                   text=values.pop('text', 'Synthetic'), time=values.pop('time', 9999999999999), type='USER', **values)


class DeliveryTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = TemporaryDirectory()
        self.journal = Journal(self.temp.name)
        self.client = NS(me=NS(contact=NS(id=10)), get_chat=AsyncMock(return_value=NS(type='DIALOG')),
                         get_user=AsyncMock(return_value=NS(names=[], phone=None)),
                         get_chat_id=lambda first, second: first ^ second,
                         fetch_history=AsyncMock(return_value=[]), get_message=AsyncMock())
        self.client._app = NS(invoke=AsyncMock(return_value=NS(payload={'chats': []})))
        self.manager = NS(client=self.client, connected=True, directory=Path(self.temp.name))
        with patch.dict(os.environ, {'MAX_DELIVERY_ENABLED': 'true', 'MAX_TEST_PEER_IDS': '20'}):
            self.driver = Messaging(self.manager, self.journal)
        self.operation = {'channel': 'max', 'operation_id': str(uuid.uuid4()), 'external_account_id': '10',
                          'external_user_id': '20', 'action': 'send', 'text': 'Literal ** text', 'attachments': []}

    async def asyncTearDown(self):
        self.journal.db.close()
        self.temp.cleanup()

    async def test_read_receipt_ignores_own_reads_and_respects_confirmed_time(self):
        await self.driver.capture(message(sender=10, id=101, time=9999999999999))
        await self.driver.capture(message(sender=10, id=102, time=9999999999999 + 1000))
        self.driver.record_read(10, 9999999999999 + 10000)
        self.assertFalse(any(e['event_type'] == 'read' for e in self.journal.events()))
        self.driver.record_read(20, 9999999999999)
        receipts = [e for e in self.journal.events() if e['event_type'] == 'read']
        self.assertEqual([e['external_message_id'] for e in receipts], ['101'])
        self.driver.record_read(20, 9999999999999 - 1000)
        self.assertEqual(self.journal.get('read_mark/20'), 9999999999999)

    async def test_read_poll_fetches_fresh_peer_mark_instead_of_cached_chat(self):
        from pymax.protocol import Opcode
        self.client._app.invoke.return_value = NS(payload={'chats': [
            {'id': 30, 'type': 'DIALOG', 'status': 'ACTIVE', 'owner': 10, 'participants': {'10': 9999, '20': 2000}}
        ]})
        self.assertEqual(await sdk.read_mark(self.client, 30, 20), 2000)
        self.client._app.invoke.assert_awaited_once_with(Opcode.CHAT_INFO, {'chatIds': [30]})
        self.client.get_chat.assert_not_awaited()

    async def test_own_echo_keeps_the_timestamp_needed_for_read_receipts(self):
        cid, _ = self.journal.begin(self.operation)
        self.journal.finish(self.operation['operation_id'], 'sent', external_message_id='101', external_message_time=9999999999999)
        await self.driver.capture(message(sender=10, id=101, cid=cid, time=9999999999999))
        self.assertEqual(self.journal.operation(self.operation['operation_id'])['external_message_time'], 9999999999999)
        self.driver.record_read(20, 9999999999999)
        receipts = [e for e in self.journal.events() if e['event_type'] == 'read']
        self.assertEqual(receipts[0]['read_message_ids'], ['101'])

    async def test_known_dialog_phone_does_not_require_a_new_global_lookup(self):
        self.client.chats = [NS(id=30, type='DIALOG')]
        self.client.get_user.return_value = NS(id=20, names=[], phone=None)
        self.client.search_by_phone = AsyncMock(side_effect=RuntimeError('private phone lookup'))
        self.driver.track(20)
        self.journal.put('resolved_phone/20', '+79990000000')
        result = await self.driver.resolve('+79990000000')
        self.assertEqual(result['external_user_id'], '20')
        self.client.search_by_phone.assert_not_awaited()

    async def test_receive_is_durable_and_replay_is_suppressed(self):
        await self.driver.capture(message())
        await self.driver.capture(message())
        events = self.journal.events()
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]['external_user_id'], '20')
        self.assertEqual(events[0]['external_chat_id'], '30')
        self.assertEqual(events[0]['channel'], 'max')
        self.journal.db.close()
        self.journal = Journal(self.temp.name)
        self.assertEqual(self.journal.events(), events)
        self.journal.ack(events[0]['journal_id'])
        self.assertEqual(self.journal.events(), [])

    async def test_pilot_does_not_capture_other_people_or_groups(self):
        await self.driver.capture(message(chat_id=23, sender=29))
        self.client.get_chat.return_value = NS(type='CHAT')
        await self.driver.capture(message())
        self.assertEqual(self.journal.events(), [])

    async def test_text_is_saved_before_media_download_and_retry_is_durable(self):
        attached = {'_type': 'AUDIO', 'url': 'https://i.oneme.ru/audio', 'duration': 5}
        await self.driver.capture(message(attaches=[attached]))
        self.assertEqual(self.journal.events()[0]['text'], 'Synthetic')
        self.assertEqual(self.journal.events()[0]['attachment_state'], 'pending')
        self.client.get_message.return_value = message(attaches=[attached])
        with patch('max_gateway.media.receive', side_effect=OSError()):
            await self.driver.process_media()
        self.assertEqual(self.journal.metrics()['media_pending'], 1)
        self.assertEqual(self.journal.db.execute('SELECT attempts FROM media').fetchone()[0], 1)

    async def test_edit_keeps_identity_and_has_new_revision(self):
        await self.driver.capture(message())
        await self.driver.capture(message(text='Changed', status='EDITED'))
        first, edited = self.journal.events()
        self.assertEqual(edited['event_type'], 'edited')
        self.assertGreater(edited['revision'], first['revision'])
        self.assertEqual(edited['external_message_id'], first['external_message_id'])

    async def test_delete_tombstone_prevents_history_resurrection(self):
        self.journal.delete('30', '101')
        await self.driver.capture(message())
        self.assertEqual(self.journal.events(), [])

    async def test_send_is_idempotent_and_literal(self):
        with patch('max_gateway.sdk.send', new=AsyncMock(return_value=message(id=501))) as sender:
            result = await self.driver.send(self.operation, [])
            replay = await self.driver.send(self.operation, [])
        self.assertEqual(result, replay)
        self.assertEqual(result['external_message_id'], '501')
        sender.assert_awaited_once()
        self.assertEqual(sender.call_args.args[2]['text'], 'Literal ** text')
        with self.assertRaises(ValueError):
            await self.driver.send({**self.operation, 'text': 'Different'}, [])

    async def test_unknown_never_sends_again_and_echo_confirms_it(self):
        with patch('max_gateway.sdk.send', new=AsyncMock(side_effect=asyncio.TimeoutError())) as sender:
            result = await self.driver.send(self.operation, [])
            replay = await self.driver.send(self.operation, [])
        self.assertEqual(result['state'], 'unknown')
        self.assertEqual(replay['state'], 'unknown')
        sender.assert_awaited_once()
        row = self.journal.db.execute('SELECT cid FROM operations').fetchone()
        await self.driver.capture(message(sender=10, cid=row['cid']))
        self.assertEqual(self.journal.operation(self.operation['operation_id'])['state'], 'sent')
        self.assertEqual(self.journal.events(), [])

    async def test_restart_fences_an_unfinished_send(self):
        self.journal.begin(self.operation)
        self.journal.db.close()
        self.journal = Journal(self.temp.name)
        self.assertEqual(self.journal.operation(self.operation['operation_id'])['state'], 'unknown')

    async def test_uncertain_send_reconciles_by_own_cid(self):
        cid, _ = self.journal.begin(self.operation)
        self.journal.finish(self.operation['operation_id'], 'unknown')
        self.client.fetch_history.return_value = [message(sender=10, cid=cid)]
        result = await self.driver.operation(self.operation['operation_id'])
        self.assertEqual(result['state'], 'sent')
        self.assertEqual(result['external_message_id'], '101')

    async def test_new_resolve_respects_private_phone_and_pilot_allowlist(self):
        self.client.search_by_phone = AsyncMock(return_value=NS(id=21, names=[]))
        with self.assertRaises(ValueError):
            await self.driver.resolve('+79990000000')
        self.driver.test_phone = '+79990000000'
        result = await self.driver.resolve('+79990000000')
        self.assertEqual(result['external_user_id'], '21')

    async def test_unsupported_media_finishes_with_visible_error(self):
        await self.driver.capture(message(attaches=[{'_type': 'AUDIO', 'url': 'https://i.oneme.ru/audio'}]))
        self.client.get_message.return_value = message()
        with patch('max_gateway.media.receive', side_effect=media.UnsupportedMedia()):
            await self.driver.process_media()
        self.assertEqual(self.journal.metrics()['media_pending'], 0)
        self.assertEqual(self.journal.events()[-1]['attachment_error'], 'unsupported_attachment')

    async def test_media_update_cannot_replace_a_newer_edit(self):
        await self.driver.capture(message(attaches=[{'_type': 'AUDIO', 'url': 'https://i.oneme.ru/audio'}]))
        await self.driver.capture(message(text='New caption', status='EDITED'))
        self.client.get_message.return_value = message()
        with patch('max_gateway.media.receive', new=AsyncMock()) as receiver:
            await self.driver.process_media()
        receiver.assert_not_awaited()
        self.assertEqual(self.journal.metrics()['media_pending'], 0)

    async def test_sdk_payload_keeps_cid_plaintext_and_reply(self):
        from pymax.protocol import InboundFrame
        app = NS(api=NS(uploads=NS()), invoke=AsyncMock(return_value=InboundFrame(ver=11, cmd=1, seq=1, opcode=64,
                 payload={'id': 900, 'sender': 10, 'time': 123, 'type': 'USER', 'text': '**literal**'})))
        client = NS(_app=app)
        await sdk.send(client, 30, {'text': '**literal**', 'reply_to': '12'}, 123456, [])
        frame = app.invoke.call_args.args[1]
        self.assertEqual(frame['message']['cid'], 123456)
        self.assertEqual(frame['message']['text'], '**literal**')
        self.assertEqual(frame['message']['elements'], [])
        self.assertEqual(frame['message']['link']['messageId'], 12)

    async def test_caption_edit_preserves_attachments(self):
        original = message(sender=10, attaches=[{'_type': 'AUDIO', 'url': 'https://i.oneme.ru/a'}])
        self.client.get_message.return_value = original
        self.client._app = NS(invoke=AsyncMock())
        await sdk.edit(self.client, 30, 101, 'Changed caption')
        payload = self.client._app.invoke.call_args.args[1]
        self.assertEqual(payload['attachments'][0]['_type'], 'AUDIO')
        self.assertEqual(payload['text'], 'Changed caption')

    async def test_real_sdk_dispatcher_delivers_event_and_client_to_registered_handlers(self):
        from pymax.dispatch.dispatcher import Dispatcher
        from pymax.dispatch.router import Router
        from pymax.dispatch.enums import EventType
        router = Router()
        self.client.on_message = router.on_message
        self.client.on_message_edit = router.on_message_edit
        self.client.on_message_delete = router.on_message_delete
        self.client.on_message_read = router.on_message_read
        self.driver.register(self.client)
        dispatcher = Dispatcher(NS(), router)
        dispatcher.bind_client(self.client)
        for entry in router.handlers[EventType.MESSAGE_NEW]:
            await dispatcher._call(entry.callback, message())
        self.assertEqual(len(self.journal.events()), 1)

    async def test_catchup_uses_the_real_public_sdk_history_signature(self):
        from unittest.mock import create_autospec
        from pymax.infra.message import MessageMixin
        public = create_autospec(MessageMixin, instance=True)
        public.fetch_history.return_value = [message()]
        self.client.fetch_history = public.fetch_history
        self.client.chats = []
        self.driver.track(20)
        self.assertTrue(await self.driver.catch_up())
        self.assertEqual(len(self.journal.events()), 1)
        self.assertIn('from_time', public.fetch_history.call_args_list[0].kwargs)

    async def test_photo_binary_preview_does_not_block_durable_text(self):
        photo = {'_type': 'PHOTO', 'photoId': 7, 'photoToken': 'synthetic', 'baseUrl': 'https://i.oneme.ru/photo',
                 'height': 64, 'width': 64, 'previewData': b'\xff\x00'}
        await self.driver.capture(message(attaches=[photo]))
        self.assertEqual(self.journal.events()[0]['text'], 'Synthetic')
        self.assertEqual(self.journal.metrics()['media_pending'], 1)

    async def test_voice_processing_wait_reuses_the_same_cid(self):
        from pymax.api.uploads.payloads import VoiceAttachPayload
        from pymax.exceptions import ApiError
        from pymax.protocol import InboundFrame
        voice = VoiceAttachPayload(video_id=3, token='synthetic')
        uploads = NS(upload_voice=AsyncMock(return_value=voice))
        messages = NS(_process_attachment_error=AsyncMock())
        result = InboundFrame(ver=11, cmd=1, seq=1, opcode=64,
                              payload={'id': 901, 'sender': 10, 'time': 123, 'type': 'USER'})
        app = NS(api=NS(uploads=uploads, messages=messages), invoke=AsyncMock(side_effect=[ApiError(opcode=64, error='attachment.not.ready'), result]))
        with patch('max_gateway.sdk.opus_duration', return_value=500):
            await sdk.send(NS(_app=app), 30, {'text': ''}, 123456,
                           [({'voice': True, 'filename': 'voice.ogg', 'content_type': 'audio/ogg'}, b'synthetic')])
        messages._process_attachment_error.assert_awaited_once()
        self.assertEqual(app.invoke.call_count, 2)
        self.assertEqual(app.invoke.call_args_list[0].args[1], app.invoke.call_args_list[1].args[1])

    async def test_forwarded_voice_keeps_outer_sender_and_download_scope(self):
        original = message(id=11, sender=10, text='Original voice', attaches=[{'_type': 'AUDIO', 'url': 'https://i.oneme.ru/audio'}])
        forwarded = message(text='', link={'type': 'FORWARD', 'chatId': 999, 'message': original})
        await self.driver.capture(forwarded)
        event = self.journal.events()[0]
        self.assertEqual(event['external_message_id'], '101')
        self.assertEqual(event['external_chat_id'], '30')
        self.assertEqual(event['sender_id'], '20')
        self.assertTrue(event['voice'])
        self.assertEqual(event['text'], 'Original voice')
        self.client.get_message.return_value = forwarded
        with patch('max_gateway.media.receive', new=AsyncMock(return_value=[])) as receiver:
            await self.driver.process_media()
        delivered = receiver.call_args.args[1]
        self.assertEqual(delivered.chat_id, 30)
        self.assertEqual(delivered.id, 101)
        self.assertEqual(delivered.attaches[0].type, 'AUDIO')

    async def test_early_outgoing_echo_waits_for_send_result_and_never_duplicates(self):
        async def send_with_early_echo(*_args):
            await self.driver.capture(message(id=501, sender=10, cid=None))
            self.assertEqual(self.journal.events(), [])
            return message(id=501, sender=10)
        with patch('max_gateway.sdk.send', new=send_with_early_echo):
            await self.driver.send(self.operation, [])
        self.assertEqual(self.journal.events(), [])

    async def test_external_delete_of_our_sent_message_is_forwarded(self):
        with patch('max_gateway.sdk.send', new=AsyncMock(return_value=message(id=501, sender=10))):
            await self.driver.send(self.operation, [])
        self.driver.record_deletion(30, 501)
        event = self.journal.events()[0]
        self.assertEqual(event['external_message_id'], '501')
        self.assertEqual(event['event_type'], 'deleted')

    def test_download_rejects_arbitrary_hosts_and_cleartext(self):
        for url in ['http://i.oneme.ru/a', 'https://127.0.0.1/a', 'https://example.com/a', 'https://i.oneme.ru@evil.test/a']:
            with self.assertRaises(media.UnsupportedMedia):
                media.valid_url(url)
        self.assertEqual(media.valid_url('https://i.oneme.ru/a'), 'https://i.oneme.ru/a')


if __name__ == '__main__':
    unittest.main()
