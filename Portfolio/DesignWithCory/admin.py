from django.contrib import admin

from .models import BlogPost, Resume, WorkSample


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


@admin.register(Resume)
class ResumeAdmin(admin.ModelAdmin):
    list_display = ("__str__", "updated_at")
