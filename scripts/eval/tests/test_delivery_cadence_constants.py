import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class DeliveryCadenceConstantsLockstepTest(unittest.TestCase):
    """The Lean proof, the Zig runtime and the eval parser each carry the
    nudge bound as a literal; they must agree or the proof stops describing
    the runtime (Codex review of #128). This is drift detection over source
    text, not a semantic link: it catches one side changing alone, it cannot
    prove the Lean policy is the Zig policy — the mirrored theorem/test names
    carry that burden."""

    def test_nudge_bound_is_identical_in_lean_zig_and_trace(self):
        lean = (ROOT / "control-plane/lean/MetaCodesControl/DeliveryCadence.lean").read_text(encoding="utf-8")
        zig = (ROOT / "src/core/delivery_cadence.zig").read_text(encoding="utf-8")
        trace = (ROOT / "scripts/eval/workbuddy/trace.py").read_text(encoding="utf-8")
        lean_bound = int(re.search(r"^def maxNudges : Nat := (\d+)", lean, re.M).group(1))
        zig_bound = int(re.search(r"pub const MAX_CADENCE_NUDGES: u8 = (\d+);", zig).group(1))
        trace_bound = int(re.search(r'formal\["delivery_cadence_max_nudges"\] != (\d+)', trace).group(1))
        self.assertEqual(lean_bound, zig_bound)
        self.assertEqual(zig_bound, trace_bound)

    def test_progress_nudge_bound_is_identical_in_lean_zig_and_trace(self):
        lean = (ROOT / "control-plane/lean/MetaCodesControl/ProgressUpdates.lean").read_text(encoding="utf-8")
        zig = (ROOT / "src/core/progress_updates.zig").read_text(encoding="utf-8")
        trace = (ROOT / "scripts/eval/workbuddy/trace.py").read_text(encoding="utf-8")
        lean_bound = int(re.search(r"^def maxNudges : Nat := (\d+)", lean, re.M).group(1))
        zig_bound = int(re.search(r"pub const MAX_PROGRESS_NUDGES: u8 = (\d+);", zig).group(1))
        trace_bound = int(re.search(r'formal\["progress_updates_max_nudges"\] != (\d+)', trace).group(1))
        self.assertEqual(lean_bound, zig_bound)
        self.assertEqual(zig_bound, trace_bound)

    def test_check_gate_bounds_are_identical_in_lean_zig_and_trace(self):
        lean = (ROOT / "control-plane/lean/MetaCodesControl/CheckGate.lean").read_text(encoding="utf-8")
        zig = (ROOT / "src/core/check_gate.zig").read_text(encoding="utf-8")
        trace = (ROOT / "scripts/eval/workbuddy/trace.py").read_text(encoding="utf-8")
        lean_stop = int(re.search(r"^def maxStopBlocks : Nat := (\d+)", lean, re.M).group(1))
        zig_stop = int(re.search(r"pub const MAX_STOP_HOOK_BLOCKS: u8 = (\d+);", zig).group(1))
        trace_stop = int(re.search(r'formal\["check_gate_stop_hook_blocks"\] > (\d+)', trace).group(1))
        self.assertEqual(lean_stop, zig_stop)
        self.assertEqual(zig_stop, trace_stop)
        zig_hard = int(re.search(r"pub const HARD_MAX_CONTINUATIONS: u8 = (\d+);", zig).group(1))
        trace_hard = int(re.search(r'not 1 <= formal\["check_gate_max_continuations"\] <= (\d+)', trace).group(1))
        self.assertEqual(zig_hard, trace_hard)

    def test_test_integrity_budget_is_identical_in_lean_zig_and_trace(self):
        lean = (ROOT / "control-plane/lean/MetaCodesControl/TestIntegrity.lean").read_text(encoding="utf-8")
        zig = (ROOT / "src/core/test_integrity.zig").read_text(encoding="utf-8")
        trace = (ROOT / "scripts/eval/workbuddy/trace.py").read_text(encoding="utf-8")
        lean_bound = int(re.search(r"^def maxNudges : Nat := (\d+)", lean, re.M).group(1))
        zig_bound = int(re.search(r"pub const MAX_NUDGES: u8 = (\d+);", zig).group(1))
        trace_bound = int(re.search(r'formal\["test_integrity_max_nudges"\] != (\d+)', trace).group(1))
        self.assertEqual(lean_bound, zig_bound)
        self.assertEqual(zig_bound, trace_bound)

    def test_stall_gate_constants_are_identical_in_lean_zig_and_trace(self):
        lean = (ROOT / "control-plane/lean/MetaCodesControl/StallGate.lean").read_text(encoding="utf-8")
        zig = (ROOT / "src/core/stall_gate.zig").read_text(encoding="utf-8")
        trace = (ROOT / "scripts/eval/workbuddy/trace.py").read_text(encoding="utf-8")
        lean_bound = int(re.search(r"^def maxDecisions : Nat := (\d+)", lean, re.M).group(1))
        zig_bound = int(re.search(r"pub const MAX_STALL_DECISIONS: u8 = (\d+);", zig).group(1))
        trace_bound = int(re.search(r'formal\["stall_gate_max_decisions"\] != (\d+)', trace).group(1))
        self.assertEqual(lean_bound, zig_bound)
        self.assertEqual(zig_bound, trace_bound)
        # The shipped thresholds and the call window: the theorems hold for
        # every value, but the Lean file names the ones the runtime ships.
        for lean_name, zig_name in (
            ("defaultRepeatRounds", "DEFAULT_REPEAT_ROUNDS: u32"),
            ("defaultRepeatCalls", "DEFAULT_REPEAT_CALLS: u32"),
            ("defaultStaleRounds", "DEFAULT_STALE_ROUNDS: u32"),
            ("stretchCap", "STRETCH_CAPACITY: usize"),
        ):
            lean_value = int(re.search(rf"^def {lean_name} : Nat := (\d+)", lean, re.M).group(1))
            zig_value = int(re.search(rf"pub const {zig_name} = (\d+);", zig).group(1))
            self.assertEqual(lean_value, zig_value, lean_name)

    def test_meter_cap_is_identical_in_lean_and_zig(self):
        lean = (ROOT / "control-plane/lean/MetaCodesControl/HostInjectionMeter.lean").read_text(encoding="utf-8")
        zig = (ROOT / "src/core/host_injection_meter.zig").read_text(encoding="utf-8")
        lean_cap = int(re.search(r"^def cap : Nat := (\d+)", lean, re.M).group(1))
        zig_cap = int(re.search(r"pub const MAX_HOST_INJECTIONS_PER_RUN: u8 = (\d+);", zig).group(1))
        self.assertEqual(lean_cap, zig_cap)


if __name__ == "__main__":
    unittest.main()
