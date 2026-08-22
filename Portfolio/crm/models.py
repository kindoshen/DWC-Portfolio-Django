from django.contrib.contenttypes.fields import GenericForeignKey, GenericRelation
from django.contrib.contenttypes.models import ContentType
from django.db import models


class TimestampedModel(models.Model):
    """Shared created_at/updated_at pair — every top-level CRM record needs it."""

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        abstract = True


class Attachable(models.Model):
    """Mixin granting a model the reverse side of Note/Attachment's generic FK."""

    notes = GenericRelation("crm.Note")
    attachments = GenericRelation("crm.Attachment")

    class Meta:
        abstract = True


class Customer(TimestampedModel, Attachable):
    """A contact — the marketing/CRM record we keep regardless of whether a deal happens."""

    name = models.CharField(max_length=200)
    email = models.EmailField()
    phone = models.CharField(max_length=30)
    company = models.CharField(max_length=200, blank=True)
    marketing_opt_in = models.BooleanField(
        default=True, help_text="OK to include in newsletters/marketing outreach."
    )

    class Meta:
        ordering = ["-created_at"]

    def __str__(self):
        return f"{self.name} ({self.email})"


class Lead(TimestampedModel, Attachable):
    """An inbound inquiry for a specific project, tied to the customer who raised it."""

    class Status(models.TextChoices):
        NEW = "new", "New"
        CONTACTED = "contacted", "Contacted"
        QUOTED = "quoted", "Quoted"
        WON = "won", "Won"
        LOST = "lost", "Lost"

    customer = models.ForeignKey(Customer, on_delete=models.CASCADE, related_name="leads")
    project_summary = models.TextField(
        blank=True, default="", help_text="What they want built, in their own words."
    )
    status = models.CharField(max_length=20, choices=Status.choices, default=Status.NEW)
    source = models.CharField(
        max_length=100, default="Contact Form", help_text="Where this lead came from."
    )

    class Meta:
        ordering = ["-created_at"]

    def __str__(self):
        return f"{self.customer.name} — {self.get_status_display()}"


class Quote(TimestampedModel, Attachable):
    """A priced proposal against a lead — the scope boundary that prevents scope creep."""

    class Status(models.TextChoices):
        DRAFT = "draft", "Draft"
        SENT = "sent", "Sent"
        ACCEPTED = "accepted", "Accepted"
        DECLINED = "declined", "Declined"
        EXPIRED = "expired", "Expired"

    lead = models.ForeignKey(Lead, on_delete=models.CASCADE, related_name="quotes")
    status = models.CharField(max_length=20, choices=Status.choices, default=Status.DRAFT)
    scope_notes = models.TextField(blank=True, help_text="What's included in this quote.")
    out_of_scope_notes = models.TextField(
        blank=True, help_text="Explicitly what's NOT included — the scope-creep guard."
    )
    estimated_start = models.DateField(null=True, blank=True)
    estimated_duration_weeks = models.PositiveIntegerField(null=True, blank=True)
    valid_until = models.DateField(null=True, blank=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self):
        return f"Quote for {self.lead.customer.name} ({self.get_status_display()})"

    @property
    def total_one_time(self):
        items = self.line_items.filter(is_recurring=False)
        return sum((item.unit_cost * item.quantity for item in items), start=0)

    @property
    def total_recurring(self):
        items = self.line_items.filter(is_recurring=True)
        return sum((item.unit_cost * item.quantity for item in items), start=0)


class QuoteLineItem(models.Model):
    class RecurringInterval(models.TextChoices):
        ONE_TIME = "one_time", "One-time"
        MONTHLY = "monthly", "Monthly"
        YEARLY = "yearly", "Yearly"

    quote = models.ForeignKey(Quote, on_delete=models.CASCADE, related_name="line_items")
    description = models.CharField(
        max_length=200, help_text="e.g. Hosting, DB hosting, deployment, domain management, SEO"
    )
    is_recurring = models.BooleanField(default=False)
    recurring_interval = models.CharField(
        max_length=20, choices=RecurringInterval.choices, default=RecurringInterval.ONE_TIME
    )
    unit_cost = models.DecimalField(max_digits=10, decimal_places=2)
    quantity = models.PositiveIntegerField(default=1)

    class Meta:
        ordering = ["id"]

    def __str__(self):
        return self.description


class Project(TimestampedModel, Attachable):
    """Work that's actually underway — what a won quote turns into."""

    class Status(models.TextChoices):
        ACTIVE = "active", "Active"
        ON_HOLD = "on_hold", "On Hold"
        COMPLETED = "completed", "Completed"
        CANCELLED = "cancelled", "Cancelled"

    name = models.CharField(max_length=200)
    customers = models.ManyToManyField(Customer, related_name="projects")
    leads = models.ManyToManyField(Lead, related_name="projects", blank=True)
    originating_quote = models.ForeignKey(
        Quote, on_delete=models.SET_NULL, null=True, blank=True, related_name="projects"
    )
    status = models.CharField(max_length=20, choices=Status.choices, default=Status.ACTIVE)
    start_date = models.DateField(null=True, blank=True)
    target_completion_date = models.DateField(null=True, blank=True)
    actual_completion_date = models.DateField(null=True, blank=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self):
        return self.name


class ProjectMilestone(models.Model):
    project = models.ForeignKey(Project, on_delete=models.CASCADE, related_name="milestones")
    title = models.CharField(max_length=200)
    due_date = models.DateField(null=True, blank=True)
    completed_at = models.DateField(null=True, blank=True)
    notes = models.TextField(blank=True)

    class Meta:
        ordering = ["due_date", "id"]

    def __str__(self):
        return self.title


class Note(models.Model):
    """A note attachable to any Customer/Lead/Quote/Project via GenericForeignKey.

    contact_method is optional — set it and a note doubles as a correspondence-log
    entry (e.g. on a Project); leave it blank and it's just an internal note.
    """

    class ContactMethod(models.TextChoices):
        EMAIL = "email", "Email"
        PHONE = "phone", "Phone"
        MEETING = "meeting", "Meeting"
        OTHER = "other", "Other"

    content_type = models.ForeignKey(ContentType, on_delete=models.CASCADE)
    object_id = models.PositiveIntegerField()
    content_object = GenericForeignKey("content_type", "object_id")

    body = models.TextField()
    contact_method = models.CharField(
        max_length=20, choices=ContactMethod.choices, blank=True
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self):
        return self.body[:60]


class Attachment(models.Model):
    """A file or image attachable to any Customer/Lead/Quote/Project."""

    content_type = models.ForeignKey(ContentType, on_delete=models.CASCADE)
    object_id = models.PositiveIntegerField()
    content_object = GenericForeignKey("content_type", "object_id")

    file = models.FileField(upload_to="crm_attachments/%Y/%m/")
    caption = models.CharField(max_length=200, blank=True)
    uploaded_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-uploaded_at"]

    def __str__(self):
        return self.caption or self.file.name
