import re
import shlex
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def checklist_commands():
    text = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
    block = re.search(r"Before submitting:\s*\n\s*```sh\n(.*?)\n```", text, re.S)
    if not block:
        raise AssertionError("AGENTS.md has no Before submitting shell block")
    return [line.strip() for line in block.group(1).splitlines() if line.strip()]


def ci_commands():
    lines = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8").splitlines()
    commands = []
    index = 0
    while index < len(lines):
        line = lines[index]
        match = re.match(r"^\s*run:\s*(.*)$", line)
        if match:
            value = match.group(1)
            if value in ("|", ">-"):
                index += 1
                while index < len(lines) and (not lines[index].strip() or len(lines[index]) - len(lines[index].lstrip()) > len(line) - len(line.lstrip())):
                    if lines[index].strip():
                        commands.append(lines[index].strip())
                    index += 1
                continue
            commands.append(value.strip())
        index += 1
    return commands


def normalized_words(command):
    words = shlex.split(command)
    if words and words[0] in ("python", "python3"):
        words[0] = "python"
    return words


class GateManifestTest(unittest.TestCase):
    def test_checklist_commands_are_present_in_ci(self):
        ci = [normalized_words(command) for command in ci_commands()]
        for expected in checklist_commands():
            words = normalized_words(expected)
            self.assertTrue(any(actual[: len(words)] == words for actual in ci), "missing checklist command: %s" % expected)


if __name__ == "__main__":
    unittest.main()
