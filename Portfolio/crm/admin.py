from django.contrib import admin
from django.contrib.contenttypes.admin import GenericTabularInline

from .models import (
    Attachment,
    Customer,
    Lead,
    Note,
    Project,
    ProjectMilestone,
    Quote,
    QuoteLineItem,
)


class NoteInline(GenericTabularInline):
    model = Note
    extra = 0
    fields = ("body", "contact_method", "created_at")
    readonly_fields = ("created_at",)


class AttachmentInline(GenericTabularInline):
    model = Attachment
    extra = 0
    fields = ("file", "caption", "uploaded_at")
    readonly_fields = ("uploaded_at",)


class QuoteLineItemInline(admin.TabularInline):
    model = QuoteLineItem
    extra = 1


class ProjectMilestoneInline(admin.TabularInline):
    model = ProjectMilestone
    extra = 1


class QuoteInline(admin.TabularInline):
    """Read-only glance at a lead's quotes — edit the quote itself for line items."""

    model = Quote
    extra = 0
    fields = ("status", "estimated_start", "estimated_duration_weeks", "valid_until")
    show_change_link = True


@admin.register(Customer)
class CustomerAdmin(admin.ModelAdmin):
    list_display = ("name", "email", "phone", "company", "marketing_opt_in", "created_at")
    list_filter = ("marketing_opt_in", "created_at")
    search_fields = ("name", "email", "phone", "company")
    inlines = [NoteInline, AttachmentInline]


@admin.register(Lead)
class LeadAdmin(admin.ModelAdmin):
    list_display = ("customer", "status", "source", "created_at")
    list_filter = ("status", "source")
    search_fields = ("customer__name", "customer__email", "project_summary")
    autocomplete_fields = ["customer"]
    inlines = [QuoteInline, NoteInline, AttachmentInline]


@admin.register(Quote)
class QuoteAdmin(admin.ModelAdmin):
    list_display = ("lead", "status", "valid_until", "created_at")
    list_filter = ("status",)
    search_fields = ("lead__customer__name",)
    autocomplete_fields = ["lead"]
    inlines = [QuoteLineItemInline, NoteInline, AttachmentInline]


@admin.register(Project)
class ProjectAdmin(admin.ModelAdmin):
    list_display = ("name", "status", "start_date", "target_completion_date")
    list_filter = ("status",)
    search_fields = ("name", "customers__name")
    filter_horizontal = ("customers", "leads")
    autocomplete_fields = ["originating_quote"]
    inlines = [ProjectMilestoneInline, NoteInline, AttachmentInline]


@admin.register(Note)
class NoteAdmin(admin.ModelAdmin):
    """Notes are normally edited inline on their parent (Customer/Lead/Quote/Project), but
    they're also reachable directly at /admin/crm/note/ — give that view real list/search
    tooling instead of the bare, unstyled default."""

    list_display = ("__str__", "content_type", "contact_method", "created_at")
    list_filter = ("contact_method", "content_type")
    search_fields = ("body",)
    readonly_fields = ("created_at",)


@admin.register(Attachment)
class AttachmentAdmin(admin.ModelAdmin):
    list_display = ("__str__", "content_type", "caption", "uploaded_at")
    list_filter = ("content_type",)
    search_fields = ("caption", "file")
    readonly_fields = ("uploaded_at",)
