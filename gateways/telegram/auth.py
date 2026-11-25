#!/usr/bin/env python3
"""Run locally by the account owner, with the gateway stopped. Never paste secrets in chat."""
import asyncio
import fcntl
import getpass
import json
import os
from pathlib import Path
from telethon import TelegramClient


async def main():
    os.umask(0o077)
    directory = Path(__file__).resolve().parents[2] / 'secrets' / 'telegram'
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (directory / 'gateway.lock').open('a') as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        config = {'api_id': int(input('Your application api_id (my.telegram.org): ')), 'api_hash': getpass.getpass('api_hash (hidden): ')}
        client = TelegramClient(str(directory / 'personal'), config['api_id'], config['api_hash'])
        await client.start(phone=lambda: getpass.getpass('Test account phone (hidden): '),
                           code_callback=lambda: getpass.getpass('Telegram login code (hidden): '),
                           password=lambda: getpass.getpass('Telegram 2FA password (hidden): '))
        (directory / 'config.json').write_text(json.dumps(config))
        await client.disconnect()
    print('Session saved locally under secrets/telegram/. No messages sent. Do not share this directory.')


if __name__ == '__main__':
    asyncio.run(main())
