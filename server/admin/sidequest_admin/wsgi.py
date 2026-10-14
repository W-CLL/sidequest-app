"""WSGI config for sidequest_admin (local tool; run with runserver)."""
import os

from django.core.wsgi import get_wsgi_application

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'sidequest_admin.settings')

application = get_wsgi_application()
