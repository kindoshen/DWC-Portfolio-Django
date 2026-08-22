import json

from django.conf import settings
from django.core.mail import send_mail
from django.http import JsonResponse
from django.views.decorators.http import require_POST
from django_ratelimit.decorators import ratelimit

from .forms import ContactForm
from .models import Customer, Lead

# Bot-detection fields that never get a visible error of their own — surfacing one would
# tell an attacker exactly which check they tripped.
_SILENT_FIELDS = ("website", "form_rendered_at")


@ratelimit(key="ip", rate="5/m", method="POST", block=False)
@require_POST
def contact_submit(request):
    """Public contact form endpoint: creates (or reuses) a Customer + a new Lead.

    Every lead gets an associated customer, per the CRM spec — repeat visitors
    are matched by email rather than creating a duplicate Customer each time.
    """
    if getattr(request, "limited", False):
        return JsonResponse(
            {"error": "Too many requests — please try again in a minute."}, status=429
        )

    form = ContactForm(request.POST)
    if not form.is_valid():
        errors = {k: v for k, v in form.errors.items() if k not in _SILENT_FIELDS}
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
