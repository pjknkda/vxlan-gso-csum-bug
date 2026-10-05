# Result summaries

Plain-text summaries copied from the lab runs behind the tables in [`../REPORT.md`](../REPORT.md).
Full run outputs (initramfs, serial logs, pcaps) are not kept in the repository; rerun
with `lab/matrix.py` / `lab/perf.py` to regenerate them under `results/`.

Most files were produced before the repository was reorganised, so case names differ
from the current `lab/matrix.py` names. The `### <case>` blocks print the receiver's
`UdpInCsumErrors` per TX offload mode and the tracing kprobe's counters.

| File | Report section | Old case name -> current name | Accelerator |
|---|---|---|---|
| `kernels.txt` | Affected kernels | `base+burst` -> `base`, `fix+burst` -> `fix` | TCG |
| `device-paths.txt` | Results by device stack | `path-X` -> `path-X`, `path-X+tso` -> `path-X+tunnel-tso` | KVM |
| `workarounds.txt` | Workarounds | current names | KVM |
| `conditions.txt` | Detailed results by condition | `X+burst` -> `X`; `na-gro-off` -> `router-gro-off`, `segs13` -> `gso-max-segs-13` | TCG |
| `tx-offload-on.txt` | QEMU igb model fix (TX offload on) | `X+burst` -> `X`, `X` -> `X+iperf`, `mangleid` -> `tunnel-tso` | TCG |
| `iperf-split-analysis.txt` | Why it looks intermittent (`skb_segment()` split decision histogram) | `base@N` (iperf) -> `base+iperf@N` | TCG |
| `vm-tap-send.txt` | VM behind a tap device (send direction) | current names | KVM |
| `inner-udp.txt` | Inner protocol: TCP and UDP | current names | KVM |
| `perf-kprobe-vs-livepatch.txt` | Fix delivery: kprobe vs livepatch (2 segs, 10 reps) | - | KVM |
| `perf-kprobe-vs-livepatch-wide.txt` | Fix delivery: kprobe vs livepatch (2/7/14 segs, 3 reps; order: rep × {none, kprobe, livepatch} × encap_hdr {0,1} × segs) | - | KVM |
