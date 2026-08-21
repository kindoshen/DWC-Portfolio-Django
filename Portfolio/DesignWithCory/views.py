from django.shortcuts import render

# Create your views here.
from django.http import HttpResponse

from .models import WorkSample

def designWithCory(request):
  # render() (not a bare template.render()) binds the request to the context,
  # which {% csrf_token %} needs to issue a real token for the contact form.
  return render(request, 'landing.html')

def about(request):
  return render(request, 'about.html')

def work_samples(request):
  return render(request, 'work_samples.html', {'work_samples': WorkSample.objects.all()})

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