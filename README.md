# VXLAN tunnel GSO re-segmentation corrupts the outer UDP checksum

**English** | [한국어](README.ko.md)

Investigated and fixed by [Elice Inc.](https://elice.io)

A Linux host that forwards TCP (or UDP, with UDP GRO forwarding enabled) into a VXLAN
tunnel with UDP checksums can send packets with a **wrong outer UDP checksum** when a
stacked device (macvlan, bond, ...) splits a GRO skb into several still-GSO skbs and a
lower device segments them again in software. Reproduced on Ubuntu 22.04 / 24.04 / 26.04
kernels (5.15 to 7.0); the code is unchanged in upstream v7.0.

- Full analysis: [docs/REPORT.md](docs/REPORT.md) ([한국어](docs/REPORT.ko.md))
- Kernel fix: [fix/udp-gso-fix.patch](fix/udp-gso-fix.patch)
- Raw result summaries behind the report's tables: [docs/data/](docs/data/)

## Install the fix (DKMS)

For hosts running an affected kernel (x86-64, Ubuntu 22.04 / 24.04 / 26.04 kernels
5.15 to 7.0). The fix is a small kernel module that applies the same change as
[fix/udp-gso-fix.patch](fix/udp-gso-fix.patch) through a kprobe. DKMS rebuilds it
for every kernel you install, and it is loaded at boot.

Get the package from the [Releases](https://github.com/pjknkda/vxlan-gso-csum-bug/releases)
page (CI builds it for every `v*` tag), or build it yourself (needs only `dpkg-deb`; no root):

```bash
git clone https://github.com/pjknkda/vxlan-gso-csum-bug.git
vxlan-gso-csum-bug/fix/dkms/build-deb.sh        # -> dist/vxlan-gso-csum-fix_<version>_amd64.deb
```

Install it on each host. apt pulls in `dkms`; the module is built for every kernel that
has headers, loaded immediately, and loaded at every boot:

```bash
sudo apt install linux-headers-$(uname -r) ./vxlan-gso-csum-fix_*_amd64.deb
```

Check that it is active:

```bash
lsmod | grep vxlan_gso_csum_fix
sudo dmesg | grep vxlan_gso_csum_fix     # "vxlan_gso_csum_fix: active (report_interval=60s)"
```

The module counts its work. `corrected_packets` is the number of packets that would
have left with a bad outer checksum:

```bash
grep . /sys/module/vxlan_gso_csum_fix/parameters/*
#   matched            skbs that met the fix condition (checksum recomputed)
#   corrected          of those, skbs whose outer checksum was actually wrong
#   corrected_packets  packets (GSO segments) in the corrected skbs
#   report_interval    seconds between kernel log reports (default 60, 0 = off)
```

Every `report_interval` seconds, if the counters changed, a line like this is logged:
`vxlan_gso_csum_fix: report: matched=1101 corrected=1101 corrected_packets=14316 (+287/+287/+3726)`
(cumulative totals, then the change since the previous report). Change the interval
at runtime with `echo 300 | sudo tee /sys/module/vxlan_gso_csum_fix/parameters/report_interval`,
or permanently with `options vxlan_gso_csum_fix report_interval=300` in `/etc/modprobe.d/`.

Remove it with `sudo apt remove vxlan-gso-csum-fix`.

Without the package, `sudo vxlan-gso-csum-bug/fix/dkms/install.sh` (after
`sudo apt install dkms linux-headers-$(uname -r)`) does the same from the source tree;
undo it with `fix/dkms/uninstall.sh`.

Both ways were tested end to end on a stock Ubuntu 24.04 cloud image (`lab/dkms-e2e.sh`,
`MODE=deb` or `MODE=script`): installed on 6.8.0-142-generic, rebuilt automatically by
DKMS when the HWE kernel 7.0.0-38-generic was installed, loaded at boot on 7.0, and
removed with nothing left behind.

Notes:
- With Secure Boot, DKMS signs the module with the machine's MOK key; that key must be
  enrolled (Ubuntu prompts for it when `dkms` is first installed). Secure Boot is not
  covered by the end-to-end test.
- The module reads the probed function's arguments from registers. This matches the
  kernels listed above; check it before using the module on other builds (see
  [docs/REPORT.md](docs/REPORT.md#fix-delivery-kprobe-vs-livepatch)).
- Once your kernel carries the patch, the module is redundant but harmless (the
  normalisation is idempotent); uninstall it.

### Versions and releases

The package version comes from the nearest `v*` git tag (`fix/dkms/version.sh`): a build
at tag `v1.1.0` is `1.1.0`, a build 3 commits later is `1.1.0+3.gabc1234` (sorts after
`1.1.0`), uncommitted changes add `.dirty`, and a copy without `.git` (e.g. a ZIP
download) is `0.0.0+unknown`. Set `VERSION=...` to override.

To release, push a tag; CI builds the package and attaches it to a GitHub Release:

```bash
git tag v1.1.0
git push origin v1.1.0
```

## Layout

```
fix/
  udp-gso-fix.patch          kernel fix (applies to Ubuntu 6.8.0-100.100, v6.8.12, v7.0)
  dkms/                      same fix as a kprobe module for DKMS (build-deb.sh, install.sh,
                             version.sh)
  livepatch-6.8.0-100/       same fix as a livepatch for 6.8.0-100-generic only
lab/
  qemu-test.py               boot one kernel in a QEMU guest and run the reproducer
  matrix.py                  run named cases in parallel guests and summarise
  perf.py                    kprobe vs livepatch per-call cost (needs KVM)
  dkms-e2e.sh                install/upgrade/uninstall test of fix/dkms on an Ubuntu cloud image
  guest/                     scripts that run inside the guest
  tools/burst.c              deterministic GRO feeder (same-flow TCP segment bursts)
  tools/tapinject.c          stand-in for a VM sending TCP through a tap device
  tools/pcap-csum.py         check outer UDP / inner TCP checksums in a pcap
  kmod/trace/                tracing kprobe (+ fix with mode=1)
  kmod/bench/                skb_gso_segment() microbenchmark
  qemu/igb-desc-offload.patch  QEMU igb model fix needed for TX-offload-on runs
scripts/                     download / build everything into .cache/ (not committed)
.github/workflows/deb.yml    CI: build the .deb, DKMS-compile it for Ubuntu 24.04 GA and HWE
                             kernels, attach it to a GitHub Release on v* tags
docs/                        report and result summaries
```

Downloads and builds go to `.cache/` and run outputs to `results/`; both are git-ignored.

## Reproduction lab: requirements

- Ubuntu 24.04 host (uses `apt-get download` for build dependencies; nothing is installed)
- `python3`, `gcc`, `make`, `curl`, `dpkg-deb`, `depmod`/`modprobe` (kmod), `busybox`,
  `iproute2`, `tcpdump`
- KVM recommended (`/dev/kvm` writable). Without it the guest runs under TCG: results
  are the same but slower, and `lab/perf.py` is meaningless.
- About 3 GB of disk for one kernel plus QEMU.

## Reproduction lab: quick start

```bash
# 1. kernel(s) under test -> .cache/sysroots/<release>
scripts/fetch-kernel.py 6.8.0-100-generic --version 6.8.0-100.100      # Launchpad (any published build)
scripts/fetch-kernel.py 7.0.0-38-generic --suite resolute-updates       # current build in a pocket

# 2. QEMU 8.2.2 with the igb fix -> .cache/qemu/bin/qemu-system-x86_64 (~10 min)
scripts/setup-qemu.sh

# 3. guest binaries and modules for each kernel -> .cache/bin, .cache/kmod/<release>
scripts/build.sh 6.8.0-100-generic
scripts/build.sh 7.0.0-38-generic        # fetches GCC 14 automatically

# 4. reproduce, and confirm the fix (kprobe mode=1) removes the errors
lab/matrix.py --tag smoke base fix
lab/matrix.py --tag smoke-7.0 --release 7.0.0-38-generic base fix
```

Expected output: `base` shows thousands of `UdpInCsumErrors` for both TX offload modes,
`fix` shows 0.

### Cases

`lab/matrix.py --help` lists all cases. Useful groups:

| Cases | What they show |
|---|---|
| `base`, `fix` | reproduction and the fix (deterministic burst traffic) |
| `udp`, `udp-gro-fwd`, `udp-gro-list`, `fix-udp-gro-*` | inner UDP instead of TCP, by router NIC GRO mode |
| `vxlan-tso-off`, `gso-max-segs-13` | the two known workarounds |
| `router-gro-off`, `vxlan-nocsum`, `no-gso-partial`, `no-tnl-seg`, `vlan-sg-off`, `tunnel-tso` | which conditions matter |
| `path-*` | device stacks between the VXLAN device and the wire |
| `vm-tso`, `vm-notso`, `vm-*-napi`, `fix-vm-*` | a VM behind a tap device on the router sends into the tunnel |
| `<case>+iperf` | the same with iperf3 instead of bursts (intermittent, see report) |
| `<case>@N` | repeat a case |

Other tools:

```bash
lab/perf.py --tag perf                                   # kprobe vs livepatch cost (KVM only)
lab/qemu-test.py --output results/manual --env TRAFFIC=burst --env NA_RX_USECS=2000 \
    --module .cache/kmod/6.8.0-100-generic/gso_entry_reseed.ko --module-args mode=0
lab/tools/pcap-csum.py --src 198.51.100.1 results/<run>/mtu9000/*.pcap
```

## Applying the fix

- **Kernel patch**: `fix/udp-gso-fix.patch` (`patch -p1` in a kernel tree). 5.15 needs the
  same hunk applied by hand (different include context).
- **kprobe module** (`fix/dkms/`, see "Install the fix" above): reads arguments from
  registers (`(skb, features, gso_inner_segment, new_protocol, is_ipv6)` → `rdi`, ...,
  `r8`). Check the target build's signature before use; see the report for its risks.
- **livepatch** (`fix/livepatch-6.8.0-100/`): carries the Ubuntu 6.8.0-100.100 function
  body, so it is only valid for that exact build. For other builds, generate a livepatch
  from `fix/udp-gso-fix.patch` with kpatch-build.

## License

Copyright (c) 2026 Elice Inc. Kernel code and patches (`fix/`, `lab/kmod/`) are GPL-2.0,
the QEMU patch is GPL-2.0-or-later, everything else is MIT. See [LICENSE](LICENSE).
