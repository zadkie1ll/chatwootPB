import signal
import time
import httpx
from django.core.management.base import BaseCommand
from delivery.worker import tick
from delivery.maintenance import heartbeat, cleanup


class Command(BaseCommand):
    help = 'Bounded durable inbox/outbox worker; no message bodies in logs'

    def add_arguments(self, parser):
        parser.add_argument('--once', action='store_true')

    def handle(self, *args, **options):
        running = True

        def stop(*_args):
            nonlocal running
            running = False

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        loops = 0
        while running:
            heartbeat('delivery')
            try:
                healthy = tick()
                heartbeat('delivery', success=healthy)
                if loops % 3600 == 0:
                    cleanup()
                loops += 1
            except (httpx.HTTPError, OSError, ValueError, KeyError) as error:
                self.stderr.write('delivery_worker: ' + type(error).__name__)
            if options['once']:
                return
            time.sleep(1)
