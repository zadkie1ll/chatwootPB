import uuid
from django.db import models


class InboxEvent(models.Model):
    event_key = models.CharField(max_length=64, unique=True)
    payload = models.JSONField()
    state = models.CharField(max_length=20, default='pending', db_index=True)
    lease_until = models.DateTimeField(null=True, blank=True)
    attempts = models.PositiveIntegerField(default=0)
    next_attempt_at = models.DateTimeField(null=True, blank=True)
    error_code = models.CharField(max_length=60, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)


class DeliveryRecord(models.Model):
    operation_id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    payload = models.JSONField()
    state = models.CharField(max_length=20, default='pending', db_index=True)
    dispatch_token = models.CharField(max_length=64, blank=True)
    external_message_id = models.CharField(max_length=40, blank=True)
    lease_until = models.DateTimeField(null=True, blank=True)
    attempts = models.PositiveIntegerField(default=0)
    next_attempt_at = models.DateTimeField(null=True, blank=True)
    error_code = models.CharField(max_length=60, blank=True)
    updated_at = models.DateTimeField(auto_now=True)
    created_at = models.DateTimeField(auto_now_add=True)


class WebhookReceipt(models.Model):
    delivery_id = models.UUIDField(primary_key=True)
    body_hash = models.CharField(max_length=64)
    created_at = models.DateTimeField(auto_now_add=True)


class CrmMutation(models.Model):
    desired_fields = models.JSONField(default=dict)
    operation_id = models.UUIDField(primary_key=True)
    payload_hash = models.CharField(max_length=64)
    payload = models.JSONField()
    state = models.CharField(max_length=20, default='pending')
    error_code = models.CharField(max_length=60, blank=True)
    lease_until = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)


class WorkerHeartbeat(models.Model):
    name = models.CharField(max_length=40, primary_key=True)
    last_seen = models.DateTimeField()
    last_success = models.DateTimeField(null=True, blank=True)
