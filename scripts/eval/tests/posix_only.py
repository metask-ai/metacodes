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
import tempfile
import unittest

POSIX = os.name != "nt"


def _probe_symlinks() -> bool:
    root = tempfile.mkdtemp()
    try:
        target = os.path.join(root, "target")
        link = os.path.join(root, "link")
        with open(target, "w", encoding="utf-8"):
            pass
        os.symlink(target, link)
        return True
    except (OSError, NotImplementedError):
        return False
    finally:
        try:
            os.unlink(os.path.join(root, "link"))
        except OSError:
            pass
        try:
            os.unlink(os.path.join(root, "target"))
        except OSError:
            pass
        try:
            os.rmdir(root)
        except OSError:
            pass


SYMLINKS_SUPPORTED = _probe_symlinks()
requires_symlinks = unittest.skipUnless(
    SYMLINKS_SUPPORTED,
    "symlink creation is not permitted on this host (Windows needs SeCreateSymbolicLinkPrivilege or Developer Mode)",
)

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
