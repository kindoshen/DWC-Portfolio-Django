from django.shortcuts import render

# Create your views here.
from django.http import HttpResponse
from django.template import loader

def designWithCory(request):
  template = loader.get_template('landing.html')
  return HttpResponse(template.render())

def robots_txt(request):
  # Allow indexing of every public page (SEO), but keep the admin, uploaded
  # CRM/media files, and the resume viewer out of search results and caches.
  lines = [
    "User-agent: *",
    "Allow: /",
    "Disallow: /admin/",
    "Disallow: /media/",
    "Disallow: /resume/",
  ]
  return HttpResponse("\n".join(lines), content_type="text/plain")