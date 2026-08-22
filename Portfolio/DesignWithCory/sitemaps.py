from django.contrib.sitemaps import Sitemap
from django.urls import reverse

from .models import BlogPost


class StaticViewSitemap(Sitemap):
    """The site's fixed pages — no model behind them, so just list the URL names."""

    changefreq = "monthly"
    priority = 0.7

    def items(self):
        return ["designWithCory", "about", "work_samples", "blog_index"]

    def location(self, item):
        return reverse(item)

    def priority(self, item):
        # Home carries the most weight; the rest share the class default.
        return 1.0 if item == "designWithCory" else 0.7


class BlogPostSitemap(Sitemap):
    changefreq = "yearly"
    priority = 0.5

    def items(self):
        return BlogPost.objects.filter(is_published=True)

    def lastmod(self, obj):
        return obj.published_at
