import asyncio
import io
import json
import os
import time
import uuid
from types import SimpleNamespace
from pathlib import Path
from telethon import TelegramClient, events, functions, types, errors

MAX_BYTES = 20 * 1024 * 1024


class PersonalDriver:
    def __init__(self, directory, journal):
        self.directory = Path(directory)
        self.journal = journal
        self.client = None
        self.account_id = None
        self.resolve_lock = asyncio.Lock()
        self.last_resolve = 0.0
        self.ready = asyncio.Event()
        self.auth_lock = asyncio.Lock()
        self.phone = None
        self.phone_code_hash = None
        self.last_code_request = 0.0

    def build_client(self, api_id, api_hash):
        client = TelegramClient(str(self.directory / 'personal'), api_id, api_hash, catch_up=True,
                                flood_sleep_threshold=0, sequential_updates=True)
        client.add_event_handler(self.on_new, events.NewMessage())
        client.add_event_handler(self.on_edit, events.MessageEdited())
        client.add_event_handler(self.on_delete, events.MessageDeleted())
        client.add_event_handler(self.on_random, events.Raw(types=types.UpdateMessageID))
        return client

    async def activate(self):
        self.account_id = str((await self.client.get_me()).id)
        self.phone_code_hash = None
        self.ready.set()
        await self.client.catch_up()

    async def auth_start(self, api_id, api_hash, phone):
        async with self.auth_lock:
            if self.account_id:
                raise ValueError('already_connected')
            if time.monotonic() - self.last_code_request < 60:
                return {'status': 'wait', 'retry_after': 60}
            if self.client:
                await self.client.disconnect()
            self.client = self.build_client(api_id, api_hash)
            await self.client.connect()
            if await self.client.is_user_authorized():
                await self.activate()
                return {'status': 'connected'}
            self.last_code_request = time.monotonic()
            result = await self.client.send_code_request(phone)
            self.phone, self.phone_code_hash = phone, result.phone_code_hash
            config_path = self.directory / 'config.json'
            with os.fdopen(os.open(config_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w') as output:
                json.dump({'api_id': api_id, 'api_hash': api_hash}, output)
            return {'status': 'code_required'}

    async def auth_verify(self, code=None, password=None):
        async with self.auth_lock:
            if self.account_id:
                return {'status': 'connected'}
            if not self.client or not self.phone_code_hash:
                raise ValueError('start_required')
            try:
                if password is not None:
                    await self.client.sign_in(password=password)
                else:
                    await self.client.sign_in(phone=self.phone, code=code, phone_code_hash=self.phone_code_hash)
            except errors.SessionPasswordNeededError:
                return {'status': 'password_required'}
            await self.activate()
            return {'status': 'connected'}

    async def connect(self):
        config_path = self.directory / 'config.json'
        if not config_path.exists():
            return False
        config = json.loads(config_path.read_text())
        self.client = self.build_client(config['api_id'], config['api_hash'])
        await self.client.connect()
        if not await self.client.is_user_authorized():
            await self.client.disconnect()
            return False
        await self.activate()
        return True

    async def resolve(self, phone):
        if not self.account_id:
            raise ValueError('not_connected')
        async with self.resolve_lock:
            await asyncio.sleep(max(0, 3 - (time.monotonic() - self.last_resolve)))
            self.last_resolve = time.monotonic()
            result = await self.client(functions.contacts.ResolvePhoneRequest(phone=phone))
            user = next((user for user in result.users if user.id == result.peer.user_id), None)
            if user is None:
                raise ValueError('recipient_unavailable')
            return {'external_account_id': self.account_id, 'external_user_id': str(user.id),
                    'name': ' '.join(filter(None, [user.first_name, user.last_name]))[:128]}

    async def send(self, data, random_id, files):
        if not self.account_id or data['external_account_id'] != self.account_id:
            raise ValueError('wrong_external_account')
        peer = await self.client.get_input_entity(int(data['external_user_id']))
        reply_to = int(data['reply_to']) if data.get('reply_to') else None
        if files:
            uploaded = []
            for metadata, content in files:
                stream = io.BytesIO(content)
                stream.name = metadata['filename']
                uploaded.append(stream)
            voice = len(files) == 1 and bool(files[0][0].get('voice'))
            messages = await self.client.send_file(peer, uploaded[0] if voice else uploaded, caption=data.get('text') or '',
                                                   voice_note=voice, reply_to=reply_to)
            messages = messages if isinstance(messages, list) else [messages]
            return [str(message.id) for message in messages]
        reply = types.InputReplyToMessage(reply_to_msg_id=reply_to) if reply_to else None
        result = await self.client(functions.messages.SendMessageRequest(peer=peer, message=data.get('text') or '', random_id=random_id, reply_to=reply))
        if isinstance(result, types.UpdateShortSentMessage):
            return [str(result.id)]
        for update in getattr(result, 'updates', []):
            if isinstance(update, types.UpdateMessageID) and update.random_id == random_id:
                return [str(update.id)]
        raise RuntimeError('send_outcome_unknown')

    async def on_random(self, update):
        self.journal.map_random_id(update.random_id, update.id)

    async def on_new(self, event):
        await self.save_message(event, 'received')

    async def on_edit(self, event):
        await self.save_message(event, 'edited')

    @property
    def connected(self):
        return bool(self.account_id and self.client and self.client.is_connected())

    async def save_message(self, event, event_type):
        await self.ready.wait()
        if not event.is_private or event.chat_id is None or event.chat_id <= 0 or event.chat_id == 777000:
            return
        message = event.message
        # Never await entity/network lookup before the durable commit.
        peer = getattr(event, 'chat', None) or getattr(event, '_entities', {}).get(event.chat_id)
        if peer is None:
            peer = SimpleNamespace(id=event.chat_id, first_name='', last_name='', phone=None, bot=False)
        if getattr(peer, 'bot', False):
            return
        raw_phone = (getattr(peer, 'phone', None) or '').lstrip('+')
        phone = '+' + raw_phone if raw_phone.isdigit() and 7 <= len(raw_phone) <= 15 and not raw_phone.startswith('0') else None
        ephemeral = getattr(message, 'ttl_period', None) or getattr(message.media, 'ttl_seconds', None)
        media = message.photo or message.document
        media_id = str(getattr(media, 'id', ''))
        base = {'schema_version': 1, 'channel': 'telegram', 'external_account_id': self.account_id,
                'external_chat_id': str(event.chat_id), 'external_user_id': str(event.chat_id),
                'external_message_id': str(message.id), 'sender_id': str(message.sender_id),
                'sender_name': ' '.join(filter(None, [getattr(peer, 'first_name', ''), getattr(peer, 'last_name', '')]))[:128],
                'direction': 'outgoing' if message.out else 'incoming', 'origin': 'official_client' if message.out else 'external',
                'event_type': event_type, 'revision': self.revision(event),
                'timestamp': message.date.isoformat(), 'text': '' if ephemeral else self.visible_text(message),
                'attachments': [], 'voice': bool(message.voice), 'phone': phone, 'media_id': media_id}
        if ephemeral:
            base['attachment_error'] = 'ephemeral_unsupported'
            base['attachment_state'] = 'failed'
        elif media and getattr(message.file, 'size', 0) and message.file.size > MAX_BYTES:
            base['attachment_error'] = 'attachment_too_large'
            base['attachment_state'] = 'failed'
        elif media:
            base['attachment_state'] = 'pending'
        elif message.media and not base['text']:
            base.update(attachment_state='failed', attachment_error='unsupported_type')
        self.journal.save_event(base, media=base.get('attachment_state') == 'pending')

    def visible_text(self, message):
        text = message.message or ''
        media = message.media
        if isinstance(media, types.MessageMediaContact):
            details = ' '.join(filter(None, [media.first_name, media.last_name, media.phone_number]))
            return '\n'.join(filter(None, [text, details]))
        if isinstance(media, (types.MessageMediaGeo, types.MessageMediaGeoLive)) and isinstance(media.geo, types.GeoPoint):
            return '\n'.join(filter(None, [text, f'https://maps.google.com/?q={media.geo.lat},{media.geo.long}']))
        if isinstance(media, types.MessageMediaDice):
            return '\n'.join(filter(None, [text, f'{media.emoticon} {media.value}']))
        if isinstance(media, types.MessageMediaPoll):
            question = getattr(media.poll.question, 'text', media.poll.question)
            answers = [str(getattr(answer.text, 'text', answer.text)) for answer in media.poll.answers]
            return '\n'.join(filter(None, [text, str(question), *answers]))
        return text

    def revision(self, event):
        if not event.message.edit_date:
            return ''
        pts = getattr(getattr(event, 'original_update', None), 'pts', 0)
        return event.message.edit_date.isoformat() + '@' + str(pts).zfill(20)

    async def process_media(self):
        row = self.journal.pending_media()
        if row is None or not self.connected or self.journal.retry_after():
            return
        base = json.loads(row['payload'])
        key = uuid.uuid4().hex
        target = self.directory / ('attachment-' + key)
        partial = target.with_suffix('.partial')
        try:
            message = await self.client.get_messages(int(base['external_user_id']), ids=int(base['external_message_id']))
            if not message or not message.media:
                self.finish_media(row, base, 'media_unavailable')
                return
            with partial.open('wb') as output:
                await asyncio.wait_for(self.client.download_media(message, file=BoundedDownload(output)), timeout=90)
            if not partial.stat().st_size:
                raise OSError('empty_download')
            os.replace(partial, target)
            filename = getattr(message.file, 'name', None) or ('photo.jpg' if message.photo else 'attachment.bin')
            metadata = {'key': key, 'filename': Path(filename).name[:150],
                        'content_type': getattr(message.file, 'mime_type', None) or 'application/octet-stream',
                        'size': target.stat().st_size}
            self.finish_media(row, base, attachments=[metadata])
        except DownloadTooLarge:
            self.finish_media(row, base, 'attachment_too_large')
        except errors.FloodWaitError as error:
            self.journal.pause(error.seconds)
            self.journal.media_retry(row, error.seconds)
        except (errors.MessageIdInvalidError, errors.ChannelPrivateError):
            self.finish_media(row, base, 'media_unavailable')
        except (errors.RPCError, OSError, asyncio.TimeoutError):
            self.journal.media_retry(row)
        finally:
            partial.unlink(missing_ok=True)

    def finish_media(self, row, base, error=None, attachments=None):
        saved = self.journal.save_event({**base, 'event_type': 'media', 'source_revision': base['revision'],
                                 'revision': base['revision'] + '/media', 'attachments': attachments or [],
                                 'attachment_state': 'failed' if error else 'ready', 'attachment_error': error})
        if not saved:
            for item in attachments or []:
                (self.directory / ('attachment-' + item['key'])).unlink(missing_ok=True)
        self.journal.media_finished(row['job_key'])

    async def edit(self, data):
        if not self.account_id or data['external_account_id'] != self.account_id:
            raise ValueError('wrong_external_account')
        peer = await self.client.get_input_entity(int(data['external_user_id']))
        try:
            await self.client.edit_message(peer, int(data['target_message_id']), data['text'], parse_mode=None)
        except errors.MessageNotModifiedError:
            pass
        return [str(data['target_message_id'])]

    async def on_delete(self, event):
        for message_id in event.deleted_ids:
            for prior in self.journal.deleted_events(message_id):
                self.journal.save_event({**prior, 'text': '', 'attachments': [], 'event_type': 'deleted', 'revision': ''})


class DownloadTooLarge(Exception):
    pass


class BoundedDownload:
    def __init__(self, output):
        self.output = output
        self.size = 0

    def write(self, data):
        if self.size + len(data) > MAX_BYTES:
            raise DownloadTooLarge()
        self.size += len(data)
        return self.output.write(data)
