"""screen.py still gives the answers apps/cli/tests/component/vterm.zig is pinned to (#319).

Offline: replays tests/tty/vterm_parity.py's corpus through screen.py (no
binary, bin_path unused) and compares with the committed fixture that
apps/cli/tests/component/vterm_test.zig replays through the Zig port.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import vterm_parity  # noqa: E402
from asserts import AssertError  # noqa: E402


def test_vterm_parity_fixture_matches_screen_py(bin_path):
    with open(vterm_parity.FIXTURE, encoding="ascii") as f:
        committed = f.read().splitlines()
    current = vterm_parity.build().splitlines()
    if committed == current:
        return
    names = [line.split('"name": ', 1)[1].split(",", 1)[0] for line in current]
    stale = [names[i] for i in range(min(len(committed), len(current))) if committed[i] != current[i]]
    raise AssertError(
        "screen.py answers differ from tests/fixtures/vterm/screen_parity.jsonl "
        f"(vectors {stale[:8]}, {len(committed)} committed vs {len(current)} built). "
        "If screen.py changed on purpose, run `python tests/tty/vterm_parity.py --write` "
        "and make apps/cli/tests/component/vterm.zig agree."
    )
