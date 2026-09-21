"""Mirror chain: remote names are validated against a fixed table."""

from svc.pipeline import exec_backend
from svc.util import remotes


def pull(remote):
    url = remotes.resolve(remote)  # raises for unknown remotes
    return exec_backend.run_argv(["git", "fetch", url])
