"""Target path normalisation used by the download chain."""

import os.path

from svc.pipeline import validate


def normalize_target(raw):
    cleaned = raw.replace("\\", "/")
    cleaned = os.path.normpath(cleaned)
    return validate.assert_relative(cleaned)
