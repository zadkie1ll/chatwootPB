import os
from pathlib import Path
BASE_DIR = Path(__file__).resolve().parent.parent
TESTING = os.environ.get('INTEGRATION_TEST_SQLITE') == 'true'
SECRET_KEY = os.environ.get('DJANGO_SECRET_KEY', 'synthetic-unit-test-only') if TESTING else os.environ['DJANGO_SECRET_KEY']
DEBUG = False
ALLOWED_HOSTS = ['integration-web', 'localhost', '127.0.0.1', 'testserver']
INSTALLED_APPS = ['django.contrib.contenttypes', 'rest_framework', 'delivery']
MIDDLEWARE = ['django.middleware.security.SecurityMiddleware']
ROOT_URLCONF = 'config.urls'
WSGI_APPLICATION = 'config.wsgi.application'
USE_TZ = True
DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'
DATABASES = {'default': {'ENGINE': 'django.db.backends.sqlite3', 'NAME': BASE_DIR / 'test.sqlite3'}} if TESTING else {
    'default': {'ENGINE': 'django.db.backends.postgresql', 'HOST': os.environ['INTEGRATION_DB_HOST'],
                'NAME': os.environ['INTEGRATION_DB_NAME'], 'USER': os.environ['INTEGRATION_DB_USER'],
                'PASSWORD': os.environ['INTEGRATION_DB_PASSWORD'], 'CONN_MAX_AGE': 30}}
REST_FRAMEWORK = {'DEFAULT_AUTHENTICATION_CLASSES': ['delivery.auth.ServiceAuthentication'],
                  'DEFAULT_PERMISSION_CLASSES': ['rest_framework.permissions.IsAuthenticated'],
                  'UNAUTHENTICATED_USER': None, 'DEFAULT_RENDERER_CLASSES': ['rest_framework.renderers.JSONRenderer']}
DATA_UPLOAD_MAX_MEMORY_SIZE = 2 * 1024 * 1024
FILE_UPLOAD_MAX_MEMORY_SIZE = 20 * 1024 * 1024
LOGGING = {'version': 1, 'disable_existing_loggers': False, 'handlers': {'console': {'class': 'logging.StreamHandler'}},
           'root': {'handlers': ['console'], 'level': 'WARNING'}}
