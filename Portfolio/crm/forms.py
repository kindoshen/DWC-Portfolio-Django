from django import forms


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

    def clean_website(self):
        value = self.cleaned_data.get("website")
        if value:
            raise forms.ValidationError("Spam detected.")
        return value
