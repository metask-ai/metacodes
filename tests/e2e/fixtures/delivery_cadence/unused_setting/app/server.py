"""Server (reads its settings at import time)."""

from app import settings

INSTANCE_NAME = settings.get("core.instance_name")
LISTEN_PORT = settings.get_int("core.listen_port")
DEBUG_ENDPOINTS = settings.get_bool("core.debug_endpoints")


def describe():
    return "server"
