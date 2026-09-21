import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class DeliveryCadenceConstantsLockstepTest(unittest.TestCase):
    """The Lean proof, the Zig runtime and the eval parser each carry the
    nudge bound as a literal; they must agree or the proof stops describing
    the runtime (Codex review of #128)."""

    def test_nudge_bound_is_identical_in_lean_zig_and_trace(self):
        lean = (ROOT / "control-plane/lean/MetaCodesControl/DeliveryCadence.lean").read_text(encoding="utf-8")
        zig = (ROOT / "src/core/delivery_cadence.zig").read_text(encoding="utf-8")
        trace = (ROOT / "scripts/eval/workbuddy/trace.py").read_text(encoding="utf-8")
        lean_bound = int(re.search(r"^def maxNudges : Nat := (\d+)", lean, re.M).group(1))
        zig_bound = int(re.search(r"pub const MAX_CADENCE_NUDGES: u8 = (\d+);", zig).group(1))
        trace_bound = int(re.search(r'formal\["delivery_cadence_max_nudges"\] != (\d+)', trace).group(1))
        self.assertEqual(lean_bound, zig_bound)
        self.assertEqual(zig_bound, trace_bound)

    def test_meter_cap_is_identical_in_lean_and_zig(self):
        lean = (ROOT / "control-plane/lean/MetaCodesControl/HostInjectionMeter.lean").read_text(encoding="utf-8")
        zig = (ROOT / "src/core/host_injection_meter.zig").read_text(encoding="utf-8")
        lean_cap = int(re.search(r"^def cap : Nat := (\d+)", lean, re.M).group(1))
        zig_cap = int(re.search(r"pub const MAX_HOST_INJECTIONS_PER_RUN: u8 = (\d+);", zig).group(1))
        self.assertEqual(lean_cap, zig_cap)


if __name__ == "__main__":
    unittest.main()
