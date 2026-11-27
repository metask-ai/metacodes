"""Only the Renderer writes past the inline viewport.

The REPL draws its input box and spinner in a region at the bottom of the main
screen and lets everything above it flow into the terminal's own scrollback,
which has no undo. doc/TUI_VIEWPORT_OWNERSHIP.md is the ownership model; this
scan enforces the part of it that is visible in the source of ``apps/cli/src/repl/``:

* **erase**: nothing erases more of the display than ED 0. The ED 1/2/3 bytes
  are spelled only in ``tui/ansi.zig``, and its ``clear.screen``,
  ``clear.screen_and_home`` and ``clear.to_start_of_screen`` are used only by
  ``RenderRegion.resetScreen`` (Ctrl+L, ``/clear``, ``/resume``). ED 3 would
  also wipe the user's scrollback from before the session.
* **anchor**: no cursor save/restore (DECSC/DECRC ``ESC 7``/``ESC 8``, SCO
  ``CSI s``/``CSI u``). A saved position is an absolute screen row; the frame's
  own newlines scroll the screen under it, and Warp does not restore DECRC. The
  region climbs back by the rows it tracked (``reflow.Anchor``).
* **sink**: the terminal is written only by the functions in ``ALLOWED_SINKS``:
  the Renderer's ``flush``, and code that runs while the region is erased or
  frozen, on the alternate screen, before the region exists, without drawing
  anything, or on a regular file. Text for the scrollback goes through the
  Renderer (``emitToScroll`` while generating, ``emitTerminal`` /
  ``emitScrollback`` otherwise), which erases the region, prints, and draws it
  again in one frame.

String literals are read the way Zig reads them (``\\x1b``, ``\\u{1b}``, a raw
ESC byte, literals joined with ``++`` on one line). Comments are not code, and
test blocks are not scanned: their fixtures spell these sequences on purpose.
"""
from __future__ import annotations

import re
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCOPE = Path("apps/cli/src/repl")
ADR = "doc/TUI_VIEWPORT_OWNERSHIP.md"

# Where the wide-erase bytes may be spelled: the escape table defines them.
WIDE_ERASE_BYTES_ALLOWED = {Path("apps/cli/src/repl/tui/ansi.zig")}
# Who may use ansi.zig's wide-erase names: the one user-requested screen reset.
WIDE_ERASE_NAMES_ALLOWED = {(Path("apps/cli/src/repl/tui/render_region.zig"), "resetScreenInFrame")}

# (file, function) -> why it may write to a terminal (or a file) directly.
# "*" is every function in the file. Every entry must still match a write.
ALLOWED_SINKS = {
    # The Renderer. Every frame, and every byte for the scrollback while the
    # region exists, leaves through here.
    (Path("apps/cli/src/repl/tui/render_region.zig"), "flush"): "the Renderer's one write to the terminal",
    # Slash-command output and the banner: printed before the first read, or
    # after readLineRaw's defer erased the region; the next read draws it again.
    (Path("apps/cli/src/repl/cmd_output.zig"), "flushEcho"): "command echo, region erased",
    (Path("apps/cli/src/repl/cmd_output.zig"), "end"): "command result block, region erased",
    (Path("apps/cli/src/repl/cmd_output.zig"), "print"): "command result text, region erased",
    (Path("apps/cli/src/repl/cmd_output.zig"), "notice"): "command notice, region erased",
    (Path("apps/cli/src/repl/loop.zig"), "printResumeHint"): "exit hint, after the last read",
    # Command dialogs drawn in the region's place after readLineRaw erased it,
    # or while enterExclusiveOverlay holds the render lock with the region
    # erased. Each tracks its own rows and erases them with ED 0.
    (Path("apps/cli/src/repl/tui/dialog/pane.zig"), "writeAll"): "bottom pane, region erased",
    (Path("apps/cli/src/repl/tui/dialog/permission.zig"), "writeAll"): "permission dialog, region frozen",
    (Path("apps/cli/src/repl/tui/dialog/ask_question.zig"), "writeAll"): "AskUserQuestion dialog, region frozen",
    # The alternate screen. The terminal restores the main screen on exit;
    # nothing reaches the scrollback.
    (Path("apps/cli/src/repl/transcript_viewer.zig"), "writeAll"): "transcript viewer, alternate screen",
    (Path("apps/cli/src/repl/tui/overlay.zig"), "writeAll"): "alternate screen enter/exit",
    (Path("apps/cli/src/repl/tui/widget/pager.zig"), "writeAll"): "pager, alternate screen",
    # Before the region exists.
    (Path("apps/cli/src/repl/tui/splash_player.zig"), "writeAll"): "startup splash, before the first read",
    # Modes, queries and titles: nothing lands on the grid.
    (Path("apps/cli/src/repl/input.zig"), "emitEnableSequences"): "keyboard protocol, bracketed paste and win32-input-mode on",
    (Path("apps/cli/src/repl/input.zig"), "emitDisableSequences"): "keyboard protocol, bracketed paste and win32-input-mode off",
    (Path("apps/cli/src/repl/input.zig"), "rescueTerminal"): "keyboard protocol, bracketed paste and mouse off when the process dies or stops",
    (Path("apps/cli/src/repl/input.zig"), "emitLateKeyboardEnable"): "keyboard protocol on when the terminal's Kitty answer came after the startup probe",
    (Path("apps/cli/src/repl/tui/bg_probe.zig"), "sendQuery"): "OSC 11, Kitty flags and DA1 queries at startup",
    (Path("apps/cli/src/repl/tui/terminal_title.zig"), "writeAll"): "OSC 0 window title",
    # Regular files, not the terminal.
    (Path("apps/cli/src/repl/history.zig"), "saveToFile"): "history file",
    (Path("apps/cli/src/repl/paste.zig"), "store"): "pasted-text file",
    (Path("apps/cli/src/repl/tui/config.zig"), "writeFile"): "TUI config file",
    (Path("apps/cli/src/repl/input.zig"), "externalEdit"): "the editor's temporary file",
    # No region at all.
    (Path("apps/cli/src/repl/headless.zig"), "*"): "-p/--print, never a RenderRegion",
    # Failure output of assertion helpers only tests call.
    (Path("apps/cli/src/repl/tui/test_capture.zig"), "expectContains"): "test assertion diagnostics",
    (Path("apps/cli/src/repl/tui/test_capture.zig"), "expectNoAnsi"): "test assertion diagnostics",
    (Path("apps/cli/src/repl/stream_json_backend.zig"), "expectStrictNdjson"): "test assertion diagnostics",
}

# Erase in display (CSI J) beyond ED 0, or with a parameter only known at run
# time; CSI may also be the C1 byte.
CSI = r"(?:\x1b\[|\x9b)"
WIDE_ERASE_BYTES = re.compile(CSI + r"\??(?:0*[123]|\{[^}]*\})J")
WIDE_ERASE_NAME = re.compile(r"\bclear\s*\.\s*(?:screen(?:_and_home)?|to_start_of_screen)\b")
# DECSC/DECRC and SCO save/restore. Kitty's CSI >/</?/= ... u is not one.
SAVE_RESTORE = re.compile(r"\x1b[78]|" + CSI + r"[su]")
SINK = re.compile(
    r"(?:\bstd|@import\(\"std\"\))\s*\.\s*debug\s*\.\s*(?:print|lockStderr\w*)\b"
    r"|\bFile\s*\.\s*std(?:err|out)\b"
    r"|\bstd\s*\.\s*c\s*\.\s*write\b"
    r"|\bposix\s*\.\s*write\b"
    r"|(?:\bpfs|\bplatform\s*\.\s*fs|@import\(\"platform\"\)\s*\.\s*fs)\s*\.\s*write(?:All)?\b"
    r"|\bWriteConsole\w*\b|\bWriteFile\b"
)

FN_DECL = re.compile(r"^(\s*)(?:pub\s+)?(?:(?:export|extern|inline|noinline)\s+)*fn\s+(\w+)\s*\(")
TEST_DECL = re.compile(r"^(\s*)test\b")
JOIN = re.compile(r"\s*\+\+\s*")
ESCAPES = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", "'": "'", '"': '"'}


def _decode(body: str) -> str:
    """A Zig string literal's text, escapes resolved."""
    out = []
    i = 0
    while i < len(body):
        c = body[i]
        if c != "\\" or i + 1 >= len(body):
            out.append(c)
            i += 1
            continue
        e = body[i + 1]
        if e in ESCAPES:
            out.append(ESCAPES[e])
            i += 2
        elif e == "x" and re.fullmatch(r"[0-9a-fA-F]{2}", body[i + 2 : i + 4]):
            out.append(chr(int(body[i + 2 : i + 4], 16)))
            i += 4
        elif e == "u" and (m := re.match(r"\{([0-9a-fA-F]+)\}", body[i + 2 :])):
            out.append(chr(int(m.group(1), 16)))
            i += 2 + m.end()
        else:
            out.append(c)
            i += 1
    return "".join(out)


def split_line(line: str) -> tuple[str, list[str]]:
    """(code, strings): the line's code with every literal emptied and its
    comment dropped, and the decoded text of each run of literals joined by
    ``++``. An ``@import`` keeps its argument so a sink spelled through it
    stays visible."""
    code = []
    strings: list[str] = []
    since_literal: list[str] | None = None  # code after the last literal
    i = 0
    n = len(line)
    while i < n:
        if line.startswith("//", i):
            break
        if line.startswith("\\\\", i):  # multiline string literal: rest of line
            strings.append(line[i + 2 :])
            code.append('""')
            break
        c = line[i]
        if c in "\"'":
            j = i + 1
            while j < n and line[j] != c:
                j += 2 if line[j] == "\\" else 1
            body = line[i + 1 : j]
            if c == '"':
                text = _decode(body)
                if since_literal is not None and JOIN.fullmatch("".join(since_literal)):
                    strings[-1] += text
                else:
                    strings.append(text)
                since_literal = []
                kept = body if "".join(code).rstrip().endswith("@import(") else ""
                code.append(c + kept + c)
            else:
                code.append("''")
            i = j + 1
            continue
        code.append(c)
        if since_literal is not None:
            since_literal.append(c)
        i += 1
    return "".join(code), strings


def governed_sources(root: Path) -> list[Path]:
    """Root-relative Zig files under apps/cli/src/repl, sorted."""
    base = root / SCOPE
    if not base.is_dir():
        raise NotADirectoryError(str(base))
    return sorted(path.relative_to(root) for path in base.rglob("*.zig"))


def scanned_lines(text: str):
    """(line number, enclosing function or "", code, strings) for every line
    outside test blocks. zig fmt closes a block with `}` at the indentation of
    the line that opened it, which is all the tracking needs."""
    lines = text.splitlines()
    functions: list[tuple[str, str]] = []  # (indent, name)
    skip_until: str | None = None
    index = 0
    while index < len(lines):
        line = lines[index]
        number = index + 1
        index += 1
        if skip_until is not None:
            if line.rstrip() == skip_until:
                skip_until = None
            continue
        code, strings = split_line(line)
        test = TEST_DECL.match(code)
        if test and code.rstrip().endswith("{"):
            skip_until = test.group(1) + "}"
            continue
        if test:  # `test "x" {}` on one line
            continue
        if functions and line.rstrip() == functions[-1][0] + "}":
            functions.pop()
            continue
        decl = FN_DECL.match(code)
        if decl:
            if code.count("{") and code.count("{") == code.count("}"):
                # One-line body: its code belongs to the function.
                yield number, decl.group(2), code, strings
                continue
            # The body opens where the signature ends with `{`; a `;` first
            # means a declaration without a body.
            end = index - 1
            while not split_line(lines[end])[0].rstrip().endswith(("{", ";")) and end + 1 < len(lines):
                end += 1
            if split_line(lines[end])[0].rstrip().endswith("{"):
                functions.append((decl.group(1), decl.group(2)))
        yield number, functions[-1][1] if functions else "", code, strings


def sink_hits(root: Path) -> list[tuple[Path, int, str, str]]:
    """(file, line, function, call) for every terminal write in the scope."""
    hits = []
    for relative in governed_sources(root):
        for number, function, code, _ in scanned_lines((root / relative).read_text(encoding="utf-8")):
            for match in SINK.finditer(code):
                hits.append((relative, number, function, re.sub(r"\s+", "", match.group(0))))
    return hits


def erase_name_hits(root: Path) -> list[tuple[Path, int, str]]:
    hits = []
    for relative in governed_sources(root):
        if relative in WIDE_ERASE_BYTES_ALLOWED:
            continue
        for number, function, code, _ in scanned_lines((root / relative).read_text(encoding="utf-8")):
            if WIDE_ERASE_NAME.search(code):
                hits.append((relative, number, function))
    return hits


def violations(root: Path) -> list[str]:
    """`path:line: rule: what` for every break of the ownership model."""
    found = []
    for relative in governed_sources(root):
        text = (root / relative).read_text(encoding="utf-8")
        for number, _, _, strings in scanned_lines(text):
            where = f"{relative.as_posix()}:{number}"
            for literal in strings:
                if WIDE_ERASE_BYTES.search(literal) and relative not in WIDE_ERASE_BYTES_ALLOWED:
                    found.append(f"{where}: erase: ED 1/2/3 bytes outside tui/ansi.zig")
                if SAVE_RESTORE.search(literal):
                    found.append(f"{where}: anchor: cursor save/restore (DECSC/DECRC, CSI s/u)")
    for relative, number, function in erase_name_hits(root):
        if (relative, function) not in WIDE_ERASE_NAMES_ALLOWED:
            found.append(f"{relative.as_posix()}:{number}: erase: wide erase outside RenderRegion.resetScreen")
    for relative, number, function, call in sink_hits(root):
        if (relative, function) not in ALLOWED_SINKS and (relative, "*") not in ALLOWED_SINKS:
            name = function or "top level"
            found.append(f"{relative.as_posix()}:{number}: sink: {call} in {name} writes past the Renderer")
    return sorted(found, key=lambda item: (item.split(":")[0], int(item.split(":")[1]), item))


def stale_allowances(root: Path) -> list[str]:
    """Allowlist entries that no longer match anything: a renamed function
    must not leave its exemption behind for the next function of that name."""
    sinks = {(relative, function) for relative, _, function, _ in sink_hits(root)}
    files = {relative for relative, _ in sinks}
    stale = [
        f"{relative.as_posix()}:{function}"
        for relative, function in ALLOWED_SINKS
        if not ((relative in files) if function == "*" else ((relative, function) in sinks))
    ]
    names = {(relative, function) for relative, _, function in erase_name_hits(root)}
    stale += [f"{relative.as_posix()}:{function}" for relative, function in WIDE_ERASE_NAMES_ALLOWED - names]
    return sorted(stale)


def write(root: Path, relative: str, text: str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


class ScrollbackDisciplineTest(unittest.TestCase):
    def test_repl_writes_the_terminal_only_through_the_renderer(self):
        self.assertEqual(
            violations(ROOT),
            [],
            f"see {ADR}: erase with ED 0 (ansi.clear.to_end_of_screen) and reset the screen only through "
            "RenderRegion.resetScreen; climb with relative moves, never save/restore the cursor; send "
            "scrollback text through the Renderer (emitToScroll / emitTerminal / emitScrollback), or add the "
            "function to ALLOWED_SINKS with the reason it cannot reach the region",
        )

    def test_every_allowance_still_matches_a_write(self):
        self.assertEqual(stale_allowances(ROOT), [], "drop or rename the stale ALLOWED_SINKS entries")

    def test_the_rule_still_sees_the_renderer(self):
        # An empty scan would pass trivially; the Renderer's own sink and the
        # screen reset must be in it.
        self.assertIn(Path("apps/cli/src/repl/tui/render_region.zig"), governed_sources(ROOT))
        self.assertIn(
            (Path("apps/cli/src/repl/tui/render_region.zig"), "flush"),
            {(relative, function) for relative, _, function, _ in sink_hits(ROOT)},
        )
        self.assertEqual(
            {(relative, function) for relative, _, function in erase_name_hits(ROOT)}, WIDE_ERASE_NAMES_ALLOWED
        )


class ScannerTest(unittest.TestCase):
    """Both sides of every rule, on a planted tree."""

    def scan(self, files: dict[str, str]) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative, text in files.items():
                write(root, relative, text)
            return violations(root)

    def test_wide_erase_bytes_are_reported_however_they_are_spelled(self):
        found = self.scan(
            {
                "apps/cli/src/repl/tui/tui_backend.zig": (
                    "fn handleKey() void {\n"
                    '    region.emitTerminal("\\x1b[2J\\x1b[H");\n'
                    '    region.emitTerminal("\\u{1b}[3J");\n'
                    '    region.emitTerminal("\\x1B[" ++ "2J");\n'
                    '    region.emitTerminalFmt("\\x1b[{d}J", .{n});\n'
                    '    region.emitTerminal("\x1b[1J");\n'
                    '    region.emitTerminal("\\x9b2J");\n'
                    "}\n"
                ),
            }
        )
        self.assertEqual(
            found,
            [f"apps/cli/src/repl/tui/tui_backend.zig:{n}: erase: ED 1/2/3 bytes outside tui/ansi.zig" for n in range(2, 8)],
        )

    def test_ed0_comments_fixtures_and_the_escape_table_are_not_wide_erases(self):
        found = self.scan(
            {
                "apps/cli/src/repl/tui/ansi.zig": (
                    "pub const clear = struct {\n"
                    '    pub const screen = "\\x1b[2J";\n'
                    '    pub const to_end_of_screen = "\\x1b[0J";\n'
                    "};\n"
                ),
                "apps/cli/src/repl/tui/render_region.zig": (
                    "fn eraseRegion(w: anytype) void {\n"
                    "    w.writeAll(ansi.clear.to_end_of_screen); // never \\x1b[2J here\n"
                    '    w.writeAll("\\x1b[J\\x1b[0J\\x1b[2K");\n'
                    '    w.writeAll("https://x/\\x1b[2J"); // a URL is not a comment\n'
                    "}\n"
                    'test "fixtures spell what they assert against" {\n'
                    '    try expect(indexOf(out, "\\x1b[2J") == null);\n'
                    '    try expect(indexOf(out, "\\x1b7") == null);\n'
                    "    _ = ansi.clear.screen;\n"
                    "}\n"
                ),
            }
        )
        self.assertEqual(found, ["apps/cli/src/repl/tui/render_region.zig:4: erase: ED 1/2/3 bytes outside tui/ansi.zig"])

    def test_wide_erase_names_only_in_reset_screen(self):
        found = self.scan(
            {
                "apps/cli/src/repl/tui/render_region.zig": (
                    "    fn resetScreenInFrame(self: *RenderRegion) void {\n"
                    "        self.scratch.writer.writeAll(ansi.clear.screen_and_home) catch {};\n"
                    "    }\n"
                    "    fn drawGenRegion(self: *RenderRegion) void {\n"
                    "        w.writeAll(ansi.clear.screen) catch {};\n"
                    "        w.writeAll(ansi.clear . to_start_of_screen) catch {};\n"
                    "        w.writeAll(ansi.screen.alt_enter) catch {};\n"
                    "    }\n"
                ),
            }
        )
        self.assertEqual(
            found,
            [
                "apps/cli/src/repl/tui/render_region.zig:5: erase: wide erase outside RenderRegion.resetScreen",
                "apps/cli/src/repl/tui/render_region.zig:6: erase: wide erase outside RenderRegion.resetScreen",
            ],
        )

    def test_cursor_save_restore_is_reported_even_in_the_escape_table(self):
        found = self.scan(
            {
                "apps/cli/src/repl/tui/ansi.zig": 'pub const save = "\\x1b7";\npub const restore = "\\u{1b}8";\n',
                "apps/cli/src/repl/tui/render_region.zig": (
                    "fn frame() void {\n"
                    '    w.writeAll("\\x1b[s");\n'
                    '    w.writeAll("\\x1b" ++ "[u");\n'
                    "}\n"
                ),
            }
        )
        self.assertEqual(
            found,
            [
                "apps/cli/src/repl/tui/ansi.zig:1: anchor: cursor save/restore (DECSC/DECRC, CSI s/u)",
                "apps/cli/src/repl/tui/ansi.zig:2: anchor: cursor save/restore (DECSC/DECRC, CSI s/u)",
                "apps/cli/src/repl/tui/render_region.zig:2: anchor: cursor save/restore (DECSC/DECRC, CSI s/u)",
                "apps/cli/src/repl/tui/render_region.zig:3: anchor: cursor save/restore (DECSC/DECRC, CSI s/u)",
            ],
        )

    def test_sequences_that_merely_contain_7_8_s_or_u_are_not_save_restore(self):
        found = self.scan(
            {
                "apps/cli/src/repl/input.zig": (
                    "fn emitEnableSequences() void {\n"
                    '    const kbd = "\\x1b[>1u\\x1b[<u\\x1b[?u\\x1b[=1;1u";\n'
                    '    const sgr = "\\x1b[37m\\x1b[38;5;78m\\x1b[?7h";\n'
                    '    const title = "\\x1b]0;t\\x07\\x1b[?1049h";\n'
                    "}\n"
                ),
            }
        )
        self.assertEqual(found, [])

    def test_terminal_writes_outside_the_allowlist_are_reported(self):
        found = self.scan(
            {
                "apps/cli/src/repl/tui/tui_backend.zig": (
                    "const print = std.debug.print;\n"
                    "fn handleKey(self: *TuiBackend) void {\n"
                    '    std.debug.print("{s}", .{text});\n'
                    '    @import("std").debug.print("x", .{});\n'
                    "    _ = pfs.writeAll(2, bytes);\n"
                    '    _ = @import("platform").fs.writeAll(1, bytes);\n'
                    "    std.Io.File.stderr().writeAll(bytes) catch {};\n"
                    "    _ = std.c.write(2, bytes.ptr, bytes.len);\n"
                    "}\n"
                ),
                "apps/cli/src/repl/tui/render_region.zig": (
                    "    fn flush(self: *RenderRegion) void {\n"
                    '        std.debug.print("{s}", .{bytes});\n'
                    "    }\n"
                    "    fn drawGenRegion(self: *RenderRegion) void {\n"
                    '        std.debug.print("{s}", .{bytes});\n'
                    "    }\n"
                ),
            }
        )
        self.assertEqual(
            found,
            [
                "apps/cli/src/repl/tui/render_region.zig:5: sink: std.debug.print in drawGenRegion writes past the Renderer",
                "apps/cli/src/repl/tui/tui_backend.zig:1: sink: std.debug.print in top level writes past the Renderer",
                "apps/cli/src/repl/tui/tui_backend.zig:3: sink: std.debug.print in handleKey writes past the Renderer",
                'apps/cli/src/repl/tui/tui_backend.zig:4: sink: @import("std").debug.print in handleKey writes past the Renderer',
                "apps/cli/src/repl/tui/tui_backend.zig:5: sink: pfs.writeAll in handleKey writes past the Renderer",
                'apps/cli/src/repl/tui/tui_backend.zig:6: sink: @import("platform").fs.writeAll in handleKey writes past the Renderer',
                "apps/cli/src/repl/tui/tui_backend.zig:7: sink: File.stderr in handleKey writes past the Renderer",
                "apps/cli/src/repl/tui/tui_backend.zig:8: sink: std.c.write in handleKey writes past the Renderer",
            ],
        )

    def test_allowed_writers_comments_strings_and_tests_are_not_sinks(self):
        found = self.scan(
            {
                "apps/cli/src/repl/tui/render_region.zig": (
                    "    /// flush goes through std.debug.print (lockStderr)\n"
                    "    fn flush(self: *RenderRegion) void {\n"
                    '        std.debug.print("{s}", .{bytes});\n'
                    "    }\n"
                    "    fn hint() []const u8 {\n"
                    '        return "do not call std.debug.print here";\n'
                    "    }\n"
                    'test "a test may print" {\n'
                    '    std.debug.print("debug {d}\\n", .{1});\n'
                    "}\n"
                ),
                "apps/cli/src/repl/headless.zig": 'pub fn run() void {\n    std.debug.print("error\\n", .{});\n}\n',
                "apps/cli/src/repl/tui/overlay.zig": (
                    "fn writeAll(fd: c_int, bytes: []const u8) void {\n"
                    "    _ = pfs.writeAll(fd, bytes);\n"
                    "}\n"
                ),
            }
        )
        self.assertEqual(found, [])

    def test_functions_are_tracked_across_signatures_one_liners_and_nesting(self):
        found = self.scan(
            {
                "apps/cli/src/repl/loop.zig": (
                    "fn printResumeHint(\n"
                    "    app: *App,\n"
                    ") void {\n"
                    "    const redraw = struct {\n"
                    "        fn call() void {\n"
                    '            std.debug.print("nested", .{});\n'
                    "        }\n"
                    "    }.call;\n"
                    '    std.debug.print("hint", .{});\n'
                    "}\n"
                    "extern fn write(fd: c_int) isize;\n"
                    'fn quick() void { std.debug.print("x", .{}); }\n'
                    'const after = std.debug.print("top", .{});\n'
                ),
            }
        )
        self.assertEqual(
            found,
            [
                "apps/cli/src/repl/loop.zig:6: sink: std.debug.print in call writes past the Renderer",
                "apps/cli/src/repl/loop.zig:12: sink: std.debug.print in quick writes past the Renderer",
                "apps/cli/src/repl/loop.zig:13: sink: std.debug.print in top level writes past the Renderer",
            ],
        )

    def test_a_renamed_function_leaves_its_allowance_stale(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write(root, "apps/cli/src/repl/tui/render_region.zig", "fn flushFrame() void {\n    std.debug.print(\"x\", .{});\n}\n")
            stale = stale_allowances(root)
            self.assertIn("apps/cli/src/repl/tui/render_region.zig:flush", stale)
            self.assertIn("apps/cli/src/repl/tui/render_region.zig:resetScreenInFrame", stale)
            self.assertIn("apps/cli/src/repl/headless.zig:*", stale)

    def test_missing_scope_is_an_error_not_an_empty_scan(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(NotADirectoryError):
                violations(Path(directory))


if __name__ == "__main__":
    unittest.main()
