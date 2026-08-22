"""Tests for the DesignWithCory app: the BlogPost/Resume/WorkSample models and the public
views built on top of them. File-backed fields (BlogPost.cover_image, Resume.file,
WorkSample.image) use a temporary MEDIA_ROOT so tests never touch or depend on real
uploaded content in media/.
"""

import io
import os
import shutil
import tempfile
from datetime import timedelta

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from PIL import Image

from .models import BlogPost, Resume, WorkSample

TEMP_MEDIA_ROOT = tempfile.mkdtemp(prefix="dwc-test-media-")


def tearDownModule():
    shutil.rmtree(TEMP_MEDIA_ROOT, ignore_errors=True)


def write_real_image(relative_path, image_format):
    """Writes a genuine, tiny, Pillow-openable image at MEDIA_ROOT/relative_path.

    Unlike SimpleUploadedFile(..., b"fake-image-bytes", ...) elsewhere in this file —
    fine for models that only ever read a FileField's .url — work_sample_item.html reads
    sample.image.width/.height, which makes Django actually open() and decode the file
    at render time. A page that renders any seeded WorkSample (0002_seed_work_samples.py)
    needs a real file sitting at that exact seeded path inside TEMP_MEDIA_ROOT, or the
    request 500s on FileNotFoundError — not a hypothetical, this is exactly what happens
    if a real deploy's media/ is ever missing a file a live DB row still points at.
    """
    full_path = os.path.join(TEMP_MEDIA_ROOT, relative_path)
    os.makedirs(os.path.dirname(full_path), exist_ok=True)
    buffer = io.BytesIO()
    Image.new("RGB", (2, 2)).save(buffer, format=image_format)
    with open(full_path, "wb") as f:
        f.write(buffer.getvalue())


def make_blog_post(**overrides):
    defaults = {
        "title": "Test Post",
        "slug": "test-post",
        "cover_image": SimpleUploadedFile("cover.jpg", b"fake-image-bytes", content_type="image/jpeg"),
        "excerpt": "A short teaser.",
        "body": "First paragraph.\n\nSecond paragraph.",
        "published_at": timezone.now(),
    }
    defaults.update(overrides)
    return BlogPost.objects.create(**defaults)


@override_settings(MEDIA_ROOT=TEMP_MEDIA_ROOT)
class BlogPostModelTests(TestCase):
    def test_str_is_title(self):
        post = make_blog_post(title="Hello World")
        self.assertEqual(str(post), "Hello World")

    def test_get_absolute_url(self):
        post = make_blog_post(slug="my-post")
        self.assertEqual(post.get_absolute_url(), reverse("blog_detail", args=["my-post"]))

    def test_body_paragraphs_splits_on_blank_lines(self):
        post = make_blog_post(body="First.\n\nSecond.\n\nThird.")
        self.assertEqual(post.body_paragraphs, ["First.", "Second.", "Third."])

    def test_body_paragraphs_ignores_extra_blank_lines(self):
        post = make_blog_post(body="First.\n\n\n\nSecond.")
        self.assertEqual(post.body_paragraphs, ["First.", "Second."])

    def test_ordering_is_newest_published_first(self):
        # Data migrations seed real posts into any freshly-migrated DB (including the test
        # one), so assert relative order among just these two rather than exact table
        # contents — the table is never actually empty in practice.
        older = make_blog_post(
            slug="older", published_at=timezone.now() - timedelta(days=7)
        )
        newer = make_blog_post(slug="newer", published_at=timezone.now())
        ours = list(BlogPost.objects.filter(slug__in=["older", "newer"]))
        self.assertEqual(ours, [newer, older])

    def test_slug_must_be_unique(self):
        make_blog_post(slug="dupe")
        with self.assertRaises(Exception):
            make_blog_post(slug="dupe")


@override_settings(MEDIA_ROOT=TEMP_MEDIA_ROOT)
class ResumeModelTests(TestCase):
    def test_current_returns_none_when_empty(self):
        # A seed migration puts a real Resume row in any freshly-migrated DB (including the
        # test one) — clear it to genuinely exercise the empty-table path.
        Resume.objects.all().delete()
        self.assertIsNone(Resume.current())

    def test_current_returns_the_most_newly_created_resume(self):
        resume = Resume.objects.create(
            file=SimpleUploadedFile("resume.pdf", b"%PDF-fake", content_type="application/pdf")
        )
        self.assertEqual(Resume.current(), resume)

    def test_str_includes_update_date(self):
        resume = Resume.objects.create(
            file=SimpleUploadedFile("resume.pdf", b"%PDF-fake", content_type="application/pdf")
        )
        self.assertIn("Resume (updated ", str(resume))

    def test_current_returns_most_recently_updated_of_several(self):
        Resume.objects.create(
            file=SimpleUploadedFile("old.pdf", b"%PDF-old", content_type="application/pdf")
        )
        newest = Resume.objects.create(
            file=SimpleUploadedFile("new.pdf", b"%PDF-new", content_type="application/pdf")
        )
        self.assertEqual(Resume.current(), newest)


class WorkSampleModelTests(TestCase):
    def test_str_is_title(self):
        sample = WorkSample.objects.create(title="wHNT", summary="Blockchain", description="...")
        self.assertEqual(str(sample), "wHNT")

    def test_ordering_by_order_then_id(self):
        # Same story as BlogPost: seed data means the table's never actually empty, so
        # compare relative order of just the rows this test created.
        second = WorkSample.objects.create(title="Z-second", summary="", description="", order=2)
        first = WorkSample.objects.create(title="Z-first", summary="", description="", order=1)
        ours = list(WorkSample.objects.filter(title__in=["Z-first", "Z-second"]))
        self.assertEqual(ours, [first, second])

    def test_default_display_type_is_image(self):
        sample = WorkSample.objects.create(title="X", summary="", description="")
        self.assertEqual(sample.display_type, WorkSample.DisplayType.IMAGE)


@override_settings(MEDIA_ROOT=TEMP_MEDIA_ROOT)
class PublicViewTests(TestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        # The two seeded WorkSample rows (0002_seed_work_samples.py) that still have a
        # real (non-blank) image — every WorkSample-displaying page renders these
        # alongside whatever a given test creates, and work_sample_item.html needs an
        # openable file at each path. EstiMate's seeded image was cleared by
        # 0007_estimate_backend_copy.py, so it isn't in this list.
        write_real_image("work_samples/wHNT.jpg", "JPEG")
        write_real_image("work_samples/bountydashboard-cover.png", "PNG")

    def test_home_page_loads(self):
        response = self.client.get(reverse("designWithCory"))
        self.assertEqual(response.status_code, 200)
        self.assertTemplateUsed(response, "landing.html")

    def test_home_page_shows_only_published_posts_capped_at_three(self):
        for i in range(4):
            make_blog_post(slug=f"post-{i}", published_at=timezone.now() - timedelta(days=i))
        make_blog_post(slug="unpublished", is_published=False)

        response = self.client.get(reverse("designWithCory"))
        recent_posts = list(response.context["recent_posts"])
        self.assertEqual(len(recent_posts), 3)
        self.assertTrue(all(p.is_published for p in recent_posts))

    def test_about_page_loads(self):
        response = self.client.get(reverse("about"))
        self.assertEqual(response.status_code, 200)

    def test_work_samples_page_loads(self):
        response = self.client.get(reverse("work_samples"))
        self.assertEqual(response.status_code, 200)

    def test_work_samples_page_includes_newly_created_samples_in_order(self):
        second = WorkSample.objects.create(title="Z-second", summary="", description="", order=2)
        first = WorkSample.objects.create(title="Z-first", summary="", description="", order=1)
        response = self.client.get(reverse("work_samples"))
        ours = [s for s in response.context["work_samples"] if s.pk in (first.pk, second.pk)]
        self.assertEqual(ours, [first, second])

    def test_blog_index_loads(self):
        response = self.client.get(reverse("blog_index"))
        self.assertEqual(response.status_code, 200)

    def test_blog_index_excludes_unpublished_posts(self):
        make_blog_post(slug="published", is_published=True)
        make_blog_post(slug="unpublished", is_published=False)
        response = self.client.get(reverse("blog_index"))
        slugs = [p.slug for p in response.context["posts"]]
        self.assertIn("published", slugs)
        self.assertNotIn("unpublished", slugs)

    def test_blog_detail_loads_for_published_post(self):
        make_blog_post(slug="my-post")
        response = self.client.get(reverse("blog_detail", args=["my-post"]))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.context["post"].slug, "my-post")

    def test_blog_detail_404s_for_unpublished_post(self):
        make_blog_post(slug="draft", is_published=False)
        response = self.client.get(reverse("blog_detail", args=["draft"]))
        self.assertEqual(response.status_code, 404)

    def test_blog_detail_404s_for_nonexistent_slug(self):
        response = self.client.get(reverse("blog_detail", args=["does-not-exist"]))
        self.assertEqual(response.status_code, 404)

    def test_resume_pdf_404s_when_no_resume_uploaded(self):
        # A seed migration puts a real Resume row (pointing at a file that doesn't exist in
        # this test's temp MEDIA_ROOT) into any freshly-migrated DB — clear it first so this
        # actually exercises the "nothing uploaded yet" path rather than a FileNotFoundError.
        Resume.objects.all().delete()
        response = self.client.get(reverse("resume_pdf"))
        self.assertEqual(response.status_code, 404)

    def test_resume_pdf_serves_the_current_resume(self):
        Resume.objects.create(
            file=SimpleUploadedFile("resume.pdf", b"%PDF-fake-bytes", content_type="application/pdf")
        )
        response = self.client.get(reverse("resume_pdf"))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response["Content-Type"], "application/pdf")
        self.assertIn("inline", response["Content-Disposition"])
        self.assertEqual(response["X-Content-Type-Options"], "nosniff")

    def test_robots_txt(self):
        response = self.client.get("/robots.txt")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response["Content-Type"], "text/plain")
        body = response.content.decode()
        self.assertIn("Disallow: /admin/", body)
        self.assertIn("Disallow: /resume/", body)
        self.assertIn("Allow: /", body)
