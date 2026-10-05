#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Run reproducer cases in parallel QEMU guests and summarise them.

Every case uses the deterministic burst feeder (lab/tools/burst.c) unless it ends
in "+iperf", and loads the tracing kprobe (lab/kmod/trace) so the report also
shows how many __skb_udp_tunnel_segment() re-entries used a non-seed checksum.
Cases starting with "fix" load the same module with mode=1 (the fix applied).

  lab/matrix.py --tag smoke base fix
  lab/matrix.py --tag paths --release 7.0.0-38-generic path-macvlan-nic path-vlan-nic
  lab/matrix.py --tag repeat base@1 base@2 base@3      # name@N repeats a case
"""
import argparse
import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import re
import subprocess
import sys

LAB = Path(__file__).resolve().parent
ROOT = LAB.parent

BURST = ["--env", "TRAFFIC=burst", "--env", "NA_RX_USECS=2000"]
TUNNEL_TSO = ["--env", "NIC_K_SETUP=tx-tcp-mangleid-segmentation on"]

# Conditions, on the default stack vxlan -> macvlan -> VLAN -> NIC.
CONDITIONS = {
    "base": [],
    "router-gro-off": ["--na-gro", "off"],
    "vxlan-nocsum": ["--env", "VXLAN_UDPCSUM=0"],
    "gso-max-segs-13": ["--segs", "13"],
    "vxlan-tso-off": ["--env", "VXLAN_TSO=off"],
    "no-gso-partial": ["--env", "NIC_K=tx-gso-partial off"],
    "no-tnl-seg": ["--env", "NIC_K=tx-udp_tnl-segmentation off tx-udp_tnl-csum-segmentation off"],
    "vlan-sg-off": ["--vlan-sg", "off"],
    "tunnel-tso": TUNNEL_TSO,
}
# Device stacks between the VXLAN device and the wire on the router.
PATHS = {
    "path-macvlan-vlan-nic": [],
    "path-macvlan-nic": ["--env", "NA_VLAN=0"],
    "path-vlan-nic": ["--env", "NA_MACVLAN=0"],
    "path-nic": ["--env", "NA_VLAN=0", "--env", "NA_MACVLAN=0"],
    "path-macvlan-vlan-bond-nic": ["--bond"],
    "path-vlan-bond-nic": ["--bond", "--env", "NA_MACVLAN=0"],
    "path-bond-nic": ["--bond", "--env", "NA_VLAN=0", "--env", "NA_MACVLAN=0"],
}

CASES = {}
for _name, _extra in {**CONDITIONS, **PATHS}.items():
    CASES[_name] = _extra + BURST
    CASES[_name + "+iperf"] = _extra
for _name, _extra in PATHS.items():
    CASES[_name + "+tunnel-tso"] = _extra + TUNNEL_TSO + BURST
# Inner UDP instead of TCP, with the router NIC's UDP GRO modes.
UDP = ["--env", "BURST_PROTO=udp"]
UDP_GRO_FWD = ["--env", "NA_UDP_GRO_FWD=on"]
GRO_LIST = ["--env", "NA_GRO_LIST=on"]
CASES["udp"] = UDP + BURST
CASES["udp-gro-fwd"] = UDP + UDP_GRO_FWD + BURST
CASES["udp-gro-list"] = UDP + GRO_LIST + BURST
CASES["fix-udp-gro-fwd"] = UDP + UDP_GRO_FWD + BURST
CASES["fix-udp-gro-list"] = UDP + GRO_LIST + BURST
CASES["fix"] = BURST
CASES["fix+iperf"] = []
CASES["fix+tunnel-tso"] = TUNNEL_TSO + BURST
for _n in (35, 36, 37, 40):
    CASES[f"burst{_n}"] = BURST + ["--env", f"BURST_SEGS={_n}"]


def run(name, args):
    extra = CASES[name.split("@")[0]]
    out = ROOT / "results" / args.tag / name
    module = ROOT / ".cache/kmod" / args.release / "gso_entry_reseed.ko"
    cmd = [sys.executable, str(LAB / "qemu-test.py"), "--release", args.release,
           "--output", str(out), "--tx", args.tx, "--duration", str(args.duration), "--timeout", "900",
           "--module", str(module), "--module-args", "mode=1" if name.startswith("fix") else "mode=0",
           *extra]
    log = out.parent / f"{name}.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w") as stream:
        rc = subprocess.run(cmd, stdout=stream, stderr=subprocess.STDOUT).returncode
    return name, out, rc


def summarise(name, out, rc):
    lines = [f"### {name} (rc={rc})"]
    for tsv in sorted(out.glob("mtu*/summary.tsv")):
        for row in tsv.read_text().splitlines()[1:]:
            f = row.split("\t")
            mbps = ""
            jsons = list(tsv.parent.glob(f"gso{f[4]}-tx{f[5]}-rx*-iperf.json"))
            if jsons:
                try:
                    end = json.loads(jsons[0].read_text())["end"]
                    mbps = (f" iperf={end['sum_received']['bits_per_second'] / 1e6:.0f}Mbps"
                            f" retrans={end['sum_sent']['retransmits']}")
                except (ValueError, KeyError):
                    mbps = " iperf=failed"
            inner = f" inner_udp: delivered={f[11]} csum_err={f[10]}" if len(f) > 11 and f[11] != "0" else ""
            lines.append(f"  tx={f[5]:3} UdpInCsumErrors={f[7]:>6} {f[9]}{mbps}{inner}")
    mod = out / "module.log"
    if not mod.exists():
        lines.append("  (no module.log)")
        return "\n".join(lines)
    text = mod.read_text()
    for m in re.finditer(r"gso_entry_reseed: (split_reason (?:split|head_len_mismatch|no_sg_or_csum)=\d+)", text):
        lines.append("  " + m.group(1))
    bad_calls = bad_segs = 0
    for m in re.finditer(r"hist (\S+) 0x[0-9a-f]+ \d+ \d+ (\d) \d \d (\d) \|.*\| (\d+) (\d+)", text):
        if m.group(2) == "1" and m.group(3) == "0":
            bad_calls += int(m.group(4))
            bad_segs += int(m.group(4)) * int(m.group(5))
    lines.append(f"  non-seed re-entries: calls={bad_calls} ~segs={bad_segs}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("cases", nargs="+", metavar="case", help=f"one of: {' '.join(CASES)}")
    parser.add_argument("--tag", required=True, help="results go to results/<tag>/<case>")
    parser.add_argument("--release", default="6.8.0-100-generic")
    parser.add_argument("--tx", default="on off", help="router NIC TX offload modes, in this order")
    parser.add_argument("--duration", type=int, default=10, help="iperf seconds (+iperf cases)")
    parser.add_argument("-j", "--jobs", type=int, default=4)
    args = parser.parse_args()
    unknown = [n for n in args.cases if n.split("@")[0] not in CASES]
    if unknown:
        parser.error(f"unknown cases: {unknown}")
    with ThreadPoolExecutor(args.jobs) as pool:
        results = list(pool.map(lambda n: run(n, args), args.cases))
    report = "\n".join(summarise(*r) for r in results)
    (ROOT / "results" / args.tag / "report.txt").write_text(report + "\n")
    print(report)


if __name__ == "__main__":
    main()
