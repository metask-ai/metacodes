"""Dispatch a job to its worker module by name."""

import importlib


def dispatch(job, ctx):
    module = importlib.import_module("workers.%s" % job.payload["kind"])
    return module.run(job, ctx)
