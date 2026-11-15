from django.urls import include, path
from django_glue import django_glue_urls


urlpatterns = [
    path('catalog/', include('catalog.urls')),
]

urlpatterns += django_glue_urls()
