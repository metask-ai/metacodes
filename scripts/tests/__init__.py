"""Repository control-plane tests."""

import sys

if sys.version_info < (3, 9):  # issue #59: the suites are written for the macOS system python3
    raise SystemExit(
        f"metacodes: the Python suites need Python >= 3.9, found {sys.version.split()[0]}; see requirements-dev.txt"
    )

from scripts import test_ids  # noqa: E402

test_ids.record_unittest_results("scripts-tests")
