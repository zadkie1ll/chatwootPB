import hmac
import os
from rest_framework.authentication import BaseAuthentication
from rest_framework.exceptions import AuthenticationFailed


class ServicePrincipal:
    is_authenticated = True


class ServiceAuthentication(BaseAuthentication):
    def authenticate(self, request):
        expected = os.environ.get('INTEGRATION_API_TOKEN', '')
        supplied = request.headers.get('Authorization', '').removeprefix('Bearer ')
        if len(expected) < 32 or not hmac.compare_digest(supplied, expected):
            raise AuthenticationFailed('Service authentication required')
        return ServicePrincipal(), None

    def authenticate_header(self, request):
        return 'Bearer'
