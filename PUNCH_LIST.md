# Punch List

A living audit of this codebase — what's been checked, what was found, and what's still
open. This replaces the informal, chat-only audit from earlier in the project's history
with an actual file so findings don't get lost between sessions. Re-run this kind of pass
periodically (after a version bump, before a real production push, etc.) rather than
treating it as a one-time checklist.

**Last full pass:** 2026-08-29, against Django 6.0.8 / commit range up through the
Creations page, the Work Samples iframe rework, and the Django 6 upgrade.

---

## Fixed this pass

| # | Category | Finding | Fix |
|---|---|---|---|
| 1 | Correctness | `crm/views.py` imported `json` and never used it (confirmed via `pyflakes`) — harmless, but dead weight and a "wait, where's this used?" for the next reader. | Removed the import. |
| 2 | Correctness | `DesignWithCory/sitemaps.py`'s `StaticViewSitemap` defined **both** a `priority = 0.7` class attribute *and* a `def priority(self, item)` method in the same class body. The method silently shadows the attribute — Python just keeps the last binding — so the `0.7` on the attribute line was **dead and unreachable**, not a "default" the method fell back to as its own comment implied. | Removed the dead attribute; rewrote the method's comment to say plainly that `0.7` only lives in one place now. |
| 3 | Docs drift | Six files still said "Django 4.2" in doc-comment URLs and version strings after the [Django 6.0.8 upgrade](../../commit/33dc700) — `settings.py`'s docstring + 6 internal `docs.djangoproject.com/en/4.2/...` links, `urls.py`, `asgi.py`, `wsgi.py`, `base.html`'s header comment, and README's Django badge. The upgrade commit only touched the two links closest to the code it actually changed. | All `/en/4.2/` links repointed to `/en/6.0/`; `settings.py`'s docstring annotated with the upgrade note instead of silently rewritten (it's genuinely historical — Django *did* originally scaffold this at 4.2.30); `base.html` and the README badge updated to 6.0. |
| 4 | Build script | `utils/deploy-droplet.sh` calls `git clone` in `phase_clone_and_env` but never installs `git` anywhere in the script — the Docker install phase pulls in `docker-ce`/`docker-compose-plugin`, none of which depend on `git`. A truly minimal droplet image would fail at that phase. | Added an upfront `apt-get install -y rsync git curl ca-certificates` at the very start of `phase_root_bootstrap` (see #5 for why `rsync` is in that list too). |
| 5 | Build script | Both `utils/deploy-droplet.sh` and `utils/deploy-monolith.sh` call `rsync` in `phase_root_bootstrap` (to copy `root`'s `authorized_keys` to the new deploy user) **before any apt-get phase has run** — `rsync` is a common omission on minimal cloud images, unlike core utilities. `deploy-monolith.sh` additionally never installs `curl` anywhere, despite using it starting in `phase_dns_check`. | Both scripts now `apt-get install` their first-needed packages (`rsync`, `curl`, and — droplet script only — `git`) at the top of `phase_root_bootstrap`, before first use. |
| 6 | Repo layout | The two deployment scripts lived at the repo root alongside application config, easy to mistake for part of the app itself rather than standalone droplet-bootstrap tooling. | Moved both into `utils/` (`utils/deploy-droplet.sh`, `utils/deploy-monolith.sh`). Updated every reference: their own `curl -fsSL .../main/...` download URLs, `DEPLOYMENT.md`'s link, and README's Deployment section and Project Structure diagram. `run.sh` (the local dev-server launcher) was deliberately **left at the repo root** — see "Known / open items" below for why. |
| 7 | Comment clarity | `resume-viewer.js`'s `watermark()` used a nested loop with four magic numbers (`-canvas.height` start, `90`/`260` step, `-30°` rotation) and no explanation of why the loop bounds overshoot the canvas. | Added a comment explaining the translate+rotate-then-plain-grid technique and why the loop starts negative (so the rotated tiling still covers every corner, not just a centered patch). |
| 8 | README drift | Multiple: Python/Django version badges (3.9+/4.2 → still said the old floor after the Django 6 upgrade); Overview didn't mention the Creations page at all; Third-Party Libraries table was missing `dj-database-url` (in `requirements.txt` and load-bearing in `settings.py`, just never added to the table); the `gunicorn` row said "(Docker image)" even though the new monolith path uses it directly too; Deployment section had no mention of `deploy-monolith.sh` anywhere; Project Structure diagram predated `utils/`, `static/lab/`, `static/css/creations.css`, and the `Attachable` mixin. | All updated — see the README diff in this same change. |
| 9 | Accuracy | README claimed "100% line coverage" — no longer true. Actual: **95%** (`coverage report`, Django 6.0.8, 63 tests). Newer code shipped without matching tests: `DesignWithCory/sitemaps.py` (72%), `validators.py` (47%), `views.py` (97%, missing the `creations` view entirely), `crm/forms.py` (88%), `crm/views.py` (96%). | README corrected to state 95% and point here instead of repeating a stale number. **Not fixed** — see below; writing the missing tests is real, separate work, not a doc fix. |

---

## Known / open items (found, not fixed this pass)

These are real gaps, deliberately left as follow-up work rather than folded into a
documentation/cleanup pass:

- **Test coverage regression (95%, was 100%).** Concretely missing:
  - `DesignWithCory/views.py`: the `creations` view (line 75) has **zero** test coverage
    — the entire Creations page feature ships untested, despite the amount of custom
    JS/CSS behavior (two-tier modal, resize handling, focus trap) behind it.
  - `DesignWithCory/validators.py`: the actual *rejection* branches of
    `validate_image_upload_size` / `validate_document_upload_size` (an over-limit file)
    and all of `validate_embed_url` are untested — only the trivial
    `FileExtensionValidator` instantiations are exercised indirectly.
  - `DesignWithCory/sitemaps.py`: no test ever hits `/sitemap.xml` or exercises either
    `Sitemap` subclass directly.
  - `crm/forms.py` (88%) / `crm/views.py` (96%): the honeypot/timing anti-spam
    rejection paths and the rate-limited (`429`) response are only partially covered.
- **`run.sh` was not moved into `utils/`.** It's a local dev-server convenience launcher
  (loads `.env`, execs `manage.py runserver`), not deployment automation — moving it
  would also require rewriting its `cd "$(dirname "${BASH_SOURCE[0]}")"` logic (currently
  correct because the script lives at repo root, where `.env`/`env/`/`Portfolio/` all
  are) and updating `.claude/launch.json`'s path to it. Judgment call: left in place as
  out of scope for "build scripts."
- **The monolith path's SQLite default doesn't horizontally scale** — by design (see
  `utils/deploy-monolith.sh`'s own header comment) and fine for this project's actual
  traffic, but worth remembering if traffic ever justifies revisiting it. The script
  already supports pointing `DATABASE_URL` at an external Postgres instead, with no code
  changes needed.
- **The résumé viewer's watermark is not real DRM** — already stated plainly in both the
  code comments and README; repeated here only so it stays on this list rather than
  getting rediscovered as a "vulnerability."

## Verified clean this pass

Checked and found no issues (worth recording so the *next* audit doesn't re-derive this
from scratch):

- No `TODO`/`FIXME`/`XXX`/`HACK` markers anywhere in first-party code (only in vendored
  `productionfiles/admin/` — Django's own shipped admin assets — and the vendored jQuery/
  xregexp bundles, none of which this project should be editing).
- No `Lorem ipsum` or other obvious placeholder copy anywhere in templates or Python.
- `pyflakes` clean across `DesignWithCory/`, `crm/`, and `Portfolio/` aside from the two
  findings above (now fixed).
- `manage.py check` and `manage.py check --deploy` both clean under real production-shaped
  env vars.
- `ModelAdmin.autocomplete_fields` targets (`Lead→Customer`, `Quote→Lead`,
  `Project→Quote`) each have a corresponding `search_fields` on the target's own
  `ModelAdmin` — this is a real Django system-check requirement (admin.E040) and easy to
  get wrong when adding a new `autocomplete_fields` entry later; already correct
  everywhere it's used.
- `favicon.ico` (referenced by a hard redirect in `Portfolio/urls.py`) genuinely exists
  and is a valid multi-resolution icon — an earlier planning note in this project's
  history said it had been skipped for lack of tooling; it was generated anyway and is
  fine.
- `shellcheck` clean on both `utils/*.sh` (three pre-existing, reviewed-and-accepted
  notes: a tilde inside a human-readable string, apt's own `${distro_id}` config syntax
  that must *not* be shell-expanded, and an unfollowed `/etc/os-release` source — all
  intentional).
