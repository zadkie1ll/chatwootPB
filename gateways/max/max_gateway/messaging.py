import asyncio
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import time
import traceback

from .journal import digest
from . import media, sdk


class Messaging:
    def __init__(self, manager, journal):
        self.manager, self.journal = manager, journal
        self.lock = asyncio.Lock()
        self.last_poll = 0
        self.poll_cursor = 0
        self.error = None
        self.error_type = None
        self.error_code = None
        self.error_trace = []
        self.enabled = os.environ.get('MAX_DELIVERY_ENABLED', 'false') == 'true'
        self.allowed_peers = {int(peer) for peer in os.environ.get('MAX_TEST_PEER_IDS', '').split(',') if peer.strip()}
        self.test_phone = os.environ.get('MAX_TEST_PHONE', '')
        if self.test_phone and self.allowed_peers:
            known = journal.get('pilot_peer/' + digest(self.test_phone))
            if known:
                self.allowed_peers.add(known)
        self.since = journal.get('delivery_since')
        if self.enabled and self.since is None:
            self.since = int(time.time() * 1000)
            journal.put('delivery_since', self.since)

    @property
    def client(self):
        if not self.manager.connected:
            raise RuntimeError('channel_unavailable')
        return self.manager.client

    def allowed(self, peer):
        return self.enabled and (not self.allowed_peers or peer in self.allowed_peers)

    def register(self, client):
        @client.on_message()
        async def incoming(message, _client):
            await self.capture(message)

        @client.on_message_edit()
        async def edited(message, _client):
            await self.capture(message)

        @client.on_message_read()
        async def read(event, _client):
            if not self.enabled or not self.manager.connected or event.set_as_unread:
                return
            peer = client.me.contact.id ^ event.chat_id
            if event.user_id != peer:
                return
            chat = await client.get_chat(event.chat_id)
            if chat.type == 'DIALOG':
                self.record_read(peer, event.mark)

        @client.on_message_delete()
        async def deleted(event, _client):
            if not self.enabled or not self.manager.connected:
                return
            peer = client.me.contact.id ^ event.chat_id
            chat = await client.get_chat(event.chat_id)
            if not chat or chat.type != 'DIALOG' or not self.allowed(peer):
                return
            for mid in event.message_ids:
                self.record_deletion(event.chat_id, mid)

    def record_read(self, peer, mark):
        if not self.allowed(peer) or peer == self.client.me.contact.id or mark <= 0:
            return
        account = self.client.me.contact.id
        chat_id = account ^ peer
        key = 'read_mark/' + str(peer)
        mark = max(mark, self.journal.get(key, 0))
        self.journal.put(key, mark)
        known = {}
        for row in self.journal.db.execute("SELECT id,payload FROM messages WHERE peer=? AND deleted=0", (str(chat_id),)):
            event = json.loads(row['payload'])
            if event.get('direction') == 'outgoing' and event.get('timestamp'):
                known[row['id']] = int(datetime.fromisoformat(event['timestamp']).timestamp() * 1000)
        for row in self.journal.db.execute("SELECT result FROM operations WHERE peer=? AND state='sent'", (str(peer),)):
            result = json.loads(row['result'])
            if result.get('external_message_time') and result.get('external_message_id'):
                known[result['external_message_id']] = result['external_message_time']
        read_ids = sorted(mid for mid, sent_time in known.items() if sent_time <= mark)
        for offset in range(0, len(read_ids), 100):
            batch = read_ids[offset:offset + 100]
            self.journal.emit({'schema_version': 1, 'channel': 'max', 'external_account_id': str(account),
                'external_user_id': str(peer), 'external_chat_id': str(chat_id), 'external_message_id': batch[-1],
                'direction': 'outgoing', 'event_type': 'read', 'revision': digest(batch), 'read_message_ids': batch,
                'text': '', 'attachments': [], 'origin': 'external'})
        self.journal.db.commit()

    def record_deletion(self, chat_id, message_id):
        account = self.client.me.contact.id
        peer = account ^ chat_id
        fallback = None
        if self.journal.own(peer, message_id):
            fallback = {'channel': 'max', 'external_account_id': str(account), 'external_user_id': str(peer),
                        'external_chat_id': str(chat_id), 'external_message_id': str(message_id), 'sender_id': str(account),
                        'direction': 'outgoing', 'event_type': 'deleted', 'text': '', 'origin': 'external',
                        'revision': str(int(time.time() * 1000)).zfill(16)}
        self.journal.delete(str(chat_id), str(message_id), fallback)

    async def resolve(self, phone):
        client = self.client
        user = None
        dialogs = {chat.id for chat in (getattr(client, 'chats', None) or []) if chat.type == 'DIALOG'}
        for peer in self.journal.get('tracked_peers', []):
            if (client.me.contact.id ^ peer) in dialogs and self.journal.get('resolved_phone/' + str(peer)) == phone:
                user = await client.get_user(peer)
                if user:
                    break
        if user is None:
            user = await client.search_by_phone(phone)
        if phone == self.test_phone and self.allowed_peers:
            self.allowed_peers.add(user.id)
            self.journal.put('pilot_peer/' + digest(phone), user.id)
        if user.id == client.me.contact.id or not self.allowed(user.id):
            raise ValueError('recipient_unavailable')
        self.journal.put('resolved_phone/' + str(user.id), phone)
        self.track(user.id)
        return {'external_account_id': str(client.me.contact.id), 'external_user_id': str(user.id), 'name': self.name(user)}

    def track(self, peer):
        tracked = self.journal.get('tracked_peers', [])
        if peer not in tracked:
            self.journal.put('tracked_peers', tracked + [peer])

    @staticmethod
    def name(user):
        if user and user.names:
            item = user.names[0]
            return item.name or ' '.join(filter(None, (item.first_name, item.last_name)))
        return 'MAX'

    @staticmethod
    def message_content(message):
        current = message
        texts = [message.text] if message.text else []
        for _ in range(3):
            link = current.link
            if current.attaches or not link or link.type != 'FORWARD':
                break
            current = link.message
            if current.text and current.text not in texts:
                texts.append(current.text)
        return message.model_copy(update={'attaches': current.attaches, 'text': '\n'.join(texts)})

    async def capture(self, message):
        if not self.enabled or not self.manager.connected or message.chat_id is None:
            return
        client = self.client
        peer = client.me.contact.id ^ message.chat_id
        if not self.allowed(peer) or peer == client.me.contact.id or message.sender not in (peer, client.me.contact.id):
            return
        chat = await client.get_chat(message.chat_id)
        if not chat or chat.type != 'DIALOG':
            return
        if message.status == 'REMOVED':
            self.record_deletion(message.chat_id, message.id)
            return
        self.track(peer)
        if message.time < self.since:
            return
        if message.sender == client.me.contact.id:
            if message.status != 'EDITED' and self.journal.confirm_echo(peer, message.cid, message.id, message.time):
                return
            if self.journal.own(peer, message.id):
                self.journal.remember_sent_time(peer, message.id, message.time)
                # Remote caption/text changes for our own messages still update CW.
                if message.status != 'EDITED':
                    return
        user = await client.get_user(peer)
        phone = '+' + str(user.phone).lstrip('+') if user and user.phone else self.journal.get('resolved_phone/' + str(peer))
        if phone and not re.fullmatch(r'\+[1-9]\d{6,14}', phone):
            phone = None
        content = self.message_content(message)
        attaches = [{
            'type': str(getattr(item.type, 'value', item.type)),
            **{key: getattr(item, key, None) for key in ('photo_id', 'file_id', 'audio_id', 'video_id', 'name', 'size', 'duration')}
        } for item in content.attaches]
        event = {'schema_version': 1, 'channel': 'max', 'external_account_id': str(client.me.contact.id),
                 'external_user_id': str(peer), 'external_chat_id': str(message.chat_id), 'external_message_id': str(message.id),
                 'sender_id': str(message.sender), 'sender_name': self.name(user), 'phone': phone,
                 'event_type': 'edited' if message.status == 'EDITED' else 'received', 'direction': 'outgoing' if message.sender == client.me.contact.id else 'incoming',
                 'origin': 'external', 'text': content.text, 'timestamp': datetime.fromtimestamp(message.time / 1000, timezone.utc).isoformat(),
                 'voice': any(str(getattr(item.type, 'value', item.type)) == 'AUDIO' for item in content.attaches)}
        if attaches:
            event['attachment_state'] = 'pending'
        signature = digest([content.text, attaches])
        self.journal.save_message(event, signature, bool(attaches))

    async def send(self, data, files):
        client = self.client
        peer = int(data['external_user_id'])
        if not self.allowed(peer) or str(client.me.contact.id) != str(data['external_account_id']):
            return {'state': 'failed', 'error_code': 'channel_unavailable'}
        chat_id = client.get_chat_id(client.me.contact.id, peer)
        # Serialize send/edit and echo reconciliation against journal mutations.
        async with self.lock:
            cid, previous = self.journal.begin(data)
            if previous:
                return previous
            operation_id = data['operation_id']
            try:
                if data.get('action', 'send') == 'edit':
                    mid = await sdk.edit(client, chat_id, int(data['target_message_id']), data['text'])
                else:
                    message = await sdk.send(client, chat_id, data, cid, files)
                    mid = message.id
                result = self.journal.finish(operation_id, 'sent', external_message_id=str(mid),
                    **({'external_message_time': message.time} if data.get('action', 'send') != 'edit' else {}))
                self.record_read(peer, self.journal.get('read_mark/' + str(peer), 0))
                return result
            except sdk.UploadBeforeSend:
                return self.journal.finish(operation_id, 'failed', error_code='attachment_upload_failed')
            except asyncio.CancelledError:
                self.journal.finish(operation_id, 'unknown', error_code='send_outcome_unknown')
                raise
            except Exception as error:
                # Only explicitly definitive errors may be classified as failed.
                from pymax.exceptions import ApiError
                rejected = isinstance(error, ValueError) or (isinstance(error, ApiError) and error.error in (
                    'proto.payload', 'chat.denied', 'chat.not.found', 'contact.not.found', 'message.edit.denied', 'message.not.found', 'user.blocked'))
                state = 'failed' if rejected else 'unknown'
                code = getattr(error, 'error', '') or ''
                return self.journal.finish(operation_id, state, error_code='recipient_unavailable' if rejected else 'send_outcome_unknown',
                                           error_type=type(error).__name__, provider_error_code=code if re.fullmatch('[a-z_.]{1,64}', code) else None)

    async def operation(self, operation_id):
        result = self.journal.operation(operation_id)
        if result.get('provider_error_code') == 'proto.payload' and result['state'] == 'unknown':
            return self.journal.finish(operation_id, 'failed', error_code='invalid_external_payload')
        if result['state'] != 'unknown' or not self.manager.connected:
            return result
        row = self.journal.db.execute('SELECT * FROM operations WHERE id=?', (operation_id,)).fetchone()
        data = json.loads(row['payload'])
        client = self.client
        chat_id = client.get_chat_id(client.me.contact.id, int(row['peer']))
        try:
            if data.get('action') == 'edit':
                message = await client.get_message(chat_id, int(data['target_message_id']))
                if message and message.sender == client.me.contact.id and message.text == data['text']:
                    return self.journal.finish(operation_id, 'sent', external_message_id=str(message.id))
            else:
                for message in await client.fetch_history(chat_id, backward=100):
                    if message.sender == client.me.contact.id and message.cid == row['cid']:
                        return self.journal.finish(operation_id, 'sent', external_message_id=str(message.id))
        except Exception:
            pass
        return result

    async def process_media(self):
        row = self.journal.media_job()
        if not row:
            return
        event = json.loads(row['payload'])
        try:
            client = self.client
            message = await client.get_message(int(event['external_chat_id']), int(event['external_message_id']))
            if not message or message.status == 'REMOVED':
                self.journal.delete(event['external_chat_id'], event['external_message_id'])
                self.journal.media_result(row, error='attachment_unavailable')
                return
            # A later edit's media job supersedes this one.
            current = self.journal.db.execute('SELECT revision,deleted FROM messages WHERE peer=? AND id=?', (event['external_chat_id'], event['external_message_id'])).fetchone()
            if not current or current['deleted'] or str(current['revision']).zfill(16) != event['revision']:
                self.journal.db.execute('DELETE FROM media WHERE id=?', (row['id'],))
                self.journal.db.commit()
                return
            attachments = await media.receive(client, self.message_content(message), self.manager.directory)
            self.journal.media_result(row, attachments=attachments)
        except media.UnsupportedMedia:
            self.journal.media_result(row, error='unsupported_attachment')
        except Exception:
            self.journal.retry_media(row)

    async def catch_up(self):
        if time.time() - self.last_poll < 10:
            return False
        self.last_poll = time.time()
        client = self.client
        peers = set(self.journal.get('tracked_peers', []))
        peers.update(client.me.contact.id ^ chat.id for chat in client.chats or [] if chat.type == 'DIALOG')
        peers = sorted(peer for peer in peers if self.allowed(peer))
        if not peers:
            return True
        peer = peers[self.poll_cursor % len(peers)]
        chat_id = client.get_chat_id(client.me.contact.id, peer)
        self.poll_cursor += 1
        cursor_key = 'history/' + str(chat_id)
        cursor = self.journal.get(cursor_key, self.since)
        # Overlap catches recent edits and duplicates are suppressed by signature.
        messages = await client.fetch_history(chat_id, forward=100, backward=0, from_time=max(self.since, cursor - 1000))
        newest = cursor
        for message in sorted(messages, key=lambda item: (item.time, item.id)):
            message.chat_id = chat_id
            await self.capture(message)
            newest = max(newest, message.time)
        self.journal.put(cursor_key, newest)
        # Scan recent messages for edits made in other clients while offline.
        for message in await client.fetch_history(chat_id, backward=30):
            message.chat_id = chat_id
            await self.capture(message)

        mark = max(await sdk.read_mark(client, chat_id, peer), self.journal.get('read_mark/' + str(peer), 0))
        self.record_read(peer, mark)
        return True

    async def diagnostics(self):
        peers = [peer for peer in self.journal.get('tracked_peers', []) if self.allowed(peer)]
        if not self.allowed_peers or not peers:
            return {'pilot': False}
        client = self.client
        chat_id = client.get_chat_id(client.me.contact.id, peers[0])
        result = {'pilot': True, 'sync_error_type': self.error_type, 'sync_api_code': self.error_code, 'sync_error_trace': self.error_trace}
        for mode in ['chat', 'backward', 'forward']:
            try:
                if mode == 'chat':
                    chat = await client.get_chat(chat_id)
                    result[mode] = {'type': str(getattr(chat.type, 'value', chat.type))}
                else:
                    messages = await client.fetch_history(chat_id, **({'backward': 30} if mode == 'backward' else {'forward': 30, 'backward': 0, 'from_time': self.since}))
                    result[mode] = [{'sender_is_peer': message.sender == peers[0], 'sender_is_self': message.sender == client.me.contact.id,
                                     'age_seconds': round(time.time() - message.time / 1000), 'after_activation': message.time >= self.since,
                                     'attachments': [str(getattr(item.type, 'value', item.type)) for item in message.attaches]} for message in messages]
            except Exception as error:
                code = getattr(error, 'error', '') or ''
                result[mode] = {'error_type': type(error).__name__, 'api_code': code if re.fullmatch('[a-z_.]{1,64}', code) else None}
        return result

    async def tick(self):
        if not self.enabled or not self.manager.connected:
            return
        try:
            polled = await self.catch_up()
            await self.process_media()
            if polled:
                self.error, self.error_type, self.error_code = None, None, None
        except Exception as error:
            self.error = 'sync_unavailable'
            self.error_type = type(error).__name__
            self.error_trace = [{'file': Path(frame.filename).name, 'line': frame.lineno, 'function': frame.name}
                                for frame in traceback.extract_tb(error.__traceback__)[-5:]]
            code = getattr(error, 'error', '') or ''
            self.error_code = code if re.fullmatch('[a-z_.]{1,64}', code) else None
