"""Filesystem access rooted at the asset directory."""

import os

ASSET_ROOT = os.environ.get("SVC_ASSET_ROOT", "/var/lib/svc/assets")


def read_bytes(relative):
    with open(os.path.join(ASSET_ROOT, relative), "rb") as handle:
        return handle.read()


def exists(relative):
    return os.path.exists(os.path.join(ASSET_ROOT, relative))
