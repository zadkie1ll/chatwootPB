import os
import signal
import time
import httpx
from django.core.management.base import BaseCommand
from crm.client import CrmError
from crm.reconcile import reconcile_batch
from delivery.maintenance import heartbeat


class Command(BaseCommand):
    help = 'Reconcile responsible Bitrix users without echoing assignments back to CRM'

    def add_arguments(self, parser):
        parser.add_argument('--once', action='store_true')

    def handle(self, *args, **options):
        running = True
        cursor = 0

        def stop(*_args):
            nonlocal running
            running = False

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        while running:
            heartbeat('crm')
            if os.environ.get('BITRIX_ENABLED') == 'true':
                try:
                    cursor = reconcile_batch(cursor)
                    heartbeat('crm', success=True)
                except (CrmError, httpx.HTTPError, OSError, ValueError, KeyError) as error:
                    self.stderr.write('crm_reconcile_worker: ' + type(error).__name__)
            if options['once']:
                return
            for _ in range(30):
                if not running:
                    break
                time.sleep(1)
