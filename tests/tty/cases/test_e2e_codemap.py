import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from e2e_helpers import assert_tool_e2e, require_model  # noqa: E402


def test_e2e_read_source_outline(bin_path):
    require_model()
    with tempfile.TemporaryDirectory() as cwd:
        with open(os.path.join(cwd, "sample.zig"), "w", encoding="utf-8") as sample:
            sample.write("pub fn sample() void {}\n")
        assert_tool_e2e(
            bin_path,
            "Use Read with outline=true on sample.zig and report its symbols.",
            "Read",
            required_keys=["file_path", "outline"],
            cwd=cwd,
            require_card=False,
            wait_s=14,
        )
