#!/usr/bin/env python
"""Django's command-line utility for administrative tasks."""
import os
import sys


MIN_PYTHON = (3, 12)
MAX_PYTHON_EXCLUSIVE = (3, 15)  # Django 6.0 officially supports 3.12 through 3.14.


def main():
    """Run administrative tasks."""
    if not (MIN_PYTHON <= sys.version_info[:2] < MAX_PYTHON_EXCLUSIVE):
        # Deliberately loud and immediate: running on an unsupported interpreter doesn't
        # fail cleanly, it fails deep inside Django's own internals (or the interpreter's
        # own parser, on `import django` itself) with a cryptic low-level error that gives
        # no hint the Python version is the actual problem. Django 6.0 requires 3.12+;
        # caught the equivalent failure mode with Django 4.2 on too-new a Python from a
        # virtualenv that had silently been rebuilt — see README > Prerequisites.
        sys.exit(
            f"Python {'.'.join(map(str, sys.version_info[:3]))} is not supported here — "
            f"this project targets Python {'.'.join(map(str, MIN_PYTHON))} through "
            f"{MAX_PYTHON_EXCLUSIVE[0]}.{MAX_PYTHON_EXCLUSIVE[1] - 1} (Django 6.0's "
            "supported range). If this is a fresh `python -m venv env`, recreate it with "
            "one of those versions explicitly, e.g.: python3.12 -m venv env"
        )
    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'Portfolio.settings')
    try:
        from django.core.management import execute_from_command_line
    except ImportError as exc:
        raise ImportError(
            "Couldn't import Django. Are you sure it's installed and "
            "available on your PYTHONPATH environment variable? Did you "
            "forget to activate a virtual environment?"
        ) from exc
    execute_from_command_line(sys.argv)


if __name__ == '__main__':
    main()
