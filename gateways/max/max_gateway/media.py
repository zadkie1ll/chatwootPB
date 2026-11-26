import asyncio
import ipaddress
import mimetypes
from pathlib import Path
import socket
from urllib.parse import urlsplit
import uuid

import aiohttp

MAX_BYTES = 20 * 1024 * 1024
CDN_DOMAINS = ('oneme.ru', 'max.ru', 'okcdn.ru', 'mycdn.me', 'userapi.com', 'vkuser.net', 'vk.com')


class UnsupportedMedia(ValueError):
    pass


class PublicResolver(aiohttp.abc.AbstractResolver):
    async def resolve(self, host, port=0, family=socket.AF_INET):
        results = await asyncio.get_running_loop().getaddrinfo(host, port, family=family, type=socket.SOCK_STREAM)
        if not results or any(not ipaddress.ip_address(row[4][0]).is_global for row in results):
            raise UnsupportedMedia('private_address')
        return [{'hostname': host, 'host': row[4][0], 'port': port, 'family': row[0], 'proto': row[2], 'flags': 0} for row in results]

    async def close(self):
        pass


def valid_url(url):
    parts = urlsplit(url)
    host = (parts.hostname or '').lower()
    if parts.scheme != 'https' or parts.username or parts.password or parts.port not in (None, 443):
        raise UnsupportedMedia('unsafe_url')
    if not any(host == domain or host.endswith('.' + domain) for domain in CDN_DOMAINS):
        raise UnsupportedMedia('unsupported_cdn')
    return url


async def download(url, directory, filename, preferred_type=None):
    key = uuid.uuid4().hex
    target = Path(directory) / ('attachment-' + key)
    partial = target.with_suffix('.part')
    try:
        connector = aiohttp.TCPConnector(resolver=PublicResolver(), use_dns_cache=False)
        async with aiohttp.ClientSession(connector=connector, timeout=aiohttp.ClientTimeout(total=80)) as session:
            for _ in range(4):
                async with session.get(valid_url(url), allow_redirects=False) as response:
                    if response.status in (301, 302, 303, 307, 308):
                        from urllib.parse import urljoin
                        url = urljoin(url, response.headers['Location'])
                        continue
                    response.raise_for_status()
                    if response.content_length and response.content_length > MAX_BYTES:
                        raise UnsupportedMedia('attachment_too_large')
                    size = 0
                    with partial.open('wb') as file:
                        async for chunk in response.content.iter_chunked(65536):
                            size += len(chunk)
                            if size > MAX_BYTES:
                                raise UnsupportedMedia('attachment_too_large')
                            file.write(chunk)
                    if size == 0:
                        raise UnsupportedMedia('empty_attachment')
                    partial.replace(target)
                    content_type = preferred_type or mimetypes.guess_type(filename)[0] or response.content_type
                    return {'key': key, 'filename': filename, 'content_type': content_type, 'size': size}
        raise UnsupportedMedia('redirect_limit')
    finally:
        partial.unlink(missing_ok=True)


async def receive(client, message, directory):
    result = []
    try:
        for item in message.attaches:
            kind = str(getattr(item.type, 'value', item.type))
            if kind == 'PHOTO':
                url, name, mime = item.base_url, 'photo.jpg', 'image/jpeg'
            elif kind == 'FILE':
                if item.size > MAX_BYTES:
                    raise UnsupportedMedia('attachment_too_large')
                file = await client.get_file_by_id(message.chat_id, message.id, item.file_id)
                if not file or file.unsafe:
                    raise UnsupportedMedia('unsafe_attachment')
                url, name, mime = file.url, Path(item.name).name[:150], None
            elif kind == 'AUDIO':
                url, name, mime = item.url, 'voice.ogg', 'audio/ogg'
            elif kind == 'VIDEO':
                video = await client.get_video_by_id(message.chat_id, message.id, item.video_id)
                url, name, mime = video.url if video else None, 'video.mp4', 'video/mp4'
            else:
                raise UnsupportedMedia('unsupported_attachment')
            if not url:
                raise UnsupportedMedia('unsupported_attachment')
            result.append(await download(url, directory, name, mime))
            if sum(file['size'] for file in result) > MAX_BYTES:
                raise UnsupportedMedia('attachment_too_large')
    except BaseException:
        for item in result:
            (Path(directory) / ('attachment-' + item['key'])).unlink(missing_ok=True)
        raise
    return result
