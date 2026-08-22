"""Tests for the crm app, focused on the one real user-contributed-data surface in this
project: the public contact form (crm.forms.ContactForm + crm.views.contact_submit) that
turns anonymous POST data into Customer/Lead rows. Also covers model behavior worth pinning
down as the CRM grows (Quote totals, cascade deletes, the generic Note/Attachment relation).
"""

from decimal import Decimal

from django.contrib.contenttypes.models import ContentType
from django.core import mail
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone

from .forms import ContactForm
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


class ContactFormTests(TestCase):
    """Validation on the actual data visitors submit — the most important surface in
    the app to get right, since it's the only one unauthenticated users can write to."""

    def valid_data(self, **overrides):
        data = {
            "name": "Jamie Rivera",
            "email": "jamie@example.com",
            "phone": "555-0100",
            "message": "Looking to build a booking app.",
            "website": "",
            # Comfortably past MIN_SUBMIT_SECONDS (forms.py) so the timing anti-spam
            # check doesn't flag a normal test submission as too-fast-to-be-human.
            "form_rendered_at": str(int(timezone.now().timestamp()) - 10),
        }
        data.update(overrides)
        return data

    def test_valid_submission_is_valid(self):
        form = ContactForm(self.valid_data())
        self.assertTrue(form.is_valid(), form.errors)

    def test_message_is_optional(self):
        form = ContactForm(self.valid_data(message=""))
        self.assertTrue(form.is_valid(), form.errors)

    def test_name_is_required(self):
        form = ContactForm(self.valid_data(name=""))
        self.assertFalse(form.is_valid())
        self.assertIn("name", form.errors)

    def test_email_is_required(self):
        form = ContactForm(self.valid_data(email=""))
        self.assertFalse(form.is_valid())
        self.assertIn("email", form.errors)

    def test_email_must_be_well_formed(self):
        form = ContactForm(self.valid_data(email="not-an-email"))
        self.assertFalse(form.is_valid())
        self.assertIn("email", form.errors)

    def test_phone_is_required(self):
        form = ContactForm(self.valid_data(phone=""))
        self.assertFalse(form.is_valid())
        self.assertIn("phone", form.errors)

    def test_name_over_max_length_is_rejected(self):
        form = ContactForm(self.valid_data(name="x" * 201))
        self.assertFalse(form.is_valid())
        self.assertIn("name", form.errors)

    def test_honeypot_empty_passes(self):
        form = ContactForm(self.valid_data(website=""))
        self.assertTrue(form.is_valid(), form.errors)

    def test_honeypot_filled_is_rejected(self):
        form = ContactForm(self.valid_data(website="http://spam.example"))
        self.assertFalse(form.is_valid())
        self.assertIn("website", form.errors)


@override_settings(RATELIMIT_ENABLE=False)
class ContactSubmitViewTests(TestCase):
    """The endpoint itself: what actually gets written to the DB and who gets emailed.

    Rate limiting (crm.views) is disabled here — several tests below submit multiple
    real POSTs against the same view in quick succession (e.g. the returning-customer
    tests), which would otherwise trip the 5/min-per-IP limit and fail on the rate
    limit rather than on what each test actually means to check. django-ratelimit
    respects this setting as its own documented way to no-op in tests.
    """

    def setUp(self):
        self.url = reverse("contact_submit")

    def valid_data(self, **overrides):
        data = {
            "name": "Jamie Rivera",
            "email": "jamie@example.com",
            "phone": "555-0100",
            "message": "Looking to build a booking app.",
            "website": "",
            # Comfortably past MIN_SUBMIT_SECONDS (forms.py) so the timing anti-spam
            # check doesn't flag a normal test submission as too-fast-to-be-human.
            "form_rendered_at": str(int(timezone.now().timestamp()) - 10),
        }
        data.update(overrides)
        return data

    def test_get_not_allowed(self):
        response = self.client.get(self.url)
        self.assertEqual(response.status_code, 405)

    def test_valid_submission_creates_customer_and_lead(self):
        response = self.client.post(self.url, self.valid_data())
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"ok": True})

        customer = Customer.objects.get(email="jamie@example.com")
        self.assertEqual(customer.name, "Jamie Rivera")
        self.assertEqual(customer.phone, "555-0100")

        lead = Lead.objects.get(customer=customer)
        self.assertEqual(lead.project_summary, "Looking to build a booking app.")
        self.assertEqual(lead.source, "Contact Form")
        self.assertEqual(lead.status, Lead.Status.NEW)

    def test_valid_submission_sends_notification_email(self):
        self.client.post(self.url, self.valid_data())
        self.assertEqual(len(mail.outbox), 1)
        sent = mail.outbox[0]
        self.assertIn("Jamie Rivera", sent.subject)
        self.assertIn("jamie@example.com", sent.body)
        self.assertIn("555-0100", sent.body)
        self.assertIn("Looking to build a booking app.", sent.body)

    def test_missing_message_still_creates_lead_with_empty_summary(self):
        self.client.post(self.url, self.valid_data(message=""))
        lead = Lead.objects.get(customer__email="jamie@example.com")
        self.assertEqual(lead.project_summary, "")

    def test_invalid_submission_creates_nothing(self):
        response = self.client.post(self.url, self.valid_data(email="not-an-email"))
        self.assertEqual(response.status_code, 400)
        self.assertFalse(Customer.objects.exists())
        self.assertFalse(Lead.objects.exists())
        self.assertEqual(len(mail.outbox), 0)

    def test_invalid_submission_returns_field_error_message(self):
        response = self.client.post(self.url, self.valid_data(name=""))
        self.assertEqual(response.status_code, 400)
        self.assertIn("error", response.json())

    def test_honeypot_submission_is_rejected_generically(self):
        response = self.client.post(
            self.url, self.valid_data(website="http://spam.example")
        )
        self.assertEqual(response.status_code, 400)
        # The honeypot field name must never leak into the error the client sees —
        # that would hand a bot author exactly what tripped the check.
        self.assertNotIn("website", response.json()["error"].lower())
        self.assertFalse(Customer.objects.exists())

    def test_returning_customer_reuses_existing_record(self):
        self.client.post(self.url, self.valid_data())
        self.client.post(self.url, self.valid_data(message="A second, different project."))

        self.assertEqual(Customer.objects.filter(email="jamie@example.com").count(), 1)
        self.assertEqual(Lead.objects.filter(customer__email="jamie@example.com").count(), 2)

    def test_returning_customer_with_updated_details_gets_updated(self):
        self.client.post(self.url, self.valid_data())
        self.client.post(
            self.url, self.valid_data(name="Jamie R. Rivera", phone="555-0199")
        )

        customer = Customer.objects.get(email="jamie@example.com")
        self.assertEqual(customer.name, "Jamie R. Rivera")
        self.assertEqual(customer.phone, "555-0199")

    def test_every_lead_has_a_customer(self):
        """Direct enforcement check on the spec's core rule, not just an incidental
        side effect of how the view happens to be written today."""
        self.client.post(self.url, self.valid_data())
        lead = Lead.objects.get(customer__email="jamie@example.com")
        self.assertIsNotNone(lead.customer_id)


class CustomerModelTests(TestCase):
    def test_str_includes_name_and_email(self):
        customer = Customer.objects.create(
            name="Alex Kim", email="alex@example.com", phone="555-0111"
        )
        self.assertEqual(str(customer), "Alex Kim (alex@example.com)")

    def test_ordering_is_newest_first(self):
        older = Customer.objects.create(name="A", email="a@example.com", phone="1")
        newer = Customer.objects.create(name="B", email="b@example.com", phone="2")
        self.assertEqual(list(Customer.objects.all()), [newer, older])

    def test_deleting_customer_cascades_to_leads(self):
        customer = Customer.objects.create(
            name="Alex Kim", email="alex@example.com", phone="555-0111"
        )
        Lead.objects.create(customer=customer)
        customer.delete()
        self.assertFalse(Lead.objects.exists())


class LeadModelTests(TestCase):
    def test_str_includes_customer_name_and_status(self):
        customer = Customer.objects.create(
            name="Alex Kim", email="alex@example.com", phone="555-0111"
        )
        lead = Lead.objects.create(customer=customer)
        self.assertEqual(str(lead), "Alex Kim — New")


class QuoteModelTests(TestCase):
    def setUp(self):
        self.customer = Customer.objects.create(
            name="Alex Kim", email="alex@example.com", phone="555-0111"
        )
        lead = Lead.objects.create(customer=self.customer)
        self.quote = Quote.objects.create(lead=lead)

    def test_str_includes_customer_name_and_status(self):
        self.assertEqual(str(self.quote), "Quote for Alex Kim (Draft)")

    def test_total_one_time_sums_non_recurring_line_items(self):
        QuoteLineItem.objects.create(
            quote=self.quote, description="Build", unit_cost=Decimal("2000.00"), quantity=1
        )
        QuoteLineItem.objects.create(
            quote=self.quote, description="Design", unit_cost=Decimal("500.00"), quantity=2
        )
        QuoteLineItem.objects.create(
            quote=self.quote,
            description="Hosting",
            unit_cost=Decimal("20.00"),
            quantity=1,
            is_recurring=True,
        )
        self.assertEqual(self.quote.total_one_time, Decimal("3000.00"))

    def test_total_recurring_sums_only_recurring_line_items(self):
        QuoteLineItem.objects.create(
            quote=self.quote, description="Build", unit_cost=Decimal("2000.00"), quantity=1
        )
        QuoteLineItem.objects.create(
            quote=self.quote,
            description="Hosting",
            unit_cost=Decimal("20.00"),
            quantity=1,
            is_recurring=True,
        )
        QuoteLineItem.objects.create(
            quote=self.quote,
            description="Domain",
            unit_cost=Decimal("1.50"),
            quantity=1,
            is_recurring=True,
        )
        self.assertEqual(self.quote.total_recurring, Decimal("21.50"))

    def test_totals_are_zero_with_no_line_items(self):
        self.assertEqual(self.quote.total_one_time, 0)
        self.assertEqual(self.quote.total_recurring, 0)

    def test_line_item_str_is_its_description(self):
        item = QuoteLineItem.objects.create(
            quote=self.quote, description="Hosting", unit_cost=Decimal("20.00")
        )
        self.assertEqual(str(item), "Hosting")


class ProjectModelTests(TestCase):
    def test_project_can_exist_without_an_originating_quote(self):
        project = Project.objects.create(name="Direct-hire rebuild")
        self.assertIsNone(project.originating_quote)

    def test_str_is_the_project_name(self):
        project = Project.objects.create(name="Direct-hire rebuild")
        self.assertEqual(str(project), "Direct-hire rebuild")

    def test_milestone_str_is_its_title(self):
        project = Project.objects.create(name="Direct-hire rebuild")
        milestone = ProjectMilestone.objects.create(project=project, title="Kickoff call")
        self.assertEqual(str(milestone), "Kickoff call")

    def test_deleting_quote_nulls_project_reference_instead_of_cascading(self):
        customer = Customer.objects.create(
            name="Alex Kim", email="alex@example.com", phone="555-0111"
        )
        lead = Lead.objects.create(customer=customer)
        quote = Quote.objects.create(lead=lead)
        project = Project.objects.create(name="New build", originating_quote=quote)

        quote.delete()
        project.refresh_from_db()
        self.assertIsNone(project.originating_quote)
        # The project itself must survive losing its quote.
        self.assertTrue(Project.objects.filter(pk=project.pk).exists())


class NoteAttachmentGenericRelationTests(TestCase):
    """The GenericForeignKey plumbing that lets a Note/Attachment attach to any of
    Customer/Lead/Quote/Project — worth pinning down since a typo in content_type/
    object_id wiring fails silently rather than raising."""

    def test_note_attaches_to_customer_and_is_reachable_via_reverse_relation(self):
        customer = Customer.objects.create(
            name="Alex Kim", email="alex@example.com", phone="555-0111"
        )
        Note.objects.create(content_object=customer, body="Called, left a voicemail.")

        self.assertEqual(customer.notes.count(), 1)
        self.assertEqual(customer.notes.first().body, "Called, left a voicemail.")

    def test_note_on_one_customer_does_not_leak_to_another(self):
        alex = Customer.objects.create(name="Alex Kim", email="alex@example.com", phone="1")
        sam = Customer.objects.create(name="Sam Lee", email="sam@example.com", phone="2")
        Note.objects.create(content_object=alex, body="Note about Alex.")

        self.assertEqual(alex.notes.count(), 1)
        self.assertEqual(sam.notes.count(), 0)

    def test_attachment_content_type_matches_the_attached_model(self):
        customer = Customer.objects.create(
            name="Alex Kim", email="alex@example.com", phone="555-0111"
        )
        attachment = Attachment.objects.create(
            content_object=customer, file="crm_attachments/2026/01/test.pdf"
        )
        self.assertEqual(attachment.content_type, ContentType.objects.get_for_model(Customer))
        self.assertEqual(attachment.object_id, customer.pk)

    def test_note_str_is_truncated_body(self):
        customer = Customer.objects.create(
            name="Alex Kim", email="alex@example.com", phone="555-0111"
        )
        note = Note.objects.create(content_object=customer, body="x" * 100)
        self.assertEqual(str(note), "x" * 60)

    def test_attachment_str_prefers_caption_over_filename(self):
        customer = Customer.objects.create(
            name="Alex Kim", email="alex@example.com", phone="555-0111"
        )
        with_caption = Attachment.objects.create(
            content_object=customer, file="crm_attachments/2026/01/test.pdf", caption="Signed contract"
        )
        without_caption = Attachment.objects.create(
            content_object=customer, file="crm_attachments/2026/01/other.pdf"
        )
        self.assertEqual(str(with_caption), "Signed contract")
        self.assertEqual(str(without_caption), without_caption.file.name)
