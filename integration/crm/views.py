import os
from rest_framework import serializers
from rest_framework.decorators import api_view
from rest_framework.response import Response
from .client import BitrixClient, CrmError
from .mutations import publish


class ResolveRequest(serializers.Serializer):
    phone = serializers.CharField(max_length=40, required=False, default='', allow_blank=True)
    deal_url = serializers.CharField(max_length=500, required=False, default='', allow_blank=True)


class PublishRequest(serializers.Serializer):
    operation_id = serializers.UUIDField()
    entity_type = serializers.ChoiceField(choices=['deal', 'lead'], required=False)
    deal_id = serializers.RegexField(r'^[1-9]\d{0,17}$')
    assigned_user_id = serializers.RegexField(r'^[1-9]\d{0,17}$', required=False, allow_blank=True)
    chat_url = serializers.CharField(max_length=500)


def configured():
    if os.environ.get('BITRIX_ENABLED') != 'true':
        raise CrmError('crm_not_configured')
    return BitrixClient()


def error_response(error):
    status = 422 if error.code.startswith(('invalid_', 'provide_')) else 503
    return Response({'error': error.code}, status=status)


@api_view(['GET'])
def employees(request):
    try:
        client = configured()
        employee_id = request.query_params.get('id')
        if employee_id and not employee_id.isdigit():
            raise CrmError('invalid_employee')
        return Response({'portal': client.portal, 'employees': client.employees(employee_id)})
    except CrmError as error:
        return error_response(error)


@api_view(['POST'])
def resolve(request):
    data = ResolveRequest(data=request.data)
    data.is_valid(raise_exception=True)
    try:
        return Response(configured().resolve(**data.validated_data))
    except CrmError as error:
        return error_response(error)


@api_view(['POST'])
def publish_link(request):
    data = PublishRequest(data=request.data)
    data.is_valid(raise_exception=True)
    payload = {**data.validated_data, 'operation_id': str(data.validated_data['operation_id'])}
    try:
        result = publish(configured(), payload)
        return Response(result, status=200 if result['state'] == 'applied' else 202)
    except CrmError as error:
        return error_response(error)
