from django.shortcuts import get_object_or_404, render

# Create your views here.
from django.http import FileResponse, Http404, HttpResponse
from django.urls import reverse

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

def resume_pdf(request):
  # Served from a dedicated view (not a direct static URL) and disallowed in
  # robots.txt so it isn't trivially discoverable, guessable, or indexed —
  # the actual scrape-resistance lives in how the frontend renders this
  # (canvas via PDF.js, watermarked, no download link) rather than here.
  resume = Resume.current()
  if not resume:
    raise Http404
  response = FileResponse(resume.file.open('rb'), content_type='application/pdf')
  response['Content-Disposition'] = 'inline; filename="resume.pdf"'
  response['X-Content-Type-Options'] = 'nosniff'
  return response

def robots_txt(request):
  # Allow indexing of every public page (SEO) — including blog/work-sample images
  # under /media/, which a blanket "Disallow: /media/" used to hide from image
  # search along with everything else in that directory. Only the resume itself
  # (and the admin, and the watermarked-canvas viewer's own route) stay out.
  lines = [
    "User-agent: *",
    "Allow: /",
    "Disallow: /admin/",
    "Disallow: /media/resume/",
    "Disallow: /resume/",
    "",
    f"Sitemap: {request.build_absolute_uri(reverse('django.contrib.sitemaps.views.sitemap'))}",
  ]
  return HttpResponse("\n".join(lines), content_type="text/plain")