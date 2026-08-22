from django.db import models
from django.urls import reverse

from .validators import (
    validate_document_upload_size,
    validate_embed_url,
    validate_image_upload_size,
    validate_pdf_extension,
    validate_web_image_extension,
)


class BlogPost(models.Model):
    title = models.CharField(max_length=200)
    slug = models.SlugField(max_length=220, unique=True)
    # FileField, not ImageField: one existing cover is a hand-authored SVG, which
    # Pillow (ImageField's validation backend) can't parse — see validators.py.
    cover_image = models.FileField(
        upload_to="blog/",
        validators=[validate_web_image_extension, validate_image_upload_size],
        help_text="Shown on the blog card and post header.",
    )
    excerpt = models.TextField(
        help_text="First-paragraph teaser shown on the card, above the fade-out."
    )
    body = models.TextField(help_text="Full post. Paragraphs (blank-line separated) are rendered as <p>.")
    published_at = models.DateTimeField()
    is_published = models.BooleanField(default=True)

    class Meta:
        ordering = ["-published_at"]

    def __str__(self):
        return self.title

    def get_absolute_url(self):
        return reverse("blog_detail", args=[self.slug])

    @property
    def body_paragraphs(self):
        return [p.strip() for p in self.body.split("\n\n") if p.strip()]


class Resume(models.Model):
    """Singleton-ish: the current resume PDF, swappable via admin without a deploy."""

    file = models.FileField(
        upload_to="resume/",
        validators=[validate_pdf_extension, validate_document_upload_size],
    )
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self):
        return f"Resume (updated {self.updated_at:%Y-%m-%d})"

    @classmethod
    def current(cls):
        return cls.objects.order_by("-updated_at").first()


class WorkSample(models.Model):
    """A featured project on the Work Samples page.

    display_type drives layout in work_sample_item.html: 'image' and
    'iframe' alternate left/right down the page; 'grandiose' breaks out to
    a full-width treatment for complex, multi-screen apps.
    """

    class DisplayType(models.TextChoices):
        IMAGE = "image", "Image"
        IFRAME = "iframe", "Embedded iframe"
        GRANDIOSE = "grandiose", "Grandiose (full-width, multi-view)"

    title = models.CharField(max_length=200)
    summary = models.CharField(max_length=200, help_text="Short one-line role/type, e.g. 'Mobile app'.")
    description = models.TextField()
    display_type = models.CharField(max_length=20, choices=DisplayType.choices, default=DisplayType.IMAGE)
    image = models.ImageField(
        upload_to="work_samples/", blank=True, validators=[validate_image_upload_size]
    )
    embed_url = models.CharField(
        max_length=300,
        blank=True,
        validators=[validate_embed_url],
        help_text="Relative or absolute URL for display_type=iframe.",
    )
    repo_url = models.URLField(blank=True)
    live_url = models.URLField(blank=True)
    order = models.PositiveIntegerField(default=0)

    class Meta:
        ordering = ["order", "id"]

    def __str__(self):
        return self.title
