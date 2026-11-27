# Terminal setup

In the metacodes prompt, Enter submits and Shift+Enter starts a new line. A
terminal can only report Shift+Enter when it tells it apart from Enter, and
not every terminal does. When the footer says `\ + ⏎ for newline`, Shift+Enter
submits in this terminal; ending a line with `\` and pressing Enter inserts the
line break instead. `/terminal-setup` (or `metacodes terminal-setup`) fixes
that where the terminal's own settings can. Further down: [selecting text with
the mouse](#selecting-text-with-the-mouse) while metacodes runs, and
[multiplexers and remote sessions](#multiplexers-and-remote-sessions) (tmux,
GNU screen, Zellij, mosh, SSH).

| Terminal | Shift+Enter without setup | What `/terminal-setup` does |
| --- | --- | --- |
| iTerm2, WezTerm, Ghostty, kitty, Warp | newline (metacodes turns on the Kitty keyboard protocol) | nothing; says so |
| Other terminals that answer the keyboard-protocol query at startup | newline | nothing; says so (in the TUI, which has the answer) |
| Apple Terminal | submits | maps Shift+Return in the default profile |
| VS Code, Cursor, Windsurf, VSCodium, other VS Code builds | submits | adds a `keybindings.json` entry |
| tmux, anything else | depends on the terminal | explains the manual setup; changes nothing |

Both setups make Shift+Enter send Esc followed by Return (`ESC CR`, the bytes
`1b 0d`), which metacodes reads as a newline. It is the sequence Claude Code's
VS Code binding sends, so a binding Claude Code installed already counts.

metacodes takes `ESC CR` for a newline only when the two bytes arrive together,
as a terminal writes them for one key press. An Esc you press and then an
Enter are two keys even when they come quickly: in reverse search Esc still
cancels. Pasted text
keeps its line breaks. Terminals that send `ESC CR` for Alt+Enter (xterm, VTE
terminals such as GNOME Terminal, Konsole, Alacritty) now get a newline from
Alt+Enter too.

One limit is inferred, not measured: a connection that delivers keys in bursts,
such as mosh or an SSH session over a link that loses packets, can bring an Esc
and an Enter pressed in quick succession in one batch. metacodes then reads
them as `ESC CR`, a newline, instead of Esc followed by Enter.

```sh
/terminal-setup                 # in the TUI: set up this terminal
/terminal-setup status          # say what it would change, change nothing
/terminal-setup restore         # undo what it set up

metacodes terminal-setup [--dry-run | --restore]
                         [--terminal apple-terminal|vscode|vscode-insiders|cursor|windsurf|vscodium]
                         [--keybindings <keybindings.json>]
```

Without `--terminal`, the command sets up the terminal it runs in (from
`TERM_PROGRAM` and the variables VS Code sets). `--terminal` sets up another
one, for example Apple Terminal from iTerm2. Before it changes anything it
prints the file it will change, what it adds and where the backup goes.

## Apple Terminal

It adds Shift+Return → `ESC CR` to the key map (Settings › Profiles ›
Keyboard) of the profile new windows use (`Default Window Settings`, and
`Startup Window Settings` when that is another profile). Nothing else in the
settings changes.

- **Restart Terminal afterwards.** Terminal reads its profiles when it starts:
  until you quit it (⌘Q) and open it again, this window and any new one still
  send a plain Return. The footer keeps saying `\ + ⏎` until then.
- **A profile without its own key map gets a copy of the built-in one.** A
  profile's key map replaces Terminal's built-in map as a whole, so a map
  holding only Shift+Return would turn off F1–F20, Shift+arrows and
  Option+arrows. The command copies the built-in map
  (`Terminal.app/Contents/Resources/keyMappings.plist`) into the profile and
  adds Shift+Return to it; restore takes the copy out again.
- **An existing Shift+Return mapping is never replaced.** The command says what
  it sends and stops; remove it in the profile's Keyboard settings first.
- **It applies to every program in that profile.** Shift+Return sends Esc+Return
  to the shell and to other programs too; zsh, for one, inserts a line break
  instead of running the command.
- Windows that use another profile are not changed. Run the command again after
  making that profile the default, or add the mapping by hand. Which profile a
  window uses is not visible from inside it, so the footer assumes one of the
  profiles the command changed.
- A profile whose name contains a backslash or starts with `@` cannot be changed
  by the command (the settings tools cannot address it; macOS 15's `plutil`
  aborts on the latter); the command says so.
- After a macOS update that changes Terminal's built-in key map, a copy the
  command made earlier keeps the old map, and restore then takes out only
  Shift+Return (the copy no longer matches the built-in map) and leaves that old
  copy in the profile. Remove it by hand in the profile's Keyboard settings
  (Restore Defaults), or import the backup.

The command uses only the system's own tools: `defaults export` and
`defaults import` for Terminal's settings (`com.apple.Terminal`), and `plutil`
for the edit.

## VS Code and its forks

It appends this entry to the user `keybindings.json` (on macOS
`~/Library/Application Support/<Code|Cursor|…>/User/`, on Linux
`~/.config/<…>/User/`, on Windows `%APPDATA%\<…>\User\`):

```json
{
    "key": "shift+enter",
    "command": "workbench.action.terminal.sendSequence",
    "args": { "text": "\u001b\r" },
    "when": "terminalFocus"
}
```

- VS Code picks the change up at once; there is nothing to restart.
- Comments, trailing commas and the existing entries' formatting are kept. A
  missing file is created; a file that is not a list of bindings is left alone.
- **A binding that already holds Shift+Enter in the terminal is not
  replaced**: one whose `when` names the terminal (`terminalFocus`, …) or has no
  `when` at all. The command shows it and stops.
- Which build runs the terminal comes from its `product.json` (found through
  `VSCODE_GIT_ASKPASS_MAIN`), so forks get their own folder; `VSCODE_PORTABLE`
  is honoured. For an install started with `--user-data-dir`, name the file:
  `--keybindings <file>`.
- **Profiles.** The entry goes into the Default profile's file. A window that
  uses a profile with keyboard shortcuts of its own reads that profile's
  `User/profiles/<id>/keybindings.json` instead (measured: such a window kept
  sending a plain Return). The command lists those profiles (from
  `User/globalStorage/storage.json`) with the `--keybindings` command for each,
  and the footer shows `shift + ⏎` only once every one of them has the entry,
  since which profile a window uses is not visible from inside it.
- A `keybindings.json` that is a symbolic link (home-manager, stow, chezmoi)
  stays a link: the file it points to is the one changed. If that file cannot be
  written (the Nix store), add the entry where it is managed. A link to nothing
  is left alone.
- In a remote window (Remote-SSH, WSL, a dev container, Codespaces) the key
  bindings live on the machine that shows the window, so the command prints
  the entry to add there instead.
- It applies to every program in the integrated terminal, as above.

## Backups and undo

Each change is backed up first, into `<state root>/terminal-setup/`
(`metacodes doctor` shows the state root): the whole of Terminal's settings as
`apple-terminal-<UTC time>.plist`, the `keybindings.json` as it was as
`<build>-keybindings-<UTC time>.json`. The same directory holds
`installed.json`, the record of what the command changed.

The record is written before the change and kept in step with it. If it cannot
be read, nothing is changed (it would otherwise be saved over) until it is
fixed or moved away.

`/terminal-setup restore` (or `metacodes terminal-setup --restore`) undoes what
the record lists, and only that; `--terminal <name>` or `--keybindings <file>`
narrows it to that terminal or file, and naming one with nothing recorded is an
error. A file that does not parse any more is left as it is and stays in the
record, so the restore can be run again once the file is fixed.

- Apple Terminal: Shift+Return comes out of each profile it was added to; a key
  map the command copied in goes too, unless you edited other keys in it since.
  A Shift+Return mapping that sends something else by now is left alone. Quit
  and reopen Terminal for the change to take effect.
- VS Code: the entry the command added comes out; your own entries, comments
  and edits stay.

The backups stay. To put back all of Terminal's settings exactly as they were,
quit Terminal and run `defaults import com.apple.Terminal <backup>`; for
`keybindings.json`, copy the backup over it.

## Other terminals

Bind Shift+Enter in the terminal's own settings to send `ESC CR` (often written
`\e\r` or `\u001b\r`). For Alacritty (`alacritty.toml`):

```toml
[[keyboard.bindings]]
key = "Return"
mods = "Shift"
chars = "\u001b\r"
```

Inside tmux, Shift+Enter reaches metacodes only when tmux forwards modified
keys: set `extended-keys on` (see [tmux](#tmux) below). metacodes reads both
forms tmux sends them in, its default `ESC [27;2;13~` and the CSI u form
`ESC [13;2u` of `extended-keys-format csi-u`. metacodes cannot see that
setting, so inside tmux the footer says `\ + ⏎ for newline` even when tmux
forwards the keys.

## Turning the keyboard protocol off

Set `METACODES_NO_KEYBOARD_ENHANCEMENT` (to any value, even `0`, like the other
`METACODES_NO_*` switches) and metacodes turns on neither the Kitty keyboard
protocol (`ESC [ > 1 u`) nor xterm modifyOtherKeys (`ESC [ > 4 ; 2 m`), in any
terminal, and does not ask a terminal it does not recognize about them at
startup. Leaving, handing the terminal to `$EDITOR`, and being stopped and
continued (`kill -STOP`, then `kill -CONT`) then send nothing for them either.
Use it when keys come out garbled, or not at all, with the protocol on, as
they can in some terminals or behind a multiplexer that rewrites them.
Shift+Enter then submits in the terminals of the table's first two rows: end a
line with `\` and press Enter, or bind Shift+Enter to `ESC CR` as above. The
footer says `\ + ⏎ for newline`, `/doctor` shows the protocol as off and why,
and `/terminal-setup` says the variable is set.

## The footer hint

The footer says `shift + ⏎ for newline` when Shift+Enter inserts a newline: the
terminal speaks the keyboard protocol (outside tmux, see above); VS Code's `keybindings.json` holds the
binding (whoever added it), and so does that of every profile with shortcuts of
its own; or `/terminal-setup` mapped it in Apple Terminal, the Terminal running
now is not the one that was running at setup (setup records it even when run
from another terminal), and the mapping is still in one of the profiles it
changed.

## Selecting text with the mouse

On macOS and Linux the interactive TUI turns on mouse reporting
(`ESC [?1002h`, `ESC [?1006h`) for as long as it runs, so that dragging over
text copies it: when the left button is released, metacodes copies the text
under the drag through OSC 52 (and `pbcopy` in a local macOS session) and the
prompt says `Copied to clipboard`. It stays off on Windows and inside GNU
screen.

While it is on, the terminal hands the mouse to metacodes:

- The wheel does not scroll the terminal's scrollback, at the prompt or
  during a reply. In the transcript viewer (Ctrl+X Ctrl+O) it scrolls the
  transcript.
- The terminal's own selection, with its own copy and context menu, needs the
  key that makes the terminal skip mouse reporting:

| Terminal | Select text while metacodes runs |
| --- | --- |
| iTerm2 | hold Option while dragging |
| Ghostty, kitty, WezTerm, Alacritty, Warp, Zed | hold Shift while dragging |
| VS Code, Cursor and other VS Code builds | Windows and Linux: hold Shift; macOS: hold Option, once `terminal.integrated.macOptionClickForcesSelection` is on (it is off by default) |
| Apple Terminal | Apple documents no key for it: turn mouse reporting off for the window with View › Allow Mouse Reporting (⌘R), and on again afterwards |
| tmux | the outer terminal's key above: tmux turns mouse reporting on in the outer terminal for metacodes whatever its `mouse` option says |

The copied text reaches the clipboard only when the terminal takes OSC 52:
Apple Terminal ignores it, iTerm2 takes it once Settings › General ›
Selection › Applications in terminal may access clipboard is on, and tmux
passes it on only with `set-clipboard on`. In a local macOS session `pbcopy`
copies the text anyway; over SSH OSC 52 is the only way, and the prompt says
`Copied to clipboard` either way.

## Multiplexers and remote sessions

### tmux

Recommended in `~/.tmux.conf`:

```tmux
set -g extended-keys on
set -as terminal-features 'xterm*:extkeys'
set -g set-clipboard on
set -as terminal-features 'xterm*:hyperlinks'
```

- `extended-keys on` lets Shift+Enter and the other modified keys through
  (see [Other terminals](#other-terminals)); the `extkeys` feature tells tmux
  that the outer terminal can send them, for a terminal tmux does not know.
- `set-clipboard on` lets drag-to-copy reach the outer terminal's clipboard.
- The `hyperlinks` feature keeps file references in replies clickable; tmux
  drops OSC 8 links without it.

metacodes turns the keyboard protocol on inside tmux without asking (tmux
would answer for itself, not for the terminal outside it). tmux takes Ctrl+B
as its prefix, so the hint to run an agent in the background says
`ctrl+b ctrl+b`: the first Ctrl+B goes to tmux, the second reaches metacodes.

### GNU screen

Add `altscreen on` to `~/.screenrc`: without it, leaving the transcript viewer
does not bring back what was on the screen.

- Inside screen metacodes requests no keyboard protocol, which screen does not
  forward, unless `TERM` names kitty or Ghostty. Shift+Enter therefore
  submits: end the line with `\` and press Enter.
- Mouse reporting and drag-to-copy stay off: screen 4 does not forward the
  SGR mouse mode metacodes uses. Select text with the terminal as usual.
- screen 4 does not pass 24-bit colour on, so text drawn in it comes out in
  the default colour; screen 5 has `truecolor on`.
- Ctrl+A is screen's prefix: press Ctrl+A and then `a` to send Ctrl+A (start of
  line) to metacodes.

### Zellij

Inside Zellij metacodes requests the keyboard protocol only when `TERM` names
kitty or Ghostty; elsewhere Shift+Enter submits, so end the line with `\` and
press Enter. Zellij's default key bindings take Ctrl keys such as Ctrl+O and
Ctrl+T for its own modes; in locked mode (Ctrl+G) every key goes to
metacodes.

### mosh

mosh 1.4 and later pass OSC 52 copies and 24-bit colour on. mosh delivers
keys in bursts, so an Esc and an Enter pressed in quick succession can arrive
together and count as a newline (see the start of this page).

### SSH

`TERM_PROGRAM` does not travel over SSH, so on the remote side metacodes asks
the terminal about the keyboard protocol at startup instead of knowing it by
name; the question goes through SSH to the terminal you see. On a slow link
the answer can come after metacodes stopped waiting for it at startup
(120 ms); the protocol is turned on when it arrives, and until then
Shift+Enter submits and the footer says `\ + ⏎ for newline`. Drag-to-copy
reaches your clipboard only through OSC 52 (see above).

## How this was established

The Apple Terminal behaviour above was measured on macOS 15.7 (Intel) and
26.6 (Apple silicon) GitHub runners, driving Terminal.app with System Events
and reading the bytes the tty received (metacodes#386): Shift+Return sends `1b 0d`
with the mapping and `0d` without it; a key map holding only Shift+Return drops
F5 (`ESC [15~`), Shift+Right (`ESC [1;2C`) and Option+Left (`ESC b`); a running
Terminal keeps the old mapping in old and new windows until it is reopened, and
quitting it does not write its profiles back over the change. The same runs
took the metacodes binary through the whole flow inside Terminal: setup, the
same Terminal still sending `0d`, the reopened one sending `1b 0d` with F5,
Shift+Right and Option+Left unchanged, a two-line prompt from Shift+Return
under the `shift + ⏎` footer, and restore leaving the profile as it was before.
zsh binds `ESC CR` to `self-insert-unmeta`; bash leaves it unbound. The macOS
CI suite runs the edit, the backup and the restore with the real `plutil` and
`defaults` against a temporary settings domain
(`apps/cli/src/app/terminal_setup/apple_terminal.zig`, `setup.zig`). The VS Code side was
driven the same way on Windows (VS Code 1.105, a separate instance with its own
user data): Shift+Enter reached a console program as `0d` before setup and as
`1b 0d` after, without a restart; a window opened with `--profile` (a profile
with its own shortcuts) still sent `0d` with the entry only in the Default
profile's file. The key spelling rules come from VS Code's own keybinding
parser (in the 1.105 bundle): modifiers first, `+` or `-` between, so
`shift-enter` counts and `enter+shift` names no key.
