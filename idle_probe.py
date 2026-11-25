import concurrent.futures
import os
import subprocess
import time
from collections import Counter

def sample(args):
    label, idx, bounded, overlap, single = args
    env = dict(os.environ, IDLE_PROBE_POOL="1", METACODES_TEST_ROOT="tests/component",
               METACODES_SANDBOX_HELPER=os.path.abspath("zig-out/bin/metacodes-fs-helper.exe"))
    for key, on in [("BOUND", bounded), ("OVERLAP", overlap), ("SINGLE", single)]:
        if on:
            env["IDLE_PROBE_" + key] = "1"
    started = time.monotonic()
    p = subprocess.run(["zig-out/bin/agentcore-abi-contract.exe"], env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    lines = p.stdout.decode(errors="replace").splitlines()
    start = next(i for i,l in enumerate(lines) if l.startswith("probe baseline"))
    end = next(i for i,l in enumerate(lines[start:], start) if l.startswith("probe after session teardown"))
    print(label, idx, p.returncode, round(time.monotonic()-started, 3), *lines[start:end+1], sep=" | ", flush=True)
    return p.returncode

for label, bounded, overlap, single, count in [
    ("natural", False, False, True, 48), ("capped", True, False, True, 48),
    ("overlap", False, True, True, 1), ("capped-overlap", True, True, True, 1),
    ("overlap-suite", False, True, False, 1), ("capped-overlap-suite", True, True, False, 1)
]:
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        print(label, Counter(pool.map(sample, [(label,i,bounded,overlap,single) for i in range(count)])), flush=True)
