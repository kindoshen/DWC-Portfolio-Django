"""
URL configuration for Portfolio project.

The `urlpatterns` list routes URLs to views. For more information please see:
    https://docs.djangoproject.com/en/4.2/topics/http/urls/
Examples:
Function views
    1. Add an import:  from my_app import views
    2. Add a URL to urlpatterns:  path('', views.home, name='home')
Class-based views
    1. Add an import:  from other_app.views import Home
    2. Add a URL to urlpatterns:  path('', Home.as_view(), name='home')
Including another URLconf
    1. Import the include() function: from django.urls import include, path
    2. Add a URL to urlpatterns:  path('blog/', include('blog.urls'))
"""
from django.contrib import admin
from django.urls import path, include
from django.views.generic import RedirectView
from django.templatetags.static import static

urlpatterns = [
    path('', include('DesignWithCory.urls')),
    path('admin/', admin.site.urls),
    # Browsers probe /favicon.ico directly regardless of the <link rel="icon">
    # tags in base.html, so redirect it to the real file under STATIC_URL.
    path('favicon.ico', RedirectView.as_view(url=static('favicon/favicon.ico'), permanent=True)),
]
