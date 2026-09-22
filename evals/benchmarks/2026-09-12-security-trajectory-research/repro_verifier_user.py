"""Neutral Linux probe: root reopens a non-root-owned temporary log.

Run in a disposable container with /tmp and /workdir mounted as writable tmpfs.
No benchmark code, model calls, network, or changes to kernel settings.
"""
import json
import os
from pathlib import Path
import tempfile

assert os.getuid() == 0, 'Run as root in a disposable container'
paths = [Path('/tmp/uid-probe.log'), Path('/workdir/uid-probe.log')]
child = os.fork()
if child == 0:
    os.setuid(1001)
    for path in paths:
        path.write_text('neutral log\n')
        # World-writable controls distinguish sticky-directory protection
        # from ordinary discretionary file permissions.
        path.chmod(0o666)
        with path.open('w') as handle:
            handle.write('same UID reopen succeeds\n')
    os._exit(0)
_, status = os.waitpid(child, 0)
assert status == 0, status
results = []
for path in paths:
    entry = {'path': str(path), 'owner_uid': path.stat().st_uid,
             'mode': oct(path.stat().st_mode & 0o7777)}
    try:
        with path.open('w') as handle:
            handle.write('root reopen\n')
        entry['root_reopen'] = 'success'
    except OSError as exc:
        entry['root_reopen'] = type(exc).__name__
        entry['errno'] = exc.errno
    results.append(entry)
with tempfile.NamedTemporaryFile(prefix='root-probe-', dir='/tmp') as handle:
    handle.write(b'new unique temporary file succeeds\n')
print(json.dumps({'sysctl_protected_regular': Path('/proc/sys/fs/protected_regular').read_text().strip(),
                  'same_uid_reopen': 'success', 'root_unique_tmpfile': 'success',
                  'results': results}, indent=2))
