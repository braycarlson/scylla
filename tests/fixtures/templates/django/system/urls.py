from django.urls.conf import include, path


urlpatterns = [
    path('glue/', include('django_glue.urls')),
    path('location/', include('app.location.urls', namespace='location')),
]
