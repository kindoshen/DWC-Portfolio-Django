from django.contrib import admin

from .models import BlogPost, WorkSample


@admin.register(WorkSample)
class WorkSampleAdmin(admin.ModelAdmin):
    list_display = ("title", "summary", "display_type", "order")
    list_editable = ("order",)


@admin.register(BlogPost)
class BlogPostAdmin(admin.ModelAdmin):
    list_display = ("title", "published_at", "is_published")
    list_filter = ("is_published",)
    search_fields = ("title", "excerpt", "body")
    prepopulated_fields = {"slug": ("title",)}
