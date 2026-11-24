"""The installer scripts refuse to move an install to an older version even
when the release unit predates that check in `metacodes install` (releases up
to 0.5.0), and leave the decision to a unit that carries it.

Both scripts copy the installer's semantic-version order (apps/cli/src/app/install.zig
`isOlder` over std.SemanticVersion): install.sh `version_older` (sh + awk) and
install.ps1 `Test-OlderVersion`. They are held to the rows of
apps/cli/src/app/install.zig `version_order_cases`, the table `isOlder` itself is tested
against, so the three cannot drift apart unnoticed.

install.sh runs end to end against a stand-in release unit whose executable
records its arguments; install.ps1 is checked through its order function only
(its stand-in would have to be a Windows executable).

The same stand-in shows where install.sh tells a unit it came from, for
`metacodes update` (doc/UPDATE_DESIGN.md §3): a published release, served from a
loopback mirror, is installed with `--release-base <base>` when the unit's
`install --help` names that option and without it otherwise; an archive or unit
named on the command line is installed with neither, so the install keeps the
source it had.
"""
import hashlib
import http.server
import io
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INSTALL_SH = ROOT / "scripts" / "install.sh"
INSTALL_PS1 = ROOT / "scripts" / "install.ps1"
INSTALL_ZIG = ROOT / "src" / "app" / "install.zig"


def order_cases():
    """(candidate, installed, candidate precedes installed) rows of
    `version_order_cases` in apps/cli/src/app/install.zig."""
    text = INSTALL_ZIG.read_text(encoding="utf-8")
    block = text.split("// BEGIN version order cases", 1)[1].split("// END version order cases", 1)[0]
    rows = [(a, b, c == "true") for a, b, c in re.findall(r'\.\{ "([^"]*)", "([^"]*)", (true|false) \}', block)]
    if len(rows) < 30:
        raise AssertionError(f"read only {len(rows)} version order rows from {INSTALL_ZIG}")
    return rows


def posix_shells():
    """/bin/sh plus every other POSIX shell found, once per real binary (on
    Linux /bin/sh is dash; on macOS it is bash in POSIX mode)."""
    found, seen = [], set()
    for name in ("/bin/sh", shutil.which("dash"), shutil.which("bash")):
        if name and os.path.exists(name):
            real = os.path.realpath(name)
            if real not in seen:
                seen.add(real)
                found.append(name)
    return found


# The executable of a release unit as far as install.sh can tell: it answers
# `install --help` (naming --allow-downgrade only when the unit carries the
# check) and records the arguments of the install it is asked to do.
STUB = """#!/bin/sh
if [ "$1" = install ] && [ "$2" = --help ]; then
  echo "usage: metacodes install --prefix <dir> [--upgrade]{guard_option} [--force]{source_options}" >&2
  exit 0
fi
printf '%s\\n' "$@" > "$STUB_ARGV"
"""


@unittest.skipUnless(os.name == "posix", "install.sh is the POSIX installer")
class InstallShTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        (self.tmp / "home").mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def unit(self, version, guards, sources=False, parent=None):
        """A release unit of `version`; `guards`: its install refuses
        downgrades; `sources`: it can record where it came from."""
        unit = Path(tempfile.mkdtemp(dir=parent or self.tmp, prefix="unit-"))
        (unit / "bin").mkdir()
        (unit / "manifest.json").write_text(
            '{\n  "schema_version": 2,\n  "vendor": "metask",\n  "name": "metacodes-cli",\n'
            f'  "release": {{\n    "version": "{version}",\n    "channel": "pre"\n  }}\n}}\n',
            encoding="utf-8",
        )
        exe = unit / "bin" / "metacodes"
        exe.write_text(
            STUB.replace("{guard_option}", " [--allow-downgrade]" if guards else "").replace(
                "{source_options}", " [--release-base <url> | --checkout <dir>]" if sources else ""
            ),
            encoding="utf-8",
        )
        exe.chmod(0o755)
        return unit

    def prefix(self, installed):
        """An install prefix whose record names `installed` (none when None),
        written the way `metacodes install` writes it."""
        prefix = self.tmp / "opt" / "metacodes"
        record = prefix / "etc" / "metacodes"
        record.mkdir(parents=True, exist_ok=True)
        if installed is not None:
            (record / "install.json").write_text(
                f'{{\n  "schema_version": "metacodes-install-v1",\n  "version": "{installed}",\n  "state_root": "state"\n}}\n',
                encoding="utf-8",
            )
        return prefix

    def host(self, system, machine, translated=None):
        """A PATH entry that makes install.sh see another host: `uname -s` /
        `uname -m` answer `system` / `machine`, and `sysctl -n
        sysctl.proc_translated` answers `translated` (1 in a Rosetta shell on
        Apple Silicon) or fails as on Linux and older macOS."""
        directory = Path(tempfile.mkdtemp(dir=self.tmp, prefix="host-"))
        real_uname = shutil.which("uname")
        (directory / "uname").write_text(
            f'#!/bin/sh\ncase "$1" in -s) echo {system} ;; -m) echo {machine} ;; *) exec {real_uname} "$@" ;; esac\n',
            encoding="utf-8",
        )
        answer = f"echo {translated}; exit 0" if translated is not None else "exit 1"
        (directory / "sysctl").write_text(
            f'#!/bin/sh\nif [ "$1 $2" = "-n sysctl.proc_translated" ]; then {answer}; fi\nexit 1\n',
            encoding="utf-8",
        )
        for name in ("uname", "sysctl"):
            (directory / name).chmod(0o755)
        return directory

    def install(self, unit, prefix, *options, shell="/bin/sh", host=None):
        """Runs install.sh; returns (exit code, stderr, the unit's install
        arguments or None when the unit was not asked to install). A `unit` of
        None installs a published release (`options` name the mirror); `host`
        is a directory from host() to put first on PATH."""
        argv_file = self.tmp / "argv"
        if argv_file.exists():
            argv_file.unlink()
        path = os.environ.get("PATH", os.defpath)
        completed = subprocess.run(
            [shell, str(INSTALL_SH), "--no-link", "--no-sdk", "--prefix", str(prefix), *options, *([str(unit)] if unit else [])],
            # A user locale whose collation is not ASCII order: the order must
            # not depend on it.
            env={
                "PATH": f"{host}{os.pathsep}{path}" if host else path,
                "HOME": str(self.tmp / "home"),
                "STUB_ARGV": str(argv_file),
                "LC_ALL": "en_US.UTF-8",
            },
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
            check=False,
        )
        argv = argv_file.read_text(encoding="utf-8").splitlines() if argv_file.exists() else None
        return completed.returncode, completed.stderr, argv

    def test_an_earlier_unit_is_held_to_the_installers_version_order(self):
        cases = order_cases()
        for shell in posix_shells():
            for candidate, installed, older in cases:
                with self.subTest(shell=shell, candidate=candidate, installed=installed):
                    code, err, argv = self.install(self.unit(candidate, False), self.prefix(installed), shell=shell)
                    if older:
                        self.assertNotEqual(code, 0, err)
                        self.assertIn(f"holds metacodes {installed}, newer than {candidate}", err)
                        self.assertIsNone(argv, "the unit was asked to install over a newer version")
                    else:
                        self.assertEqual(code, 0, err)
                        self.assertNotIn("newer than", err)
                        self.assertIsNotNone(argv)

    def test_an_earlier_unit_downgrades_only_when_asked_and_never_sees_the_option(self):
        unit, prefix = self.unit("0.5.0", False), self.prefix("0.6.0")
        code, err, argv = self.install(unit, prefix, "--allow-downgrade")
        self.assertEqual(code, 0, err)
        self.assertIn("replacing metacodes 0.6.0 with the older 0.5.0", err)
        self.assertIn("--upgrade", argv)
        self.assertNotIn("--allow-downgrade", argv)  # it would reject it as unknown

        code, err, argv = self.install(unit, prefix, "--force")
        self.assertEqual(code, 0, err)
        self.assertIn("--force", argv)
        self.assertNotIn("--allow-downgrade", argv)

        code, err, argv = self.install(self.unit("0.6.1", False), prefix)
        self.assertEqual(code, 0, err)
        self.assertNotIn("replacing", err)

    def test_a_unit_that_carries_the_check_decides_for_itself(self):
        unit, prefix = self.unit("0.5.0", True), self.prefix("0.6.0")
        code, err, argv = self.install(unit, prefix)
        self.assertEqual(code, 0, err)
        self.assertNotIn("newer than", err)  # the script left the refusal to the unit
        self.assertNotIn("--allow-downgrade", argv)

        code, err, argv = self.install(unit, prefix, "--allow-downgrade")
        self.assertEqual(code, 0, err)
        self.assertNotIn("replacing", err)
        self.assertIn("--allow-downgrade", argv)

    def test_a_fresh_prefix_has_nothing_to_compare(self):
        prefix = self.tmp / "opt" / "fresh"
        code, err, argv = self.install(self.unit("0.5.0", False), prefix)
        self.assertEqual(code, 0, err)
        self.assertEqual(argv[:4], ["install", "--prefix", str(prefix), "--upgrade"])

    def test_a_unit_named_on_the_command_line_records_no_source(self):
        code, err, argv = self.install(self.unit("0.8.0", True, sources=True), self.prefix(None))
        self.assertEqual(code, 0, err)
        self.assertNotIn("--release-base", argv)
        self.assertNotIn("--checkout", argv)

    def test_a_published_release_records_the_mirror_it_came_from(self):
        # Any host with a release does; this one is fixed so the test runs on
        # every POSIX machine (the next test covers the others).
        host = self.host("Linux", "x86_64")
        for sources in (True, False):
            with self.subTest(sources=sources), ReleaseMirror(self, "0.8.0", "x86_64-linux-gnu", sources) as mirror:
                code, err, argv = self.install(None, self.prefix(None), "--release-base", mirror.base + "/", host=host)
                self.assertEqual(code, 0, err)
                self.assertEqual(argv[:4], ["install", "--prefix", str(self.tmp / "opt" / "metacodes"), "--upgrade"])
                if sources:
                    # The trailing slash is install.sh's to drop, as always.
                    self.assertEqual(argv[argv.index("--release-base") + 1], mirror.base)
                else:
                    self.assertNotIn("--release-base", argv)  # it would reject it as unknown
                self.assertTrue(mirror.served("/latest"))

    def test_a_published_release_is_the_archive_of_the_hosts_target(self):
        """host_target (#307): the mirror's release holds only the expected
        target's archive, so any other pick fails its download."""
        cases = (
            ("Darwin", "arm64", None, "aarch64-macos"),
            ("Darwin", "x86_64", "0", "x86_64-macos"),
            ("Darwin", "x86_64", None, "x86_64-macos"),  # no sysctl.proc_translated (before macOS 11)
            ("Darwin", "x86_64", "1", "aarch64-macos"),  # a Rosetta shell on Apple Silicon
            ("Linux", "x86_64", None, "x86_64-linux-gnu"),
            ("Linux", "aarch64", None, "aarch64-linux-gnu"),
            ("Linux", "arm64", None, "aarch64-linux-gnu"),
        )
        for system, machine, translated, target in cases:
            with self.subTest(system=system, machine=machine, translated=translated), \
                    ReleaseMirror(self, "0.8.0", target, True) as mirror:
                code, err, argv = self.install(None, self.prefix(None), "--release-base", mirror.base, "--version", "0.8.0",
                                               host=self.host(system, machine, translated))
                self.assertEqual(code, 0, err)
                self.assertIn(f"metacodes 0.8.0 for {target} from {mirror.base}", err)
                self.assertTrue(mirror.served(f"/download/0.8.0/metacodes-0.8.0-{target}.tar.gz"))
                self.assertIsNotNone(argv)

    def test_a_host_without_a_release_is_refused_before_any_download(self):
        for system, machine in (("Linux", "riscv64"), ("Linux", "armv7l"), ("FreeBSD", "amd64")):
            with self.subTest(system=system, machine=machine), \
                    ReleaseMirror(self, "0.8.0", "x86_64-linux-gnu", True) as mirror:
                code, err, argv = self.install(None, self.prefix(None), "--release-base", mirror.base, "--version", "0.8.0",
                                               host=self.host(system, machine))
                self.assertNotEqual(code, 0)
                self.assertIn(f"no metacodes release is built for {system} {machine}", err)
                self.assertEqual(mirror.requests, [])
                self.assertIsNone(argv)


class ReleaseMirror:
    """A loopback copy of the releases page layout: `latest` redirects to
    `tag/<version>`, and `download/<version>/` holds the release's
    SHA256SUMS and the target's archive of a stand-in unit."""

    def __init__(self, test, version, target, sources):
        root_name = f"metacodes-{version}-{target}"
        staging = Path(tempfile.mkdtemp(dir=test.tmp, prefix="mirror-"))
        unit = test.unit(version, True, sources=sources, parent=staging)
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
            archive.add(str(unit), arcname=root_name)
        asset = f"{root_name}.tar.gz"
        data = buffer.getvalue()
        sums = f"{hashlib.sha256(data).hexdigest()}  {asset}\n".encode()
        self.files = {
            f"/r/download/{version}/{asset}": data,
            f"/r/download/{version}/metacodes-{version}-SHA256SUMS": sums,
        }
        self.version = version
        self.requests = []

    def served(self, suffix):
        return any(path.endswith(suffix) for path in self.requests)

    def __enter__(self):
        mirror = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_HEAD(self):  # noqa: N802 — install.sh asks for `latest` with curl -I
                self.do_GET(head=True)

            def do_GET(self, head=False):  # noqa: N802 (http.server's name)
                mirror.requests.append(self.path)
                if self.path == "/r/latest":
                    self.send_response(302)
                    self.send_header("Location", f"{mirror.base}/tag/{mirror.version}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if self.path == f"/r/tag/{mirror.version}":
                    body = b"release page"
                elif self.path in mirror.files:
                    body = mirror.files[self.path]
                else:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if not head:
                    self.wfile.write(body)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}/r"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


def powershell():
    """PowerShell 7 where installed (GitHub's Linux and macOS runners carry
    it), else Windows PowerShell on Windows."""
    for name in ("pwsh", "powershell"):
        found = shutil.which(name)
        if found and (name == "pwsh" or os.name == "nt"):
            return found
    return None


@unittest.skipUnless(powershell(), "no PowerShell on this host")
class InstallPs1Test(unittest.TestCase):
    def test_install_ps1_is_held_to_the_installers_version_order(self):
        text = INSTALL_PS1.read_text(encoding="utf-8")
        function = text.split("# BEGIN version order", 1)[1].split("# END version order", 1)[0]
        cases = order_cases()
        rows = "\n".join(f"@('{a}', '{b}')," for a, b, _ in cases)
        script = function + "\n$cases = @(\n" + rows + "\n$null)\n" + (
            "foreach ($case in $cases) { if ($null -ne $case) { if (Test-OlderVersion $case[0] $case[1]) { 'True' } else { 'False' } } }\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "order.ps1"
            path.write_text(script, encoding="utf-8-sig")
            completed = subprocess.run(
                [powershell(), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(path)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=120,
                check=False,
            )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        answers = completed.stdout.split()
        self.assertEqual(len(answers), len(cases), completed.stdout + completed.stderr)
        for (candidate, installed, older), answer in zip(cases, answers):
            with self.subTest(candidate=candidate, installed=installed):
                self.assertEqual(answer, str(older))


if __name__ == "__main__":
    unittest.main()
