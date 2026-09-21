"""Export dispatch: picks a renderer for the requested format."""

from svc.pipeline import render, validate


def select(fmt, target):
    # The format is whitelisted; the target is passed through as given
    # because renderers were expected to quote it themselves.
    fmt = validate.assert_format(fmt)
    plan = render.plan(fmt, target)
    return render.execute(plan)
