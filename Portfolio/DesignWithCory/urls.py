from django.urls import path
from . import views

urlpatterns = [
    path('', views.designWithCory, name='designWithCory'),
]