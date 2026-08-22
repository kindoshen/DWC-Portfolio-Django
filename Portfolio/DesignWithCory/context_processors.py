from django.conf import settings


def site_contact(request):
    """The phone number and email shown to visitors — was hardcoded independently in both
    footer.html and lead_gen.html, so changing either meant remembering to edit both."""
    return {
        "SITE_PHONE_DISPLAY": settings.SITE_PHONE_DISPLAY,
        "SITE_PHONE_TEL": settings.SITE_PHONE_TEL,
        "SITE_EMAIL": settings.DEFAULT_FROM_EMAIL,
    }
