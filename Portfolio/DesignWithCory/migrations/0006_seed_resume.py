from django.db import migrations


def seed_resume(apps, schema_editor):
    Resume = apps.get_model("DesignWithCory", "Resume")
    if not Resume.objects.exists():
        Resume.objects.create(file="resume/cory-comly-resume.pdf")


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
