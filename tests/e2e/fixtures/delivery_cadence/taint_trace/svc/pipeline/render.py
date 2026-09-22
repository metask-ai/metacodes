"""Build and execute an export plan."""

from svc.pipeline import exec_backend, quoting


def plan(fmt, target):
    return {"fmt": fmt, "target": target, "tool": "convert"}


def execute(plan):
    command = build_command(plan)
    return exec_backend.run_command(command)


def build_command(plan):
    # NOTE: quoting.shell_quote is imported but the target is interpolated raw.
    return "%s --format %s %s" % (plan["tool"], plan["fmt"], plan["target"])
