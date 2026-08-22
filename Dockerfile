# Build context is the repo root (see docker-compose.yml) so this can COPY both
# requirements.txt (root) and the Django project itself (Portfolio/).
FROM python:3.12-slim

# Runtime-only env: keeps pip/python from writing .pyc files or buffering stdout, neither
# of which you want in a container's logs.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Dependencies first, isolated from app-code changes, so this layer only rebuilds when
# requirements.txt actually changes rather than on every code edit.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY Portfolio/ .

# Runs as a non-root user — psycopg2-binary/Pillow are wheel installs with no compiled
# artifacts that need root, and there's no reason this process needs root at runtime.
RUN useradd --create-home --shell /bin/bash django \
    && mkdir -p /app/media /app/productionfiles \
    && chown -R django:django /app
USER django

EXPOSE 8000

# migrate/collectstatic are deliberately NOT run automatically here — see README.md
# "Deployment" for the explicit `docker compose exec` steps. Auto-running migrations on
# every container start/restart is a common source of surprise mid-deploy; explicit is
# safer for a small, single-replica setup like this one.
CMD ["gunicorn", "Portfolio.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "3"]
