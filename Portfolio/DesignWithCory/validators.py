"""Shared upload validators for admin-managed file/image fields across both apps.

Plain module-level functions (not a validator-factory/closure) so Django's migration
writer can serialize a reference to them directly — a `validate_x(n)()`-style factory
can't be deconstructed into a migration file the same way.
"""

from django.core.exceptions import ValidationError
from django.core.validators import FileExtensionValidator, URLValidator

validate_pdf_extension = FileExtensionValidator(allowed_extensions=["pdf"])

# Not django.forms.ImageField/models.ImageField: Pillow (which backs that field's
# validation) can't parse .svg at all, and one existing blog cover is an SVG on purpose
# (small, scalable, no reason to rasterize it) — an extension whitelist covers raster
# *and* vector web-image formats without that blind spot.
validate_web_image_extension = FileExtensionValidator(
    allowed_extensions=["jpg", "jpeg", "png", "gif", "webp", "svg"]
)


def validate_image_upload_size(file):
    """Work-sample/blog cover images: keeps media/ from filling up with unnecessarily huge files."""
    max_bytes = 8 * 1024 * 1024
    if file.size > max_bytes:
        raise ValidationError(f"Image is {file.size / 1024 / 1024:.1f}MB — the limit is 8MB.")


def validate_document_upload_size(file):
    """Resumes and CRM attachments: PDFs/scans commonly run larger than a web image."""
    max_bytes = 15 * 1024 * 1024
    if file.size > max_bytes:
        raise ValidationError(f"File is {file.size / 1024 / 1024:.1f}MB — the limit is 15MB.")


_absolute_url_validator = URLValidator(schemes=["http", "https"])


def validate_embed_url(value):
    """WorkSample.embed_url covers both a same-origin static embed (e.g. "/static/lab/x.html")
    and a real external URL, so a plain URLField (which rejects root-relative paths) is too
    strict — this accepts either shape instead of forcing every embed to be an absolute URL."""
    if value.startswith("/"):
        return
    _absolute_url_validator(value)
