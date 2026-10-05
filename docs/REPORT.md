# Corrupted outer UDP checksum when a VXLAN GSO skb is segmented twice

**English** | [한국어](REPORT.ko.md)

- Authors: [Elice Inc.](https://elice.io)
- Date: 2026-10-05
- Kernels checked: Ubuntu 22.04 / 24.04 / 26.04 LTS (5.15 to 7.0); the relevant code is identical in upstream v5.15 to v7.0

## Summary

- **Symptom**: a Linux host that **forwards TCP (or, with UDP GRO forwarding enabled, UDP) into a VXLAN tunnel with UDP checksums** sends packets with a **wrong outer UDP checksum** under certain device stacks. The receiver drops them as UDP checksum errors (`Udp: InCsumErrors`), so TCP retransmits and throughput collapses.
- **Cause**: when a tunnel GSO skb that has already been through one segmentation pass is **software-segmented again** by a lower device, `__skb_udp_tunnel_segment()` misreads its outer UDP checksum field (see "Root cause").
- **Scope**: reproduced on Ubuntu 22.04 (5.15, HWE 6.8), 24.04 (6.8, HWE 7.0) and 26.04 (7.0), with NIC TX checksum offload on and off. The same code is in upstream v7.0.
- **Fix**: a roughly 20-line patch that normalises the outer UDP checksum to the pseudo-header seed when segmentation is re-entered (`fix/udp-gso-fix.patch`). Errors drop to 0 on every kernel and device stack tested.
- **Known workarounds**: turning off TSO on the vxlan device, or lowering its `gso_max_segs`, avoids the problem. Both keep tunnel GSO skbs off this path (see "Workarounds").
- **Reproduction**: deterministic, in a single QEMU VM with no physical NIC.

## Affected setups

### Typical device stack

The problem occurs on a **router/gateway host** that receives TCP and sends it on to another host through VXLAN. The sending side looks like this:

```
   TCP traffic from another host
              |
              v
   +-----------------------+
   |  RX NIC  (GRO on)     |   (a)
   +-----------------------+
              |  IP forwarding
              v
   +-----------------------+
   |  vxlan  (udpcsum)     |   (b)
   +-----------------------+
              |
              v
   +-----------------------+
   |  upper device         |   (c)  1st software GSO
   |  e.g. macvlan, bond   |
   +-----------------------+
              |
              v
   +-----------------------+
   |  lower device         |   (d)  2nd software GSO  <-- checksum corrupted here
   |  e.g. VLAN, NIC       |
   +-----------------------+
              |
              v
   wire: bad outer UDP checksum -> dropped by the receiver
```

- (a) GRO on the receiving NIC merges consecutive TCP segments of one flow into a single frag_list skb.
- (b) vxlan encapsulates it as a tunnel GSO skb (`gso_type = TCPV4 | UDP_TUNNEL_CSUM`).
- (c) An upper device without `NETIF_F_FRAGLIST` software-segments it. The frag_list skb is not fully segmented; it is split into several skbs that are **still GSO**.
- (d) A lower device cannot take those GSO skbs as they are and segments them again in software. This is where the outer UDP checksum goes wrong.

### Conditions (all must hold)

| # | Condition | Meaning | Avoidance (with performance trade-offs) |
|---|---|---|---|
| 1 | **GRO on the forwarding host's RX NIC builds frag_list skbs** | Happens when at least two GRO blocks are merged (block size is driver-specific: 18 segments on igb, about 7 on mlx5 by inference). Common with high-throughput TCP. Forwarded UDP is GRO'd only with `rx-udp-gro-forwarding on` (see "Inner protocol: TCP and UDP"). | RX NIC GRO off |
| 2 | The VXLAN device **uses outer UDP checksums** | IPv4 VXLAN with `udpcsum`. An IPv6 underlay uses checksums by default (IPv6 not tested). | `noudpcsum` |
| 3 | **The vxlan device passes GSO skbs down (TSO on)** | With vxlan TSO off, packets are segmented before encapsulation and no tunnel GSO skb exists. | **vxlan TSO off** |
| 4 | vxlan `gso_max_segs` is at least the GRO skb size | Larger skbs are fully segmented at the vxlan device and never reach this path. | **`gso_max_segs` N < 2 × GRO block** (e.g. 13 with mlx5) |
| 5 | Between VXLAN and the NIC there is a device **without FRAGLIST but with SG and TSO for tunnel skbs** | Always true for macvlan and bond. True for VLAN only until the lower device's features change (see "VLAN history dependence"). This device performs the first split. | change the stack |
| 6 | A device below it **software-segments the split result again** | NIC TX checksum off, no tunnel TSO on the NIC, or a NIC that supports UDP tunnel checksum only through GSO_PARTIAL (mlx5, igb, ...). | - |

First observed on an Ubuntu 24.04 `6.8.0-100-generic` forwarding host (mlx5 ConnectX-5, bond, VLAN, macvlan, VXLAN udpcsum) sending to an Intel i40e receiver. The i40e RX checksum offload can hide the errors, so they were confirmed with RX offload off.

## Results by device stack

Results for each sender-side stack between the VXLAN device and the wire, using the deterministic reproducer (200 bursts of 40 segments) on 6.8.0-100 under KVM. Values are the increase of the receiver's `Udp: InCsumErrors`. TX offload on was measured first, then off. Raw data: `docs/data/device-paths.txt`.

| Stack below VXLAN | First split at | TX on | TX off |
|---|---|---|---|
| macvlan → VLAN → NIC | macvlan | **7204** | **7295** |
| macvlan → NIC | macvlan | **7678** | **7605** |
| macvlan → VLAN → bond → NIC | macvlan | **7451** | **7372** |
| bond → NIC | bond | **7593** | **7677** |
| VLAN → NIC | VLAN (only before NIC features change) | **7385** | 0 ¹ |
| VLAN → bond → NIC | none ² | 0 | 0 |
| NIC directly | none ³ | 0 | 0 |

- With the NIC doing tunnel TSO through GSO_PARTIAL like mlx5 (igb `tx-tcp-mangleid-segmentation on`), every stack behaved the same (7195 to 7761 where reproduced).
- ¹ Switching to TX off changes the NIC's features, and the VLAN loses SG at that moment. The result is due to the feature-change history, not to TX off itself.
- ² A bond under the VLAN recomputes its features at slave link-up (after the VLAN exists), so the VLAN always loses SG.
- ³ When the NIC itself splits the skb, the result goes straight to the NIC; there is no second segmentation pass.

## Inner protocol: TCP and UDP

The tunnel segmentation path does not depend on the inner protocol, so inner UDP was tested too (deterministic reproducer sending 200 bursts of 40 equal-size UDP datagrams of one flow, 6.8.0-100, KVM, default stack). Raw data: `docs/data/inner-udp.txt`.

| Inner traffic | Router NIC GRO mode | `UdpInCsumErrors` TX on / off | Inner datagrams delivered (of 8000) TX on / off | Tunnel skb `gso_type` |
|---|---|---|---|---|
| TCP (reference) | default | **7675 / 7719** | - | `TCPV4 \| UDP_TUNNEL_CSUM` |
| UDP | default | 0 / 0 | 8000 / 8000 | (no GSO) |
| UDP | **`rx-udp-gro-forwarding on`** | **7722 / 7601** | **278 / 399** | `UDP_L4 \| UDP_TUNNEL_CSUM` |
| UDP | `rx-gro-list on` | 0 / 0 | 8000 / 8000 | `FRAGLIST \| UDP_L4 \| UDP_TUNNEL_CSUM` |
| UDP + fix | `rx-udp-gro-forwarding on` | 0 / 0 | 8000 / 8000 | `UDP_L4 \| UDP_TUNNEL_CSUM` |

- **Default settings**: forwarded UDP is not GRO'd, so there is no GSO skb and no exposure.
- **`rx-udp-gro-forwarding on`**: UDP GRO builds frag_list skbs through the same `skb_gro_receive()` as TCP, the upper device splits them in `skb_segment()`, and the lower device re-enters `__skb_udp_tunnel_segment()` exactly as with TCP. About 95 to 97% of the datagrams were dropped at the receiver; the fix brings this to 0.
- **`rx-gro-list on`** (fraglist GRO): the upper device segments the skb with `skb_segment_list()` straight into individual packets, so there is no second pass.

### VLAN history dependence

`register_netdevice()` adds `NETIF_F_SG` to a new device's `hw_enc_features`, so a freshly created VLAN has SG for tunnel skbs and can perform the first split. On a feature-change event from the lower device (`NETDEV_FEAT_CHANGE`), however, `vlan_transfer_features()` overwrites `hw_enc_features` with `vlan_tnl_features(real_dev)`, which does not include SG. Whether a VLAN stack reproduces therefore depends on **whether the lower NIC or bond changed features after the VLAN was created** (an `ethtool -K`, a bond slave change, ...). macvlan and bond have no such history dependence.

## Root cause

Flow confirmed from the kernel source (6.8.12; identical in 5.15 and 7.0) and kprobe instrumentation.

1. **GRO**: the forwarding host's RX NIC merges TCP segments of one flow into a frag_list skb. In the lab (igb), the head holds 18 segments (1 linear + 17 page frags) and each frag_list member also holds 18.
2. **Encapsulation**: vxlan turns it into a tunnel GSO skb with `gso_type = TCPV4 | UDP_TUNNEL_CSUM`. The outer UDP checksum field holds the standard pseudo-header seed.
3. **First software GSO (upper device)**: `validate_xmit_skb()` segments because the device lacks FRAGLIST. When the device features include SG, csum, TSO and UDP_TUNNEL_CSUM, and the following holds, `skb_segment()` takes the "Try to split the SKB to multiple GSO SKBs with no frag_list" path:
   - all frag_list members except the last have the same length
   - no member has non-head_frag linear data
   - **head payload length == first member length**

   The result is not fully segmented packets but **several skbs that are still GSO**.
4. These output skbs have `ip_summed=CHECKSUM_PARTIAL`, `encapsulation=1` and `encap_hdr_csum=1`. The output loop of `__skb_udp_tunnel_segment()` writes a **completed LCO checksum** (from `gso_make_checksum()`) into their outer UDP checksum field. That value is correct if hardware TSO consumes the skb as is.
5. **Second software GSO (lower device)**: if the lower device cannot take this GSO skb as is, it is segmented again.
   - With TX checksum off or no tunnel TSO, the tunnel GSO features are absent.
   - On a GSO_PARTIAL NIC, the skb lacks `SKB_GSO_PARTIAL`, so `gso_features_check()` removes `dev->gso_partial_features` (UDP_TUNNEL_CSUM).
6. The re-entered `__skb_udp_tunnel_segment()` assumes the input's outer checksum field holds the **pseudo-header seed** of step 2:
   ```c
   partial = csum_sub(csum_unfold(uh->check), htonl(skb->len));
   ```
   It actually holds the completed checksum from step 4, so **every segment produced from this skb gets a wrong outer UDP checksum**. The segments also have `encapsulation=1`, so the kernel computes the outer checksum itself and NIC TX checksum offload does not repair it.

In every instrumented run, the receiver's error count matched "number of re-entries with a non-seed checksum × segments of those skbs".

### Fix

At the entry of the re-segmenting consumer `__skb_udp_tunnel_segment()` (after `pskb_may_pull()`, before `partial` is computed), normalise the outer checksum of a re-entered skb to the standard seed. The full patch is `fix/udp-gso-fix.patch`; it applies as is to Ubuntu 6.8.0-100.100, upstream 6.8.12 and 7.0. On 5.15 the hunk must be applied by hand (different include context).

```c
if ((skb_shinfo(skb)->gso_type & SKB_GSO_UDP_TUNNEL_CSUM) &&
    skb->encap_hdr_csum) {
	if (is_ipv6) {
		const struct ipv6hdr *ip6h = ipv6_hdr(skb);

		uh->check = ~udp_v6_check(skb->len, &ip6h->saddr, &ip6h->daddr, 0);
	} else {
		const struct iphdr *iph = ip_hdr(skb);

		uh->check = ~udp_v4_check(skb->len, iph->saddr, iph->daddr, 0);
	}
}
```

For hosts whose kernel cannot be rebuilt, `fix/dkms/` delivers the same change as a kprobe module installed through DKMS (see `README.md`, "Install the fix").

Fixing the **output** of the first split instead is wrong: that value is correct for a hardware TSO consumer, and rewriting it to the seed breaks the TX offload path. An earlier attempt confirmed this failure.

### Why it looks intermittent with ordinary traffic

The split path is taken only when the GRO skb holds **at least two blocks** (head length = first member length). In three 30-second iperf runs in the lab, 99.5% of about 10,000 frag_list skbs were one block plus a remainder (19 to 35 segments) and were not split (`docs/data/iperf-split-analysis.txt`). The GRO skb size depends on how many packets arrive within one NAPI poll, so the error rate varies with traffic pattern and load.

## Workarounds

Why the two known workarounds help and what they cost. Measured on 6.8.0-100 under KVM, default stack (macvlan → VLAN → NIC).

| Setting | Bursts: TX on / off | iperf errors: TX on / off | First split | Re-entries |
|---|---|---|---|---|
| default | 7170 / 7330 | 3347 / 2648 | 372 | 1107 |
| **vxlan TSO off** (`ethtool -K <vxlan> tso off`) | 0 / 0 | 0 / 0 | 0 | 0 |
| **vxlan `gso_max_segs 13`** | 0 / 0 | 0 / 0 | 0 | 0 |
| fix applied | 0 / 0 | 0 / 0 | 317 | 894 (all normalised) |

**Why vxlan TSO off helps.** Without TSO on the vxlan device, its `validate_xmit_skb()` segments the GRO skb into MSS-sized plain TCP packets **before encapsulation**. vxlan then encapsulates each packet individually, so no `SKB_GSO_UDP_TUNNEL_CSUM` skb is ever created and there is neither a first split nor a re-entry (0 and 0 above).

**Why limiting `gso_max_segs` helps.** `gso_features_check()` drops the GSO features for skbs with `gso_segs > dev->gso_max_segs`, so large GRO skbs are handled at the vxlan device exactly as with TSO off. Smaller skbs keep GSO but hold fewer than two blocks and cannot meet the split condition. On the original host, 13 worked and 14 failed, consistent with an mlx5 GRO block of 7 segments (2 × 7 = 14; the block size is inferred from observations). The safe value depends on the driver's GRO block size and does not carry over to other NICs (igb, with 18-segment blocks, would need 35 or less by the same reasoning).

**Cost.** Both workarounds make the whole stack below vxlan (encapsulation, route/neighbour handling, macvlan, VLAN, bond, qdisc, driver) run **per MSS packet instead of per GSO skb**. Per-packet CPU cost grows by the GRO aggregation factor and NIC TSO is no longer used. TSO off affects every skb; `gso_max_segs` affects only skbs above the limit, so it is the cheaper of the two. Throughput in this lab (about 200 to 270 Mbps with iperf) is limited by the emulated NIC and does not show the CPU difference (`docs/data/workarounds.txt`); the real cost has to be measured as CPU usage on real hardware. The fix keeps tunnel GSO intact and adds a few tens of nanoseconds per re-segmented skb (see "Fix delivery: kprobe vs livepatch").

## Affected kernels

Deterministic reproducer (40-segment bursts), igb NICs (patched QEMU model). Raw data: `docs/data/kernels.txt`.

| LTS | Kernel | TX offload off | TX offload on | Fix applied (off / on) |
|---|---|---|---|---|
| 22.04 GA | 5.15.0-198 | **6544** | **6252** | 0 / 0 |
| 22.04 HWE | 6.8.0-138 (`~22.04.1`) | **6018** | **6288** | 0 / 0 |
| 24.04 GA | 6.8.0-100 | **5031** | **5536** | 0 / 0 |
| 24.04 GA | 6.8.0-146 | **5648** | **6235** | 0 / 0 |
| 24.04 HWE / 26.04 GA | 7.0.0-38 | **6343** | **6585** | 0 / 0 |

Values are the increase of the receiver's `Udp: InCsumErrors`. `__skb_udp_tunnel_segment()` (the `partial` computation) and `skb_segment()` (the split condition) are identical in upstream v5.15, v6.8.12 and v7.0. Other UDP tunnels that use the same function (GENEVE, ...) are likely affected as well but were not tested.

## Fix delivery: kprobe vs livepatch

Per-call cost of applying the fix from a kprobe pre-handler (`fix/dkms/`) versus replacing the function with a livepatch (`fix/livepatch-6.8.0-100/`).

- An in-kernel microbenchmark (`lab/kmod/bench/gso_bench.c`) builds a VXLAN GSO skb and calls `skb_gso_segment()` in a loop.
- Within one boot, "no fix → kprobe → livepatch" was alternated 10 times (KVM, 6.8.0-100, 2-segment skb, median of 200k calls per round). Raw data: `docs/data/perf-kprobe-vs-livepatch*.txt`.
- On x86 both mechanisms hook the function entry through ftrace (fentry); the kprobe was confirmed as `[FTRACE]` in `kprobes/list`.

| | Per call | vs no fix |
|---|---|---|
| no fix | 1302 ns (sd 18) | - |
| kprobe | 1372 ns (sd 16) | **+70 ns** |
| livepatch (function replaced via `klp_patch`) | 1338 ns (sd 6) | **+36 ns** |

- Both modules used here were separately confirmed to bring errors to 0 with the deterministic reproducer (TX on and off).
- The difference between the fix condition being true (seed actually recomputed) and false is 0 to 4 ns, so the fix logic itself is negligible; the cost is almost entirely the hook entry.
- For 7- and 14-segment skbs (3.8 to 6.7 µs per call) the difference disappeared in measurement noise (±50 to 200 ns).
- The function runs **once per software-segmented tunnel GSO skb**, not per packet. On the original host that was about 13,000 calls per second, i.e. under 0.1% of one CPU core even with the kprobe. At an assumed 1 million calls per second it would be about 7% of a core for the kprobe and 4% for the livepatch.

So **performance does not decide the choice**; operational differences do.

| | kprobe | livepatch |
|---|---|---|
| Build | kernel headers only | exact source, vmlinux and compiler (kpatch-build). The livepatch in this repository was written by hand from the 6.8.0-100.100 function body |
| Argument access | read from registers (`regs->di`, `regs->r8`); silently wrong if the ABI changes or the compiler emits a clone (`.isra`/`.constprop`) | source level, guaranteed by the compiler |
| Fix location | function entry only (before `pskb_may_pull()`) | the exact spot (after `pskb_may_pull()`) |
| Ways to be bypassed | another livepatch replacing the same function stops the kprobe from firing; registration fails if the function is inlined in a build | defined patch stacking and transition model |

## Reproduction lab

### Topology

One QEMU VM, split into network namespaces that stand in for two hosts. The two emulated NICs (igb) are connected through a QEMU hub (virtual switch).

```
+------------------------------+        +--------------------------------------+
| client ns                    |  TCP   | router ns + evn ns                   |
|                              |        |                                      |
| generator (iperf3/burst) ----|--------|> nic0 (igb #1, GRO on)               |
|                              |        |    v  IP forwarding                  |
|                              |        |  vxlan0 (udpcsum, TSO)               |
|                              | VXLAN  |    v                                 |
| vlan444 <--------------------|--------|-- macvlan -> vlan444 -> nic0         |
|   v                          |        |  (stack below vxlan0 varies)         |
| vxlan-rx -> bridge -> veth --|---+    +--------------------------------------+
|                              |   |
| UdpInCsumErrors counted here |   |    +-------------------+
| (RX checksum offload off)    |   +--->| server ns         |
+------------------------------+        | TCP sink (iperf3) |
                                        +-------------------+
```

- **client ns** sends the TCP traffic and also acts as the VXLAN receiver that validates checksums. Its RX checksum offload is off so checksums are verified in software.
- **router ns / evn ns** is the forwarding host under test: the NIC and VLAN live in router ns, macvlan and vxlan in evn ns. The script variables `NA_*` configure this side.
- Kernels are Ubuntu `.deb`s extracted without installation and booted as a diskless initramfs (`scripts/fetch-kernel.py`).
- The NICs are QEMU `igb` (Intel 82576). Like mlx5, the Linux igb driver advertises UDP tunnel checksum offload through GSO_PARTIAL. An all-veth setup does not reproduce (no second segmentation pass).
- **Deterministic reproducer** (`lab/tools/burst.c`): the client sends 200 bursts of 40 consecutive TCP segments of one flow (1188 bytes, ACK, no PSH) through AF_PACKET. `rx-usecs=2000` on the router NIC makes each burst land in one GRO run, producing an 18+18+4 frag_list skb each time. 75 to 99% of bursts take the split path.
- **Instrumentation** (`lab/kmod/trace/gso_entry_reseed.c`, kprobe): records why `skb_segment()` did or did not split, the GRO block layout, and the entry state of every `__skb_udp_tunnel_segment()` call (device, seed or not). With `mode=1` it applies the fix.

### QEMU igb model fix (needed for TX offload on)

The QEMU 8.2 igb model ignores the header offsets in the TX context descriptor (`MACLEN/IPLEN/L4LEN`) and offloads checksum and TSO on the **outermost L4 header** it parses itself. For VXLAN frames it therefore handles the outer UDP header instead of the inner TCP header, unlike a real 82576. With TX offload on this caused two problems:
- the inner TCP checksum was left unfilled and throughput collapsed;
- QEMU recomputed the outer UDP checksum and hid the bug.

`lab/qemu/igb-desc-offload.patch` adds an `x-desc-offload=on` property to igb that offloads by descriptor offsets, like the hardware:
- TSO replicates the `MACLEN+IPLEN+L4LEN` header; the IP header gets its length and ID updated and a checksum over the IPLEN range, and TCP gets seq, flags and checksum updated;
- the outer UDP header is left alone, as the hardware does.
- With the patch, inner TCP checksum errors on the sender's frames are 0, and TX offload on reproduces and is fixed as shown above (`docs/data/tx-offload-on.txt`).
- Checking a pcap captured with receiver GRO off using `lab/tools/pcap-csum.py`, the number of frames with a bad outer UDP checksum on the wire (7797) matches the receiver's `UdpInCsumErrors` (7797) exactly, with TX offload on.

### Running it

See `README.md` at the repository root. With a writable `/dev/kvm` the guest runs under KVM, otherwise under TCG; reproduction and fix results do not depend on the accelerator. The affected-kernels table was measured under TCG, the other tables under KVM. Performance measurements need KVM (under TCG a single call takes tens of microseconds and the difference disappears).

## Detailed results by condition (6.8.0-100, TX offload off, TCG)

Raw data: `docs/data/conditions.txt`.

| Setting | UdpInCsumErrors | Splits / 200 bursts |
|---|---|---|
| default (macvlan → VLAN → NIC) | 7354 | 189 |
| GSO_PARTIAL off | 7148 | 184 |
| NIC tunnel TSO features off | 6817 | 178 |
| VLAN sg off | 6603 | 172 |
| **router NIC GRO off** | **0** | 0 |
| **VXLAN noudpcsum** | **0** | 0 |
| **vxlan gso_max_segs 13** | **0** | 0 |
| **fix applied** | **0** | 194 |

With 36-segment bursts most GRO runs ended at 35 segments (one block + 17) and only one split happened, consistent with the "at least two blocks" condition.

## Limitations

- The condition matrix ran each combination once. With a deterministic reproducer the difference (thousands vs. 0) is clear.
- The 18-segment GRO block comes from igb's 2 KB RX buffers. The 7-segment block for mlx5 is inferred from observations.
- The CPU cost of the workarounds cannot be measured in this lab (emulated NIC).
- IPv6 underlays and UDP tunnels other than VXLAN were not tested. Inner UDP was tested only on 6.8.0-100 with the default stack.
- The QEMU patch covers TSO/TXSM for TCP and UDP over IPv4/IPv6; SCTP and the VMDq/loopback paths keep the original behaviour.
