"""Platform gates for tests whose subject only exists on POSIX hosts.

Windows dev boxes can run most of this suite, but three things cannot be
emulated there and must be skipped honestly rather than fail or, worse, pass
vacuously:

* the paid budget journal (``memory_budget_journal.py``) refuses Windows by
  design: it anchors every open on a directory descriptor (``dir_fd``) and
  relies on ``flock``, ``O_NOFOLLOW`` and ``geteuid`` ownership, none of which
  the Windows Python runtime provides;
* fixtures that are ``#!/bin/sh`` scripts cannot be executed (``WinError 193``),
  so a probe that runs them proves nothing;
* permission bits are synthesized from FAT-style attributes (files 0o666,
  directories 0o777), so ``S_IMODE`` assertions describe nothing real.
"""

from __future__ import annotations

import os
import unittest

POSIX = os.name != "nt"

requires_posix_budget_journal = unittest.skipUnless(
    POSIX,
    "budget journal requires POSIX flock/dir_fd (memory_budget_journal.py refuses Windows)",
)
requires_posix_exec = unittest.skipUnless(
    POSIX, "fixture is a #!/bin/sh script; Windows cannot execute it"
)
requires_posix_mode_bits = unittest.skipUnless(
    POSIX, "st_mode permission bits are synthetic on Windows"
)
# The paid-artifact publish path anchors every open on a directory descriptor
# (O_DIRECTORY + dir_fd relative opens + os.link without following symlinks);
# Windows Python cannot open directories at all, so the whole path is POSIX-only.
requires_posix_dir_fd = unittest.skipUnless(
    POSIX, "paid artifact publication requires dir_fd-anchored opens (POSIX only)"
)
