"""Archive chain: fetch is a file read, compress shells out with argv."""

from svc.pipeline import exec_backend, validate
from svc.util import storage


def fetch(target):
    return storage.read_bytes(target)


def compress(name, level):
    name = validate.assert_token(name)
    level = validate.assert_int(level, 1, 9)
    return exec_backend.run_argv(["gzip", "-%d" % level, name])
