import base64
import hashlib
from datetime import timedelta
import os
import httpx
from django.db import connection, transaction
from django.db.models import Q
from django.utils import timezone
from .models import DeliveryRecord, InboxEvent
from . import transport
from .scanner import scan, UnsafeAttachment

OUTBOX_CURSORS = {}


def persist(row):
    row.save(update_fields=[field.name for field in row._meta.fields if not field.primary_key and field.name not in ('lease_until', 'created_at')])


def retry_at(attempt):
    return timezone.now() + timedelta(seconds=min(300, 2 ** min(attempt, 8)))


def event_key(event):
    values = [event.get(key, '') for key in ('channel', 'external_account_id', 'external_chat_id', 'external_message_id', 'event_type', 'revision')]
    return hashlib.sha256('/'.join(map(str, values)).encode()).hexdigest()


def sync_inbox():
    failures = []
    for channel in transport.enabled_channels():
        try:
            for event in transport.channel_gateway(channel, 'GET', '/events').get('events', []):
                if event.get('channel') != channel:
                    raise ValueError('event_channel_mismatch')
                InboxEvent.objects.get_or_create(event_key=event_key(event), defaults={'payload': event})
                transport.channel_gateway(channel, 'POST', '/events/' + str(event['journal_id']) + '/ack')
        except (httpx.HTTPError, OSError, ValueError, KeyError) as error:
            failures.append(error)
    if failures:
        raise failures[0]


def ingest_one(row):
    event = dict(row.payload)
    files = []
    import json
    try:
        for item in event.get('attachments', []):
            url, token = transport.gateway_configuration(event.get('channel', 'telegram'))
            response = httpx.get(url + '/attachments/' + item['key'],
                                 headers={'Authorization': 'Bearer ' + token}, timeout=90)
            response.raise_for_status()
            try:
                scan(response.content)
            except UnsafeAttachment:
                event.update(attachments=[], attachment_error='attachment_rejected', attachment_state='failed')
                files = []
                break
            files.append(('attachments[]', (item['filename'], response.content, item['content_type'])))
        if files:
            transport.cw('POST', '/ingest', data={'event': json.dumps(event)}, files=files)
        else:
            transport.cw('POST', '/ingest', json={'event': event})
        if event.get('journal_id'):
            transport.channel_gateway(event.get('channel', 'telegram'), 'POST', '/events/' + str(event['journal_id']) + '/complete')
        row.state, row.error_code = 'processed', ''
    except (httpx.HTTPError, KeyError, ValueError, OSError):
        # Retain the durable event indefinitely on transient failure. Other
        # rows and chats continue; a failed file never discards its text.
        row.state, row.error_code = 'pending', 'ingest_unavailable'
        row.next_attempt_at = retry_at(row.attempts)
    persist(row)


def sync_outbox():
    for state in ('pending', 'unknown', 'in_flight'):
        after = OUTBOX_CURSORS.get(state, 0)
        page = transport.cw('GET', '/outbox', params={'state': state, 'after': after})
        operations = page.get('operations', [])
        OUTBOX_CURSORS[state] = page.get('next_cursor') or 0
        for operation in operations:
            row, created = DeliveryRecord.objects.get_or_create(operation_id=operation['operation_id'], defaults={
                'payload': operation, 'state': 'pending' if operation['state'] == 'pending' else 'unknown',
                'dispatch_token': operation.get('dispatch_token') or ''})
            if not created:
                changes = {'payload': operation}
                if operation.get('dispatch_token'):
                    changes['dispatch_token'] = operation['dispatch_token']
                DeliveryRecord.objects.filter(pk=row.pk).update(**changes)


def acknowledge(row):
    state = 'sent' if row.state == 'sent_ack' else 'failed' if row.state == 'failed_ack' else 'unknown'
    transport.cw('PATCH', '/operations/' + str(row.operation_id), json={
        'dispatch_token': row.dispatch_token, 'state': state,
        'external_message_id': row.external_message_id or None, 'error_code': row.error_code})
    row.state = state
    persist(row)


def dispatch_one(row):
    operation_id = str(row.operation_id)
    rejected = False
    try:
        prepared = prepare_outgoing_files(operation_id, row.payload.get('attachments', []))
    except UnsafeAttachment:
        prepared, rejected = [], True
    try:
        operation = transport.cw('POST', '/operations/' + operation_id + '/claim')
    except httpx.HTTPStatusError as error:
        if error.response.status_code == 409:
            row.state = 'cancelled' if error.response.json().get('state') == 'cancelled' else 'unknown'
            persist(row)
            return
        raise
    row.dispatch_token = operation['dispatch_token']
    row.state = 'sending'
    persist(row)
    if rejected:
        row.state, row.error_code = 'failed_ack', 'attachment_rejected'
        persist(row)
        acknowledge(row)
        return
    operation['attachments'] = prepared
    try:
        result = transport.channel_gateway(operation.get('channel', 'telegram'), 'POST', '/send', json=operation)
    except (httpx.HTTPError, OSError):
        row.state, row.error_code = 'unknown', 'send_outcome_unknown'
        persist(row)
        acknowledge(row)
        return
    apply_result(row, result)


def prepare_outgoing_files(operation_id, attachments):
    result = []
    for item in attachments:
        response = httpx.get(os.environ['CHATWOOT_INTERNAL_URL'] + '/internal/corporate/operations/' + operation_id + '/attachments/' + str(item['id']),
                             headers={'Authorization': 'Bearer ' + os.environ['CW_SERVICE_TOKEN']}, timeout=20)
        response.raise_for_status()
        scan(response.content)
        result.append({**item, 'data': base64.b64encode(response.content).decode()})
    return result


def apply_result(row, result):
    state = result.get('state')
    row.error_code = '' if state == 'sent' else row.error_code
    if state == 'retry':
        transport.cw('PATCH', '/operations/' + str(row.operation_id), json={
            'dispatch_token': row.dispatch_token, 'state': 'pending', 'error_code': 'flood_wait'})
        row.state = 'pending'
        row.next_attempt_at = timezone.now() + timedelta(seconds=min(86400, max(1, int(result['retry_after']))))
        persist(row)
        return
    if state == 'sent':
        row.state, row.external_message_id = 'sent_ack', str(result['external_message_id'])
    elif state == 'failed':
        row.state, row.error_code = 'failed_ack', result.get('error_code', 'external_failure')
    else:
        row.state, row.error_code = 'unknown', 'send_outcome_unknown'
    persist(row)
    acknowledge(row)


def reconcile_one(row):
    result = transport.channel_gateway(row.payload.get('channel', 'telegram'), 'GET', '/operations/' + str(row.operation_id))
    if result.get('state') in ('sent', 'failed') and row.dispatch_token:
        apply_result(row, result)
    else:
        row.next_attempt_at = timezone.now() + timedelta(seconds=30)
        persist(row)


def recover_expired_sends():
    # A dead worker may have sent before persisting the acknowledgement. Only
    # reconcile after its lease expires; never put this operation back in pending.
    now = timezone.now()
    DeliveryRecord.objects.filter(state='sending').filter(
        Q(lease_until__isnull=True) | Q(lease_until__lte=now)
    ).update(state='unknown', error_code='send_outcome_unknown', next_attempt_at=now)


def process_rows(model, states, callback):
    now = timezone.now()
    for row_id in model.objects.filter(state__in=states).filter(Q(lease_until__isnull=True) | Q(lease_until__lte=now)).filter(Q(next_attempt_at__isnull=True) | Q(next_attempt_at__lte=now)).order_by('created_at').values_list('pk', flat=True)[:50]:
        with transaction.atomic():
            row = model.objects.select_for_update(skip_locked=connection.features.has_select_for_update_skip_locked).filter(pk=row_id, state__in=states).first()
            if row is None:
                continue
            if row.lease_until and row.lease_until > now:
                continue
            lease = now + timedelta(minutes=10)
            model.objects.filter(pk=row.pk).update(lease_until=lease)
            row.attempts += 1
            # A short DB transaction holds no locks across external HTTP calls.
            persist(row)
        from .maintenance import heartbeat
        heartbeat('delivery')
        try:
            callback(row)
        except (httpx.HTTPError, KeyError, ValueError, OSError, UnsafeAttachment):
            if isinstance(row, DeliveryRecord) and row.state == 'sending':
                row.state, row.error_code = 'unknown', 'send_outcome_unknown'
            row.next_attempt_at = retry_at(row.attempts)
            persist(row)
        finally:
            model.objects.filter(pk=row.pk, lease_until=lease).update(lease_until=None)


def tick():
    healthy = True
    for sync in (sync_inbox, sync_outbox):
        try:
            sync()
        except (httpx.HTTPError, OSError, ValueError, KeyError):
            healthy = False  # Already persisted rows still continue.
    recover_expired_sends()
    process_rows(InboxEvent, ['pending', 'dead'], ingest_one)
    process_rows(DeliveryRecord, ['pending'], dispatch_one)
    process_rows(DeliveryRecord, ['sent_ack', 'failed_ack'], acknowledge)
    process_rows(DeliveryRecord, ['unknown'], reconcile_one)
    return healthy
