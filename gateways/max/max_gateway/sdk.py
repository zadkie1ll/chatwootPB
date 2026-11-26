"""Version-specific adapter for the reviewed PyMax 2.5.0 protocol models.

We use the pinned runtime for MSG_SEND so our durable CID and plain text are
preserved. The convenience send_message generates a fresh CID and Markdown.
"""
from pymax import File, Photo, Voice
from pymax.api.messages.payloads import SendMessagePayload, SendMessagePayloadMessage, ReplyLink
from pymax.api.response import require_payload_model
from pymax.protocol import Opcode
from pymax.exceptions import ApiError
from pymax.types.domain import Message


class UploadBeforeSend(Exception):
    pass


def opus_duration(content):
    if b'OpusHead' not in content[:256]:
        return None
    cursor, samples = 0, 0
    while cursor + 27 <= len(content):
        if content[cursor:cursor + 4] != b'OggS':
            return None
        count = content[cursor + 26]
        if cursor + 27 + count > len(content):
            return None
        granule = int.from_bytes(content[cursor + 6:cursor + 14], 'little')
        if granule != (1 << 64) - 1:
            samples = max(samples, granule)
        cursor += 27 + count + sum(content[cursor + 27:cursor + 27 + count])
    return max(1, samples // 48) if samples else None


async def send(client, chat_id, data, cid, files):
    uploads = client._app.api.uploads
    attachments = []
    try:
        for item, content in files:
            filename = item['filename']
            if item.get('voice') and (duration := opus_duration(content)):
                attached = await uploads.upload_voice(Voice(raw=content, name=filename, duration=duration))
            elif item['content_type'] in ('image/jpeg', 'image/png', 'image/gif', 'image/webp'):
                attached = await uploads.upload_photo(Photo(raw=content, name=filename))
            else:
                attached = await uploads.upload_file(File(raw=content, name=filename))
            if attached is None:
                raise RuntimeError('upload_failed')
            attachments.append(attached)
    except Exception as error:
        raise UploadBeforeSend() from error
    message = SendMessagePayloadMessage(text=data.get('text') or None, cid=cid, elements=[], attaches=attachments,
                                        link=ReplyLink(message_id=int(data['reply_to'])) if data.get('reply_to') else None)
    frame = SendMessagePayload(chat_id=chat_id, message=message, notify=True)
    payload = frame.to_payload()
    try:
        result = await client._app.invoke(Opcode.MSG_SEND, payload)
    except ApiError as error:
        if error.error != 'attachment.not.ready':
            raise
        # The server explicitly rejected this send while processing voice.
        # Match the pinned SDK: wait for its upload signal, then reuse the CID.
        await client._app.api.messages._process_attachment_error(attachments)
        result = await client._app.invoke(Opcode.MSG_SEND, payload)
    return require_payload_model(result, Message)


async def edit(client, chat_id, message_id, text):
    message = await client.get_message(chat_id, message_id)
    if message is None or message.sender != client.me.contact.id:
        raise ValueError('message_not_owned')
    # Retain original attachments when editing captions. SDK convenience edit
    # uploads new attachments and otherwise clears them.
    frame = {'chatId': chat_id, 'messageId': message_id, 'text': text, 'elements': [],
             'attachments': [item.model_dump(by_alias=True, exclude_none=True, exclude={'preview_data'}) for item in message.attaches]}
    await client._app.invoke(Opcode.MSG_EDIT, frame)
    return message_id
