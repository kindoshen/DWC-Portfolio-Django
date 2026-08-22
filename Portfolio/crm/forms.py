from django import forms
from django.utils import timezone

# A real visitor can't read the form, decide what to type, and submit faster than this.
MIN_SUBMIT_SECONDS = 3


class ContactForm(forms.Form):
    """The public contact form — backs a Customer + Lead pair, not a model directly,
    since it spans both. Required fields match the punch list: name, email, phone."""

    name = forms.CharField(max_length=200)
    email = forms.EmailField()
    phone = forms.CharField(max_length=30)
    message = forms.CharField(required=False, widget=forms.Textarea)

    # Honeypot: real visitors never see or fill this field (CSS-hidden in the
    # template); a bot filling it out is the signal we drop the submission.
    website = forms.CharField(required=False)

    # Timing companion to the honeypot: a hidden Unix-timestamp set by the template at
    # render time. A submission that arrives implausibly fast — or omits/mangles the
    # field, which a naive scripted POST replaying only the visible fields would — reads
    # as automated. Both checks fail the *same* generic way so neither tips off a bot
    # author which one caught them.
    form_rendered_at = forms.CharField()

    def clean_website(self):
        value = self.cleaned_data.get("website")
        if value:
            raise forms.ValidationError("Spam detected.")
        return value

    def clean_form_rendered_at(self):
        value = self.cleaned_data.get("form_rendered_at")
        try:
            rendered_at = int(value)
        except (TypeError, ValueError):
            raise forms.ValidationError("Spam detected.")
        if timezone.now().timestamp() - rendered_at < MIN_SUBMIT_SECONDS:
            raise forms.ValidationError("Spam detected.")
        return rendered_at
