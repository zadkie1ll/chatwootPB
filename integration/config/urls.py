from django.urls import path
from delivery import views
from crm import views as crm_views
urlpatterns = [path('health/details/', views.diagnostics), path('health/', views.health), path('resolve/', views.resolve),
               path('crm/employees/', crm_views.employees), path('crm/resolve/', crm_views.resolve),
               path('crm/publish/', crm_views.publish_link),
               path('channel/<str:step>/', views.channel),
               path('webhooks/chatwoot/', views.chatwoot_webhook)]
