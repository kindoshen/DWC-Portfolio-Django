from django.urls import path
from . import views

urlpatterns = [
    path('', views.designWithCory, name='designWithCory'),
    path('about/', views.about, name='about'),
    path('portfolio/', views.work_samples, name='work_samples'),
    path('creations/', views.creations, name='creations'),
    path('blog/', views.blog_index, name='blog_index'),
    path('blog/<slug:slug>/', views.blog_detail, name='blog_detail'),
    path('resume/', views.resume_pdf, name='resume_pdf'),
]