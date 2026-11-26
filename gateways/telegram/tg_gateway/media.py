"""Bounded Telegram sticker/custom-emoji downloads; TGS uses Telegram's thumbnail."""
import asyncio
import os
import uuid
from pathlib import Path
from telethon import functions, types

MAX_BYTES = 20 * 1024 * 1024
MAX_CUSTOM_EMOJIS = 100


class DownloadTooLarge(Exception):
    pass


class BoundedDownload:
    def __init__(self, output):
        self.output, self.size = output, 0

    def write(self, data):
        if self.size + len(data) > MAX_BYTES:
            raise DownloadTooLarge()
        self.size += len(data)
        return self.output.write(data)


def custom_emojis(message):
    return [{'offset': e.offset, 'length': e.length, 'document_id': str(e.document_id)}
            for e in (getattr(message, 'entities', None) or [])
            if isinstance(e, types.MessageEntityCustomEmoji)][:MAX_CUSTOM_EMOJIS]


async def receive(client, message, directory):
    documents = []
    if message.photo or message.document:
        documents.append((message, None))
    ids = list(dict.fromkeys(int(e['document_id']) for e in custom_emojis(message)))
    if ids:
        for doc in await client(functions.messages.GetCustomEmojiDocumentsRequest(document_id=ids)):
            if isinstance(doc, types.Document):
                documents.append((doc, str(doc.id)))
    result, total = [], 0
    try:
        for asset, emoji_id in documents:
            doc = asset.document if hasattr(asset, 'document') else asset
            mime = getattr(doc, 'mime_type', '')
            thumbnail = mime == 'application/x-tgsticker'
            key = uuid.uuid4().hex
            target = Path(directory) / ('attachment-' + key)
            partial = target.with_suffix('.partial')
            try:
                with partial.open('wb') as output:
                    options = {'thumb': -1} if thumbnail else {}
                    await asyncio.wait_for(client.download_media(asset, file=BoundedDownload(output), **options), timeout=90)
                size = partial.stat().st_size
                total += size
                if total > MAX_BYTES:
                    raise DownloadTooLarge()
                if not size:
                    raise OSError('empty_download')
                file = getattr(asset, 'file', None)
                content_type = 'image/jpeg' if thumbnail else getattr(file, 'mime_type', None) or mime or 'application/octet-stream'
                extension = {'image/webp': '.webp', 'image/jpeg': '.jpg', 'image/png': '.png', 'video/webm': '.webm'}.get(content_type, '.bin')
                name = ('emoji-' + emoji_id + extension) if emoji_id else ('sticker-preview.jpg' if thumbnail else getattr(file, 'name', None) or 'telegram' + extension)
                os.replace(partial, target)
                result.append({'key': key, 'filename': Path(name).name[:150], 'content_type': content_type, 'size': size,
                               **({'emoji_document_id': emoji_id} if emoji_id else {})})
            finally:
                partial.unlink(missing_ok=True)
        return result
    except BaseException:
        for item in result:
            (Path(directory) / ('attachment-' + item['key'])).unlink(missing_ok=True)
        raise
