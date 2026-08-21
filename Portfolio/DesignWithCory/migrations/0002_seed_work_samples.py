from django.db import migrations

SAMPLES = [
    {
        "title": "wHNT — a decentralized bridge for Helium",
        "summary": "Blockchain / DeFi",
        "description": (
            "Helium gives the world a decentralized, people-powered wireless network — but its most "
            "loyal supporters, the HNT miners and holders, still had to rely on centralized exchanges "
            "just to use their earnings. We built a bridge that converts HNT into Wrapped HNT (wHNT) on "
            "EVM-compatible chains, opening it up to the broader DeFi market so holders can buy, sell, "
            "and earn yield on their tokens without giving up custody to an exchange."
        ),
        "display_type": "image",
        "image": "work_samples/wHNT.jpg",
        "order": 10,
    },
    {
        "title": "The Pattern Atlas",
        "summary": "Interactive reference / TypeScript",
        "description": (
            "A single-page reference covering all 17 classic Gang-of-Four design patterns — Creational, "
            "Structural, and Behavioral — each one demonstrated with a working, verified TypeScript "
            "implementation instead of a textbook diagram. Built as a fast, dependency-free tool I "
            "actually reach for; try it live below."
        ),
        "display_type": "iframe",
        "embed_url": "/static/lab/pattern-atlas.html",
        "order": 20,
    },
    {
        "title": "EstiMate",
        "summary": "iOS / Android app — React Native",
        "description": (
            "A job-estimating app built for a painting contractor who was still quoting jobs on paper. "
            "EstiMate turns a walkthrough into a line-itemized quote on the spot — leads, properties, "
            "quotes, and a day-sheet of the week's jobs, all in one place, with signed estimates and "
            "price changes tracked automatically instead of living in someone's truck."
        ),
        "display_type": "grandiose",
        "image": "work_samples/estimate-thumbnail.png",
        "order": 30,
    },
    {
        "title": "PwnHub",
        "summary": "Security tooling / Django",
        "description": (
            "A high-efficiency, high-automation workstation for bug-bounty work — built to take the "
            "repetitive parts of recon and traffic analysis off my plate so I can spend the time on the "
            "part that actually needs a human. Runs on Celery workers and Redis/Postgres, drives "
            "Selenium for automated crawling, and captures traffic through mitmproxy, all orchestrated "
            "through Docker/Kubernetes."
        ),
        "display_type": "image",
        "image": "work_samples/bountydashboard-cover.png",
        "order": 40,
    },
]


def seed_work_samples(apps, schema_editor):
    WorkSample = apps.get_model("DesignWithCory", "WorkSample")
    for sample in SAMPLES:
        WorkSample.objects.get_or_create(title=sample["title"], defaults=sample)


def remove_work_samples(apps, schema_editor):
    WorkSample = apps.get_model("DesignWithCory", "WorkSample")
    WorkSample.objects.filter(title__in=[s["title"] for s in SAMPLES]).delete()


class Migration(migrations.Migration):

    dependencies = [
        ("DesignWithCory", "0001_initial"),
    ]

    operations = [
        migrations.RunPython(seed_work_samples, remove_work_samples),
    ]
