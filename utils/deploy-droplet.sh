#!/usr/bin/env bash
# deploy-droplet.sh — bootstraps a fresh Ubuntu 24.04 DigitalOcean droplet into a running,
# hardened deployment of this app. Companion script to DEPLOYMENT.md: every phase below
# implements one numbered section of that guide, in the same dependency order, for the
# same reasons documented there — read DEPLOYMENT.md for the "why", this is the "how,
# automated."
#
# USAGE
#   Run as root, once, on a brand-new droplet:
#     curl -fsSL https://raw.githubusercontent.com/kindoshen/DWC-Portfolio-Django/main/utils/deploy-droplet.sh -o deploy-droplet.sh
#     bash deploy-droplet.sh
#   It creates a non-root "deploy" user and stops. Log back in as that user and run the
#   *same* script again — it detects the user and continues from there.
#
# SAFE TO RE-RUN. Every phase checks whether its own work is already done and skips it if
# so — if this fails partway (a typo'd domain, DNS not propagated yet, whatever), fix the
# one thing and run it again rather than starting over.
#
# WHAT THIS DOES NOT DO (see DEPLOYMENT.md for why, and do these yourself):
#   - Create the droplet itself (section 2) — that's one `doctl` command or a few clicks,
#     and doing it from inside a script that then needs to run *on* that droplet is
#     backwards.
#   - Add the generated SSH deploy key to GitHub (section 8) — deliberately: this script
#     never touches your GitHub account or holds a personal access token. It prints the
#     key and waits for a human to paste it into GitHub's own UI as a read-only deploy key.
#   - Configure the DigitalOcean Cloud Firewall (section 5) — that's the *network-level*
#     firewall in front of the droplet, not something a script running on the droplet can
#     reach without a DigitalOcean API token. UFW (which this script does configure) is
#     the host-level half of that two-layer design; do the other half in the DO console.
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
STATE_DIR="/opt/.deploy-droplet-state"   # tiny marker files so re-runs skip finished phases

# ---------------------------------------------------------------------------------------
# Small helpers
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
  # Done in Python, not sed: values here include user-typed SMTP passwords, which can
  # contain '/', '&', backslashes, or anything else — passed via environment variables
  # rather than interpolated into a shell/sed pattern, so nothing needs escaping at all.
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

# ---------------------------------------------------------------------------------------
# Phase: root bootstrap (DEPLOYMENT.md section 3) — creates the non-root user and stops.
# Everything after this runs as that user, every time, including re-runs.
# ---------------------------------------------------------------------------------------
phase_root_bootstrap() {
  log "Phase 1/11: create non-root user '${DEPLOY_USER}' (section 3)"

  # Not guaranteed present on a minimal droplet image: rsync (used a few lines down,
  # before any later apt-get phase gets a chance to run), and git (never installed by
  # any later phase either — the Docker install below pulls in docker-ce/compose, none
  # of which depend on git). curl/ca-certificates ARE also installed again later
  # (phase_docker_install) for Docker's own apt repo setup, but a fresh droplet doing
  # nothing but this bootstrap step until then still benefits from having them now.
  apt-get update -qq
  apt-get install -y -qq rsync git curl ca-certificates >/dev/null

  if id "$DEPLOY_USER" &>/dev/null; then
    ok "User '${DEPLOY_USER}' already exists."
  else
    adduser --disabled-password --gecos "" "$DEPLOY_USER"
    usermod -aG sudo "$DEPLOY_USER"
    ok "Created '${DEPLOY_USER}' with sudo rights."
  fi

  if [[ -s /root/.ssh/authorized_keys ]]; then
    rsync --archive --chown="${DEPLOY_USER}:${DEPLOY_USER}" /root/.ssh "/home/${DEPLOY_USER}/"
    ok "Copied root's authorized_keys to ${DEPLOY_USER} so key-based login carries over."
  else
    warn "root has no ~/.ssh/authorized_keys to copy. The next phase disables SSH" \
         "password auth unconditionally (this script assumes local console access, not" \
         "a remote SSH session, so it doesn't gate that on a login self-test) — paste" \
         "your public key into /home/${DEPLOY_USER}/.ssh/authorized_keys yourself first" \
         "if you'll want to SSH in as ${DEPLOY_USER} afterward."
  fi

  echo
  ok "Phase 1 complete."
  echo "    Log out, then log back in as: ssh ${DEPLOY_USER}@<this-droplet-ip>"
  echo "    Then re-run this exact script — it will pick up from phase 2."
  exit 0
}

# ---------------------------------------------------------------------------------------
# Phase: SSH hardening (section 4)
# ---------------------------------------------------------------------------------------
phase_ssh_hardening() {
  log "Phase 2/11: harden SSH (section 4)"
  if phase_done ssh_hardening; then ok "Already done, skipping."; return; fi

  # No "can deploy still SSH in with a key?" self-test here — this script runs locally
  # at the droplet's own console (or an equivalent always-available local session), not
  # over the SSH connection it's about to harden, so there's no remote session at risk
  # of being locked out mid-phase. sshd_config.bak.* below is still kept as the recovery
  # path if ${DEPLOY_USER}'s authorized_keys turns out to be wrong for *future* logins.
  sudo cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"
  sudo sed -i \
    -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
    -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
    -e 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' \
    -e 's/^#\?X11Forwarding.*/X11Forwarding no/' \
    /etc/ssh/sshd_config

  # Ubuntu 24.04 also reads /etc/ssh/sshd_config.d/*.conf, which can silently override the
  # above (e.g. a cloud-init drop-in) — DEPLOYMENT.md section 4 flags this explicitly.
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
# Phase: firewall (section 5 — the UFW/host-level half; the Cloud Firewall half is manual)
# ---------------------------------------------------------------------------------------
phase_firewall() {
  log "Phase 3/11: UFW firewall (section 5)"
  if phase_done firewall; then ok "Already done, skipping."; return; fi

  sudo ufw allow OpenSSH
  sudo ufw allow 80/tcp
  sudo ufw allow 443/tcp
  sudo ufw --force enable
  sudo ufw status verbose
  ok "UFW active: 22, 80, 443 only."

  warn "This only covers the host-level firewall. Also create a DigitalOcean Cloud" \
       "Firewall (22/80/443 inbound, this droplet) in the DO console or via" \
       "'doctl compute firewall create' — DEPLOYMENT.md section 5 has the exact rule" \
       "set. This script can't do that half for you without a DO API token, and" \
       "deliberately doesn't ask you to put one on this server for a one-time setup step."
  mark_done firewall
}

# ---------------------------------------------------------------------------------------
# Phase: fail2ban, unattended-upgrades, swap, timezone (section 6)
# ---------------------------------------------------------------------------------------
phase_baseline_hardening() {
  log "Phase 4/11: fail2ban, automatic updates, swap (section 6)"
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
    sudo fallocate -l 2G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile >/dev/null
    sudo swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
    ok "2G swapfile created and enabled."
  else
    ok "Swapfile already exists."
  fi

  sudo timedatectl set-timezone UTC
  ok "Timezone set to UTC (matches settings.py's TIME_ZONE)."
  mark_done baseline_hardening
}

# ---------------------------------------------------------------------------------------
# Phase: Docker Engine (section 7)
# ---------------------------------------------------------------------------------------
phase_docker_install() {
  log "Phase 5/11: install Docker Engine (section 7)"
  if command -v docker &>/dev/null && sudo docker compose version &>/dev/null; then
    ok "Docker + Compose plugin already installed, skipping."
  else
    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl >/dev/null
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -qq
    sudo apt-get install -y -qq \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
    ok "Docker Engine + Compose plugin installed."
  fi

  sudo systemctl enable --now docker >/dev/null

  if ! groups "$DEPLOY_USER" | grep -q docker; then
    sudo usermod -aG docker "$DEPLOY_USER"
    warn "Added ${DEPLOY_USER} to the 'docker' group — this needs a fresh login to take" \
         "effect. This script uses 'sudo docker' for its own remaining steps regardless" \
         "(so it works right now either way); log out/in later for passwordless" \
         "'docker ...' yourself."
  else
    ok "${DEPLOY_USER} already in the docker group."
  fi

  # Cap container log growth now, before anything's actually running — see section 16.
  if [[ ! -f /etc/docker/daemon.json ]]; then
    echo '{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}' | sudo tee /etc/docker/daemon.json >/dev/null
    sudo systemctl restart docker
    ok "Docker log rotation configured (10m x 3 files per container)."
  fi
}

# ---------------------------------------------------------------------------------------
# Phase: GitHub deploy key (section 8) — generated here, added to GitHub by a human.
# ---------------------------------------------------------------------------------------
phase_github_deploy_key() {
  log "Phase 6/11: authenticate to GitHub with a deploy key (section 8)"

  if [[ -f "$DEPLOY_KEY_PATH" ]]; then
    ok "Deploy key already exists at ${DEPLOY_KEY_PATH}."
  else
    ssh-keygen -t ed25519 -C "$(hostname)-deploy-key" -f "$DEPLOY_KEY_PATH" -N ""
    ok "Generated a new ed25519 deploy key."
  fi

  mkdir -p ~/.ssh
  if ! grep -q "IdentityFile ${DEPLOY_KEY_PATH}" ~/.ssh/config 2>/dev/null; then
    cat >> ~/.ssh/config <<EOF
Host github.com
  HostName github.com
  User git
  IdentityFile ${DEPLOY_KEY_PATH}
  IdentitiesOnly yes
EOF
    chmod 600 ~/.ssh/config
  fi

  if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 \
       | grep -q "successfully authenticated"; then
    ok "GitHub deploy key already authenticated. Skipping the manual step."
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
  cat "${DEPLOY_KEY_PATH}.pub"
  echo "----- END PUBLIC KEY -----"
  echo

  until ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 \
          | grep -q "successfully authenticated"; do
    read -rp "Press Enter once the deploy key is added on GitHub (or Ctrl+C to abort)... "
  done
  ok "GitHub deploy key authenticated."
}

# ---------------------------------------------------------------------------------------
# Phase: clone + .env (section 9)
# ---------------------------------------------------------------------------------------
phase_clone_and_env() {
  log "Phase 7/11: clone the repo and configure .env (section 9)"

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
    ok ".env already exists — leaving it alone. Delete it first if you want this script" \
       "to regenerate it from scratch."
    return
  fi

  cp .env.example .env

  local secret_key postgres_password
  secret_key=$(python3 -c "import secrets; print(secrets.token_urlsafe(50))")
  postgres_password=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")

  echo
  echo "A few values for .env — the rest have sane production defaults already in" \
       ".env.example (see README.md > Environment Variables for the full reference)."
  local primary_domain www_domain admin_email
  ask primary_domain "Primary domain (e.g. designwithcory.com)"
  ask www_domain "www variant (Enter to use www.${primary_domain}, or type 'none' to skip it)" "www.${primary_domain}"
  [[ "$www_domain" == "none" ]] && www_domain=""
  ask admin_email "Email for 500-error alerts + Let's Encrypt renewal notices"

  local allowed_hosts="$primary_domain"
  local csrf_origins="https://${primary_domain}"
  if [[ -n "$www_domain" ]]; then
    allowed_hosts="${allowed_hosts},${www_domain}"
    csrf_origins="${csrf_origins},https://${www_domain}"
  fi

  set_env_var DJANGO_SECRET_KEY "$secret_key"
  set_env_var DJANGO_DEBUG "False"
  set_env_var DJANGO_ALLOWED_HOSTS "$allowed_hosts"
  set_env_var DJANGO_CSRF_TRUSTED_ORIGINS "$csrf_origins"
  set_env_var DJANGO_SECURE_SSL_REDIRECT "True"
  set_env_var DJANGO_BEHIND_PROXY "True"
  set_env_var DJANGO_ADMIN_EMAIL "$admin_email"
  set_env_var POSTGRES_PASSWORD "$postgres_password"

  echo
  if confirm "Configure real SMTP now (for contact-form/lead emails)? Skipping leaves mail printing to the container log."; then
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
         "'docker compose logs web', which is fine for now but revisit before you" \
         "actually rely on the contact form."
  fi

  chmod 600 .env
  ok ".env written and locked to 600. Domains: ${allowed_hosts}"
}

# ---------------------------------------------------------------------------------------
# Phase: DNS check (section 10) — verifies, doesn't configure (that's your DNS provider)
# ---------------------------------------------------------------------------------------
phase_dns_check() {
  log "Phase 8/11: verify DNS points at this droplet (section 10)"

  # Re-derive the domain(s) from .env in case this is a re-run and the variables above
  # were never set this time (phase_clone_and_env returned early because .env existed).
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
# Phase: nginx + Let's Encrypt (section 11)
# ---------------------------------------------------------------------------------------
phase_nginx_tls() {
  log "Phase 9/11: nginx reverse proxy + TLS (section 11)"

  local hosts_line web_port
  hosts_line=$(grep '^DJANGO_ALLOWED_HOSTS=' "${APP_DIR}/.env" | cut -d= -f2-)
  web_port=$(grep '^WEB_PORT=' "${APP_DIR}/.env" | cut -d= -f2-)
  web_port="${web_port:-8000}"
  local server_names="${hosts_line//,/ }"

  if ! command -v nginx &>/dev/null; then
    sudo apt-get install -y -qq nginx >/dev/null
  fi

  if [[ ! -f "/etc/nginx/sites-available/${NGINX_SITE_NAME}" ]]; then
    sudo tee "/etc/nginx/sites-available/${NGINX_SITE_NAME}" >/dev/null <<EOF
server {
    listen 80;
    server_name ${server_names};

    location / {
        proxy_pass http://127.0.0.1:${web_port};
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
    ok "nginx site already configured, skipping."
  fi

  if sudo test -d "/etc/letsencrypt/live" && sudo find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d | grep -q .; then
    ok "A Let's Encrypt certificate already exists, skipping certbot."
    return
  fi

  if ! command -v certbot &>/dev/null; then
    sudo apt-get install -y -qq certbot python3-certbot-nginx >/dev/null
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
# Phase: build + launch the stack (section 12)
# ---------------------------------------------------------------------------------------
phase_launch_stack() {
  log "Phase 10/11: build and launch the Docker Compose stack (section 12)"
  cd "$APP_DIR"

  sudo docker compose build
  sudo docker compose up -d

  log "Waiting for the database to report healthy..."
  # Via `docker inspect` on the actual container ID, not `docker compose ps --format` —
  # the Go-template fields compose's own `ps` exposes differ across Compose versions and
  # don't reliably include a Health field; the container's own health status via inspect
  # does, on every Docker version this script installs.
  local db_container tries=0
  db_container=$(sudo docker compose ps -q db)
  [[ -n "$db_container" ]] || die "No 'db' container found — did 'docker compose up -d' actually start it?"
  until [[ "$(sudo docker inspect --format='{{.State.Health.Status}}' "$db_container" 2>/dev/null)" == "healthy" ]]; do
    ((tries++))
    if (( tries > 30 )); then die "db never became healthy — check 'docker compose logs db'."; fi
    sleep 2
  done
  ok "Database healthy."

  sudo docker compose exec web python manage.py migrate
  sudo docker compose exec web python manage.py collectstatic --noinput
  ok "Migrations applied, static files collected."

  if sudo docker compose exec web python manage.py shell -c \
       "from django.contrib.auth import get_user_model; import sys; sys.exit(0 if get_user_model().objects.filter(is_superuser=True).exists() else 1)" \
       2>/dev/null; then
    ok "A superuser already exists, skipping createsuperuser."
  else
    echo
    log "Create the admin superuser (interactive — the password is never written to a" \
        "file or log by this script):"
    sudo docker compose exec web python manage.py createsuperuser
  fi
}

# ---------------------------------------------------------------------------------------
# Phase: verify (section 13)
# ---------------------------------------------------------------------------------------
phase_verify() {
  log "Phase 11/11: verify the deployment (section 13)"
  cd "$APP_DIR"

  local hosts_line primary_domain
  hosts_line=$(grep '^DJANGO_ALLOWED_HOSTS=' .env | cut -d= -f2-)
  primary_domain="${hosts_line%%,*}"

  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' "https://${primary_domain}/" || echo "000")
  if [[ "$code" == "200" ]]; then
    ok "https://${primary_domain}/ -> 200"
  else
    warn "https://${primary_domain}/ -> ${code} (expected 200). Check 'docker compose logs web' and 'journalctl -u nginx'."
  fi

  code=$(curl -s -o /dev/null -w '%{http_code}' "https://${primary_domain}/admin/" || echo "000")
  if [[ "$code" == "200" || "$code" == "302" ]]; then
    ok "https://${primary_domain}/admin/ -> ${code}"
  else
    warn "https://${primary_domain}/admin/ -> ${code} (expected 200 or 302)."
  fi

  echo
  log "Django's own --deploy checklist, against this real config:"
  sudo docker compose exec web python manage.py check --deploy || true
}

# ---------------------------------------------------------------------------------------
# Beyond the core 11 phases above (which mirror DEPLOYMENT.md sections 3-13 one-to-one):
# a bit of section 15 (backup cron) worth setting up right away rather than as a later
# manual step, and a live-checked recap of section 17's checklist to close out on.
# ---------------------------------------------------------------------------------------
phase_backups() {
  log "Bonus: daily Postgres backups (section 15)"
  if phase_done backups; then ok "Already configured, skipping."; return; fi

  sudo mkdir -p "$BACKUP_DIR"
  sudo chown "${DEPLOY_USER}:${DEPLOY_USER}" "$BACKUP_DIR"

  local pg_user pg_db
  pg_user=$(grep '^POSTGRES_USER=' "${APP_DIR}/.env" | cut -d= -f2-)
  pg_db=$(grep '^POSTGRES_DB=' "${APP_DIR}/.env" | cut -d= -f2-)

  local cron_line
  cron_line="0 3 * * * cd ${APP_DIR} && docker compose exec -T db pg_dump -U ${pg_user} ${pg_db} | gzip > ${BACKUP_DIR}/db-\$(date +\%F).sql.gz && find ${BACKUP_DIR} -name '*.sql.gz' -mtime +7 -delete"

  (crontab -l 2>/dev/null | grep -vF "$BACKUP_DIR/db-"; echo "$cron_line") | crontab -
  ok "Daily 03:00 UTC Postgres backup cron installed, 7-day local retention."
  warn "This only protects against a bad migration/fat-fingered DELETE, not against" \
       "losing the droplet itself — see DEPLOYMENT.md section 15 for shipping these" \
       "off-server (rclone to Spaces/S3 takes about ten more minutes) and PLEASE test" \
       "a restore at least once. An untested backup is a hypothesis."
  mark_done backups
}

print_security_summary() {
  log "Security checklist (section 17) — live-checked against this droplet:"
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

  crontab -l 2>/dev/null | grep -q "pg_dump" \
    && echo -e "$check_ok Backup cron installed" \
    || echo -e "$check_warn Backup cron installed"

  echo
  echo "Still manual — this script can't verify these from inside the droplet:"
  echo "  [ ] DigitalOcean Cloud Firewall configured (section 5 — the network-level half)"
  echo "  [ ] A backup has actually been test-restored at least once (section 15)"
  echo "  [ ] The admin superuser has a strong, unique password"
  echo "  [ ] Real content uploaded through /admin/ — media/ doesn't travel with git clone"
}

# ---------------------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------------------
main() {
  if [[ $EUID -eq 0 ]]; then
    phase_root_bootstrap   # exits on its own
  fi

  if [[ "$(whoami)" != "$DEPLOY_USER" ]]; then
    die "Run this as root (first time only) or as '${DEPLOY_USER}' (every time after)." \
        "You're currently: $(whoami)."
  fi

  phase_ssh_hardening
  phase_firewall
  phase_baseline_hardening
  phase_docker_install
  phase_github_deploy_key
  phase_clone_and_env
  phase_dns_check
  phase_nginx_tls
  phase_launch_stack
  phase_verify
  phase_backups
  print_security_summary

  echo
  ok "Done. See DEPLOYMENT.md sections 14-16 for how to deploy future updates, read" \
     "logs, and manage backups going forward."
}

main "$@"
