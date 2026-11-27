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
from tty_driver import IS_WINDOWS, READY, case_tmpdir, run, submit, wait_for  # noqa: E402
from asserts import TTYAssert  # noqa: E402
from e2e_helpers import SkipTest  # noqa: E402
from metask_mock import ACCESS_TOKEN, MODEL, MetaskMock  # noqa: E402
from test_unbound import KEY_VARIABLES, NOT_SET  # noqa: E402
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
        raw = run(bin_path, submit("hi", "METASK_MOCK_REPLY") + submit("/logout", "Switched to the preset fast (from .env)")
                  + submit("again", "RELAY_REPLY"), env=env, base_url=None, cwd=work, term_size=(30, 140))
        a = TTYAssert(raw, rows=30, cols=140)
        screen = _screen(a)
        a.assert_prose_contains(PRESET_NOTICE)
        assert b".env configures House relay" not in re.sub(rb"\x1b\[[0-9;?>]*[A-Za-z]", b"", raw)
        assert "Switched to the preset fast (from .env): Prov B · b-model\n" in screen + "\n", screen
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
        raw = run(bin_path, submit("/logout", "Switched to the preset fast (from shell)") + submit("again", "RELAY_REPLY"),
                  env=env, base_url=None, cwd=work, term_size=(30, 140))
        a = TTYAssert(raw, rows=30, cols=140)
        a.assert_prose_contains(PRESET_NOTICE)
        assert "Switched to the preset fast (from shell): Prov B · b-model\n" in _screen(a) + "\n", _screen(a)
        assert preset_relay.requests == [("/relay/v1/chat/completions", f"Bearer {PRESET_KEY}", "b-model")], preset_relay.requests
        assert relay.requests == [] and mock.messages == [], (relay.requests, mock.messages)


def test_logout_onto_a_preset_without_its_key_says_which_key_and_where(bin_path):
    with MetaskMock() as mock, _Relay() as relay, _Relay() as preset_relay:
        env = _signed_in(mock, relay, preset_relay, "METACODES_PRESET=fast\n")
        state = os.path.join(env["HOME"], ".metacodes")
        work = case_tmpdir("cc-tty-preset-work-")
        raw = run(bin_path, submit("/logout", "No model is set up now"), env=env, base_url=None, cwd=work,
                  term_size=(30, 160))
        screen = _screen(TTYAssert(raw, rows=30, cols=160))
        assert "No model is set up now: the preset fast needs a key for Prov B." in screen, screen
        assert f"Set PROV_B_TOKEN in {os.path.join(state, '.env')}" in screen, screen
        assert "Switched to" not in screen, screen
        assert preset_relay.requests == [] and relay.requests == [] and mock.messages == [], \
            (preset_relay.requests, relay.requests, mock.messages)


UNCHOSEN = "No model is chosen for this directory: it remembers no preset, and global_default is off."


def _repositories():
    root = os.path.realpath(case_tmpdir("cc-tty-dirs-"))
    paths = {}
    for name in ("x", "y", "z"):
        paths[name] = os.path.join(root, name)
        os.makedirs(os.path.join(paths[name], ".git"))
    return root, paths


def _listing(root):
    return sorted(os.path.relpath(os.path.join(base, name), root)
                  for base, dirs, files in os.walk(root) for name in dirs + files)


def _session_records(state):
    projects = os.path.join(state, "projects")
    if not os.path.isdir(projects):
        return []
    return [os.path.join(project, entry) for project in os.listdir(projects)
            for entry in os.listdir(os.path.join(projects, project)) if entry != "memory"]


def test_with_global_default_off_x_and_y_keep_their_presets_and_z_opens_unbound(bin_path):
    if IS_WINDOWS:
        raise SkipTest("directory presets are keyed by POSIX paths here, as in the component tests")
    with MetaskMock() as mock, _Relay() as relay, _Relay() as preset_relay:
        home = case_tmpdir("cc-tty-preset-")
        state = os.path.join(home, ".metacodes")
        os.makedirs(state, exist_ok=True)
        mock.write_session(state)
        root, dirs = _repositories()
        config = _with_preset_provider(relay, preset_relay)
        config["presets"] = {
            "a": {"target": {"kind": "auto_route", "selector": "relay-model"}},
            "b": {"target": {"kind": "auto_route", "selector": "b-model"}},
        }
        config["directory_presets"] = {dirs["x"]: "a", dirs["y"]: "b"}
        config["global_selection"] = {"target": {"kind": "auto_route", "selector": "relay-model"}, "scope": "global"}
        config["global_default"] = False
        config_path = os.path.join(state, "config.json")
        with open(config_path, "w") as f:
            json.dump(config, f)
        with open(os.path.join(state, ".env"), "w") as f:
            f.write(f"HOUSE_RELAY_TOKEN={RELAY_KEY}\nPROV_B_TOKEN={PRESET_KEY}\nMETACODES_PROVIDER=house-relay\n")
        env = {name: None for name in KEY_VARIABLES}
        env.update({"HOME": home, "METACODES_HOME": None, "METACODES_JEV_URL": "off",
                    "HOUSE_RELAY_TOKEN": None, "PROV_B_TOKEN": None})
        env.update(mock.env(home))
        before = _listing(root)

        raw = run(bin_path, [READY, "type:hi", "key:enter", wait_for(UNCHOSEN, 10), "strictsleep:0.5"],
                  env=env, base_url=None, cwd=dirs["z"], term_size=(40, 240))
        a = TTYAssert(raw, rows=40, cols=240)
        a.assert_prose_contains(NOT_SET)
        echo = a.final.find_row("❯ hi")
        if echo is None:
            a._fail("the prompt's echo is missing")
        a.assert_line_contains(echo + 1, "⎿  " + UNCHOSEN)
        screen = _screen(a)
        assert "Choose one for this session:  /model" in screen, screen
        assert "--preset <name> (presets: a, b)" in screen, screen
        assert f'"{dirs["z"]}": "<name>" under directory_presets in {config_path}' in screen, screen
        assert "/login" not in screen.split(UNCHOSEN, 1)[1], screen
        assert relay.requests == [] and preset_relay.requests == [] and mock.messages == [], \
            (relay.requests, preset_relay.requests, mock.messages)
        assert _session_records(state) == [], _session_records(state)

        raw_x = run(bin_path, submit("hi", "RELAY_REPLY"), env=env, base_url=None, cwd=dirs["x"], term_size=(30, 140))
        TTYAssert(raw_x, rows=30, cols=140).assert_prose_contains("relay-model · from .env")
        raw_y = run(bin_path, submit("hi", "RELAY_REPLY"), env=env, base_url=None, cwd=dirs["y"], term_size=(30, 140))
        TTYAssert(raw_y, rows=30, cols=140).assert_prose_contains("b-model · from .env")
        assert relay.requests == [("/relay/v1/chat/completions", f"Bearer {RELAY_KEY}", "relay-model")], relay.requests
        assert preset_relay.requests == [("/relay/v1/chat/completions", f"Bearer {PRESET_KEY}", "b-model")], preset_relay.requests
        assert mock.messages == [], mock.messages
        assert _listing(root) == before, (before, _listing(root))


def test_with_global_default_off_logout_leaves_the_session_without_a_model(bin_path):
    if IS_WINDOWS:
        raise SkipTest("directory presets are keyed by POSIX paths here, as in the component tests")
    with MetaskMock() as mock, _Relay() as relay:
        home = case_tmpdir("cc-tty-preset-")
        state = os.path.join(home, ".metacodes")
        os.makedirs(state, exist_ok=True)
        mock.write_session(state)
        root, dirs = _repositories()
        config = relay.config()
        config["global_default"] = False
        with open(os.path.join(state, "config.json"), "w") as f:
            json.dump(config, f)
        with open(os.path.join(state, ".env"), "w") as f:
            f.write(f"HOUSE_RELAY_TOKEN={RELAY_KEY}\nMETACODES_PROVIDER=house-relay\n")
        env = {name: None for name in KEY_VARIABLES}
        env.update({"HOME": home, "METACODES_HOME": None, "METACODES_JEV_URL": "off", "HOUSE_RELAY_TOKEN": None})
        env.update(mock.env(home))
        raw = run(bin_path, submit("hi", "METASK_MOCK_REPLY") + submit("/logout", "No model is set up now"),
                  env=env, base_url=None, cwd=dirs["z"], term_size=(30, 140), extra_args=["--provider", "metask"])
        a = TTYAssert(raw, rows=30, cols=140)
        screen = _screen(a)
        assert "No model is set up now" in screen, screen
        assert "Switched to" not in screen, screen
        assert [authorization for authorization, _ in mock.messages] == [f"Bearer {ACCESS_TOKEN}"], mock.messages
        assert relay.requests == [], relay.requests


FILE_METASK_KEY = "sk-metask-in-env-tty-0003"


def test_a_metask_key_beside_the_env_preset_waits_and_the_preset_answers(bin_path):
    with _Relay() as relay:
        home = case_tmpdir("cc-tty-preset-")
        state = os.path.join(home, ".metacodes")
        os.makedirs(state, exist_ok=True)
        config = relay.config()
        config["presets"] = {"fast": {"target": {"kind": "auto_route", "selector": "relay-model"}}}
        with open(os.path.join(state, "config.json"), "w") as f:
            json.dump(config, f)
        with open(os.path.join(state, ".env"), "w") as f:
            f.write(f"METACODES_PRESET=fast\nHOUSE_RELAY_TOKEN={RELAY_KEY}\nMETASK_API_KEY={FILE_METASK_KEY}\n")
        env = {name: None for name in KEY_VARIABLES}
        env.update({"HOME": home, "METACODES_HOME": None, "METACODES_JEV_URL": "off", "HOUSE_RELAY_TOKEN": None})
        every_route_at_the_relay = config["custom_providers"]["house-relay"]["channels"][0]["base_url"]
        work = case_tmpdir("cc-tty-preset-work-")
        raw = run(bin_path, submit("hi", "RELAY_REPLY"), env=env, base_url=every_route_at_the_relay, cwd=work,
                  term_size=(30, 140))
        a = TTYAssert(raw, rows=30, cols=140)
        a.assert_prose_contains("relay-model · from .env")
        assert relay.requests == [("/relay/v1/chat/completions", f"Bearer {RELAY_KEY}", "relay-model")], relay.requests
        assert FILE_METASK_KEY.encode() not in raw
