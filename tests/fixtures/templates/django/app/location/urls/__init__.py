from django.urls.conf import include, path


app_name = 'location'

urlpatterns = [
    path('page/', include('app.location.urls.page_urls', namespace='page')),
]
