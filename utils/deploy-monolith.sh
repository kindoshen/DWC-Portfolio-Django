#!/usr/bin/env bash
# deploy-monolith.sh — bootstraps a fresh Ubuntu 24.04-or-newer DigitalOcean droplet into a running,
# hardened deployment of this app WITHOUT Docker: a Python venv running gunicorn under
# systemd, behind nginx for TLS termination. One process, no container runtime — a genuine
# single-box monolith. See deploy-droplet.sh (and DEPLOYMENT.md) for the Docker + Postgres
# alternative this otherwise mirrors phase-for-phase; read the comments in *that* script
# for background this one doesn't repeat. (One structural difference: deploy-droplet.sh
# still opens with a root "phase 1" that creates the deploy user and hands off; this
# script dropped that and assumes the deploy user already exists, so its phase numbers
# run one behind that script's from "harden SSH" onward.)
#
# USAGE
#   This script runs entirely as the preconfigured non-root "deploy" user — the account
#   your droplet image / cloud-init already created with sudo rights and either your SSH
#   key or console access in place. It does NOT create that user, and it never needs a
#   working SSH login *to localhost* to do its job: run it once, as "deploy", from any
#   shell you already have on the box (the serial/web console, a cloud-init runcmd, a
#   `doctl compute ssh` session, a CI step — whatever):
#     curl -fsSL https://raw.githubusercontent.com/kindoshen/DWC-Portfolio-Django/main/utils/deploy-monolith.sh -o deploy-monolith.sh
#     bash deploy-monolith.sh
#   It runs straight through all 13 phases in one pass. (Earlier versions began with a
#   root "phase 0" that created the deploy user and made you log back in as it before
#   continuing; that step is gone — provision the user when you create the droplet, e.g.
#   via the cloud-init 'users:' block or `adduser deploy && usermod -aG sudo deploy`.)
#
#   The deploy user's sudo must work non-interactively OR you must run this somewhere you
#   can answer sudo's password prompt — every phase past this point uses `sudo`.
#
# SAFE TO RE-RUN. Every phase checks whether its own work is already done and skips it if
# so — if this fails partway (a typo'd domain, DNS not propagated yet, whatever), fix the
# one thing and run it again rather than starting over.
#
# DATABASE: phase_clone_and_env (phase 6) asks you to pick one of three — SQLite (the
# default: zero extra moving parts, genuinely fine at a portfolio site's actual traffic
# level), a Postgres instance you already run elsewhere (Managed Databases, RDS, whatever
# — this script just points DATABASE_URL at it), or a **local** Postgres server that this
# script installs, creates a role/database on, and tunes itself (phase 7). That third
# option used to be out of scope for this script on the theory that a local DB server was
# more ongoing surface than a monolith deploy should take on — it's in scope now because
# entry-level droplets (512MB-1GB RAM) are exactly where that operational cost is worth it
# for the headroom Postgres gives over SQLite under concurrent writes, and because the
# tuning below is computed from this box's *actual* detected RAM/CPU at run time rather
# than a fixed guess, which is most of what made "hand-tune a local Postgres" feel like
# real work in the first place.
#
# ENTRY-LEVEL SIZING: this script reads this droplet's real memory (detect_total_mem_mb)
# and CPU count (detect_cpu_count) and uses them — not a hardcoded assumption — to size
# the swapfile (phase 3), gunicorn's worker count (phase 11), and, if you chose local
# Postgres, its shared_buffers/effective_cache_size/work_mem/maintenance_work_mem/
# max_connections (phase 7). Re-running this script after a droplet resize re-derives all
# of these from whatever the new specs actually are.
#
# WHAT THIS DOES NOT DO (see DEPLOYMENT.md for the equivalent reasoning — it applies here
# unchanged):
#   - Create the droplet itself — that's one `doctl` command or a few clicks, and doing it
#     from inside a script that then needs to run *on* that droplet is backwards.
#   - Add the generated SSH deploy key to GitHub — deliberately: this script never touches
#     your GitHub account or holds a personal access token. It prints the key and waits for
#     a human to paste it into GitHub's own UI as a read-only deploy key.
#   - Configure the DigitalOcean Cloud Firewall — that's the *network-level* firewall in
#     front of the droplet, not something a script running on the droplet can reach without
#     a DigitalOcean API token. UFW (which this script does configure) is the host-level
#     half of that two-layer design; do the other half in the DO console.
#   - Point DNS at the droplet — this script checks that you've done it, not does it for
#     you; your DNS provider is unrelated to your droplet.

set -euo pipefail

# ---------------------------------------------------------------------------------------
# Config — the only things you should need to edit before running this.
# ---------------------------------------------------------------------------------------
REPO_SSH_URL="git@github.com:kindoshen/DWC-Portfolio-Django.git"
APP_DIR="/opt/designwithcory"
BACKUP_DIR="/opt/backups"
DEPLOY_USER="deploy"
DEPLOY_KEY_PATH="/home/${DEPLOY_USER}/.ssh/github_deploy_key"
NGINX_SITE_NAME="designwithcory"
SERVICE_NAME="designwithcory"
GUNICORN_PORT="8000"          # internal only — nginx is the only thing that ever talks to it
POSTGRES_DB_NAME="designwithcory"
POSTGRES_DB_USER="designwithcory"
STATE_DIR="/opt/.deploy-monolith-state"   # tiny marker files so re-runs skip finished phases

# Minimum Python this app runs on — Django 6.0's own floor. The script builds the venv
# from the distro's DEFAULT `python3` (not a version-pinned package name), because which
# 3.x that is varies by image: Ubuntu 24.04/24.10 ship 3.12, 25.04 ships 3.13, 25.10
# ships 3.14, Debian 13 ships 3.13. Any of those is fine; anything older than this is not
# and the script stops with a clear message rather than building a venv Django won't load.
PYTHON_MIN="3.12"

# ---------------------------------------------------------------------------------------
# Small helpers — identical to deploy-droplet.sh's; kept in sync deliberately rather than
# sourced from a shared file, so either script still works copied/curled on its own.
# ---------------------------------------------------------------------------------------
log()  { echo -e "\n\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[XX]\033[0m $*" >&2; exit 1; }

done_marker()   { echo "${STATE_DIR}/$1"; }
phase_done()    { [[ -f "$(done_marker "$1")" ]]; }
mark_done()     { sudo mkdir -p "$STATE_DIR"; sudo touch "$(done_marker "$1")"; }

ask() {
  # ask VAR_NAME "Prompt" ["default"]
  local __var="$1" prompt="$2" default="${3:-}" reply
  if [[ -n "$default" ]]; then
    read -rp "$prompt [$default]: " reply
    reply="${reply:-$default}"
  else
    read -rp "$prompt: " reply
  fi
  printf -v "$__var" '%s' "$reply"
}

ask_secret() {
  local __var="$1" prompt="$2" reply
  read -rsp "$prompt: " reply
  echo
  printf -v "$__var" '%s' "$reply"
}

confirm() {
  local prompt="$1" reply
  read -rp "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

set_env_var() {
  # set_env_var KEY VALUE — replaces an existing "KEY=" line in .env. Every key this
  # script sets already exists (blank) in .env.example, so replace-only is correct and
  # safe here: if a key were missing entirely, that's a real gap in .env.example we'd
  # want to notice, not silently paper over by appending.
  #
  # Done in Python, not sed: values here include user-typed SMTP passwords and Postgres
  # connection strings, which can contain '/', '&', backslashes, or anything else —
  # passed via environment variables rather than interpolated into a shell/sed pattern,
  # so nothing needs escaping at all.
  local key="$1" value="$2"
  if ! grep -q "^${key}=" "${APP_DIR}/.env"; then
    die ".env has no '${key}=' line — .env.example may be out of date with this script."
  fi
  ENV_KEY="$key" ENV_VALUE="$value" ENV_FILE="${APP_DIR}/.env" python3 - <<'PYEOF'
import os

key, value, path = os.environ["ENV_KEY"], os.environ["ENV_VALUE"], os.environ["ENV_FILE"]
prefix = key + "="
with open(path) as f:
    lines = f.readlines()
for i, line in enumerate(lines):
    if line.startswith(prefix):
        lines[i] = f"{key}={value}\n"
        break
else:
    raise SystemExit(f"{prefix} not found in {path}")
with open(path, "w") as f:
    f.writelines(lines)
PYEOF
}

venv_python() { echo "${APP_DIR}/env/bin/python"; }
venv_pip()    { echo "${APP_DIR}/env/bin/pip"; }

# "a.com, www.a.com" -> "https://a.com,https://www.a.com". DJANGO_CSRF_TRUSTED_ORIGINS has
# to track DJANGO_ALLOWED_HOSTS one-for-one (Django needs the scheme on each), so both the
# first-time write and the re-run update below derive it the same way from one host list.
csrf_origins_for() {
  local hosts="$1" out="" h
  IFS=',' read -ra _h <<< "${hosts// /}"
  for h in "${_h[@]}"; do
    [[ -n "$h" ]] || continue
    out+="${out:+,}https://${h}"
  done
  echo "$out"
}

# Version of the distro-default python3 the venv is built from, as e.g. "3.14.4".
system_python_version() { python3 -c 'import platform; print(platform.python_version())'; }

# True iff `python3` is >= $PYTHON_MIN. Compared numerically (tuple compare), so "3.14"
# correctly beats "3.9" — a string compare would get that backwards.
python_version_ok() {
  python3 - "$PYTHON_MIN" <<'PYEOF'
import sys
want = tuple(int(p) for p in sys.argv[1].split("."))
sys.exit(0 if sys.version_info[:len(want)] >= want else 1)
PYEOF
}

# Real hardware, not a guess — everything sized "for a low-RAM droplet" below (swap,
# gunicorn workers, Postgres tuning) reads these at the point it's actually needed rather
# than once at the top, so a re-run after resizing the droplet picks up the new numbers.
detect_total_mem_mb() { awk '/MemTotal/{printf "%d", $2 / 1024}' /proc/meminfo; }
detect_cpu_count()    { nproc; }

compute_gunicorn_workers() {
  # (2 x CPU) + 1 is gunicorn's own standard guidance, but it assumes RAM isn't the
  # constraint — on an entry-level droplet it usually is. ~256MB per sync worker is a
  # reasonable budget for this app; the flat 512MB reserved off the top covers nginx,
  # fail2ban, the OS itself, and — if phase 7 installed one — a local Postgres server,
  # so this never recommends more workers than the box can hold without swapping under
  # normal load. Whichever bound is tighter wins; 2 is the floor either way, since a
  # single worker means every request queues behind whatever the last one is doing.
  local mem_mb cpu by_cpu by_mem workers
  mem_mb=$(detect_total_mem_mb)
  cpu=$(detect_cpu_count)
  by_cpu=$(( cpu * 2 + 1 ))
  by_mem=$(( (mem_mb - 512) / 256 ))
  (( by_mem < 1 )) && by_mem=1
  workers=$(( by_cpu < by_mem ? by_cpu : by_mem ))
  (( workers < 2 )) && workers=2
  echo "$workers"
}

# ---------------------------------------------------------------------------------------
# Phase: SSH hardening — identical to deploy-droplet.sh's.
# ---------------------------------------------------------------------------------------
phase_ssh_hardening() {
  log "Phase 1/13: harden SSH"
  if phase_done ssh_hardening; then ok "Already done, skipping."; return; fi

  # No "can deploy still SSH in with a key?" self-test here — this script is run from a
  # shell you already hold on the box (console, cloud-init, an existing session), not
  # over the SSH connection it's about to harden, so there's no remote session at risk
  # of being locked out mid-phase. It also never depends on SSH-to-localhost working:
  # if ${DEPLOY_USER}'s authorized_keys turns out to be wrong, that only affects *future*
  # logins, and sshd_config.bak.* below is the recovery path for exactly that.
  sudo cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"
  sudo sed -i \
    -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
    -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
    -e 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' \
    -e 's/^#\?X11Forwarding.*/X11Forwarding no/' \
    /etc/ssh/sshd_config

  # Ubuntu 24.04 also reads /etc/ssh/sshd_config.d/*.conf, which can silently override the
  # above (e.g. a cloud-init drop-in).
  if grep -rlq "PasswordAuthentication" /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
    sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config.d/*.conf
    warn "Found and patched a PasswordAuthentication override in sshd_config.d/."
  fi

  sudo sshd -t || die "sshd_config is invalid after edits — NOT restarting sshd." \
                      "Restore from /etc/ssh/sshd_config.bak.* and try again."
  sudo systemctl restart ssh
  ok "SSH hardened: root login and password auth disabled, config verified valid."
  mark_done ssh_hardening
}

# ---------------------------------------------------------------------------------------
# Phase: firewall — identical to deploy-droplet.sh's (the UFW/host-level half; the Cloud
# Firewall half is manual).
# ---------------------------------------------------------------------------------------
phase_firewall() {
  log "Phase 2/13: UFW firewall"
  if phase_done firewall; then ok "Already done, skipping."; return; fi

  sudo ufw allow OpenSSH
  sudo ufw allow 80/tcp
  sudo ufw allow 443/tcp
  sudo ufw --force enable
  sudo ufw status verbose
  ok "UFW active: 22, 80, 443 only. Note ${GUNICORN_PORT}/tcp is deliberately NOT opened —" \
     "gunicorn only ever binds 127.0.0.1, reachable solely via nginx's reverse proxy."

  warn "This only covers the host-level firewall. Also create a DigitalOcean Cloud" \
       "Firewall (22/80/443 inbound, this droplet) in the DO console or via" \
       "'doctl compute firewall create'. This script can't do that half for you without" \
       "a DO API token, and deliberately doesn't ask you to put one on this server for a" \
       "one-time setup step."
  mark_done firewall
}

# ---------------------------------------------------------------------------------------
# Phase: fail2ban, unattended-upgrades, swap, timezone — identical to deploy-droplet.sh's.
# ---------------------------------------------------------------------------------------
phase_baseline_hardening() {
  log "Phase 3/13: fail2ban, automatic updates, swap"
  if phase_done baseline_hardening; then ok "Already done, skipping."; return; fi

  sudo apt-get update -qq
  sudo apt-get install -y -qq fail2ban unattended-upgrades dnsutils >/dev/null
  sudo systemctl enable --now fail2ban >/dev/null
  ok "fail2ban installed and running."

  echo 'Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
};' | sudo tee /etc/apt/apt.conf.d/51unattended-upgrades-security >/dev/null
  echo 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";' | sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null
  ok "Unattended security upgrades enabled."

  if [[ ! -f /swapfile ]]; then
    local total_mem_mb swap_mb
    total_mem_mb=$(detect_total_mem_mb)
    # 2x RAM, floored at 1G and capped at 4G — entry-level droplets (512MB-1GB) need
    # swap closer to double their RAM to survive a real spike (a `pip install`, a burst
    # of concurrent gunicorn workers, Postgres's own transient memory use if phase 7
    # installs it); a box with plenty of RAM already doesn't need swap scaling linearly
    # with it, hence the cap.
    swap_mb=$(( total_mem_mb * 2 ))
    (( swap_mb > 4096 )) && swap_mb=4096
    (( swap_mb < 1024 )) && swap_mb=1024
    sudo fallocate -l "${swap_mb}M" /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile >/dev/null
    sudo swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
    ok "${swap_mb}MB swapfile created and enabled (detected ${total_mem_mb}MB RAM)."
  else
    ok "Swapfile already exists."
  fi

  sudo timedatectl set-timezone UTC
  ok "Timezone set to UTC (matches settings.py's TIME_ZONE)."
  mark_done baseline_hardening
}

# ---------------------------------------------------------------------------------------
# Phase: system packages — the Docker-flavored script installs Docker Engine here; this
# one installs the much shorter list of things a bare Python app actually needs. It uses
# the distro's DEFAULT python3 (packages `python3` / `python3-venv`, not a pinned
# `python3.12`): every supported base image — Ubuntu 24.04 (3.12) through 25.10 (3.14),
# Debian 13 (3.13) — ships a python3 new enough for Django 6.0 straight from its own
# repos, with no deadsnakes PPA or compiling from source. A pinned `python3.12` breaks
# the moment the image moves on (25.10 has no `python3.12` package at all); the explicit
# version *floor* below is what actually guards against too-old, and it does so with a
# real check instead of a package name that happens to fail on the wrong distro.
# ---------------------------------------------------------------------------------------
phase_system_packages() {
  log "Phase 4/13: install Python, nginx, certbot, and curl"
  if phase_done system_packages; then ok "Already done, skipping."; return; fi

  # curl used to be installed by the old root phase 0 (gone now). It's needed first in
  # phase_dns_check (phase 8) and isn't guaranteed on a minimal droplet image, so it's
  # pulled in here — the earliest phase that installs packages anyway, and well before
  # anything reads it. git gets the same treatment; phase_clone_and_env needs it next.
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    python3 python3-venv python3-pip \
    git curl nginx certbot python3-certbot-nginx >/dev/null

  # Django 6.0 won't import on < ${PYTHON_MIN}. Catch that here, with a message that
  # names the actual version, rather than letting phase_app_setup build a venv that
  # then explodes on the first `manage.py` call.
  local pyver
  pyver=$(system_python_version)
  if ! python_version_ok; then
    die "This image's default python3 is ${pyver}, older than the ${PYTHON_MIN} that" \
        "Django 6.0 requires. Redeploy on a newer base image (Ubuntu 24.04+ / Debian" \
        "13+ all qualify) — this script deliberately won't pull in a deadsnakes PPA or" \
        "build Python from source on a box this old."
  fi
  ok "Installed: python3 ${pyver}, nginx, certbot, curl."

  # No build-essential / libpq-dev on purpose: every pinned dependency in requirements.txt
  # (Django, Pillow, psycopg2-binary, gunicorn, ...) ships a prebuilt wheel for this
  # platform — the Dockerfile installs into its python:*-slim base the same way, with no
  # compiler either. If a future dependency ever needs one, `pip install` will say so
  # explicitly rather than failing silently, and `sudo apt-get install build-essential
  # libpq-dev` is the fix.
  mark_done system_packages
}

# Does SSH auth to github.com already succeed for this user? True for a preconfigured
# deploy user that already has a working key (its own ~/.ssh/id_*, an agent, or a deploy
# key added to GitHub on an earlier run) — in which case phase 5 has nothing to do.
github_ssh_works() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 \
    | grep -q "successfully authenticated"
}

# Print the OpenSSH public key for a private key, whether or not a matching .pub file
# sits next to it (an existing id_* the user points us at might not have one).
print_public_key() {
  local key="$1"
  if [[ -f "${key}.pub" ]]; then cat "${key}.pub"; else ssh-keygen -y -f "$key"; fi
}

# ---------------------------------------------------------------------------------------
# Phase: GitHub deploy key — same intent as deploy-droplet.sh's, but checks for a key /
# working auth that already exists before generating one, and is skippable: the only
# thing downstream that needs GitHub is the SSH clone in phase 6, so if you're handling
# that another way (HTTPS remote, a key you'll wire up later) you can decline every
# prompt here and this phase becomes a no-op.
# ---------------------------------------------------------------------------------------
phase_github_deploy_key() {
  log "Phase 5/13: authenticate to GitHub with a deploy key"

  # 1. Already working? Nothing to generate, nothing to paste into GitHub's UI.
  if github_ssh_works; then
    ok "GitHub SSH auth already works for this user — no deploy key needed."
    return
  fi

  # 2. Skip gate. Declining here (or any non-interactive run, where confirm reads EOF)
  #    leaves GitHub auth unconfigured; phase 6's clone will then fail until it's sorted.
  if ! confirm "Set up a GitHub deploy key now? (needed only for the SSH clone in phase 6)"; then
    warn "Skipping GitHub deploy-key setup. phase_clone_and_env (phase 6) can't clone" \
         "${REPO_SSH_URL} until this user can reach GitHub over SSH — re-run this script" \
         "once that's in place, or point REPO_SSH_URL at an https:// URL instead."
    return
  fi

  # 3. Reuse an existing key before generating a fresh one.
  local key_path=""
  if [[ -f "$DEPLOY_KEY_PATH" ]]; then
    key_path="$DEPLOY_KEY_PATH"
    ok "Reusing the existing deploy key at ${key_path}."
  elif [[ -d "$HOME/.ssh" ]]; then
    local existing
    existing=$(find "$HOME/.ssh" -maxdepth 1 -type f -name 'id_*' ! -name '*.pub' 2>/dev/null \
      | sort | head -n1 || true)
    if [[ -n "$existing" ]] \
       && confirm "This user already has an SSH key at ${existing} — use it for GitHub instead of generating a new one?"; then
      key_path="$existing"
    fi
  fi

  if [[ -z "$key_path" ]]; then
    ssh-keygen -t ed25519 -C "$(hostname)-deploy-key" -f "$DEPLOY_KEY_PATH" -N ""
    key_path="$DEPLOY_KEY_PATH"
    ok "Generated a new ed25519 deploy key at ${key_path}."
  fi

  # 4. Point ssh at whichever key we settled on.
  mkdir -p ~/.ssh
  if ! grep -q "IdentityFile ${key_path}" ~/.ssh/config 2>/dev/null; then
    cat >> ~/.ssh/config <<EOF
Host github.com
  HostName github.com
  User git
  IdentityFile ${key_path}
  IdentitiesOnly yes
EOF
    chmod 600 ~/.ssh/config
  fi

  if github_ssh_works; then
    ok "GitHub SSH auth works with ${key_path}. Skipping the manual step."
    return
  fi

  echo
  warn "This key is NOT yet authorized on GitHub. Add it now:"
  echo "    1. Copy the public key below."
  echo "    2. On GitHub: this repo -> Settings -> Deploy keys -> Add deploy key."
  echo "    3. Paste it. Leave 'Allow write access' UNCHECKED — read-only is correct" \
       "and is the whole point of using a deploy key instead of a personal token."
  echo
  echo "----- BEGIN PUBLIC KEY -----"
  print_public_key "$key_path"
  echo "----- END PUBLIC KEY -----"
  echo

  while ! github_ssh_works; do
    local reply=""
    if ! read -rp "Press Enter once the key is added on GitHub ('s' to skip, Ctrl+C to abort)... " reply; then
      warn "No input (non-interactive?) — skipping before GitHub auth was confirmed."
      return
    fi
    if [[ "$reply" =~ ^[Ss]$ ]]; then
      warn "Skipping before GitHub auth was confirmed — phase 6's clone will fail if the" \
           "key isn't actually active yet."
      return
    fi
  done
  ok "GitHub deploy key authenticated."
}

# ---------------------------------------------------------------------------------------
# Re-run helper: rewrite DJANGO_ALLOWED_HOSTS (and DJANGO_CSRF_TRUSTED_ORIGINS, kept in
# lock-step) in an existing .env without touching anything else. Called from
# phase_clone_and_env when .env already exists. Declining the prompt — or a
# non-interactive run — leaves both values exactly as they were.
# ---------------------------------------------------------------------------------------
update_allowed_hosts() {
  local current
  current=$(grep '^DJANGO_ALLOWED_HOSTS=' .env | cut -d= -f2-)
  echo "Current DJANGO_ALLOWED_HOSTS: ${current:-<empty>}"
  confirm "Update the allowed hosts / domains?" || { ok "Leaving DJANGO_ALLOWED_HOSTS unchanged."; return 0; }

  local new_hosts
  ask new_hosts "Comma-separated hostnames (e.g. designwithcory.com,www.designwithcory.com)" "$current"
  new_hosts="${new_hosts// /}"   # tolerate 'a.com, b.com'
  if [[ -z "$new_hosts" ]]; then
    warn "Empty host list — leaving DJANGO_ALLOWED_HOSTS unchanged."
    return 0
  fi
  if [[ "$new_hosts" == "$current" ]]; then
    ok "Host list unchanged."
    return 0
  fi

  local new_csrf
  new_csrf=$(csrf_origins_for "$new_hosts")
  set_env_var DJANGO_ALLOWED_HOSTS "$new_hosts"
  set_env_var DJANGO_CSRF_TRUSTED_ORIGINS "$new_csrf"
  ok "DJANGO_ALLOWED_HOSTS        -> ${new_hosts}"
  ok "DJANGO_CSRF_TRUSTED_ORIGINS -> ${new_csrf}"
  warn "phase 9 re-syncs nginx's server_name from this and reloads. If you ADDED a" \
       "hostname and a TLS cert already exists, that cert won't cover it until you run:" \
       "sudo certbot --nginx --expand -d ${new_hosts//,/ -d } — then" \
       "sudo systemctl restart ${SERVICE_NAME}"
}

# ---------------------------------------------------------------------------------------
# Phase: clone + .env — same shape as deploy-droplet.sh's, minus the Docker-only knobs
# (WEB_PORT) and with a three-way prompt for the database — SQLite, a local Postgres
# (phase 7 below provisions it), or a Postgres instance you already run elsewhere.
# ---------------------------------------------------------------------------------------
phase_clone_and_env() {
  log "Phase 6/13: clone the repo and configure .env"

  if [[ -d "$APP_DIR/.git" ]]; then
    ok "Repo already cloned at ${APP_DIR}."
  else
    sudo mkdir -p "$APP_DIR"
    sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "$APP_DIR"
    git clone "$REPO_SSH_URL" "$APP_DIR"
    ok "Cloned into ${APP_DIR}."
  fi

  cd "$APP_DIR"

  if [[ -f .env ]]; then
    ok ".env already exists — not regenerating it. Delete it first if you want this" \
       "script to rebuild it from scratch."
    # ...but domains do change on a live deploy (added a www variant, moved domain,
    # added a subdomain), and every later phase reads them straight from .env, so offer
    # to update just the host list in place.
    update_allowed_hosts
    return
  fi

  cp .env.example .env

  local secret_key
  secret_key=$(python3 -c "import secrets; print(secrets.token_urlsafe(50))")

  echo
  echo "A few values for .env — the rest have sane production defaults already in" \
       ".env.example (see README.md > Environment Variables for the full reference)."
  local primary_domain www_domain admin_email
  ask primary_domain "Primary domain (e.g. designwithcory.com)"
  ask www_domain "www variant (Enter to use www.${primary_domain}, or type 'none' to skip it)" "www.${primary_domain}"
  [[ "$www_domain" == "none" ]] && www_domain=""
  ask admin_email "Email for 500-error alerts + Let's Encrypt renewal notices"

  local allowed_hosts="$primary_domain"
  [[ -n "$www_domain" ]] && allowed_hosts="${allowed_hosts},${www_domain}"
  local csrf_origins
  csrf_origins=$(csrf_origins_for "$allowed_hosts")

  set_env_var DJANGO_SECRET_KEY "$secret_key"
  set_env_var DJANGO_DEBUG "False"
  set_env_var DJANGO_ALLOWED_HOSTS "$allowed_hosts"
  set_env_var DJANGO_CSRF_TRUSTED_ORIGINS "$csrf_origins"
  set_env_var DJANGO_SECURE_SSL_REDIRECT "True"
  set_env_var DJANGO_BEHIND_PROXY "True"
  set_env_var DJANGO_ADMIN_EMAIL "$admin_email"

  echo "Database — pick one:"
  echo "  1) SQLite (default) — zero extra moving parts; fine at this project's actual traffic"
  echo "  2) Local Postgres — installed, created, and tuned to this droplet's real RAM/CPU" \
       "by the next phase"
  echo "  3) An existing Postgres instance you already run elsewhere (Managed Databases, RDS, ...)"
  local db_choice
  ask db_choice "Choose 1, 2, or 3" "1"

  case "$db_choice" in
    2)
      # The actual DATABASE_URL isn't known yet — phase_postgres_local generates the
      # password and writes it once Postgres is actually installed. This marker is what
      # tells that (and every later) phase the choice was "local," including on a re-run
      # where .env already exists and this whole block is skipped via the early `return`
      # above — the marker, not an in-memory variable, is what survives that.
      mark_done local_postgres_requested
      ok "Local Postgres selected — phase 7 will install it and write DATABASE_URL" \
         "automatically once it has real credentials to write."
      ;;
    3)
      local database_url
      ask database_url "Postgres connection string (postgres://user:password@host:port/dbname)"
      set_env_var DATABASE_URL "$database_url"
      ;;
    *)
      ok "Leaving DATABASE_URL blank — this deploy will use SQLite at" \
         "${APP_DIR}/Portfolio/db.sqlite3, same as local development."
      ;;
  esac

  echo
  if confirm "Configure real SMTP now (for contact-form/lead emails)? Skipping leaves mail printing to the journal (journalctl -u ${SERVICE_NAME})."; then
    local smtp_host smtp_port smtp_user smtp_pass
    ask smtp_host "SMTP host"
    ask smtp_port "SMTP port" "587"
    ask smtp_user "SMTP username"
    ask_secret smtp_pass "SMTP password"
    set_env_var DJANGO_EMAIL_HOST "$smtp_host"
    set_env_var DJANGO_EMAIL_PORT "$smtp_port"
    set_env_var DJANGO_EMAIL_HOST_USER "$smtp_user"
    set_env_var DJANGO_EMAIL_HOST_PASSWORD "$smtp_pass"
  else
    warn "Skipped SMTP config — contact-form notifications will only ever land in" \
         "'journalctl -u ${SERVICE_NAME}', which is fine for now but revisit before you" \
         "actually rely on the contact form."
  fi

  chmod 600 .env
  ok ".env written and locked to 600. Domains: ${allowed_hosts}"
}

# ---------------------------------------------------------------------------------------
# Phase: local PostgreSQL — only does anything if phase 6 recorded "local Postgres" as
# the choice; otherwise a fast no-op. Installs the server, creates a dedicated role +
# database with a freshly generated password, writes DATABASE_URL, and tunes Postgres's
# memory settings from this droplet's *actual* detected RAM rather than a fixed guess.
# ---------------------------------------------------------------------------------------
phase_postgres_local() {
  log "Phase 7/13: local PostgreSQL (only if chosen in phase 6)"

  if ! phase_done local_postgres_requested; then
    ok "SQLite or an external Postgres was chosen in phase 6 — nothing to provision here."
    return
  fi
  if phase_done postgres_local; then ok "Already provisioned, skipping."; return; fi

  sudo apt-get update -qq
  sudo apt-get install -y -qq postgresql postgresql-contrib >/dev/null
  sudo systemctl enable --now postgresql >/dev/null
  ok "PostgreSQL installed and running."

  local db_pass
  db_pass=$(python3 -c "import secrets; print(secrets.token_urlsafe(24))")

  # createuser/createdb both fail loudly if the role/database already exists, so check
  # first — this whole phase needs to survive a re-run cleanly, same as every other one.
  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${POSTGRES_DB_USER}'" | grep -q 1; then
    # Role survived from an earlier, interrupted attempt at this phase — the password
    # just generated above wouldn't match whatever it was set to then, so reset it
    # explicitly rather than writing a DATABASE_URL below with a password that's wrong.
    sudo -u postgres psql <<SQL
ALTER ROLE ${POSTGRES_DB_USER} WITH PASSWORD '${db_pass}';
SQL
  else
    # Piped via stdin, not `psql -c "...${db_pass}..."` — a -c argument is visible to
    # anyone on the box running `ps aux` for the few milliseconds the command runs;
    # stdin isn't.
    sudo -u postgres psql <<SQL
CREATE ROLE ${POSTGRES_DB_USER} WITH LOGIN PASSWORD '${db_pass}';
SQL
  fi

  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB_NAME}'" | grep -q 1; then
    sudo -u postgres createdb -O "${POSTGRES_DB_USER}" "${POSTGRES_DB_NAME}"
  fi
  ok "Role '${POSTGRES_DB_USER}' and database '${POSTGRES_DB_NAME}' ready."

  set_env_var DATABASE_URL "postgres://${POSTGRES_DB_USER}:${db_pass}@127.0.0.1:5432/${POSTGRES_DB_NAME}"

  # Self-test over the same TCP path Django will actually use, not just the Unix-socket
  # `sudo -u postgres psql` above — catches a bad pg_hba.conf now, with a clear message,
  # instead of `manage.py migrate` failing later with a much less obvious Django DB error.
  # Ubuntu's default pg_hba.conf already permits password auth on 127.0.0.1, so this
  # should just work; the check exists for the droplet where something's overridden that.
  if ! PGPASSWORD="$db_pass" psql -h 127.0.0.1 -U "${POSTGRES_DB_USER}" -d "${POSTGRES_DB_NAME}" -tAc "SELECT 1;" &>/dev/null; then
    die "Provisioned Postgres, but couldn't connect back to it over TCP as" \
        "'${POSTGRES_DB_USER}' with the generated password. Check" \
        "/etc/postgresql/*/main/pg_hba.conf has a 'host ... 127.0.0.1/32 scram-sha-256'" \
        "line (Ubuntu's default does) and 'sudo systemctl status postgresql'."
  fi
  ok "DATABASE_URL written to .env and confirmed reachable over TCP."

  # --- Tuning, computed from this box's real specs, not a fixed guess -------------------
  local total_mem_mb shared_buffers_mb effective_cache_mb work_mem_mb maint_mem_mb max_conns
  total_mem_mb=$(detect_total_mem_mb)
  # Standard Postgres tuning guidance (shared_buffers ~25% of RAM, effective_cache_size
  # ~50-75%) assumes a server dedicated to nothing but the database. This box also runs
  # gunicorn and nginx and the OS itself, so these are deliberately more conservative —
  # roughly half the textbook fraction — to leave real headroom for everything else,
  # which matters most exactly on the entry-level (512MB-1GB) droplets this script is
  # meant to size correctly for: the gap between "conservative" and "textbook" here is
  # the gap between staying up and the OOM killer picking a process at random.
  shared_buffers_mb=$(( total_mem_mb / 8 ))
  (( shared_buffers_mb < 32 ))  && shared_buffers_mb=32
  (( shared_buffers_mb > 256 )) && shared_buffers_mb=256
  effective_cache_mb=$(( total_mem_mb / 3 ))
  work_mem_mb=4
  maint_mem_mb=$(( total_mem_mb / 16 ))
  (( maint_mem_mb < 16 ))  && maint_mem_mb=16
  (( maint_mem_mb > 128 )) && maint_mem_mb=128
  # A small Django app behind a handful of gunicorn workers never needs Postgres's
  # default 100 connections — each one reserved costs real memory whether it's ever
  # actually used or not.
  max_conns=20

  sudo -u postgres psql <<SQL
ALTER SYSTEM SET shared_buffers = '${shared_buffers_mb}MB';
ALTER SYSTEM SET effective_cache_size = '${effective_cache_mb}MB';
ALTER SYSTEM SET work_mem = '${work_mem_mb}MB';
ALTER SYSTEM SET maintenance_work_mem = '${maint_mem_mb}MB';
ALTER SYSTEM SET max_connections = ${max_conns};
SQL
  sudo systemctl restart postgresql
  ok "PostgreSQL tuned for ${total_mem_mb}MB RAM: shared_buffers=${shared_buffers_mb}MB," \
     "effective_cache_size=${effective_cache_mb}MB, work_mem=${work_mem_mb}MB," \
     "maintenance_work_mem=${maint_mem_mb}MB, max_connections=${max_conns}."

  mark_done postgres_local
}

# ---------------------------------------------------------------------------------------
# Phase: DNS check — identical to deploy-droplet.sh's.
# ---------------------------------------------------------------------------------------
phase_dns_check() {
  log "Phase 8/13: verify DNS points at this droplet"

  local hosts_line
  hosts_line=$(grep '^DJANGO_ALLOWED_HOSTS=' "${APP_DIR}/.env" | cut -d= -f2-)
  IFS=',' read -ra domains <<< "$hosts_line"
  if [[ ${#domains[@]} -eq 0 || -z "${domains[0]}" ]]; then
    die "DJANGO_ALLOWED_HOSTS in .env is empty — fix that before continuing."
  fi

  local droplet_ip
  droplet_ip=$(curl -fsS http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null \
    || curl -fsS https://ifconfig.me)
  echo "This droplet's public IP: ${droplet_ip}"

  local all_ok=true
  for domain in "${domains[@]}"; do
    local resolved
    resolved=$(dig +short "$domain" | tail -n1)
    if [[ "$resolved" == "$droplet_ip" ]]; then
      ok "${domain} -> ${resolved}"
    else
      warn "${domain} resolves to '${resolved:-nothing}', not ${droplet_ip}."
      all_ok=false
    fi
  done

  if ! $all_ok; then
    warn "DNS isn't fully pointed at this droplet yet — this can take anywhere from" \
         "minutes to a few hours to propagate. certbot (next phase) will fail cleanly" \
         "if it isn't ready; you can re-run this script once it is."
    confirm "Continue anyway?" || die "Fix DNS, then re-run this script."
  fi
}

# ---------------------------------------------------------------------------------------
# Phase: nginx + Let's Encrypt — same reverse-proxy shape as deploy-droplet.sh's, just
# pointed at gunicorn's fixed local port instead of a docker-published one.
# ---------------------------------------------------------------------------------------
phase_nginx_tls() {
  log "Phase 9/13: nginx reverse proxy + TLS"

  local hosts_line
  hosts_line=$(grep '^DJANGO_ALLOWED_HOSTS=' "${APP_DIR}/.env" | cut -d= -f2-)
  local server_names="${hosts_line//,/ }"

  if [[ ! -f "/etc/nginx/sites-available/${NGINX_SITE_NAME}" ]]; then
    sudo tee "/etc/nginx/sites-available/${NGINX_SITE_NAME}" >/dev/null <<EOF
server {
    listen 80;
    server_name ${server_names};

    location / {
        proxy_pass http://127.0.0.1:${GUNICORN_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        client_max_body_size 20M;
    }
}
EOF
    sudo ln -sf "/etc/nginx/sites-available/${NGINX_SITE_NAME}" /etc/nginx/sites-enabled/
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo nginx -t
    sudo systemctl reload nginx
    ok "nginx site configured for: ${server_names}"
  else
    # Site exists already. Keep its server_name(s) in step with DJANGO_ALLOWED_HOSTS in
    # case the host list changed on a re-run (see update_allowed_hosts) — but only
    # rewrite when it's actually drifted, so an ordinary re-run stays a no-op. certbot
    # may have added a second server{} block; the sed hits the server_name line in both.
    local site="/etc/nginx/sites-available/${NGINX_SITE_NAME}" want have
    want=$(printf '%s\n' ${server_names} | sort -u | paste -sd' ' -)
    have=$(sudo sed -n 's/^[[:space:]]*server_name[[:space:]]\+\([^;]*\);.*/\1/p' "$site" \
             | tr ' ' '\n' | sed '/^$/d' | sort -u | paste -sd' ' -)
    if [[ -n "$want" && "$want" != "$have" ]]; then
      sudo sed -i "s/^\(\s*server_name\s\+\).*/\1${server_names};/" "$site"
      sudo nginx -t
      sudo systemctl reload nginx
      ok "nginx server_name re-synced from .env: [${have}] -> [${server_names}]"
      warn "If a TLS cert already exists it still covers only the old names — run" \
           "'sudo certbot --nginx --expand -d ${server_names// / -d }' to add the rest."
    else
      ok "nginx site already configured for: ${server_names}"
    fi
  fi

  if sudo test -d "/etc/letsencrypt/live" && sudo find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d | grep -q .; then
    ok "A Let's Encrypt certificate already exists, skipping certbot."
    return
  fi

  local admin_email
  admin_email=$(grep '^DJANGO_ADMIN_EMAIL=' "${APP_DIR}/.env" | cut -d= -f2-)
  [[ -n "$admin_email" ]] || ask admin_email "Email for Let's Encrypt renewal notices"

  local domain_args=()
  for d in ${server_names}; do domain_args+=(-d "$d"); done

  sudo certbot --nginx "${domain_args[@]}" \
    --non-interactive --agree-tos -m "$admin_email" --redirect
  ok "TLS certificate issued and nginx configured to redirect HTTP -> HTTPS."

  sudo certbot renew --dry-run
  ok "Certbot auto-renewal confirmed working (dry run)."
}

# ---------------------------------------------------------------------------------------
# Phase: Python venv + app setup — the Docker-flavored script's "docker compose build"
# equivalent: create the venv, install pinned dependencies, migrate, collectstatic.
# ---------------------------------------------------------------------------------------
phase_app_setup() {
  log "Phase 10/13: Python venv, dependencies, migrations, static files"
  cd "$APP_DIR"

  if [[ ! -x "$(venv_python)" ]]; then
    # Built from the distro-default python3, so this tracks whatever 3.x the image ships.
    # phase_system_packages already enforced the >= ${PYTHON_MIN} floor, but re-check
    # here too: on a re-run that phase is marked done and skipped, and this is the last
    # point before a too-old interpreter would bake itself into the venv.
    python_version_ok || die "python3 is $(system_python_version), older than the" \
      "${PYTHON_MIN} Django 6.0 needs — see phase 4's note. Not creating the venv."
    python3 -m venv env
    ok "Created venv at ${APP_DIR}/env ($("$(venv_python)" --version 2>&1))."
  else
    ok "venv already exists ($("$(venv_python)" --version 2>&1))."
  fi

  "$(venv_pip)" install --upgrade pip --quiet
  "$(venv_pip)" install -r requirements.txt --quiet
  ok "Dependencies installed ($("$(venv_pip)" show Django | awk '/^Version/{print "Django "$2}'))."

  # EnvironmentFile (used by the systemd unit in the next phase) needs .env's real values
  # in *this* shell too, so migrate/collectstatic below see the same config gunicorn will.
  set -a
  # shellcheck disable=SC1091
  source "${APP_DIR}/.env"
  set +a

  cd "$APP_DIR/Portfolio"
  "$(venv_python)" manage.py migrate --noinput
  "$(venv_python)" manage.py collectstatic --noinput >/dev/null
  ok "Migrations applied, static files collected."

  if "$(venv_python)" manage.py shell -c \
       "from django.contrib.auth import get_user_model; import sys; sys.exit(0 if get_user_model().objects.filter(is_superuser=True).exists() else 1)" \
       2>/dev/null; then
    ok "A superuser already exists, skipping createsuperuser."
  else
    echo
    log "Create the admin superuser (interactive — the password is never written to a" \
        "file or log by this script):"
    "$(venv_python)" manage.py createsuperuser
  fi
}

# ---------------------------------------------------------------------------------------
# Phase: systemd service — this is the actual "run it as a monolith" step: gunicorn as a
# managed, auto-restarting service instead of a container. Restart=on-failure + systemd's
# own crash-loop backoff replace what `restart: unless-stopped` gives the Docker version.
# ---------------------------------------------------------------------------------------
phase_systemd_service() {
  log "Phase 11/13: install the gunicorn systemd service"

  local gunicorn_workers
  gunicorn_workers=$(compute_gunicorn_workers)
  echo "Detected: $(detect_total_mem_mb)MB RAM, $(detect_cpu_count) CPU core(s) ->" \
       "${gunicorn_workers} gunicorn workers."

  sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<EOF
[Unit]
Description=DesignWithCory Django app (gunicorn)
After=network.target

[Service]
Type=simple
User=${DEPLOY_USER}
Group=${DEPLOY_USER}
WorkingDirectory=${APP_DIR}/Portfolio
EnvironmentFile=${APP_DIR}/.env
Environment=PYTHONUNBUFFERED=1
ExecStart=${APP_DIR}/env/bin/gunicorn Portfolio.wsgi:application \\
    --bind 127.0.0.1:${GUNICORN_PORT} \\
    --workers ${gunicorn_workers} \\
    --access-logfile - \\
    --error-logfile -
Restart=on-failure
RestartSec=5

# Hardening: everything on disk is read-only to this process except the three paths it
# actually needs to write (the sqlite file + its journal live alongside media/productionfiles
# in this same directory, so one ReadWritePaths entry covers all three).
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${APP_DIR}/Portfolio

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now "${SERVICE_NAME}"

  local tries=0
  until systemctl is-active --quiet "${SERVICE_NAME}"; do
    ((tries++))
    if (( tries > 15 )); then
      die "${SERVICE_NAME}.service did not become active — check" \
          "'journalctl -u ${SERVICE_NAME} -n 50'."
    fi
    sleep 1
  done
  ok "${SERVICE_NAME}.service is active and enabled on boot."
}

# ---------------------------------------------------------------------------------------
# Phase: verify — same shape as deploy-droplet.sh's, checking the systemd service and a
# direct localhost hit on gunicorn in addition to the public HTTPS checks.
# ---------------------------------------------------------------------------------------
phase_verify() {
  log "Phase 12/13: verify the deployment"
  cd "$APP_DIR"

  local hosts_line primary_domain
  hosts_line=$(grep '^DJANGO_ALLOWED_HOSTS=' .env | cut -d= -f2-)
  primary_domain="${hosts_line%%,*}"

  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${GUNICORN_PORT}/" || echo "000")
  if [[ "$code" == "200" ]]; then
    ok "gunicorn itself (http://127.0.0.1:${GUNICORN_PORT}/) -> 200"
  else
    warn "gunicorn itself -> ${code} (expected 200). Check 'journalctl -u ${SERVICE_NAME} -n 50'."
  fi

  code=$(curl -s -o /dev/null -w '%{http_code}' "https://${primary_domain}/" || echo "000")
  if [[ "$code" == "200" ]]; then
    ok "https://${primary_domain}/ -> 200"
  else
    warn "https://${primary_domain}/ -> ${code} (expected 200). Check 'journalctl -u nginx' too."
  fi

  code=$(curl -s -o /dev/null -w '%{http_code}' "https://${primary_domain}/admin/" || echo "000")
  if [[ "$code" == "200" || "$code" == "302" ]]; then
    ok "https://${primary_domain}/admin/ -> ${code}"
  else
    warn "https://${primary_domain}/admin/ -> ${code} (expected 200 or 302)."
  fi

  echo
  log "Django's own --deploy checklist, against this real config:"
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
  (cd Portfolio && "$(venv_python)" manage.py check --deploy) || true
}

# ---------------------------------------------------------------------------------------
# Phase: backups — sqlite/media by default (a straight file copy, since there's no server
# process to dump from); switches to pg_dump automatically if .env's DATABASE_URL points
# at Postgres instead.
# ---------------------------------------------------------------------------------------
phase_backups() {
  log "Phase 13/13: daily backups"
  if phase_done backups; then ok "Already configured, skipping."; return; fi

  sudo mkdir -p "$BACKUP_DIR"
  sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "$BACKUP_DIR"

  local database_url
  database_url=$(grep '^DATABASE_URL=' "${APP_DIR}/.env" | cut -d= -f2-)

  # Both branches: compute the date ONCE into a shell variable rather than calling `date`
  # separately per filename — a job that started just before midnight could otherwise tag
  # its own db/media files with two different dates. And the retention `find` groups its
  # two -name patterns in parens: find's implicit AND binds tighter than -o, so an
  # unparenthesized "-name A -o -name B -mtime +7 -delete" would only ever apply -mtime/
  # -delete to pattern B, silently keeping every db-* backup forever.
  local cron_line
  if [[ -z "$database_url" ]]; then
    # SQLite: the database is a file. sqlite3's own .backup command (not a plain `cp`)
    # takes a consistent snapshot even if gunicorn has the file open mid-write, the same
    # guarantee pg_dump gives for Postgres — a bare file copy wouldn't.
    cron_line="0 3 * * * DATE=\$(date +\%F); sqlite3 ${APP_DIR}/Portfolio/db.sqlite3 \".backup '${BACKUP_DIR}/db-\$DATE.sqlite3'\" && gzip -f ${BACKUP_DIR}/db-\$DATE.sqlite3 && tar czf ${BACKUP_DIR}/media-\$DATE.tar.gz -C ${APP_DIR}/Portfolio media && find ${BACKUP_DIR} \( -name 'db-*.sqlite3.gz' -o -name 'media-*.tar.gz' \) -mtime +7 -delete"
    if ! command -v sqlite3 &>/dev/null; then
      sudo apt-get install -y -qq sqlite3 >/dev/null
    fi
    ok "Daily 03:00 UTC SQLite + media backup cron installed, 7-day local retention."
  else
    # Postgres, local (phase 7) or external (phase 6) — either way dump via .env's own
    # connection string rather than assuming local pg_dump credentials/trust auth exist.
    cron_line="0 3 * * * DATE=\$(date +\%F); pg_dump \"${database_url}\" | gzip > ${BACKUP_DIR}/db-\$DATE.sql.gz && tar czf ${BACKUP_DIR}/media-\$DATE.tar.gz -C ${APP_DIR}/Portfolio media && find ${BACKUP_DIR} \( -name 'db-*.sql.gz' -o -name 'media-*.tar.gz' \) -mtime +7 -delete"
    if ! command -v pg_dump &>/dev/null; then
      sudo apt-get install -y -qq postgresql-client >/dev/null
    fi
    ok "Daily 03:00 UTC Postgres + media backup cron installed, 7-day local retention."
  fi

  (crontab -l 2>/dev/null | grep -vF "$BACKUP_DIR/db-" | grep -vF "$BACKUP_DIR/media-"; echo "$cron_line") | crontab -
  warn "This only protects against a bad migration/fat-fingered DELETE, not against" \
       "losing the droplet itself — ship these off-server too (rclone to Spaces/S3 takes" \
       "about ten more minutes) and PLEASE test a restore at least once. An untested" \
       "backup is a hypothesis."
  mark_done backups
}

print_security_summary() {
  log "Security checklist — live-checked against this droplet:"
  cd "$APP_DIR"

  local check_ok="\033[1;32m[x]\033[0m" check_warn="\033[1;33m[ ]\033[0m"

  sudo grep -q "^PermitRootLogin no" /etc/ssh/sshd_config \
    && echo -e "$check_ok Root SSH login disabled" \
    || echo -e "$check_warn Root SSH login disabled"

  sudo grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config \
    && echo -e "$check_ok Password SSH auth disabled" \
    || echo -e "$check_warn Password SSH auth disabled"

  sudo ufw status | grep -q "Status: active" \
    && echo -e "$check_ok UFW active" \
    || echo -e "$check_warn UFW active"

  systemctl is-active --quiet fail2ban \
    && echo -e "$check_ok fail2ban running" \
    || echo -e "$check_warn fail2ban running"

  systemctl is-active --quiet "${SERVICE_NAME}" \
    && echo -e "$check_ok ${SERVICE_NAME}.service running" \
    || echo -e "$check_warn ${SERVICE_NAME}.service running"

  systemctl is-enabled --quiet "${SERVICE_NAME}" \
    && echo -e "$check_ok ${SERVICE_NAME}.service enabled on boot" \
    || echo -e "$check_warn ${SERVICE_NAME}.service enabled on boot"

  if phase_done local_postgres_requested; then
    systemctl is-active --quiet postgresql \
      && echo -e "$check_ok postgresql.service running (local Postgres)" \
      || echo -e "$check_warn postgresql.service running (local Postgres)"
  fi

  [[ "$(stat -c '%a' .env)" == "600" ]] \
    && echo -e "$check_ok .env permissions are 600" \
    || echo -e "$check_warn .env permissions are 600"

  grep -q "^DJANGO_DEBUG=False" .env \
    && echo -e "$check_ok DJANGO_DEBUG=False" \
    || echo -e "$check_warn DJANGO_DEBUG=False"

  ! grep -q "^DJANGO_SECRET_KEY=$" .env \
    && echo -e "$check_ok DJANGO_SECRET_KEY is set" \
    || echo -e "$check_warn DJANGO_SECRET_KEY is set"

  sudo test -d /etc/letsencrypt/live \
    && echo -e "$check_ok TLS certificate present" \
    || echo -e "$check_warn TLS certificate present"

  systemctl is-active --quiet certbot.timer \
    && echo -e "$check_ok certbot renewal timer armed" \
    || echo -e "$check_warn certbot renewal timer armed"

  crontab -l 2>/dev/null | grep -q "${BACKUP_DIR}/db-\|pg_dump" \
    && echo -e "$check_ok Backup cron installed" \
    || echo -e "$check_warn Backup cron installed"

  echo
  echo "Still manual — this script can't verify these from inside the droplet:"
  echo "  [ ] DigitalOcean Cloud Firewall configured (the network-level half)"
  echo "  [ ] A backup has actually been test-restored at least once"
  echo "  [ ] The admin superuser has a strong, unique password"
  echo "  [ ] Real content uploaded through /admin/ — media/ doesn't travel with git clone"
}

print_next_steps() {
  cat <<EOF

Deploying a future update (no separate doc for this one — it's short):
    ssh ${DEPLOY_USER}@<droplet-ip>
    cd ${APP_DIR} && git pull
    env/bin/pip install -r requirements.txt --quiet
    set -a && source .env && set +a
    (cd Portfolio && ../env/bin/python manage.py migrate --noinput)
    (cd Portfolio && ../env/bin/python manage.py collectstatic --noinput)
    sudo systemctl restart ${SERVICE_NAME}

Logs:      journalctl -u ${SERVICE_NAME} -f
Status:    sudo systemctl status ${SERVICE_NAME}
Restart:   sudo systemctl restart ${SERVICE_NAME}
EOF
}

# ---------------------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------------------
main() {
  # This script no longer bootstraps its own user. It must run *as* the preconfigured
  # non-root "${DEPLOY_USER}" account — not as root (later phases write into that user's
  # $HOME, crontab, and venv, and the systemd unit runs as that user), and not as some
  # other login.
  if [[ $EUID -eq 0 ]]; then
    die "Don't run this as root. It must run as the preconfigured '${DEPLOY_USER}' user" \
        "(create it when you build the droplet: cloud-init 'users:', or" \
        "'adduser ${DEPLOY_USER} && usermod -aG sudo ${DEPLOY_USER}'), then run this as" \
        "${DEPLOY_USER}."
  fi

  if [[ "$(whoami)" != "$DEPLOY_USER" ]]; then
    die "Run this as the '${DEPLOY_USER}' user. You're currently: $(whoami)."
  fi

  # Every phase from here on uses sudo. Prime the sudo timestamp now (this prompts once,
  # interactively, if a password is required) and fail early with a clear message if this
  # user can't sudo at all — better than a confusing failure three phases deep.
  if ! sudo -v; then
    die "'${DEPLOY_USER}' can't use sudo (or sudo needs a password and none was given)." \
        "Add ${DEPLOY_USER} to the sudo group, or run where you can answer the prompt."
  fi

  phase_ssh_hardening
  phase_firewall
  phase_baseline_hardening
  phase_system_packages
  phase_github_deploy_key
  phase_clone_and_env
  phase_postgres_local
  phase_dns_check
  phase_nginx_tls
  phase_app_setup
  phase_systemd_service
  phase_verify
  phase_backups
  print_security_summary
  print_next_steps

  echo
  ok "Done."
}

main "$@"
