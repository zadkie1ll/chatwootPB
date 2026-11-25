import hashlib
import hmac
import json
import time
import uuid
from unittest.mock import patch
from datetime import timedelta
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient
from .models import DeliveryRecord, InboxEvent, WebhookReceipt
from .scanner import scan, UnsafeAttachment
from . import worker


class ServiceBoundaryTests(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.environment = patch.dict('os.environ', {'INTEGRATION_API_TOKEN': 'a' * 64, 'CW_WEBHOOK_SECRET': 's' * 64})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_no_manager_session_or_anonymous_resolve(self):
        response = self.client.post('/resolve/', {'phone': '+79990000001', 'channel': 'telegram'}, format='json')
        self.assertEqual(response.status_code, 401)

    def test_webhook_exact_bytes_ttl_and_deduplication(self):
        body = b'{"event":"message_created"}'
        timestamp = str(int(time.time()))
        signature = 'sha256=' + hmac.new(b's' * 64, timestamp.encode() + b'.' + body, hashlib.sha256).hexdigest()
        headers = {'HTTP_X_CHATWOOT_TIMESTAMP': timestamp, 'HTTP_X_CHATWOOT_SIGNATURE': signature,
                   'HTTP_X_CHATWOOT_DELIVERY': str(uuid.uuid4())}
        for _ in range(2):
            self.assertEqual(self.client.post('/webhooks/chatwoot/', body, content_type='application/json', **headers).status_code, 200)
        self.assertEqual(WebhookReceipt.objects.count(), 1)
        self.assertEqual(self.client.post('/webhooks/chatwoot/', body + b' ', content_type='application/json', **headers).status_code, 401)
        headers['HTTP_X_CHATWOOT_TIMESTAMP'] = '1'
        self.assertEqual(self.client.post('/webhooks/chatwoot/', body, content_type='application/json', **headers).status_code, 401)

    def test_durable_event_logical_key_does_not_discard_edits(self):
        event = dict(channel='telegram', external_account_id='1', external_chat_id='2', external_message_id='3', event_type='received', revision='')
        key = worker.event_key(event)
        InboxEvent.objects.get_or_create(event_key=key, defaults={'payload': event})
        InboxEvent.objects.get_or_create(event_key=key, defaults={'payload': event})
        self.assertEqual(InboxEvent.objects.count(), 1)
        self.assertNotEqual(key, worker.event_key({**event, 'event_type': 'edited', 'revision': 'new'}))

    def test_unknown_does_not_resend(self):
        row = DeliveryRecord.objects.create(payload={}, state='unknown', dispatch_token='b' * 64)
        with patch('delivery.transport.gateway', return_value={'state': 'unknown'}) as gateway, patch('delivery.transport.cw') as cw:
            worker.reconcile_one(row)
        gateway.assert_called_once_with('GET', '/operations/' + str(row.operation_id))
        cw.assert_not_called()
        self.assertEqual(row.state, 'unknown')

    def test_known_result_reconciles_without_new_send(self):
        row = DeliveryRecord.objects.create(payload={}, state='unknown', dispatch_token='b' * 64)
        with patch('delivery.transport.gateway', return_value={'state': 'sent', 'external_message_id': '123'}) as gateway, patch('delivery.transport.cw'):
            worker.reconcile_one(row)
        gateway.assert_called_once_with('GET', '/operations/' + str(row.operation_id))
        row.refresh_from_db()
        self.assertEqual(row.state, 'sent')
        self.assertEqual(row.external_message_id, '123')

    def test_mock_scanner_rejects_eicar_marker(self):
        with patch.dict('os.environ', {'TELEGRAM_MODE': 'mock'}):
            scan(b'Synthetic safe document')
            with self.assertRaises(UnsafeAttachment):
                scan(b'EICAR-STANDARD-ANTIVIRUS-TEST-FILE')

    def test_crashed_sender_becomes_unknown_only_after_lease_expiry(self):
        expired = DeliveryRecord.objects.create(payload={}, state='sending', lease_until=timezone.now() - timedelta(seconds=1))
        active = DeliveryRecord.objects.create(payload={}, state='sending', lease_until=timezone.now() + timedelta(minutes=5))
        worker.recover_expired_sends()
        expired.refresh_from_db()
        active.refresh_from_db()
        self.assertEqual(expired.state, 'unknown')
        self.assertEqual(active.state, 'sending')


class ReliabilityTests(TestCase):
    def test_transient_ingestion_does_not_dead_letter_a_saved_message(self):
        import httpx
        row = InboxEvent.objects.create(event_key='retry', payload={'text': 'Synthetic durable text'}, attempts=50)
        with patch('delivery.transport.cw', side_effect=httpx.ConnectError('synthetic outage')):
            worker.ingest_one(row)
        row.refresh_from_db()
        self.assertEqual(row.state, 'pending')
        self.assertEqual(row.payload['text'], 'Synthetic durable text')
        self.assertIsNotNone(row.next_attempt_at)

    def test_one_discovery_outage_does_not_stop_processing_saved_rows(self):
        import httpx
        with patch('delivery.worker.sync_inbox', side_effect=httpx.ConnectError('synthetic')), patch('delivery.worker.sync_outbox'), patch('delivery.worker.recover_expired_sends'), patch('delivery.worker.process_rows') as process:
            self.assertFalse(worker.tick())
        self.assertEqual(process.call_count, 4)

    def test_outbox_uses_independent_cursor_for_each_delivery_state(self):
        worker.OUTBOX_CURSORS.clear()
        with patch('delivery.transport.cw', return_value={'operations': [], 'next_cursor': None}) as cw:
            worker.sync_outbox()
        self.assertEqual([call.kwargs['params']['state'] for call in cw.call_args_list], ['pending', 'unknown', 'in_flight'])

    def test_infected_incoming_preserves_the_text_and_reports_the_file_error(self):
        from unittest.mock import Mock
        row = InboxEvent.objects.create(event_key='unsafe', payload={'text': 'Preserved synthetic text', 'attachments': [
            {'key': 'a' * 32, 'filename': 'synthetic.txt', 'content_type': 'text/plain'}]})
        response = Mock(content=b'EICAR-STANDARD-ANTIVIRUS-TEST-FILE')
        with patch.dict('os.environ', {'TELEGRAM_MODE': 'mock', 'TELEGRAM_GATEWAY_URL': 'http://synthetic', 'GATEWAY_TOKEN': 'synthetic'}), patch('delivery.worker.httpx.get', return_value=response), patch('delivery.transport.cw') as cw:
            worker.ingest_one(row)
        sent = cw.call_args.kwargs['json']['event']
        self.assertEqual(sent['text'], 'Preserved synthetic text')
        self.assertEqual(sent['attachment_error'], 'attachment_rejected')
        self.assertEqual(sent['attachments'], [])
        self.assertEqual(row.state, 'processed')


class MaxPilotRelayTests(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.environment = patch.dict('os.environ', {'INTEGRATION_API_TOKEN': 'a' * 64,
            'MAX_GATEWAY_URL': 'http://max-gateway:8092', 'MAX_GATEWAY_TOKEN': 'm' * 64})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_max_auth_requires_internal_service_credentials(self):
        self.assertEqual(self.client.get('/max-channel/status/').status_code, 401)

    def test_password_is_relayed_only_in_service_authenticated_post(self):
        self.client.credentials(HTTP_AUTHORIZATION='Bearer ' + 'a' * 64)
        with patch('delivery.views.httpx.request') as call:
            call.return_value.status_code = 200
            call.return_value.json.return_value = {'status': 'authenticating'}
            result = self.client.post('/max-channel/password/', {'attempt_id': 'synthetic', 'password': 'SyntheticPassword'}, format='json')
            self.assertEqual(result.status_code, 200)
            self.assertEqual(result['Cache-Control'], 'no-store')
            self.assertNotIn('SyntheticPassword', str(result.data))
            self.assertEqual(call.call_args.args, ('POST', 'http://max-gateway:8092/auth/password'))
            self.assertEqual(call.call_args.kwargs['headers']['Authorization'], 'Bearer ' + 'm' * 64)

    def test_unknown_steps_and_unexpected_fields_do_not_reach_gateway(self):
        self.client.credentials(HTTP_AUTHORIZATION='Bearer ' + 'a' * 64)
        with patch('delivery.views.httpx.request') as call:
            self.assertEqual(self.client.post('/max-channel/send/', {}, format='json').status_code, 404)
            self.assertEqual(self.client.post('/max-channel/start/', {'token': 'not-accepted'}, format='json').status_code, 422)
            call.assert_not_called()
