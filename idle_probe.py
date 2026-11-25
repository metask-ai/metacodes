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
    if label.startswith("warm"):
        env["IDLE_PROBE_WARM"] = "1"
    if label == "warm-monitor":
        env["IDLE_PROBE_LEAK"] = "1"
    started = time.monotonic()
    p = subprocess.run(["zig-out/bin/agentcore-abi-contract.exe"], env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    lines = p.stdout.decode(errors="replace").splitlines()
    start = next(i for i,l in enumerate(lines) if l.startswith("probe baseline"))
    end = next(i for i,l in enumerate(lines[start:], start) if l.startswith("probe after session teardown"))
    while start > 0 and lines[start-1].startswith("probe tid "):
        start -= 1
    if idx == 0 or p.returncode:
        print(label, idx, p.returncode, round(time.monotonic()-started, 3), *lines[start:end+1], sep=" | ", flush=True)
    return p.returncode

for label, bounded, overlap, single, count in [
    ("cold", True, False, True, 160), ("warm", True, False, True, 160),
    ("warm-suite", True, False, False, 1), ("warm-monitor", True, False, True, 1)
]:
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        print(label, Counter(pool.map(sample, [(label,i,bounded,overlap,single) for i in range(count)])), flush=True)
