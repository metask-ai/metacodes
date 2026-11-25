# TUI viewport ownership (ADR)

Who may put bytes on the terminal while the interactive REPL runs, and what
they may do with them.

- **Status:** accepted, 2026-10-28. Describes the code as of this date;
  where the code and this record disagree, the code is the fact and this
  record is out of date.
- **Scope:** `apps/cli/src/repl/` on an interactive terminal. `-p/--print`
  (`headless.zig`) has no region and is outside it.
- **Enforced by:** `zig build test:scrollback`
  (`scripts/tests/test_scrollback_discipline.py`), part of `zig build test`
  and `gate:pr`; see [Enforcement](#enforcement).
- **Related:** [TUI state architecture](TUI_STATE_ARCHITECTURE.md) is a
  different layer: how UI state is computed (UiState, Event, dispatch,
  render). This record is about who owns each byte on the screen once it is
  computed.

## Context

metacodes does not take over the screen. The input box, spinner, tool cards
and footer are drawn as a *region* at the bottom of the main screen
(`RenderRegion`, `apps/cli/src/repl/tui/render_region.zig`); the conversation is
printed above it and scrolls into the terminal's own scrollback, like any
command's output. The scrollback has no undo: a byte that lands in the wrong
place stays in the user's history. A redraw cannot repair it, because the
renderer can only reach the rows it drew itself, by relative cursor moves
from where it left the cursor.

Several threads produce output (the agent loop's text, the keyboard watcher,
tool progress callbacks, the spinner tick), the terminal may be resized or
re-wrapped at any time, and terminals differ in what they restore. The hard
TUI bugs fixed so far each broke one of the rules below (#298 removed the
DECSC/DECRC anchor, #362 made the erase climb the rows a resize re-wrapped);
they are written down so a review can check a change against them instead of
rediscovering them.

## Decision

### Ownership

The **Renderer** (`RenderRegion`) owns the region and every byte written while
the region is on the screen. It composes each write in its `scratch` buffer
under its mutex and sends it with one call, `flush`, through
`std.debug.print` (which holds the stderr lock). Two phases share one
region:

- **Input phase** (`loop.zig`, `readLineRaw`): `render` / `applyEvent` draw
  the box (`renderFrameInner`); text that must appear while the box is up
  goes through `emitTerminal` / `emitTerminalFmt` / `emitScrollback`.
  `readLineRaw` erases the region when it returns (`clear`, in its `defer`),
  so a slash command's output (`cmd_output`) is printed with no region on the
  screen, and the next read draws the box again below it.
- **Generation phase** (`enterGenerating` … `leaveGenerating`): the agent
  loop's text reaches the Renderer through `RegionWriter` → `writeGenText` /
  `writeGenAssistantText`, which buffer to whole lines and hand them to
  `emitToScroll`; the spinner tick, keys and tool progress redraw through
  `redrawFrameLocked`. A dialog that needs the keyboard
  (`enterExclusiveOverlay` … `exitExclusiveOverlay`) erases the region and
  holds the render lock until it is drawn again.

Everything above the region's top row is **scrollback**, including the text
of an unfinished last line (the *half-line*). The Renderer appends to it and
never moves back into it, with one exception: it returns the cursor to the
end of the half-line to continue it.

### Invariants

**1. The scrollback is written only through the Renderer.** While the region
is on the screen, every byte goes through `emitToScroll` (generation text),
`emitTerminal`/`emitScrollback` (input-phase text) or `resetScreen`, under the
Renderer's mutex. Anything else that writes the terminal does so only while
the region is not on it: after `readLineRaw` erased it, inside an exclusive
overlay, on the alternate screen, or before the first read. A write from
outside lands at the cursor, which is inside the region, and the next erase
climbs from the wrong row: part of the region spills into the scrollback.

**2. Erase, print and redraw come in pairs, in one frame.** `emitToScroll`
prints only after `eraseRegion` has taken the region off the screen
(`region_drawn` false), and draws it again if it was there. When it was, the
three steps are composed into one buffer between `ESC[?2026h` and
`ESC[?2026l` (DEC 2026 synchronized output) and flushed once, so a terminal
that supports it never shows the erased state; `redrawFrameLocked` (erase +
draw) and `renderFrameInner` (climb + ED 0 + draw) are framed the same way.
Without the region on screen, `emitToScroll` is a plain append. Code
exceptions as of this record: `endScrollLine` erases, writes its newline and
redraws as three writes rather than one frame; `leaveGenerating` and
`enterExclusiveOverlay` erase without a redraw because the region is leaving.

**3. The half-line continuation is snapshotted when the region is drawn, and
the erase restores the snapshot.** `drawGenRegion` copies the live
`text_pending_newline` / `pending_col` into `region_drawn_pending_nl` /
`region_drawn_pending_col` before it seals the half-line with a newline (the
region always starts on a row of its own). `eraseRegion` returns to the
half-line from the snapshot (up one row, `\r`, forward to the column), never
from the live flags: `writeGenText` updates those between a draw and its
erase, and an erase that chose by them would land one row off and print into
the scrollback.

**4. The region is erased with ED 0 only.** Both erase paths climb to the
region's top row and send one `ESC[0J`. The region is the last thing on the
screen, so ED 0 from its top erases exactly the region and nothing above it,
without writing a newline or scrolling. ED 2 (`ESC[2J`, the whole screen) is
sent only by `RenderRegion.resetScreen`, for a reset the user asked for
(Ctrl+L, `/clear`, `/resume`): in one frame it erases the region, sends ED 2
and home, and draws a generating region again on the top row; the input box
comes back with the caller's next render. ED 3 (`ESC[3J`) is never sent: it
wipes the scrollback, including the user's history from before the session.
ED 1 is not used.

**5. No saved cursor positions; relative moves over tracked rows.** The
Renderer never uses DECSC/DECRC (`ESC 7` / `ESC 8`) or the SCO pair
(`ESC[s` / `ESC[u`). The region is usually drawn on the bottom row, where the
frame's own `\r\n` scrolls the screen; a saved position is an absolute screen
row that does not scroll with it, so restoring it lands below the region's
top, and Warp does not restore DECRC's column at all. Instead each frame
records a `reflow.Anchor` (rows above the cursor and their widths, measured
from the frame's bytes), and the next erase climbs `anchor.climb()` rows. On
a terminal that re-wraps when it narrows, the climb counts the rows those
widths take at the new width; on one that clips (`term.reflowFromEnv`;
Windows ConPTY, xterm, GNU screen) it counts them as drawn.

**6. The half-line continuation is a mortgage on the terminal's geometry.**
`pending_col` is a column on a physical row. A resize re-wraps or clips the
scrollback, and the column no longer points at the end of the text. Before
any step that relies on the old cursor position, `observeResize` measures
the terminal; on a change during generation it drops the continuation and its
snapshot (`invalidateContinuationForResize`), and if the cursor itself was
still parked at the half-line's end, defers one newline (`resize_seal_pending`)
that `sealResizedLine` writes after the erase. `resetScreen` drops the
continuation for the same reason: the text it pointed at left the screen with
ED 2.

### Forbidden

| Operation | Why |
|-----------|-----|
| ED 3, `ESC[3J` | Wipes the scrollback, including the history from before the session. Never defined in `ansi.zig`. |
| ED 2 / ED 1 outside `resetScreen` | Erases conversation the Renderer does not own; any later erase climbs from a cursor that is not where the anchor says. |
| DECSC/DECRC, SCO `CSI s`/`CSI u` | A saved position is absolute and does not follow the frame's own scrolling; Warp does not restore DECRC. |
| Printing while the region is drawn | The text lands inside the region; the next erase climbs from the wrong row and the region's rows enter the scrollback. |
| Erasing the generating region without drawing it again | The region disappears until the next tick, and the snapshot no longer describes what is on the screen. |
| Restoring the half-line from the live flags | They can change between a draw and its erase (invariant 3). |
| A direct terminal write from outside the Renderer | No mutex, no frame: it interleaves with another thread's frame and leaves `prev_rows` / `anchor` describing a screen that is gone. |

Scroll regions (DECSTBM), SU/SD and RIS (`ESC c`) are not used either; the
first would have to come with a change to this record.

### Region and scrollback

- **Region** (erasable): the rows the Renderer drew in its last frame, from
  the region's top row to the end of the screen (`prev_rows`, `anchor`). Only
  the Renderer erases them, and only with ED 0 from their top.
- **Half-line** (borrowed): the cursor position at the end of the last,
  unfinished line of text. Its text is scrollback and is never erased; the
  Renderer only returns the cursor there (invariants 3 and 6).
- **Scrollback** (spilled): everything above the region's top. Append-only.
  A user-requested `resetScreen` clears the visible part with ED 2; nothing
  clears the rest.
- **Elsewhere:** the transcript viewer, pager and overlay draw on the
  alternate screen (`ESC[?1049h` … `ESC[?1049l`), which the terminal restores
  on exit. The command pane and the permission and AskUserQuestion dialogs
  are short-lived regions of their own, drawn while the main region is erased
  (input phase) or frozen (exclusive overlay), with the same climb + ED 0
  erase.

### Copy on select

With the `copy_on_select` preview feature, `screen_mirror` keeps a copy of
the main screen: the Renderer's `flush`, the command output and the region
dialogs feed it the bytes they write, and it applies the subset of VT the
REPL sends. It writes nothing. A drag asks for the cursor position
(`ESC[6n`) and sends the copied text as OSC 52, both through
`emitTerminal`; neither moves the cursor or touches the grid. The mirror
records its own cursor row when it sees the query, and the answer gives the
row's place on the screen.

### Review checklist

A change under `apps/cli/src/repl/` that writes to the terminal:

1. Does every byte that can appear while the region is on the screen go
   through the Renderer (`emitToScroll`, `emitTerminal`, `emitScrollback`,
   `resetScreen`, or a frame method), under its lock?
2. If it erases the region, does the same frame draw it again, or is the
   region leaving on purpose? Is an erase-then-redraw inside one DEC 2026
   frame?
3. Does any erase use more than ED 0? Is that `resetScreen`, after an
   explicit user action?
4. Does it save or restore the cursor, or move to an absolute row? Climb with
   `anchor.climb()` instead.
5. If it prints text, does it update the continuation (`updatePendingTail`),
   and does a draw that follows snapshot it?
6. If it can run after a resize, does it call `observeResize` before relying
   on the cursor position?
7. If it writes the terminal directly, is it outside the region's lifetime
   (alternate screen, before the first read, between reads, inside an
   exclusive overlay, mode or title sequences), and is its function listed in
   `ALLOWED_SINKS` with that reason?

### Enforcement

`zig build test:scrollback` runs
[`scripts/tests/test_scrollback_discipline.py`](../scripts/tests/test_scrollback_discipline.py)
over `apps/cli/src/repl/` (comments and `test` blocks excluded; string literals decoded
as Zig reads them) and fails the build on:

- ED 1/2/3 bytes outside `tui/ansi.zig`, or `ansi.clear.screen`,
  `screen_and_home` or `to_start_of_screen` outside
  `RenderRegion.resetScreen`;
- a cursor save/restore sequence anywhere, `ansi.zig` included;
- a direct terminal write (`std.debug.print`, `pfs.write*`, `std.c.write`,
  `posix.write`, `File.stderr/stdout`, `WriteConsole*`) in a function not
  listed in `ALLOWED_SINKS`, each entry with its reason, and no stale entries.

The scan is static. It cannot see *when* a listed function writes (that
`cmd_output` prints only between reads, for example), writes outside
`apps/cli/src/repl/`, or an alias of `platform.fs` under another name; invariants 2, 3
and 6 are behaviour, held by the tests below and by review.

Behaviour tests:

- `apps/cli/src/repl/tui/render_region.zig`: "input-phase clear walks up the tracked
  rows and erases with ED0", "generation erase walks up from the edit row,
  clears with ED0, returns to the half line", "after the terminal narrows,
  both erase paths climb the rows it re-wrapped the last frame into", "a
  generation resize invalidates the saved half-line cursor before erase", "a
  generation resize with the cursor on the half-line seals it exactly once",
  "a screen reset during generation erases the region, then ED2, and drops
  the half line", "a screen reset at the input box erases it like clear, then
  ED2".
- `tests/tty/cases/` (the real binary on a virtual screen):
  `test_shrink_jitter.py`, `test_wrap_resize.py`, `test_screen_resize.py`,
  `test_command_results.py` (`/clear`), `test_prompt_keys.py` and
  `test_generating.py` (Ctrl+L at the prompt and during a reply: one frame,
  never ED 3).
