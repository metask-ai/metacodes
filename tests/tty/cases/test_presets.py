"""A preset config.json does not define (#489): the TUI says so and starts without it.

`-p` and the rest stop with exit code 2 when `--preset`, `METACODES_PRESET` or
the working directory names a preset `config.json` does not define (the
component tests cover that). The interactive TUI says so once under its
banner, listing the presets that are defined, and starts as if the preset had
not been named: here on the provider `.env` configures, which answers a turn.

Everything runs against a loopback relay defined in config.json: no account,
no real request.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tty_driver import case_tmpdir, run, submit  # noqa: E402
from asserts import TTYAssert  # noqa: E402
from test_unbound import KEY_VARIABLES  # noqa: E402
from test_login_logout import RELAY_KEY, _Relay  # noqa: E402


def test_an_unknown_preset_is_named_under_the_banner_and_the_tui_starts_without_it(bin_path):
    with _Relay() as relay:
        home = case_tmpdir("cc-tty-preset-")
        state = os.path.join(home, ".metacodes")
        os.makedirs(state, exist_ok=True)
        config = relay.config()
        config["presets"] = {"relay": {"target": {"kind": "auto_route", "selector": "relay-model"}}}
        with open(os.path.join(state, "config.json"), "w") as f:
            json.dump(config, f)
        with open(os.path.join(state, ".env"), "w") as f:
            f.write(f"HOUSE_RELAY_TOKEN={RELAY_KEY}\nMETACODES_PROVIDER=house-relay\n")
        env = {name: None for name in KEY_VARIABLES}
        env.update({"HOME": home, "METACODES_HOME": None, "METACODES_JEV_URL": "off", "HOUSE_RELAY_TOKEN": None})
        work = case_tmpdir("cc-tty-preset-work-")
        raw = run(bin_path, submit("hi", "RELAY_REPLY"), env=env, base_url=None, cwd=work,
                  term_size=(30, 140), extra_args=["--preset", "nope"])
        a = TTYAssert(raw, rows=30, cols=140)
        a.assert_prose_contains("--preset nope: ")
        a.assert_prose_contains(f"{os.path.join(state, 'config.json')} defines no such preset (presets: relay).")
        a.assert_prose_contains("Started without it.")
        # It stayed open, on the next level that applies.
        a.assert_prose_contains("relay-model")
        assert relay.requests == [("/relay/v1/chat/completions", f"Bearer {RELAY_KEY}", "relay-model")], relay.requests
