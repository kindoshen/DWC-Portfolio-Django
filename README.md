# Design With Cory

![Python](https://img.shields.io/badge/python-3.9%2B-blue)
![Django](https://img.shields.io/badge/django-4.2%20LTS-0C4B33)
![License](https://img.shields.io/badge/license-proprietary-red)
![Tests](https://img.shields.io/badge/tests-63%20passing-brightgreen)

The Django-powered source for [designwithcory.com](https://designwithcory.com) — a
personal portfolio and lightweight CRM for Cory Comly, senior software engineer,
blockchain consultant, and security analyst. Started life as a static Nicepage export;
this repo is the ongoing rebuild into a real Django application: dynamic blog and work
samples, a protected résumé viewer, and a Customer/Lead/Quote/Project pipeline behind
the contact form.

**This code is proprietary.** It is not open source, not for sale, and not available for
redistribution. See [License](#license).

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Installation](#quick-installation)
  - [macOS](#macos)
  - [Linux](#linux)
  - [Windows](#windows)
- [Environment Variables](#environment-variables)
- [Building](#building)
- [Testing](#testing)
- [Usage Examples](#usage-examples)
- [Pre-Deployment Checklist](#pre-deployment-checklist)
- [Deployment](#deployment)
  - [Docker (recommended)](#docker-recommended)
  - [Without Docker](#without-docker)
- [Project Structure](#project-structure)
- [Third-Party Libraries](#third-party-libraries)
- [Contributors](#contributors)
- [Feedback / Reporting Issues](#feedback--reporting-issues)
- [License](#license)

---

## Overview

Two Django apps do the work:

- **`DesignWithCory`** — the public site: home, About, Work Samples, Blog (index +
  detail), the résumé viewer, `robots.txt`, and `sitemap.xml`.
- **`crm`** — Customer / Lead / Quote / Project, wired to the public contact form. Every
  submission becomes a `Customer` (deduplicated by email) and a `Lead`; Notes and file
  Attachments can be logged against any of the four models from the Django admin via a
  shared generic-relation mixin.

The frontend is a hand-modified Nicepage export — `nicepage.css`/`nicepage.js` are the
vendored framework/theme, `pages.css` holds everything hand-authored for the pages that
don't come from that export (About, Work Samples, Blog). There's no separate frontend
build step or JS framework: templates render server-side, a handful of small vanilla-JS
files (contact form submission, the résumé PDF.js viewer) progressively enhance them.

## Prerequisites

- **Python 3.8–3.12** — this is a hard ceiling, not a suggestion: Django 4.2 doesn't
  support 3.13+, and it fails *late and cryptically* rather than refusing to start (a
  bare `python -m venv env` against whatever `python3` happens to be on `PATH` is enough
  to hit this if that's a newer interpreter — `manage.py` now checks and fails fast with
  a clear message instead). `.python-version` in the repo root pins 3.12 for any tool
  that reads it (pyenv, uv, some IDEs) — `python3.12 -m venv env` if creating by hand
- **pip** (ships with Python)
- **git**
- **Docker & Docker Compose**, if you're taking the [Docker deployment path](#docker-recommended)
  — not required for local development
- A **PostgreSQL 14+** server, if you're running Postgres locally *without* Docker

SQLite (Python's standard library, no install needed) is enough for local development.
Production is expected to run Postgres — see [Deployment](#deployment).

## Quick Installation

Every OS follows the same shape: clone, create a virtualenv, install dependencies, copy
the env file, migrate, create an admin user, run the server.

### macOS

```bash
git clone git@github.com:kindoshen/DWC-Portfolio-Django.git
cd DWC-Portfolio-Django
python3 -m venv env
source env/bin/activate
pip install -r requirements.txt
cp .env.example .env          # then edit .env — see Environment Variables below
cd Portfolio
python manage.py migrate
python manage.py createsuperuser
python manage.py runserver
```

### Linux

```bash
git clone git@github.com:kindoshen/DWC-Portfolio-Django.git
cd DWC-Portfolio-Django
python3 -m venv env
source env/bin/activate
pip install -r requirements.txt
cp .env.example .env          # then edit .env — see Environment Variables below
cd Portfolio
python manage.py migrate
python manage.py createsuperuser
python manage.py runserver
```

(Debian/Ubuntu users without a system Python venv module yet: `sudo apt install
python3-venv` first.)

### Windows

PowerShell:

```powershell
git clone git@github.com:kindoshen/DWC-Portfolio-Django.git
cd DWC-Portfolio-Django
python -m venv env
.\env\Scripts\Activate.ps1
pip install -r requirements.txt
copy .env.example .env        # then edit .env — see Environment Variables below
cd Portfolio
python manage.py migrate
python manage.py createsuperuser
python manage.py runserver
```

Command Prompt (`cmd.exe`), if you're not using PowerShell:

```bat
git clone git@github.com:kindoshen/DWC-Portfolio-Django.git
cd DWC-Portfolio-Django
python -m venv env
env\Scripts\activate.bat
pip install -r requirements.txt
copy .env.example .env
cd Portfolio
python manage.py migrate
python manage.py createsuperuser
python manage.py runserver
```

Once it's running, the site is at **http://127.0.0.1:8000/** and the admin at
**http://127.0.0.1:8000/admin/**.

## Environment Variables

Everything is read from `os.environ` in `Portfolio/Portfolio/settings.py` — there's no
`.env`-loading library in play, so however you set these (a real `.env` + your shell/OS,
Docker Compose's `environment:`, your host's dashboard) just needs to land in the
process environment before Django starts. Copy `.env.example` to `.env` as a starting
point for local dev.

| Variable | Required? | Default | Purpose |
|---|---|---|---|
| `DJANGO_SECRET_KEY` | **Yes in production** | insecure dev-only key | Django's cryptographic signing key. Production (`DJANGO_DEBUG=False`) refuses to start without this set — see `settings.py`. Generate one with `python -c "import secrets; print(secrets.token_urlsafe(50))"`. |
| `DJANGO_DEBUG` | No | `False` | `True` enables Django's debug mode (tracebacks, no security headers). Only ever set `True` locally. |
| `DJANGO_ALLOWED_HOSTS` | **Yes in production** | *(empty)* | Comma-separated hostnames, e.g. `designwithcory.com,www.designwithcory.com`. |
| `DJANGO_CSRF_TRUSTED_ORIGINS` | If behind a proxy/custom domain | *(empty)* | Comma-separated origins, e.g. `https://designwithcory.com`. |
| `DJANGO_SECURE_SSL_REDIRECT` | No | `True` (when `DEBUG=False`) | Set `False` if TLS terminates somewhere this app can't see via `X-Forwarded-Proto`. |
| `DJANGO_HSTS_SECONDS` | No | `31536000` (1 year) | HTTP Strict Transport Security max-age. |
| `DJANGO_BEHIND_PROXY` | No | `True` | Whether to trust `X-Forwarded-Proto` for SSL detection — the normal case behind a load balancer/reverse proxy. |
| `DATABASE_URL` | No | *(unset → SQLite)* | A standard `postgres://user:pass@host:port/dbname` URL. Unset, the app falls back to a local `db.sqlite3` — fine for development, not for production. |
| `DJANGO_EMAIL_HOST` | No | *(unset → console backend)* | SMTP host. Unset, outgoing mail (contact-form notifications, admin error alerts) just prints to the console — fine for development. |
| `DJANGO_EMAIL_PORT` | No | `587` | SMTP port. |
| `DJANGO_EMAIL_HOST_USER` / `DJANGO_EMAIL_HOST_PASSWORD` | If `DJANGO_EMAIL_HOST` is set | *(empty)* | SMTP credentials. |
| `DJANGO_EMAIL_USE_TLS` | No | `True` | |
| `DJANGO_DEFAULT_FROM_EMAIL` | No | `Inquiry@DesignWithCory.com` | The "from" address on outgoing mail, and the public contact email shown in the footer/contact section. |
| `DJANGO_CONTACT_NOTIFICATION_EMAIL` | No | same as `DJANGO_DEFAULT_FROM_EMAIL` | Where new-lead notification emails from the contact form are sent. |
| `DJANGO_ADMIN_EMAIL` | No | *(unset → no error emails)* | If set, Django emails a full traceback here on any unhandled server error (only with `DEBUG=False` and real SMTP configured). |
| `DJANGO_SERVER_EMAIL` | No | same as `DJANGO_DEFAULT_FROM_EMAIL` | The "from" address on those error emails specifically. |

## Building

"Building" a Django project mostly means making sure the database schema and static
files are current — there's no separate frontend compile step.

```bash
cd Portfolio
python manage.py migrate            # apply any pending database migrations
python manage.py collectstatic --noinput   # gather static files into STATIC_ROOT (productionfiles/)
```

`collectstatic` only matters for a real deployment (WhiteNoise serves from
`STATIC_ROOT` in production); the dev server serves static files directly from each
app's `static/` directory without it.

## Testing

```bash
cd Portfolio
python manage.py test
```

63 tests, 100% line coverage on both apps' non-migration code as of this writing. To
check coverage yourself:

```bash
pip install -r ../requirements-dev.txt   # adds the `coverage` package
coverage run manage.py test
coverage report                          # add -m to see which lines, if any, are missed
```

Both apps' `tests.py` prioritize the one real user-contributed-data surface in the
project — `crm.forms.ContactForm` / `crm.views.contact_submit` — plus model behavior
(ordering, cascade deletes, computed properties) and every public view, including its
404 paths.

## Usage Examples

**Submit the contact form from the command line** (useful for smoke-testing a deploy —
note this needs the honeypot field, `website`, sent empty, and a real CSRF token/cookie
pair from a prior GET):

```bash
curl -s -c cookies.txt http://localhost:8000/ -o /dev/null
CSRF=$(grep csrftoken cookies.txt | awk '{print $7}')
curl -s -b cookies.txt -X POST http://localhost:8000/contact/submit/ \
  -H "X-CSRFToken: $CSRF" \
  --data-urlencode "csrfmiddlewaretoken=$CSRF" \
  --data-urlencode "name=Jamie Rivera" \
  --data-urlencode "email=jamie@example.com" \
  --data-urlencode "phone=555-0100" \
  --data-urlencode "message=Interested in a quote" \
  --data-urlencode "website="
```

**Add a new blog post or work sample:** everything is admin-managed — log in at
`/admin/`, add a `BlogPost` (or `WorkSample`) row. No template/code changes needed for
new content; `display_type` on `WorkSample` picks the layout (`image`/`iframe` alternate
left/right down the page, `grandiose` breaks out full-width for a complex multi-view
app).

**Attach a note or file to a lead:** open the `Lead` in `/admin/crm/`; the Notes and
Attachments inlines are on every Customer/Lead/Quote/Project admin page via the shared
`Attachable` mixin.

**Run a single test:**

```bash
python manage.py test crm.tests.ContactSubmitViewTests.test_valid_submission_creates_customer_and_lead
```

## Pre-Deployment Checklist

Before pointing real traffic at this:

- [ ] `DJANGO_SECRET_KEY` set to a freshly generated value (not the dev fallback)
- [ ] `DJANGO_DEBUG` unset or explicitly `False`
- [ ] `DJANGO_ALLOWED_HOSTS` set to your real domain(s)
- [ ] `DJANGO_CSRF_TRUSTED_ORIGINS` set if serving over a custom domain
- [ ] `DATABASE_URL` pointed at a real Postgres instance, not SQLite
- [ ] `DJANGO_EMAIL_HOST` (+ credentials) set to real SMTP, or contact-form leads will
      only ever "arrive" in a log nobody reads
- [ ] `DJANGO_ADMIN_EMAIL` set so you actually hear about unhandled 500s
- [ ] `python manage.py migrate` run against the production database
- [ ] `python manage.py collectstatic --noinput` run
- [ ] `python manage.py check --deploy` run with production env vars set, and its
      warnings addressed or consciously accepted
- [ ] A superuser created (`python manage.py createsuperuser`) and the Resume/WorkSample/
      BlogPost cover images re-uploaded through the admin — `media/` is gitignored like
      all user-uploaded content, so it does not travel with the repo to a fresh deploy

## Deployment

### Docker (recommended)

> Deploying to a real server (not just running the stack locally)? See
> [DEPLOYMENT.md](DEPLOYMENT.md) for the full, security-conscious walkthrough — droplet
> hardening, a GitHub deploy key, nginx + TLS, backups, all of it. This section is the
> quick version for people who already have a server and just need the `docker compose`
> commands.

The included `docker-compose.yml` runs the app behind Gunicorn with a Postgres 16
container — the whole stack, one command:

```bash
cp .env.example .env      # fill in real values per the table above, including a
                           # generated DJANGO_SECRET_KEY and POSTGRES_PASSWORD
docker compose build
docker compose up -d
docker compose exec web python manage.py migrate
docker compose exec web python manage.py createsuperuser
```

The app is served on the port set by `WEB_PORT` in `.env` (default `8000`). Postgres
data persists in a named Docker volume (`postgres_data`) across restarts —
`docker compose down` leaves it intact; `docker compose down -v` does not.

To rebuild after pulling code changes:

```bash
docker compose build web
docker compose up -d
docker compose exec web python manage.py migrate
```

Logs: `docker compose logs -f web`.

### Without Docker

1. Provision a Postgres 14+ database and set `DATABASE_URL` accordingly.
2. Follow [Quick Installation](#quick-installation) for your OS through `pip install`.
3. Set every variable in the [Pre-Deployment Checklist](#pre-deployment-checklist).
4. `python manage.py migrate && python manage.py collectstatic --noinput`.
5. Run the app with a real WSGI server — **not** `manage.py runserver`, which is
   dev-only:
   ```bash
   pip install gunicorn
   gunicorn Portfolio.wsgi:application --bind 0.0.0.0:8000 --workers 3
   ```
6. Put a reverse proxy (nginx, Caddy, your host's load balancer) in front of it for TLS
   termination, and point `DJANGO_ALLOWED_HOSTS`/`DJANGO_CSRF_TRUSTED_ORIGINS` at the
   real domain.
7. `media/` (user-uploaded content — résumé, blog covers, work-sample images, CRM
   attachments) needs somewhere to live that survives a redeploy: a persistent volume,
   or swap in a cloud storage backend (e.g. `django-storages`) — it is **not** committed
   to this repo.

## Project Structure

```
DWC-Portfolio-Django/
├── Portfolio/                  # Django project root (manage.py lives here)
│   ├── Portfolio/              # settings.py, urls.py, wsgi.py, asgi.py
│   ├── DesignWithCory/         # the public site app
│   │   ├── templates/          # base.html + page templates + includes/
│   │   ├── static/             # css/ (nicepage.css + pages.css), js/, images/, favicon/
│   │   ├── migrations/         # schema + seed-content data migrations
│   │   ├── models.py           # BlogPost, Resume, WorkSample
│   │   ├── views.py            # public views, robots.txt, sitemap wiring
│   │   └── validators.py       # shared upload validators (used by crm too)
│   ├── crm/                    # Customer/Lead/Quote/Project
│   │   ├── models.py
│   │   ├── forms.py            # ContactForm
│   │   ├── views.py            # contact_submit
│   │   └── admin.py
│   ├── media/                  # user-uploaded content (gitignored)
│   └── productionfiles/        # collectstatic output (gitignored)
├── requirements.txt
├── requirements-dev.txt
├── docker-compose.yml
├── Dockerfile
└── .env.example
```

## Third-Party Libraries

| Library | Purpose | License |
|---|---|---|
| [Django](https://github.com/django/django) | Web framework | BSD-3-Clause |
| [WhiteNoise](https://github.com/evansd/whitenoise) | Serves static files directly from the app in production | MIT |
| [Pillow](https://github.com/python-pillow/Pillow) | Image processing/validation for uploaded images | MIT-CMU |
| [django-ratelimit](https://github.com/jsocol/django-ratelimit) | Rate limiting on the public contact-form endpoint | Apache-2.0 |
| [PDF.js](https://github.com/mozilla/pdf.js) | Renders the résumé to `<canvas>` in the protected viewer (vendored in `static/js/pdfjs/`, not installed via pip) | Apache-2.0 |
| [psycopg](https://github.com/psycopg/psycopg2) | PostgreSQL adapter | LGPL |
| [gunicorn](https://github.com/benoitc/gunicorn) | Production WSGI server (Docker image) | MIT |
| [coverage.py](https://github.com/nedbat/coveragepy) | Test coverage measurement (dev-only) | Apache-2.0 |

The original site design/markup started as a [Nicepage](https://nicepage.com/) export;
`nicepage.css`/`nicepage.js` remain as the vendored theme framework, credited via the
site's own footer attribution link.

## Contributors

- **Cory Comly** — [github.com/kindoshen](https://github.com/kindoshen) — sole author
  and maintainer

## Feedback / Reporting Issues

This is a private, proprietary repository without a public issue tracker. For bugs,
questions, or feedback:

- Email **Inquiry@DesignWithCory.com**, or
- If you have access to this repository, open a GitHub issue or reach the maintainer
  directly at cory.comly@icloud.com

## License

Proprietary — all rights reserved. **Not open source. Not for sale or redistribution.**
See [`LICENSE`](LICENSE) for the full text. Third-party dependencies (above) remain
under their own respective licenses.
