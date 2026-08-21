from django.urls import path
from . import views

urlpatterns = [
    path('', views.designWithCory, name='designWithCory'),
    path('about/', views.about, name='about'),
    path('portfolio/', views.work_samples, name='work_samples'),
    path('blog/', views.blog_index, name='blog_index'),
    path('blog/<slug:slug>/', views.blog_detail, name='blog_detail'),
]