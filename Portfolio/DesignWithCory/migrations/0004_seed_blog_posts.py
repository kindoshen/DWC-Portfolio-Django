import datetime

from django.db import migrations
from django.utils import timezone

POSTS = [
    {
        "title": "The Pattern Atlas: 17 Design Patterns You Can Actually Verify",
        "slug": "design-pattern-atlas",
        "cover_image": "blog/pattern-atlas-cover.svg",
        "excerpt": (
            "Every design-patterns cheat sheet has the same problem: the code is pseudocode, or "
            "\"illustrative,\" or it just doesn't compile. I got tired of that, so I built one where "
            "every implementation is real, strict TypeScript that ran before it went on the page."
        ),
        "body": (
            "Every developer has bookmarked at least one design-patterns cheat sheet, and every one "
            "of those cheat sheets has the same problem: the code examples are pseudocode, or "
            "they're \"illustrative,\" or they just don't compile. You copy them in good faith and "
            "find out the hard way that the abstract factory example was never actually run.\n\n"
            "I got tired of that, so I built something different: a single HTML page covering all 17 "
            "classic Gang-of-Four patterns — five Creational, seven Structural, five Behavioral — "
            "where every implementation is real, strict TypeScript that was compiled and executed "
            "before it went on the page. Not plausible-looking code. Code that ran.\n\n"
            "Each pattern gets its own small \"circuit schematic\" — a little diagram showing which "
            "class calls which, drawn the way I'd actually explain it on a whiteboard, not the "
            "UML class-diagram version most references default to. The idea is you can look at the "
            "picture and get the shape of the pattern in five seconds, then read the actual "
            "TypeScript if you want the details.\n\n"
            "It's a tool I built for myself first — I reach for it more often than I expected to, "
            "mostly as a gut-check before I reach for a pattern I haven't used in a while. You can "
            "try it live on the Work Samples page."
        ),
    },
    {
        "title": "From Sketch to Screen: How a Project Actually Gets Built",
        "slug": "from-sketch-to-screen",
        "cover_image": "blog/from-sketch-to-screen-cover.png",
        "excerpt": (
            "Every engineer has their own process. Here's mine — from the first call to the deployed "
            "product — and why I think most of the risk in a project gets decided before anyone "
            "writes a line of code."
        ),
        "body": (
            "People ask what a typical project with me looks like, so here's the honest version, "
            "not the marketing version.\n\n"
            "It starts with a conversation, not a contract. I want to understand the business "
            "problem before I hear about the tech stack — what's actually broken, who it's broken "
            "for, and what \"fixed\" would look like in three months. A surprising number of "
            "projects get scoped wrong right here, because it's tempting to jump straight to "
            "solutions.\n\n"
            "Once I understand the need, I wireframe — low-fidelity, on purpose. It's much cheaper "
            "to argue about a box-and-arrow sketch than a finished screen, and it forces the real "
            "conversation about what the product does before anyone gets attached to how it "
            "looks.\n\n"
            "Then I build. This is the part people assume is the whole job, and it's maybe a third "
            "of it. I work in visible chunks — you see something running early and often, not a "
            "wall of silence followed by a big reveal at the end.\n\n"
            "Testing isn't a phase I bolt on afterward; it happens alongside development, against "
            "real edge cases, not just the happy path I designed for. And deployment isn't "
            "\"done\" — it's handoff: documentation, monitoring, and a walkthrough so you're not "
            "locked out of your own product.\n\n"
            "The through-line in all of it is the same question, asked at every stage: does this "
            "still match what we agreed to build? That's the difference between a project that "
            "ships on scope and one that quietly grows for six months."
        ),
    },
    {
        "title": "The Art of Branding (From an Engineer Who Isn't a Designer)",
        "slug": "the-art-of-branding",
        "cover_image": "blog/the-art-of-branding-cover.png",
        "excerpt": (
            "A logo isn't a brand — and neither is a design system, honestly. Here's how I think "
            "about brand consistency from the code side, where most of it actually gets enforced "
            "or quietly falls apart."
        ),
        "body": (
            "I'm not a brand designer, and I'd be lying if I said I picked the blue in this site's "
            "color palette for some deep strategic reason — I picked it because it looked right "
            "next to the logo. But I've shipped enough products to notice something: most of what "
            "makes a brand feel consistent, or fall apart, happens after the designer hands off "
            "the files, in decisions engineers make.\n\n"
            "A design system is only as strong as its enforcement. If the button component allows "
            "five different border-radius values because nobody locked it down, you'll have five "
            "different border radii in production within a month — not out of carelessness, but "
            "because deadlines beat vigilance every time. The brand isn't the design file; it's "
            "whatever the codebase actually lets people ship.\n\n"
            "The same is true past the UI. An API's error messages are part of the brand. So is "
            "how fast the site loads, and what happens when a form fails validation. None of that "
            "shows up in a style guide, but all of it shapes whether a product feels considered or "
            "slapped together.\n\n"
            "When I take on a project, I try to bake brand consistency into the things that are "
            "hard to violate by accident — shared components, a single source of truth for "
            "spacing and type, sensible defaults — rather than relying on everyone remembering the "
            "rules. It's less glamorous than picking a typeface, but it's usually the difference "
            "between a brand that holds up and one that erodes one deadline at a time."
        ),
    },
]


def seed_blog_posts(apps, schema_editor):
    BlogPost = apps.get_model("DesignWithCory", "BlogPost")
    base = timezone.make_aware(datetime.datetime(2026, 8, 21, 9, 0, 0))
    for i, post in enumerate(POSTS):
        BlogPost.objects.get_or_create(
            slug=post["slug"],
            defaults={**post, "published_at": base - datetime.timedelta(days=i * 7)},
        )


def remove_blog_posts(apps, schema_editor):
    BlogPost = apps.get_model("DesignWithCory", "BlogPost")
    BlogPost.objects.filter(slug__in=[p["slug"] for p in POSTS]).delete()


class Migration(migrations.Migration):

    dependencies = [
        ("DesignWithCory", "0003_blogpost"),
    ]

    operations = [
        migrations.RunPython(seed_blog_posts, remove_blog_posts),
    ]
