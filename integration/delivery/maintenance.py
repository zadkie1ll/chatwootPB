from datetime import timedelta
from pathlib import Path
from django.utils import timezone
from .models import WorkerHeartbeat, InboxEvent, DeliveryRecord, CrmMutation, WebhookReceipt


def heartbeat(name, success=False):
    now = timezone.now()
    values = {'last_seen': now}
    if success:
        values['last_success'] = now
    WorkerHeartbeat.objects.update_or_create(name=name, defaults=values)
    Path('/tmp/' + name + '-heartbeat').touch()


def cleanup():
    cutoff = timezone.now() - timedelta(days=30)
    for model, states in [(InboxEvent, ['processed']), (DeliveryRecord, ['sent', 'failed', 'cancelled']), (CrmMutation, ['applied', 'failed'])]:
        ids = list(model.objects.filter(state__in=states, updated_at__lt=cutoff).exclude(payload={}).values_list('pk', flat=True)[:100])
        model.objects.filter(pk__in=ids).update(payload={})
    ids = list(WebhookReceipt.objects.filter(created_at__lt=cutoff).values_list('pk', flat=True)[:100])
    WebhookReceipt.objects.filter(pk__in=ids).delete()
