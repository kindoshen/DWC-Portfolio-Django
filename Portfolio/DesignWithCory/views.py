from django.shortcuts import get_object_or_404, render

# Create your views here.
from django.http import HttpResponse

from .models import BlogPost, WorkSample

def designWithCory(request):
  # render() (not a bare template.render()) binds the request to the context,
  # which {% csrf_token %} needs to issue a real token for the contact form.
  recent_posts = BlogPost.objects.filter(is_published=True)[:3]
  return render(request, 'landing.html', {'recent_posts': recent_posts})

def about(request):
  return render(request, 'about.html')

def work_samples(request):
  return render(request, 'work_samples.html', {'work_samples': WorkSample.objects.all()})

def blog_index(request):
  posts = BlogPost.objects.filter(is_published=True)
  return render(request, 'blog_index.html', {'posts': posts})

def blog_detail(request, slug):
  post = get_object_or_404(BlogPost, slug=slug, is_published=True)
  return render(request, 'blog_detail.html', {'post': post})

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