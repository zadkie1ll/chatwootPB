"""Idempotent CRM updates. An ambiguous network outcome is reconciled by reads."""
from datetime import timedelta
import hashlib
import json
import os
from django.db import transaction
from django.utils import timezone
from delivery.models import CrmMutation
from .client import CrmError


def publish(client, payload):
    digest = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    fields = client.desired_fields(payload)
    now = timezone.now()
    with transaction.atomic():
        row, _ = CrmMutation.objects.get_or_create(operation_id=payload['operation_id'], defaults={
            'payload_hash': digest, 'payload': payload, 'desired_fields': fields})
        row = CrmMutation.objects.select_for_update().get(pk=row.pk)
        if row.payload_hash != digest:
            raise CrmError('crm_operation_conflict')
        if not row.desired_fields:
            # A legacy unresolved operation was issued before the Messenger
            # URL field existed. Reconcile its original fields, not new ones.
            row.desired_fields = {k:v for k,v in fields.items() if k not in (
                os.environ.get('BITRIX_MESSENGER_FIELD'), os.environ.get('BITRIX_LEAD_MESSENGER_FIELD'))}
            row.save(update_fields=['desired_fields'])
        fields = row.desired_fields
        if row.state in ('applied', 'failed'):
            return {'state': row.state, 'error': row.error_code}
        if row.state == 'sending' and row.lease_until and row.lease_until > now:
            return {'state': 'sending'}
        reconcile_only = row.state in ('sending', 'unknown')
        row.state = 'unknown' if reconcile_only else 'sending'
        row.lease_until = now + timedelta(seconds=90)
        row.save(update_fields=['state', 'lease_until', 'updated_at'])
    entity = {'entity_type': payload['entity_type']} if payload.get('entity_type') == 'lead' else {}
    mutation_started = False
    confirmed = False
    try:
        matched = client.matches(payload['deal_id'], fields, **entity)
        if not matched and not reconcile_only:
            mutation_started = True
            client.update(payload['deal_id'], fields, **entity)
            confirmed = True
            matched = client.matches(payload['deal_id'], fields, **entity)
        if matched:
            state, error = 'applied', ''
        elif confirmed:
            # A successful update acknowledgement is final. CRM automation can
            # subsequently change its owner; the separate reader follows that.
            state, error = 'applied', 'crm_changed_after_update'
        else:
            state, error = 'unknown', 'crm_outcome_unknown'
    except CrmError as failure:
        if confirmed:
            state, error = 'applied', 'crm_verification_deferred'
        elif mutation_started and failure.definitive:
            state = 'pending' if failure.retryable else 'failed'
            error = failure.code
        else:
            state = 'unknown' if mutation_started or reconcile_only else 'pending'
            error = failure.code
    CrmMutation.objects.filter(pk=row.pk).update(state=state, error_code=error, lease_until=None)
    return {'state': state, 'error': error}
