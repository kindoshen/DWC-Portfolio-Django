#!/usr/bin/env python
"""Django's command-line utility for administrative tasks."""
import os
import sys


MIN_PYTHON = (3, 8)
MAX_PYTHON_EXCLUSIVE = (3, 13)  # Django 4.2 officially supports 3.8 through 3.12.


def main():
    """Run administrative tasks."""
    if not (MIN_PYTHON <= sys.version_info[:2] < MAX_PYTHON_EXCLUSIVE):
        # Deliberately loud and immediate: running on an unsupported interpreter doesn't
        # fail cleanly, it fails deep inside Django's own internals with a cryptic error
        # that gives no hint the Python version is the actual problem — e.g. Python 3.13+
        # breaks django.template.context.BaseContext.__copy__ with
        # "'super' object has no attribute 'dicts'" on literally any page that extends a
        # template, admin included. Caught this exact failure mode from a virtualenv that
        # had silently been rebuilt against too-new a Python — see README > Prerequisites.
        sys.exit(
            f"Python {'.'.join(map(str, sys.version_info[:3]))} is not supported here — "
            f"this project targets Python {'.'.join(map(str, MIN_PYTHON))} through "
            f"{MAX_PYTHON_EXCLUSIVE[0]}.{MAX_PYTHON_EXCLUSIVE[1] - 1} (Django 4.2 LTS's "
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
