#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Compare the per-call cost of the kprobe fix and the livepatch fix.

Boots 6.8.0-100-generic once and, inside the guest (lab/guest/perf.sh), alternates
no fix / kprobe / livepatch while lab/kmod/bench times skb_gso_segment() on a
VXLAN GSO skb. Needs KVM; under TCG one call takes tens of microseconds and the
difference disappears in the noise.

  lab/perf.py --tag perf                     # 10 reps, 2-segment skb
  lab/perf.py --tag perf-wide --reps 3 --segs "2 7 14"
"""
import argparse
from collections import defaultdict
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys

LAB = Path(__file__).resolve().parent
ROOT = LAB.parent
RELEASE = "6.8.0-100-generic"   # the livepatch body is specific to this build


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", required=True, help="results go to results/<tag>")
    parser.add_argument("--reps", type=int, default=10)
    parser.add_argument("--segs", default="2")
    parser.add_argument("--iters", type=int, default=200000)
    parser.add_argument("--rounds", type=int, default=9)
    args = parser.parse_args()
    if not os.access("/dev/kvm", os.R_OK | os.W_OK):
        sys.exit("/dev/kvm is not usable; this comparison is meaningless under TCG")

    kmod = ROOT / ".cache/kmod" / RELEASE
    out = ROOT / "results" / args.tag
    cmd = [sys.executable, str(LAB / "qemu-test.py"), "--release", RELEASE, "--output", str(out),
           "--timeout", "3600", "--guest-script", str(LAB / "guest/perf.sh"),
           "--env", f"REPS={args.reps}", "--env", f"SEGS_LIST={args.segs}",
           "--env", f"ITERS={args.iters}", "--env", f"ROUNDS={args.rounds}"]
    for name in ("gso_bench", "vxlan_gso_csum_fix", "udp_gso_fix_lp"):
        cmd += ["--extra", str(kmod / f"{name}.ko")]
    subprocess.run(cmd, check=True)

    samples = defaultdict(list)
    for line in (out / "perf.txt").read_text().splitlines():
        m = re.search(r"variant=(\w+) .*segs=(\d+) encap_hdr=(\d) .*median=(\d+)", line)
        if m:
            samples[(m[2], m[3], m[1])].append(int(m[4]))
    print(f"\n{'segs':>4} {'fix cond':>8} | {'none':>13} {'kprobe':>13} {'livepatch':>13} | per call vs none")
    for segs in args.segs.split():
        for encap in ("0", "1"):
            med = {v: statistics.median(samples[(segs, encap, v)]) for v in ("none", "kprobe", "livepatch")}
            sd = {v: statistics.pstdev(samples[(segs, encap, v)]) for v in med}
            cells = " ".join(f"{med[v]:>6.0f}ns±{sd[v]:<4.0f}" for v in med)
            print(f"{segs:>4} {'true' if encap == '1' else 'false':>8} | {cells} | "
                  f"kprobe {med['kprobe'] - med['none']:+.0f}ns, livepatch {med['livepatch'] - med['none']:+.0f}ns")


if __name__ == "__main__":
    main()
