from django.db import migrations

NEW_DESCRIPTION = (
    "A job-estimating app built for a painting contractor who was still quoting jobs on paper. "
    "EstiMate turns a walkthrough into a line-itemized quote on the spot — leads, properties, "
    "quotes, and a day-sheet of the week's jobs, all in one place, with signed estimates and "
    "price changes tracked automatically instead of living in someone's truck. The backend is a "
    "set of dockerized, TypeScript-based Node.js services behind a monitored load balancer — "
    "sized to grow the boring way, adding endpoints as demand does, but built to scale "
    "horizontally so a Saturday-morning rush of quote requests never turns into a spinner."
)

OLD_DESCRIPTION = (
    "A job-estimating app built for a painting contractor who was still quoting jobs on paper. "
    "EstiMate turns a walkthrough into a line-itemized quote on the spot — leads, properties, "
    "quotes, and a day-sheet of the week's jobs, all in one place, with signed estimates and "
    "price changes tracked automatically instead of living in someone's truck."
)


def update_estimate(apps, schema_editor):
    WorkSample = apps.get_model("DesignWithCory", "WorkSample")
    # image cleared: the "grandiose" branch now renders a bespoke multi-device showcase for this
    # sample instead of the flat screenshot (see includes/estimate_device_showcase.html).
    WorkSample.objects.filter(title="EstiMate").update(description=NEW_DESCRIPTION, image="")


def revert_estimate(apps, schema_editor):
    WorkSample = apps.get_model("DesignWithCory", "WorkSample")
    WorkSample.objects.filter(title="EstiMate").update(
        description=OLD_DESCRIPTION, image="work_samples/estimate-thumbnail.png"
    )


class Migration(migrations.Migration):

    dependencies = [
        ("DesignWithCory", "0006_seed_resume"),
    ]

    operations = [
        migrations.RunPython(update_estimate, revert_estimate),
    ]
