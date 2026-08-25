from django.urls import path

from catalog import views


app_name = 'catalog'

urlpatterns = [
    path('', views.list_view, name='list'),
    path('<int:pk>/', views.detail_view, name='detail'),
]
