"""Thumbnail rendering chain (guarded)."""

from svc.pipeline import exec_backend, quoting, validate


def render(name, size):
    name = validate.assert_token(name)
    size = validate.assert_int(size, 16, 1024)
    command = "thumb --size %d %s" % (size, quoting.shell_quote(name))
    return exec_backend.run_command(command)
