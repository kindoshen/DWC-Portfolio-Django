from django.db import migrations


def seed_resume(apps, schema_editor):
    Resume = apps.get_model("DesignWithCory", "Resume")
    # get_or_create keyed on the specific file, not "any Resume exists" — the latter
    # would silently no-op on a fresh DB that already has a *different* Resume row from
    # some other seed path, leaving this specific file never created.
    Resume.objects.get_or_create(file="resume/cory-comly-resume.pdf")


def remove_resume(apps, schema_editor):
    Resume = apps.get_model("DesignWithCory", "Resume")
    Resume.objects.filter(file="resume/cory-comly-resume.pdf").delete()


class Migration(migrations.Migration):

    dependencies = [
        ("DesignWithCory", "0005_resume"),
    ]

    operations = [
        migrations.RunPython(seed_resume, remove_resume),
    ]
