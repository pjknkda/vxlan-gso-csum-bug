#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Boot one Ubuntu kernel in a diskless QEMU guest and run the reproducer in it.

The guest kernel, modules and iperf3/ethtool come from .cache/sysroots/<release>
(scripts/fetch-kernel.py); nothing is installed on the host and no host network
interface is used. lab/guest/single-node.sh builds the topology inside the guest.
"""
import argparse
import gzip
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
import time

LAB = Path(__file__).resolve().parent
ROOT = LAB.parent
CACHE = ROOT / ".cache"
PATCHED_QEMU = CACHE / "qemu/bin/qemu-system-x86_64"


def command(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def copy_binary(source, target, guest, sysroot):
    source = Path(source)
    dest = guest / target.lstrip("/")
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source.resolve(), dest)
    env = dict(os.environ, LD_LIBRARY_PATH=str(sysroot / "usr/lib/x86_64-linux-gnu"))
    deps = subprocess.run(["ldd", str(source)], capture_output=True, text=True, env=env)
    if "not found" in deps.stdout:
        raise RuntimeError(f"Missing library for {source}:\n{deps.stdout}")
    for library in re.findall(r"(?:=>\s*)?(/\S+)", deps.stdout):
        path = Path(library)
        if not path.is_file():
            continue
        # A staged libiperf library still needs its usual absolute guest path.
        try:
            relative = path.relative_to(sysroot)
        except ValueError:
            relative = Path(str(path).lstrip("/"))
        out = guest / relative
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path.resolve(), out)


def add_modules(guest, sysroot, release):
    module_root = sysroot / "lib/modules" / release
    if not (module_root / "modules.dep.bin").exists():
        command("depmod", "-b", str(sysroot), "-a", release)
    output_root = guest / "lib/modules" / release
    output_root.mkdir(parents=True, exist_ok=True)
    for path in module_root.glob("modules.*"):
        if path.is_file():
            shutil.copy2(path, output_root / path.name)
    names = ["veth", "bridge", "8021q", "macvlan", "vxlan", "igb", "bonding", "tun", "9p", "9pnet_virtio", "virtio_pci"]
    files = set()
    for name in names:
        result = command("modprobe", "-d", str(sysroot), "-S", release,
                         "--show-depends", name, capture_output=True, text=True)
        for line in result.stdout.splitlines():
            if line.startswith("insmod "):
                files.add(Path(line.split()[1]))
    for path in sorted(files):
        relative = path.relative_to(sysroot)
        dest = guest / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, dest)


def write_initramfs(root, output):
    # Write newc directly, including /dev/console without requiring host mknod.
    inode = 1
    with gzip.open(output, "wb", compresslevel=1) as stream:
        def entry(name, mode, data=b"", major=0, minor=0):
            nonlocal inode
            name_bytes = name.encode() + b"\0"
            fields = [inode, mode, 0, 0, 1, 0, len(data), 0, 0,
                      major, minor, len(name_bytes), 0]
            header = b"070701" + b"".join(f"{v:08x}".encode() for v in fields)
            stream.write(header + name_bytes)
            stream.write(b"\0" * (-(len(header) + len(name_bytes)) % 4))
            stream.write(data)
            stream.write(b"\0" * (-len(data) % 4))
            inode += 1
        for path in sorted(root.rglob("*")):
            metadata = path.lstat()
            data = (os.readlink(path).encode() if path.is_symlink()
                    else path.read_bytes() if path.is_file() else b"")
            entry(str(path.relative_to(root)), metadata.st_mode, data)
        entry("dev/console", stat.S_IFCHR | 0o600, major=5, minor=1)
        entry("dev/null", stat.S_IFCHR | 0o666, major=1, minor=3)
        entry("TRAILER!!!", 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", default="6.8.0-100-generic")
    parser.add_argument("--sysroot", type=Path, help="default: .cache/sysroots/<release>")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--duration", type=int, default=10)
    parser.add_argument("--mtus", default="9000")
    parser.add_argument("--segs", default="65535", help="vxlan gso_max_segs values")
    parser.add_argument("--tx", default="on off")
    parser.add_argument("--rx", choices=["on", "off"], default="off")
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--no-capture", action="store_true")
    parser.add_argument("--accel", choices=["auto", "kvm", "tcg"], default="auto")
    parser.add_argument("--source-gso-size", type=int, default=65536)
    parser.add_argument("--na-gro", choices=["on", "off"], default="on", help="router NIC GRO")
    parser.add_argument("--na-fraglist", choices=["on", "off"], default="on")
    parser.add_argument("--vlan-sg", choices=["on", "off"], default="on")
    parser.add_argument("--underlay", choices=["veth", "igb"], default="igb",
                        help="igb: emulated 82576 NICs on a QEMU hub; veth: all-virtual (does not reproduce)")
    parser.add_argument("--bond", action="store_true", help="igb: two sender NICs in an active-backup bond")
    parser.add_argument("--trace", action="store_true", help="count GSO/linearize calls with ftrace")
    parser.add_argument("--smp", type=int, default=2)
    parser.add_argument("--capture-filter", default="udp dst port 4789")
    parser.add_argument("--module", type=Path, help="extra .ko to insmod for the whole run (e.g. kmod/gso_entry_reseed.ko)")
    parser.add_argument("--module-args", default="")
    parser.add_argument("--guest-script", type=Path,
                        help="run this script in the guest instead of single-node.sh (OUT=/output)")
    parser.add_argument("--extra", type=Path, action="append", default=[],
                        help="file copied to /opt/repro/files/ in the guest (repeatable)")
    parser.add_argument("--qemu", type=Path,
                        help="QEMU binary; default .cache/qemu/bin/qemu-system-x86_64 (scripts/setup-qemu.sh)")
    parser.add_argument("--stock-igb", action="store_true",
                        help="do not set igb x-desc-offload=on (stock QEMU TX offload model; TX-on results unreliable)")
    parser.add_argument("--env", action="append", default=[], metavar="KEY=VALUE",
                        help="extra variable for single-node.sh (NA_VLAN, NA_MACVLAN, NIC_K, ...)")
    args = parser.parse_args()
    if args.duration <= 0:
        parser.error("--duration must be positive")
    mtus = [int(x) for x in args.mtus.split()]
    if not mtus or any(x < 1500 or x > 9000 for x in mtus):
        parser.error("--mtus values must be between 1500 and 9000")
    sysroot = (args.sysroot or CACHE / "sysroots" / args.release).resolve()
    if not (sysroot / "boot" / f"vmlinuz-{args.release}").exists():
        parser.error(f"no kernel in {sysroot}; run scripts/fetch-kernel.py {args.release} ...")
    qemu = args.qemu or (PATCHED_QEMU if PATCHED_QEMU.exists() else Path("qemu-system-x86_64"))
    desc_offload = args.underlay == "igb" and not args.stock_igb
    if desc_offload and not args.qemu and not PATCHED_QEMU.exists():
        parser.error("patched QEMU missing; run scripts/setup-qemu.sh or pass --stock-igb")
    burst = CACHE / "bin/burst"
    if not burst.exists():
        parser.error(f"{burst} missing; run scripts/build.sh {args.release}")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    guest = out / "initramfs-root"
    if guest.exists():
        raise SystemExit(f"Output already contains a guest: {guest}; use a new --output")
    for d in ["dev", "proc", "sys", "run", "tmp", "output", "bin", "sbin", "opt/repro/lab"]:
        (guest / d).mkdir(parents=True, exist_ok=True)
    tools = [(shutil.which("busybox"), "/bin/busybox"),
             (shutil.which("bash"), "/bin/bash"),
             (shutil.which("ip"), "/sbin/ip"),
             (shutil.which("sysctl"), "/sbin/sysctl"),
             (shutil.which("modprobe"), "/sbin/modprobe"),
             (shutil.which("timeout"), "/bin/timeout"),
             (sysroot / "usr/sbin/ethtool", "/sbin/ethtool"),
             (sysroot / "usr/bin/iperf3", "/bin/iperf3"),
             (burst, "/bin/burst"),
             (CACHE / "bin/tapinject", "/bin/tapinject")]
    if not args.no_capture:
        tools.append((shutil.which("tcpdump"), "/bin/tcpdump"))
    for src, target in tools:
        if not src or not Path(src).is_file():
            raise SystemExit(f"Missing binary: {src or target}")
        copy_binary(src, target, guest, sysroot)
    # glibc loads this dynamically for pthread_cancel; ldd does not list it.
    libgcc = command("gcc", "-print-file-name=libgcc_s.so.1", capture_output=True, text=True).stdout.strip()
    copy_binary(libgcc, "/lib/x86_64-linux-gnu/libgcc_s.so.1", guest, sysroot)
    os.symlink("bash", guest / "bin/sh")
    shutil.copy2(LAB / "guest/single-node.sh", guest / "opt/repro/lab/single-node.sh")
    add_modules(guest, sysroot, args.release)
    if args.module:
        shutil.copy2(args.module, guest / "opt/repro/extra.ko")
    if args.extra:
        (guest / "opt/repro/files").mkdir(parents=True, exist_ok=True)
        for path in args.extra:
            shutil.copy2(path, guest / "opt/repro/files" / path.name)
    if args.guest_script:
        shutil.copy2(args.guest_script, guest / "opt/repro/lab/custom.sh")
    env = {"DURATION": str(args.duration), "SEGS": args.segs,
           "TX_MODES": args.tx, "RX_MODE": args.rx, "CAPTURE": "0" if args.no_capture else "1",
           "SOURCE_GSO_SIZE": str(args.source_gso_size), "NA_GRO": args.na_gro,
           "NA_FRAGLIST": args.na_fraglist, "VLAN_SG": args.vlan_sg,
           "UNDERLAY": args.underlay, "BOND": "1" if args.bond else "0",
           "TRACE": "1" if args.trace else "0",
           "CAPTURE_FILTER": args.capture_filter}
    for item in args.env:
        key, sep, value = item.partition("=")
        if not sep or not re.fullmatch(r"[A-Z_][A-Z0-9_]*", key):
            parser.error(f"bad --env {item!r}")
        env[key] = value
    assignments = " ".join(f"{k}={shlex.quote(v)}" for k, v in env.items())
    init = """#!/bin/bash
export PATH=/sbin:/bin:/usr/sbin:/usr/bin
/bin/busybox --install -s /bin
mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mkdir -p /run/netns
for module in virtio_pci 9pnet_virtio 9p veth bridge 8021q macvlan vxlan igb bonding tun; do
    modprobe "$module" || { echo "VXGSO_GUEST_ERROR module=$module"; poweroff -f; }
done
mount -t 9p -o trans=virtio,version=9p2000.L output /output || {
    echo "VXGSO_GUEST_ERROR export_mount"; poweroff -f;
}
mount -t tracefs nodev /sys/kernel/tracing 2>/dev/null || true
for i in $(seq 50); do
    [ "$(ls /sys/class/net | wc -l)" -ge NETDEVS ] && break
    sleep 0.2
done
ip -br link
if [ -e /opt/repro/extra.ko ]; then
    insmod /opt/repro/extra.ko MODARGS || { echo "VXGSO_GUEST_ERROR insmod"; poweroff -f; }
fi
rc=0
""".replace("MODARGS", args.module_args).replace("NETDEVS", str(1 + (0 if args.underlay == "veth" else (3 if args.bond else 2))))
    if args.guest_script:
        init += f"env {assignments} OUT=/output /opt/repro/lab/custom.sh || rc=1\n"
        mtus = []
    for mtu in mtus:
        init += (f"env {assignments} TRANSIT_MTU={mtu} OUT=/output/mtu{mtu} "
                 "/opt/repro/lab/single-node.sh || rc=1\n")
    if args.module:
        init += f'rmmod {args.module.stem}; dmesg | grep -i {args.module.stem} | tee /output/module.log\n'
    init += 'echo "VXGSO_GUEST_DONE rc=$rc"\nsync\npoweroff -f\n'
    (guest / "init").write_text(init)
    (guest / "init").chmod(0o755)
    initramfs = out / "initramfs.cpio.gz"
    write_initramfs(guest, initramfs)
    accel = args.accel
    if accel == "auto":
        accel = "kvm" if os.access("/dev/kvm", os.R_OK | os.W_OK) else "tcg"
    cmd = [str(qemu), "-accel", accel, "-cpu", "host" if accel == "kvm" else "max",
           "-smp", str(args.smp), "-m", "1024", "-nodefaults", "-display", "none", "-no-reboot",
           "-kernel", str(sysroot / "boot" / f"vmlinuz-{args.release}"),
           "-initrd", str(initramfs), "-append", "console=ttyS0 rdinit=/init panic=-1 nokaslr",
           "-serial", "stdio", "-monitor", "none",
           "-virtfs", f"local,path={out},mount_tag=output,security_model=none,id=output"]
    if args.underlay == "igb":
        macs = ["52:54:00:47:00:01"] + (["52:54:00:47:00:02"] if args.bond else []) + ["52:54:00:47:00:10"]
        for i, mac in enumerate(macs):
            cmd += ["-netdev", f"hubport,id=p{i},hubid=0", "-device", f"igb,netdev=p{i},mac={mac}" + (",x-desc-offload=on" if desc_offload else "")]
    (out / "command.txt").write_text(shlex.join(cmd) + "\n")
    print(f"Booting {args.release} with {accel}; log: {out / 'serial.log'}", flush=True)
    start = time.monotonic()
    with (out / "serial.log").open("wb") as log:
        try:
            result = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout)
        except subprocess.TimeoutExpired:
            raise SystemExit(f"Guest timed out after {args.timeout}s; inspect {out / 'serial.log'}")
    text = (out / "serial.log").read_text(errors="replace")
    print(f"Guest exited after {time.monotonic() - start:.1f}s (QEMU rc={result.returncode})")
    if result.returncode != 0 or "VXGSO_GUEST_DONE rc=0" not in text:
        print("\n".join(text.splitlines()[-50:]))
        raise SystemExit(1)
    for path in sorted(out.glob("mtu*/summary.tsv")):
        print(f"\n{path.relative_to(out)}\n{path.read_text()}", end="")


if __name__ == "__main__":
    main()
