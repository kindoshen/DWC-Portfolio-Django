import json

from django.conf import settings
from django.core.mail import send_mail
from django.http import JsonResponse
from django.views.decorators.http import require_POST

from .forms import ContactForm
from .models import Customer, Lead


@require_POST
def contact_submit(request):
    """Public contact form endpoint: creates (or reuses) a Customer + a new Lead.

    Every lead gets an associated customer, per the CRM spec — repeat visitors
    are matched by email rather than creating a duplicate Customer each time.
    """
    form = ContactForm(request.POST)
    if not form.is_valid():
        # Surface the first real (non-honeypot) field error, if any, else a
        # generic message — the honeypot itself never gets a visible error.
        errors = {k: v for k, v in form.errors.items() if k != "website"}
        message = next(iter(errors.values()))[0] if errors else "Please check your details and try again."
        return JsonResponse({"error": message}, status=400)

    data = form.cleaned_data
    customer, _ = Customer.objects.get_or_create(
        email=data["email"],
        defaults={"name": data["name"], "phone": data["phone"]},
    )
    # Keep the contact info current if a returning customer's details changed.
    if customer.name != data["name"] or customer.phone != data["phone"]:
        customer.name = data["name"]
        customer.phone = data["phone"]
        customer.save(update_fields=["name", "phone"])

    Lead.objects.create(
        customer=customer,
        project_summary=data["message"],
        source="Contact Form",
    )

    send_mail(
        subject=f"New lead: {customer.name}",
        message=(
            f"Name: {customer.name}\n"
            f"Email: {customer.email}\n"
            f"Phone: {customer.phone}\n\n"
            f"Message:\n{data['message'] or '(none provided)'}"
        ),
        from_email=settings.DEFAULT_FROM_EMAIL,
        recipient_list=[settings.CONTACT_NOTIFICATION_EMAIL],
        fail_silently=True,
    )

    return JsonResponse({"ok": True})
