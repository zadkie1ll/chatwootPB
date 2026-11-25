import os
import socket
import struct


class UnsafeAttachment(Exception):
    pass


def scan(data):
    if not data or len(data) > 20 * 1024 * 1024:
        raise UnsafeAttachment('attachment_size')
    if os.environ.get('TELEGRAM_MODE') == 'mock':
        if b'EICAR-STANDARD-ANTIVIRUS-TEST-FILE' in data:
            raise UnsafeAttachment('malware')
        return
    # Fail closed when the production scanner is unavailable. Never silently skip it.
    with socket.create_connection((os.environ['CLAMAV_HOST'], 3310), timeout=20) as connection:
        connection.sendall(b'zINSTREAM\0')
        for offset in range(0, len(data), 65536):
            chunk = data[offset:offset + 65536]
            connection.sendall(struct.pack('!I', len(chunk)) + chunk)
        connection.sendall(struct.pack('!I', 0))
        result = connection.recv(4096)
    if not result.endswith(b'OK\x00'):
        raise UnsafeAttachment('attachment_rejected')
