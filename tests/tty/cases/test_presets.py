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
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tty_driver import READY, case_tmpdir, run, submit  # noqa: E402
from asserts import TTYAssert  # noqa: E402
from metask_mock import ACCESS_TOKEN, MODEL, MetaskMock  # noqa: E402
from test_unbound import KEY_VARIABLES  # noqa: E402
from test_login_logout import RELAY_KEY, _Relay, _screen  # noqa: E402

PRESET_KEY = "sk-preset-tty-env-0002"
PRESET_NOTICE = ".env configures the preset fast (Prov B · b-model); the default is Metask. To use it: /model, or /logout"


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


def _with_preset_provider(relay, preset_relay):
    config = relay.config()
    provider = preset_relay.config()["custom_providers"]["house-relay"]
    provider.update({
        "display_name": "Prov B",
        "env_aliases": [{"name": "PROV_B_TOKEN", "kind": "api_key", "canonical": True}],
        "models": [{"request_model_id": "b-model", "display_name": "B model"}],
    })
    config["custom_providers"]["prov-b"] = provider
    config["presets"] = {"fast": {"target": {"kind": "auto_route", "selector": "b-model"}}}
    return config


def _signed_in(mock, relay, preset_relay, env_file, shell=None):
    home = case_tmpdir("cc-tty-preset-")
    state = os.path.join(home, ".metacodes")
    os.makedirs(state, exist_ok=True)
    mock.write_session(state)
    with open(os.path.join(state, "config.json"), "w") as f:
        json.dump(_with_preset_provider(relay, preset_relay), f)
    with open(os.path.join(state, ".env"), "w") as f:
        f.write(env_file)
    env = {name: None for name in KEY_VARIABLES}
    env.update({"HOME": home, "METACODES_HOME": None, "METACODES_JEV_URL": "off",
                "HOUSE_RELAY_TOKEN": None, "PROV_B_TOKEN": None})
    env.update(mock.env(home))
    env.update(shell or {})
    return env


def test_under_a_metask_sign_in_the_notice_names_the_env_preset_and_logout_moves_onto_it(bin_path):
    with MetaskMock() as mock, _Relay() as relay, _Relay() as preset_relay:
        env = _signed_in(mock, relay, preset_relay,
                         f"HOUSE_RELAY_TOKEN={RELAY_KEY}\nPROV_B_TOKEN={PRESET_KEY}\n"
                         "METACODES_PROVIDER=house-relay\nMETACODES_PRESET=fast\n")
        work = case_tmpdir("cc-tty-preset-work-")
        raw = run(bin_path, submit("hi", "METASK_MOCK_REPLY") + submit("/logout", "Switched to Prov B (from .env)")
                  + submit("again", "RELAY_REPLY"), env=env, base_url=None, cwd=work, term_size=(30, 140))
        a = TTYAssert(raw, rows=30, cols=140)
        screen = _screen(a)
        a.assert_prose_contains(PRESET_NOTICE)
        assert b".env configures House relay" not in re.sub(rb"\x1b\[[0-9;?>]*[A-Za-z]", b"", raw)
        assert "Switched to Prov B (from .env) · b-model\n" in screen + "\n", screen
        assert mock.messages == [(f"Bearer {ACCESS_TOKEN}", MODEL)], mock.messages
        assert preset_relay.requests == [("/relay/v1/chat/completions", f"Bearer {PRESET_KEY}", "b-model")], preset_relay.requests
        assert relay.requests == [], relay.requests
        raw2 = run(bin_path, [READY, "strictsleep:0.3"], env=env, base_url=None, cwd=work, term_size=(30, 140))
        TTYAssert(raw2, rows=30, cols=140).assert_prose_contains("b-model · from .env")
        assert b".env configures" not in raw2


def test_a_preset_alone_in_env_is_named_under_a_metask_sign_in_and_logout_moves_onto_it(bin_path):
    with MetaskMock() as mock, _Relay() as relay, _Relay() as preset_relay:
        env = _signed_in(mock, relay, preset_relay, "METACODES_PRESET=fast\n", {"PROV_B_TOKEN": PRESET_KEY})
        work = case_tmpdir("cc-tty-preset-work-")
        raw = run(bin_path, submit("/logout", "Switched to Prov B (from shell)") + submit("again", "RELAY_REPLY"),
                  env=env, base_url=None, cwd=work, term_size=(30, 140))
        a = TTYAssert(raw, rows=30, cols=140)
        a.assert_prose_contains(PRESET_NOTICE)
        assert "Switched to Prov B (from shell) · b-model\n" in _screen(a) + "\n", _screen(a)
        assert preset_relay.requests == [("/relay/v1/chat/completions", f"Bearer {PRESET_KEY}", "b-model")], preset_relay.requests
        assert relay.requests == [] and mock.messages == [], (relay.requests, mock.messages)
