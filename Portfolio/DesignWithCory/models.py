from django.db import models


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
    image = models.ImageField(upload_to="work_samples/", blank=True)
    embed_url = models.CharField(
        max_length=300, blank=True, help_text="Relative or absolute URL for display_type=iframe."
    )
    repo_url = models.URLField(blank=True)
    live_url = models.URLField(blank=True)
    order = models.PositiveIntegerField(default=0)

    class Meta:
        ordering = ["order", "id"]

    def __str__(self):
        return self.title
