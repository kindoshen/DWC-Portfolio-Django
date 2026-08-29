from django.contrib.sitemaps import Sitemap
from django.urls import reverse

from .models import BlogPost


class StaticViewSitemap(Sitemap):
    """The site's fixed pages — no model behind them, so just list the URL names."""

    changefreq = "monthly"

    def items(self):
        return ["designWithCory", "about", "work_samples", "creations", "blog_index"]

    def location(self, item):
        return reverse(item)

    # Defined as a method (not a `priority = 0.7` class attribute) because it varies per
    # item: home carries the most weight, everything else shares the flat 0.7 baseline.
    # A same-named class attribute here would be silently shadowed by this method anyway
    # (Python just keeps the last binding in the class body) — so there's no "class
    # default" being read anywhere; 0.7 below is the only place that value lives.
    def priority(self, item):
        return 1.0 if item == "designWithCory" else 0.7


class BlogPostSitemap(Sitemap):
    changefreq = "yearly"
    priority = 0.5

    def items(self):
        return BlogPost.objects.filter(is_published=True)

    def lastmod(self, obj):
        return obj.published_at
