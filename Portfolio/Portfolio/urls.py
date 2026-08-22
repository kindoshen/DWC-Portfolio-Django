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
import re

from django.conf import settings
from django.contrib import admin
from django.urls import path, include, re_path
from django.views.generic import RedirectView
from django.views.static import serve as serve_static
from django.templatetags.static import static

from DesignWithCory.views import robots_txt

urlpatterns = [
    path('', include('DesignWithCory.urls')),
    path('contact/', include('crm.urls')),
    path('admin/', admin.site.urls),
    # Browsers probe /favicon.ico directly regardless of the <link rel="icon">
    # tags in base.html, so redirect it to the real file under STATIC_URL.
    path('favicon.ico', RedirectView.as_view(url=static('favicon/favicon.ico'), permanent=True)),
    # robots.txt must be served at the literal domain root, not under
    # STATIC_URL, so it gets its own view rather than living as a static file.
    path('robots.txt', robots_txt),
]

if settings.SERVE_MEDIA_VIA_DJANGO:
    # Gated on a real setting rather than DEBUG: this used to be dev-only, which meant
    # the Docker deployment served zero media (blog covers, work-sample images, the
    # résumé) the moment DEBUG=False, since nothing else in this stack serves it either.
    # Django serving media itself is slower than a dedicated web server/CDN under real
    # load, but for this project's actual traffic that's a non-issue — see settings.py.
    #
    # Deliberately NOT django.conf.urls.static.static(): that helper has its own
    # internal `if not settings.DEBUG: return []` check baked in, so it silently no-ops
    # in production regardless of the setting above. re_path() straight to the
    # underlying view (what static() just wraps) is what actually respects it.
    urlpatterns += [
        re_path(
            r'^%s(?P<path>.*)$' % re.escape(settings.MEDIA_URL.lstrip('/')),
            serve_static,
            {'document_root': settings.MEDIA_ROOT},
        ),
    ]
