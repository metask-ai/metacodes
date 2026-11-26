"""Local `/command` results and the `/skills` dialog, aligned with Claude Code
2.1.278 (recorded in the workspace's ui_compare/cc2.1.278):

  ❯ /cost
    ⎿  Total cost:  $0.0000
       Usage:       0 input, …

  - a local command's result hangs off `⎿` under its echo;
  - an unknown command is reported in place of its echo, with a suggestion;
  - `/skills` is a searchable pane of each Skill's `skillOverrides` state;
    Enter or Space cycles on → name-only → user-only → off, Esc saves the
    changes to `.claude/settings.local.json` and leaves `⎿  Updated 2 skill
    overrides` (or `⎿  No changes`); `/name` of an "off" Skill is refused in
    place of its echo, and it leaves the `/` menu.
"""
import json
import os

from tty_driver import run, submit, READY, wait_for, case_tmpdir
from asserts import TTYAssert


def _home_with_skills():
    home = case_tmpdir("cc-tty-skills-home-")
    for name, desc in (("alpha-skill", "Alpha does release notes"), ("beta-skill", "Beta reviews diffs")):
        path = os.path.join(home, ".claude", "skills", name)
        os.makedirs(path)
        with open(os.path.join(path, "SKILL.md"), "w") as f:
            f.write(f"---\nname: {name}\ndescription: {desc}\n---\nDo it.\n")
    return home


def test_local_command_result_hangs_off_the_gutter(bin_path):
    raw = run(bin_path, submit("/cost", "Total cost:"))
    a = TTYAssert(raw)
    echo = a.final.find_row("❯ /cost")
    if echo is None:
        a._fail("the /cost echo is missing")
    a.assert_line_contains(echo + 1, "  ⎿  Total cost:")
    a.assert_line_contains(echo + 2, "     Usage:")
    a.assert_box_present()
    a.assert_box_at_bottom()


def test_unknown_command_replaces_its_echo_with_a_suggestion(bin_path):
    raw = run(bin_path, submit("/foo", "Unknown command"))
    a = TTYAssert(raw)
    row = a.final.find_row("Unknown command: /foo. Did you mean /loop?")
    if row is None:
        a._fail("the unknown-command report with its suggestion is missing")
    if a.final.find_row("❯ /foo") is not None:
        a._fail("an unknown command is reported in place of its echo")


def test_vim_is_an_unknown_command_in_the_tui(bin_path):
    raw = run(bin_path, submit("/vim", "Unknown command"))
    a = TTYAssert(raw)
    row = a.final.find_row("Unknown command: /vim")
    if row is None:
        a._fail("/vim should be reported as an unknown command")
    if "Did you mean /vim" in a.final.line_text(row):
        a._fail("the suggestion must not offer /vim")
    if a.final.find_row("Editor mode") is not None:
        a._fail("/vim must not switch the editor mode")
    a.assert_input_echo("")
    a.assert_box_present()


def test_exit_says_goodbye_under_the_echo(bin_path):
    raw = run(bin_path, submit("/exit", "Goodbye"))
    a = TTYAssert(raw)
    echo = a.final.find_row("❯ /exit")
    if echo is None:
        a._fail("the /exit echo is missing")
    a.assert_line_contains(echo + 1, "⎿  Goodbye!")
    a.assert_clean_exit()


def _project_dir():
    """A repository of its own: `/skills` writes its `.claude/settings.local.json`."""
    project = case_tmpdir("cc-tty-skills-proj-")
    os.makedirs(os.path.join(project, ".git"))
    return project


def test_skills_dialog_lists_states_and_filters(bin_path):
    home = _home_with_skills()
    raw = run(bin_path, [READY, "type:/skills", "key:enter", wait_for("Search skills", 10),
                         "type:beta", wait_for("type to filter", 10), "strictsleep:0.3",
                         "key:esc", "strictsleep:0.3", "key:esc", wait_for("to cycle", 10),
                         "key:esc", wait_for("No changes", 10)],
              env={"HOME": home}, cwd=_project_dir())
    a = TTYAssert(raw)
    if not a.screens_with("2 skills · enter/space to cycle, / to search, Esc to close"):
        a._fail("the Skills pane header should count the skills and name the keys")
    if not a.screens_with("✔ on         alpha-skill · user · < 20 tok"):
        a._fail("each row should show the Skill's state, source and listing cost")
    filtered = [sc for sc in a.screens_with("1/2 skills · type to filter") if sc.find_row("alpha-skill · user") is None]
    if not filtered:
        a._fail("typing should search and filter the list")
    echo = a.final.find_row("❯ /skills")
    if echo is None:
        a._fail("the /skills echo is missing")
    a.assert_line_contains(echo + 1, "⎿  No changes")
    a.assert_box_present()


def test_skills_dialog_cycles_saves_and_gates_the_skill(bin_path):
    home = _home_with_skills()
    project = _project_dir()
    raw = run(bin_path, [READY, "type:/skills", "key:enter", wait_for("Search skills", 10),
                         "key:enter", wait_for("name-only  alpha-skill", 10),
                         "type: ", wait_for("user-only  alpha-skill", 10),
                         "key:down", "strictsleep:0.3",
                         "key:enter", "strictsleep:0.3", "key:enter", "strictsleep:0.3", "key:enter",
                         wait_for("off        beta-skill", 10),
                         "key:esc", wait_for("Updated 2 skill overrides", 10),
                         "type:/beta-skill", "strictsleep:0.5", "key:enter",
                         wait_for("disabled via skillOverrides", 10), "strictsleep:0.3",
                         "type:/beta", "strictsleep:0.8"],
              env={"HOME": home}, cwd=project)
    a = TTYAssert(raw)
    echo = a.final.find_row("❯ /skills")
    if echo is None:
        a._fail("the /skills echo is missing")
    a.assert_line_contains(echo + 1, "⎿  Updated 2 skill overrides")

    with open(os.path.join(project, ".claude", "settings.local.json")) as f:
        saved = json.load(f)["skillOverrides"]
    if saved != {"alpha-skill": "user-invocable-only", "beta-skill": "off"}:
        a._fail(f"the overrides should be saved to the project's local settings, got {saved}")

    refused = a.final.find_row('Skill "beta-skill" is disabled via skillOverrides.')
    if refused is None:
        a._fail("an off Skill's /name should be refused in Claude Code's words")
    if a.final.find_row("❯ /beta-skill") is not None:
        a._fail("the refusal replaces the /name echo")
    # An off Skill leaves the `/` menu.
    if a.final.find_row("/beta-skill  ") is not None or a.final.find_row("Beta reviews diffs") is not None:
        a._fail("an off Skill should not be offered in the / menu")


def test_clear_restarts_the_screen_at_the_banner(bin_path):
    raw = run(bin_path, submit("/cost", "Total cost:") + [READY, "type:/clear", "key:enter", "strictsleep:1.5"])
    a = TTYAssert(raw)
    if a.final.find_row("Total cost:") is not None:
        a._fail("/clear should clear the screen")
    banner = a.final.find_row("metacodes v")
    echo = a.final.find_row("❯ /clear")
    if banner is None or echo is None or echo < banner:
        a._fail("/clear should redraw the banner with the command under it")
    a.assert_box_present()
