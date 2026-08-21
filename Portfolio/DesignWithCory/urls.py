from django.urls import path
from . import views

urlpatterns = [
    path('', views.designWithCory, name='designWithCory'),
    path('about/', views.about, name='about'),
]