from django.shortcuts import get_object_or_404, render

# Create your views here.
from django.http import FileResponse, Http404, HttpResponse
from django.views.decorators.http import condition

from .models import BlogPost, Resume, WorkSample

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

def _resume_last_modified(request):
  resume = Resume.current()
  return resume.updated_at if resume else None

@condition(last_modified_func=_resume_last_modified)
def resume_pdf(request):
  # Served from a dedicated view (not a direct static URL) and disallowed in
  # robots.txt so it isn't trivially discoverable, guessable, or indexed —
  # the actual scrape-resistance lives in how the frontend renders this
  # (canvas via PDF.js, watermarked, no download link) rather than here.
  #
  # @condition handles If-Modified-Since for us (304s a client/PDF.js cache that
  # already has the current file — cheap given resume.updated_at only changes when
  # someone actually re-uploads it via admin); Cache-Control below is `private`
  # since this is a scrape-resistant, not a public/CDN-cacheable, response.
  resume = Resume.current()
  if not resume:
    raise Http404
  response = FileResponse(resume.file.open('rb'), content_type='application/pdf')
  response['Content-Disposition'] = 'inline; filename="resume.pdf"'
  response['X-Content-Type-Options'] = 'nosniff'
  response['Cache-Control'] = 'private, max-age=3600'
  return response

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