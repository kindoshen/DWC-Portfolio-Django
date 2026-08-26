from django.shortcuts import get_object_or_404, render

# Create your views here.
from django.http import FileResponse, Http404, HttpResponse
from django.urls import reverse
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

# A small, curated set of transparent-background assets — the site's own brand mark plus a
# handful of logo-concept explorations that were already sitting in static/images/ unused.
# Fixed content, not admin-editable, so a plain list here beats a model + migration for what
# is genuinely just this one gallery page.
CREATIONS = [
  {
    "image": "images/ChatGPTImageAug112026at01_52_09AM.png",
    "title": "DesignWithCory",
    "caption": "The brand mark this whole site is built around.",
  },
  {
    "image": "images/ChatGPTImageAug112026at01_25_07AM.png",
    "title": "Brand character",
    "caption": "The illustrated version of me that shows up across the site.",
  },
  {
    "image": "images/image1.png",
    "title": "Junxion",
    "caption": "Logo concept — gradient mark for a fictional connectivity brand.",
  },
  {
    "image": "images/black-logo-1.png",
    "title": "Concept 01",
    "caption": "Logo concept — an open-book mark for a fictional company.",
  },
  {
    "image": "images/black-logo-2_150.png",
    "title": "Concept 02",
    "caption": "Logo concept — a checkmark built from repeated strokes.",
  },
  {
    "image": "images/black-logo-3.png",
    "title": "Concept 03",
    "caption": "Logo concept — two interlocking rings.",
  },
  {
    "image": "images/black-logo-4.png",
    "title": "Concept 04",
    "caption": "Logo concept — an abstract monogram built from right angles.",
  },
  {
    "image": "images/black-logo-5.png",
    "title": "Concept 05",
    "caption": "Logo concept — a stepped, parallel-stroke mark.",
  },
  {
    "image": "images/black-logo-6.png",
    "title": "Concept 06",
    "caption": "Logo concept — angled twin blocks.",
  },
]

def creations(request):
  return render(request, 'creations.html', {'creations': CREATIONS})

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