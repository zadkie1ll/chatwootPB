import hashlib
import hmac
import json
import os
import time
import uuid
import httpx
from django.db import connection, transaction
from rest_framework import serializers
from rest_framework.decorators import api_view, authentication_classes, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from .models import WebhookReceipt


class ResolveRequest(serializers.Serializer):
    phone = serializers.RegexField(r'^\+[1-9]\d{6,14}$')
    channel = serializers.ChoiceField(choices=['telegram'])


@api_view(['GET', 'POST'])
def channel(request, step):
    if (request.method, step) not in [('GET', 'status'), ('POST', 'start'), ('POST', 'code'), ('POST', 'password')]:
        return Response(status=404)
    try:
        response = httpx.request(request.method, os.environ['TELEGRAM_GATEWAY_URL'] + '/auth/' + step,
                                 json=request.data if request.method == 'POST' else None,
                                 headers={'Authorization': 'Bearer ' + os.environ['GATEWAY_TOKEN']}, timeout=40)
        return Response(response.json(), status=response.status_code)
    except (httpx.HTTPError, ValueError):
        return Response({'error': 'channel_unavailable'}, status=503)


@api_view(['GET'])
@authentication_classes([])
@permission_classes([AllowAny])
def health(request):
    connection.ensure_connection()
    return Response({'status': 'ok'})


@api_view(['POST'])
def resolve(request):
    data = ResolveRequest(data=request.data)
    data.is_valid(raise_exception=True)
    try:
        response = httpx.post(os.environ['TELEGRAM_GATEWAY_URL'] + '/resolve', json=data.validated_data,
                              headers={'Authorization': 'Bearer ' + os.environ['GATEWAY_TOKEN']}, timeout=12)
        if response.status_code >= 500:
            return Response({'error': 'channel_unavailable'}, status=503)
        if response.status_code != 200:
            return Response({'error': 'recipient_unavailable'}, status=422)
        return Response(response.json())
    except (httpx.HTTPError, ValueError):
        return Response({'error': 'channel_unavailable'}, status=503)


@api_view(['POST'])
@authentication_classes([])
@permission_classes([AllowAny])
def chatwoot_webhook(request):
    body = request.body
    secret = os.environ.get('CW_WEBHOOK_SECRET', '')
    timestamp = request.headers.get('X-Chatwoot-Timestamp', '')
    signature = request.headers.get('X-Chatwoot-Signature', '')
    if not secret or not timestamp.isdigit() or abs(time.time() - int(timestamp)) > 300 or len(body) > 2 * 1024 * 1024:
        return Response(status=401)
    expected = 'sha256=' + hmac.new(secret.encode(), timestamp.encode() + b'.' + body, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(signature, expected):
        return Response(status=401)
    try:
        delivery_id = uuid.UUID(request.headers.get('X-Chatwoot-Delivery', ''))
        json.loads(body)
    except (ValueError, json.JSONDecodeError):
        return Response(status=400)
    digest = hashlib.sha256(body).hexdigest()
    with transaction.atomic():
        receipt, _ = WebhookReceipt.objects.get_or_create(delivery_id=delivery_id, defaults={'body_hash': digest})
        if receipt.body_hash != digest:
            return Response(status=409)
    # The durable CW outbox is polled independently; this authenticated receipt is a wake signal only.
    return Response(status=200)


@api_view(['GET'])
def diagnostics(request):
    from datetime import timedelta
    from django.db.models import Count, Min
    from django.utils import timezone
    from .models import InboxEvent, DeliveryRecord, WorkerHeartbeat
    now = timezone.now()
    workers = {row.name: {'healthy': (now - row.last_seen).total_seconds() < 120,
                           'last_success_age': (now - row.last_success).total_seconds() if row.last_success else None}
               for row in WorkerHeartbeat.objects.all()}
    inbound = InboxEvent.objects.filter(state__in=['pending', 'dead']).aggregate(count=Count('pk'), oldest=Min('created_at'))
    outbound = DeliveryRecord.objects.filter(state__in=['pending', 'sending', 'unknown']).aggregate(count=Count('pk'), oldest=Min('created_at'))
    def describe(values):
        return {'count': values['count'], 'oldest_seconds': (now - values['oldest']).total_seconds() if values['oldest'] else 0}
    try:
        gateway = transport_gateway_health()
    except (httpx.HTTPError, ValueError):
        gateway = {'connected': False}
    incoming = describe(inbound)
    media = gateway.get('queues', {})
    incoming['count'] += media.get('media_pending', 0)
    incoming['oldest_seconds'] = max(incoming['oldest_seconds'], media.get('media_oldest_seconds', 0))
    return Response({'workers': workers, 'incoming': incoming, 'outgoing': describe(outbound), 'telegram': gateway})


def transport_gateway_health():
    from .transport import gateway
    return gateway('GET', '/health')
