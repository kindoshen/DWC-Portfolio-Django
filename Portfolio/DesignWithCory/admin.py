from django.contrib import admin

from .models import WorkSample


@admin.register(WorkSample)
class WorkSampleAdmin(admin.ModelAdmin):
    list_display = ("title", "summary", "display_type", "order")
    list_editable = ("order",)
