#!/usr/bin/env bash
# Loads .env into the process environment and starts the local dev server.
# settings.py reads only from os.environ (no dotenv library in play), so this
# has to happen before manage.py runs — see README's Environment Variables section.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if [ ! -f .env ]; then
    echo "No .env found — copy .env.example to .env first (cp .env.example .env)." >&2
    exit 1
fi

set -a
source .env
set +a

if [ -f env/bin/activate ]; then
    source env/bin/activate
fi

exec python Portfolio/manage.py runserver "${1:-8000}"
