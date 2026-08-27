# Deploying to a DigitalOcean Droplet

A start-to-finish, security-conscious walkthrough for taking this app from "code on GitHub"
to "running in production" on a fresh Ubuntu 24.04 (Noble Numbat) droplet — Docker Compose
stack, Postgres, a hardened host, a real TLS certificate, and a repeatable update process.

This is the detailed operational runbook. [README.md](README.md) covers the app itself
(env vars, local dev, testing) — this file assumes you've read that and is specific to
*this* hosting path. Where the two overlap (the `docker compose` commands themselves),
this file is the authority on production specifics; README's Docker section is the quick
version for people who already have a server.

**[`deploy-droplet.sh`](deploy-droplet.sh)** automates sections 3 through 13 below (plus
the backup cron from section 15 and a live security recap from section 17), in the same
order, for the same reasons — run it and skip straight to reading along as it goes, or
read the sections below first and run the commands yourself by hand. Either is fine; the
script is just this document, executed. What it deliberately still stops and asks a human
for — adding the deploy key to GitHub, the DigitalOcean Cloud Firewall, DNS — is called
out explicitly at the top of the script and in the matching sections below.

## Table of Contents

1. [What you'll need before starting](#1-what-youll-need-before-starting)
2. [Create the droplet](#2-create-the-droplet)
3. [First login and a non-root user](#3-first-login-and-a-non-root-user)
4. [Harden SSH](#4-harden-ssh)
5. [Firewall (UFW + DigitalOcean Cloud Firewall)](#5-firewall-ufw--digitalocean-cloud-firewall)
6. [fail2ban, automatic updates, swap](#6-fail2ban-automatic-updates-swap)
7. [Install Docker Engine](#7-install-docker-engine)
8. [Authenticate the droplet with GitHub (deploy key)](#8-authenticate-the-droplet-with-github-deploy-key)
9. [Clone the repo and configure `.env`](#9-clone-the-repo-and-configure-env)
10. [Point DNS at the droplet](#10-point-dns-at-the-droplet)
11. [nginx reverse proxy + Let's Encrypt TLS](#11-nginx-reverse-proxy--lets-encrypt-tls)
12. [Build and launch the stack](#12-build-and-launch-the-stack)
13. [Verify the deployment](#13-verify-the-deployment)
14. [Deploying updates](#14-deploying-updates)
15. [Backups](#15-backups)
16. [Monitoring, logs, and housekeeping](#16-monitoring-logs-and-housekeeping)
17. [Security checklist (recap)](#17-security-checklist-recap)
18. [Optional next steps](#18-optional-next-steps)

---

## 1. What you'll need before starting

- A DigitalOcean account with billing set up.
- A domain name you control, with access to its DNS records (a registrar or a service
  like Cloudflare). You can technically deploy without one and reach the app by IP, but
  you cannot get a real TLS certificate for a bare IP — get a domain first.
- A local machine with an SSH key pair. If you don't have one:
  ```bash
  ssh-keygen -t ed25519 -C "your-email@example.com"
  ```
  This is the key you'll log into the *droplet* with — different from the deploy key the
  droplet itself will use to talk to GitHub (step 8).
- Write access to the `kindoshen/DWC-Portfolio-Django` GitHub repo, and its Settings page
  (to add a deploy key).
- About an hour, uninterrupted, the first time through.

---

## 2. Create the droplet

**Via the DigitalOcean web console** (Create → Droplets):

- **Image:** Ubuntu 24.04 (LTS) x64
- **Plan:** Basic, Regular (shared CPU). This app is a small Django site + one Postgres
  instance — **2 GB RAM / 1 vCPU** is a comfortable minimum once nginx, Gunicorn, and
  Postgres are all running side by side; go up if you expect real traffic.
- **Datacenter region:** whichever is geographically closest to your users.
- **Authentication:** **SSH Key** — select the public key matching the pair from step 1
  (upload it here if DigitalOcean doesn't already have it). Do **not** choose Password
  authentication; you're about to disable it anyway (step 4), and starting keyless just
  means a window where a password-brute-forceable droplet is on the public internet.
- **Hostname:** something recognizable, e.g. `designwithcory-prod`.

**Or via `doctl`** (DigitalOcean's CLI), if you'd rather script it:

```bash
doctl compute droplet create designwithcory-prod \
  --image ubuntu-24-04-x64 \
  --size s-1vcpu-2gb \
  --region nyc3 \
  --ssh-keys <your-ssh-key-fingerprint-or-id> \
  --wait
```

Either way, note the droplet's public IPv4 address when it's up — everything below refers
to it as `$DROPLET_IP`.

---

## 3. First login and a non-root user

```bash
ssh root@$DROPLET_IP
```

Running everything as `root` going forward is exactly the habit you don't want on a
server that's about to hold a database and a `SECRET_KEY`. Create a real user with sudo
rights and switch to it immediately:

```bash
adduser deploy               # pick a strong password even though you'll disable password
                              # SSH shortly — sudo still prompts for it locally
usermod -aG sudo deploy

# Copy your SSH key over so `deploy` can log in the same way root just did
rsync --archive --chown=deploy:deploy ~/.ssh /home/deploy

exit
ssh deploy@$DROPLET_IP       # confirm this works BEFORE touching sshd_config
```

Don't proceed past this point until `ssh deploy@$DROPLET_IP` logs you in without a
password prompt (key-based). If it doesn't, fix that first — the next step locks root
and password auth out entirely.

---

## 4. Harden SSH

```bash
sudo nano /etc/ssh/sshd_config
```

Set (or confirm) these:

```
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
```

Ubuntu 24.04's OpenSSH also reads `/etc/ssh/sshd_config.d/*.conf`, which can silently
override what you just set — check for a conflicting drop-in:

```bash
grep -r "PermitRootLogin\|PasswordAuthentication" /etc/ssh/sshd_config.d/ 2>/dev/null
```

If DigitalOcean's cloud-init dropped a `50-cloud-init.conf` in there with its own
`PasswordAuthentication` line, edit that instead (or delete it — `sshd_config` itself
will govern once it's gone).

Apply and verify before you disconnect:

```bash
sudo systemctl restart ssh
```

**Open a second terminal now** and confirm `ssh deploy@$DROPLET_IP` still works, and that
`ssh root@$DROPLET_IP` and a password prompt are both now refused, *before* closing your
first session. If something's wrong, your still-open first session is your only way back
in without a DigitalOcean console recovery.

---

## 5. Firewall (UFW + DigitalOcean Cloud Firewall)

Two layers, deliberately redundant — UFW on the host, and DigitalOcean's Cloud Firewall
in front of it at the network level (so even if UFW were ever misconfigured or disabled,
the droplet's provider-level firewall still blocks everything else).

**UFW, on the droplet:**

```bash
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status verbose
```

Nothing else needs a rule — Postgres (5432) isn't published to the host at all in
`docker-compose.yml`, and the app port (8000) is only ever reached internally, via nginx
(section 11), never directly from outside.

**DigitalOcean Cloud Firewall** (Networking → Firewalls → Create Firewall in the web
console, or `doctl compute firewall create`): inbound rules for TCP 22, 80, 443 from
`0.0.0.0/0` (and `::/0` for IPv6), all outbound allowed, applied to this droplet. This is
what actually stops traffic before it reaches the droplet's network interface at all.

---

## 6. fail2ban, automatic updates, swap

```bash
sudo apt update && sudo apt upgrade -y

# fail2ban: bans IPs that repeatedly fail SSH auth
sudo apt install -y fail2ban
sudo systemctl enable --now fail2ban

# Unattended security updates, applied automatically
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades   # answer "Yes"

# A 2GB droplet with Postgres + Gunicorn + nginx benefits from swap headroom,
# especially during `docker compose build`
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

Optional but worth doing while you're in here:

```bash
sudo timedatectl set-timezone UTC     # matches settings.py's TIME_ZONE
sudo hostnamectl set-hostname designwithcory-prod
```

---

## 7. Install Docker Engine

Ubuntu 24.04's own repos carry an older Docker; install from Docker's official apt repo
instead, per [Docker's documented steps](https://docs.docker.com/engine/install/ubuntu/):

```bash
# Remove any conflicting distro packages (harmless if none are installed)
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt remove -y $pkg 2>/dev/null
done

sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Let the `deploy` user run Docker without `sudo`, and confirm the daemon starts on boot
(it does by default via systemd, but confirm anyway):

```bash
sudo usermod -aG docker deploy
sudo systemctl enable --now docker

# Group membership needs a fresh login to take effect
exit
ssh deploy@$DROPLET_IP

docker run hello-world   # should pull and run without sudo
```

---

## 8. Authenticate the droplet with GitHub (deploy key)

The droplet needs to pull this repo. **Don't** use a personal access token or your own
SSH key for this — a **deploy key** is the right tool: it's scoped to exactly one repo,
read-only by default, has nothing to do with your personal GitHub account, and you can
revoke it from GitHub without touching anything else. If the droplet is ever compromised,
the blast radius is "can read this one repo," not "can act as you everywhere."

**Generate a dedicated key pair on the droplet:**

```bash
ssh-keygen -t ed25519 -C "designwithcory-prod-deploy-key" -f ~/.ssh/github_deploy_key -N ""
cat ~/.ssh/github_deploy_key.pub
```

Copy that public key's output.

**Add it to GitHub:** repo → Settings → Deploy keys → Add deploy key.

- Title: `designwithcory-prod` (or similar — something that identifies *this droplet*)
- Key: paste what you copied
- **Leave "Allow write access" unchecked.** The droplet only ever needs to `git pull`.

**Tell SSH on the droplet to actually use this key for GitHub** (rather than falling back
to a default key that doesn't exist, or trying every key in `~/.ssh`):

```bash
cat >> ~/.ssh/config <<'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/github_deploy_key
  IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config
```

**Verify:**

```bash
ssh -T git@github.com
```

You want: `Hi kindoshen/DWC-Portfolio-Django! You've successfully authenticated, but
GitHub does not provide shell access.` — that exact "successfully authenticated" line
confirms the deploy key works. (The "does not provide shell access" part is normal and
expected — deploy keys authenticate git operations, not an interactive login.)

---

## 9. Clone the repo and configure `.env`

```bash
sudo mkdir -p /opt/designwithcory
sudo chown deploy:deploy /opt/designwithcory
git clone git@github.com:kindoshen/DWC-Portfolio-Django.git /opt/designwithcory
cd /opt/designwithcory
```

`/opt` rather than `~/` — this is a service, not a personal file, and `/opt/<app>` is the
conventional place for it regardless of which user account happens to own the process.

**Build `.env`:**

```bash
cp .env.example .env
```

Now edit `.env` (`nano .env`) with real production values. The full reference for every
variable is in [README.md's Environment Variables section](README.md#environment-variables)
— the ones that specifically matter for *this* deployment:

```bash
# Generate a real secret key — do not ship the example file's blank value
python3 -c "import secrets; print(secrets.token_urlsafe(50))"
```

```dotenv
DJANGO_SECRET_KEY=<paste the generated value>
DJANGO_DEBUG=False
DJANGO_ALLOWED_HOSTS=designwithcory.com,www.designwithcory.com
DJANGO_CSRF_TRUSTED_ORIGINS=https://designwithcory.com,https://www.designwithcory.com

DJANGO_SECURE_SSL_REDIRECT=True
DJANGO_BEHIND_PROXY=True

DJANGO_EMAIL_HOST=<your SMTP host, e.g. smtp.sendgrid.net>
DJANGO_EMAIL_HOST_USER=<smtp username>
DJANGO_EMAIL_HOST_PASSWORD=<smtp password>
DJANGO_ADMIN_EMAIL=<an address you actually read, for 500-error alerts>

WEB_PORT=8000
POSTGRES_DB=designwithcory
POSTGRES_USER=designwithcory
POSTGRES_PASSWORD=<generate one — see below>
```

Generate the Postgres password the same way rather than typing something memorable:

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

Leave `DATABASE_URL` **blank** in the file — `docker-compose.yml` builds it for you at
container-start from the `POSTGRES_*` values above, so there's exactly one place to
change database credentials, not two (see the comment in `docker-compose.yml` if you
want the details).

**Lock the file down** — it holds your secret key, SMTP password, and database password:

```bash
chmod 600 .env
```

`.env` is git-ignored; it never leaves this server through the repo.

---

## 10. Point DNS at the droplet

At your domain's DNS provider, create:

| Type | Name | Value |
|---|---|---|
| A | `@` | `$DROPLET_IP` |
| A | `www` | `$DROPLET_IP` |

DNS propagation can take anywhere from a few minutes to a few hours. Confirm it's live
before moving on:

```bash
dig +short designwithcory.com
dig +short www.designwithcory.com
```

Both should return `$DROPLET_IP`. Certbot (next section) will fail its domain-ownership
check if this hasn't propagated yet.

---

## 11. nginx reverse proxy + Let's Encrypt TLS

The Docker stack serves the app on `127.0.0.1:$WEB_PORT` from inside the droplet — nginx,
running directly on the host (not in a container), sits in front of it, terminates TLS,
and is the only thing actually facing the internet on ports 80/443.

```bash
sudo apt install -y nginx
```

**Create the site config:**

```bash
sudo nano /etc/nginx/sites-available/designwithcory
```

```nginx
server {
    listen 80;
    server_name designwithcory.com www.designwithcory.com;

    # Certbot will insert its own location block here and add the 443/TLS
    # server block below automatically in the next step — this file just
    # needs to get requests to the app correctly to start with.

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        client_max_body_size 20M;   # matches DATA_UPLOAD_MAX_MEMORY_SIZE in settings.py
    }
}
```

`client_max_body_size` matters here specifically: nginx's own 1MB default would reject a
large admin file/image upload with a generic 413 *before* Django's own (already generous,
20MB) `DATA_UPLOAD_MAX_MEMORY_SIZE` ever got a say.

```bash
sudo ln -s /etc/nginx/sites-available/designwithcory /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload nginx
```

At this point `http://designwithcory.com` should proxy through to... a connection
refused, because the app isn't running yet. That's expected — confirm nginx itself is
serving (`curl -I http://localhost` from the droplet should get *some* HTTP response, not
a connection error) and move on; section 12 brings the app up.

**Get a real certificate:**

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d designwithcory.com -d www.designwithcory.com
```

Certbot will ask for an email (for renewal/expiry notices) and offer to redirect HTTP to
HTTPS automatically — say yes. It rewrites the nginx config you just wrote to add the
443/TLS server block and the redirect, so don't hand-edit those parts yourself afterward.

**Renewal is automatic** — the certbot package installs a systemd timer. Confirm it's
armed rather than assuming:

```bash
systemctl status certbot.timer
sudo certbot renew --dry-run
```

---

## 12. Build and launch the stack

```bash
cd /opt/designwithcory
docker compose build
docker compose up -d
docker compose exec web python manage.py migrate
docker compose exec web python manage.py createsuperuser
```

`collectstatic` is a deliberately separate step, not something `docker compose build` or
the container's startup command runs automatically (the Dockerfile explains why: explicit
beats magic for a small, single-replica deploy). Run it once the containers are up:

```bash
docker compose exec web python manage.py collectstatic --noinput
```

Confirm both containers are healthy:

```bash
docker compose ps
```

You want `db` showing `healthy` and `web` showing `Up`. If `web` is restarting in a loop,
`docker compose logs web` first — the most common causes at this stage are a typo in
`.env` or `DJANGO_ALLOWED_HOSTS` not matching the domain you're hitting.

---

## 13. Verify the deployment

```bash
curl -I https://designwithcory.com/
curl -I https://designwithcory.com/admin/
```

Both should return `200`/`302` over HTTPS with a valid cert (no `-k` needed). Then, from
your own machine (not the droplet) with production env vars loaded, run Django's own
deployment checklist against the real config:

```bash
docker compose exec web python manage.py check --deploy
```

Address anything it flags, or consciously accept it — this cross-checks the
[Pre-Deployment Checklist in README.md](README.md#pre-deployment-checklist), which is
worth reading through explicitly once here too.

Finally, upload real content through `/admin/` — a Resume PDF, the WorkSample/BlogPost
cover images. `media/` doesn't travel with `git clone`; it's gitignored like all
user-uploaded content, so a fresh deploy starts with none of it (README calls this out
too — it's not something this guide's `git clone` step missed).

---

## 14. Deploying updates

```bash
cd /opt/designwithcory
git pull origin main
docker compose build web
docker compose up -d
docker compose exec web python manage.py migrate
docker compose exec web python manage.py collectstatic --noinput
```

`db` doesn't need rebuilding for an app-code change — only `web` does. Postgres data
persists in the `postgres_data` named volume regardless of how many times `web` gets
rebuilt; only `docker compose down -v` (note the `-v`) touches it, and you should never
run that against production without meaning it specifically.

Watch for errors as it comes back up:

```bash
docker compose logs -f web
```

---

## 15. Backups

Nothing in the stack backs up Postgres on its own — set that up explicitly.

**A daily dump, kept 7 days, via cron:**

```bash
sudo mkdir -p /opt/backups
sudo chown deploy:deploy /opt/backups
crontab -e
```

Add:

```cron
0 3 * * * cd /opt/designwithcory && docker compose exec -T db pg_dump -U designwithcory designwithcory | gzip > /opt/backups/db-$(date +\%F).sql.gz && find /opt/backups -name '*.sql.gz' -mtime +7 -delete
```

(Match the username/database name to whatever you actually set `POSTGRES_USER`/
`POSTGRES_DB` to in `.env`.)

**This alone is not a real backup strategy** — it's a local copy on the same disk as the
database it's backing up, which survives "I fat-fingered a migration" but not "the
droplet itself is gone." Ship these off the droplet too: a small `rclone` config syncing
`/opt/backups` to a DigitalOcean Spaces bucket (or S3, or literally anywhere else) closes
that gap and is worth the ten extra minutes:

```bash
sudo apt install -y rclone
rclone config    # walks you through adding a Spaces/S3 remote
```

Then extend the cron line with `&& rclone copy /opt/backups spaces-remote:your-bucket/backups`.

To restore from a dump:

```bash
gunzip -c /opt/backups/db-2026-08-22.sql.gz | docker compose exec -T db psql -U designwithcory designwithcory
```

**Test this** at least once, before you actually need it — a backup you've never restored
from is a hypothesis, not a backup.

---

## 16. Monitoring, logs, and housekeeping

```bash
docker compose logs -f web        # app logs (gunicorn access/error + anything Django logs)
docker compose logs -f db         # Postgres logs
sudo journalctl -u nginx -f       # nginx
sudo journalctl -u docker -f      # Docker daemon itself
```

Docker's default `json-file` log driver doesn't rotate on its own and will grow forever
on a long-lived container — cap it in `/etc/docker/daemon.json`:

```bash
sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
sudo systemctl restart docker
```

(This applies to newly *created* containers, not ones already running — after setting
it, `docker compose up -d --force-recreate` once to pick it up.)

Periodically reclaim disk from old, unused images/layers left behind by rebuilds:

```bash
docker system prune -af --filter "until=168h"   # anything untouched for a week
```

For anything beyond "I can SSH in and check" — actual uptime alerting — DigitalOcean's
own free Droplet monitoring (Networking/Monitoring tab in the console, or the
`do-agent` it can install) covers CPU/memory/disk with email alerts and is enough for a
site this size without standing up a separate monitoring stack.

---

## 17. Security checklist (recap)

Everything above, as a single pass to confirm before calling this done:

- [ ] Root SSH login disabled, password auth disabled (section 4)
- [ ] UFW active, only 22/80/443 open; DigitalOcean Cloud Firewall mirrors that (section 5)
- [ ] fail2ban running; unattended-upgrades enabled (section 6)
- [ ] GitHub access via a **read-only deploy key**, not a personal token or your own key
      (section 8)
- [ ] `.env` is `chmod 600`, holds a freshly generated `DJANGO_SECRET_KEY` and
      `POSTGRES_PASSWORD` — neither is a default/example value (section 9)
- [ ] `DJANGO_DEBUG=False`, `DJANGO_ALLOWED_HOSTS` set to the real domain(s) only
      (section 9)
- [ ] Postgres is not published to the host or the internet — no `ports:` entry for `db`
      in `docker-compose.yml` (it isn't, by default; don't uncomment that section)
- [ ] TLS is live and certbot's renewal timer is confirmed armed (section 11)
- [ ] `manage.py check --deploy` run against production config, warnings addressed
      (section 13)
- [ ] Backups exist **and have been test-restored at least once**, and a copy lives
      somewhere other than the droplet's own disk (section 15)
- [ ] The admin superuser has a genuinely strong, unique password — it's the single
      highest-value credential in this whole stack

---

## 18. Optional next steps

Not required to be "in production," but worth knowing about:

- **CI/CD auto-deploy**: a GitHub Actions workflow that SSHes in and runs the section-14
  update steps on every push to `main` (using a *separate* deploy key/secret, scoped the
  same read-only way, stored in the repo's Actions secrets — not the same key from
  section 8, which GitHub itself already holds one side of).
- **Zero-downtime deploys**: right now, `docker compose up -d` briefly drops connections
  while `web` restarts. For a site this size that's a non-issue in practice, but a
  blue/green swap or a second `web` replica behind nginx removes even that.
- **Object storage for `media/`**: `django-storages` + DigitalOcean Spaces, so uploaded
  content isn't tied to this one droplet's disk and survives a droplet rebuild without a
  manual re-upload through `/admin/`.
- **A staging droplet**: a second, smaller droplet running the same stack against a
  separate database, for trying migrations/deploys before they hit production.
