#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build a guest sysroot for one Ubuntu kernel from archive .debs (nothing is installed).

  scripts/fetch-kernel.py 6.8.0-100-generic --version 6.8.0-100.100     # any published build (Launchpad)
  scripts/fetch-kernel.py 6.8.0-146-generic --suite noble-updates       # current build in a pocket

Result: .cache/sysroots/<release>/ with boot/vmlinuz-<release>, lib/modules/<release>/,
usr/src/linux-headers-* (for out-of-tree modules) and the guest userspace (iperf3, ethtool).
"""
import argparse
import lzma
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache"
MIRROR = "http://archive.ubuntu.com/ubuntu"
LAUNCHPAD = "https://launchpad.net/ubuntu/+archive/primary/+files"
# Guest userspace, taken from Ubuntu 24.04 whatever kernel is under test.
USERSPACE = {"suite": "noble", "packages": ["iperf3", "libiperf0", "libsctp1", "ethtool"]}


def index(suite, component):
    url = f"{MIRROR}/dists/{suite}/{component}/binary-amd64/Packages.xz"
    data = lzma.decompress(urllib.request.urlopen(url).read()).decode()
    packages = {}
    for stanza in data.split("\n\n"):
        fields = dict(line.split(": ", 1) for line in stanza.splitlines()
                      if ": " in line and not line.startswith(" "))
        if "Package" in fields:
            packages[fields["Package"]] = fields
    return packages


def download(url, dest):
    if dest.exists():
        return dest
    print(f"download {dest.name}")
    tmp = dest.with_suffix(".part")
    urllib.request.urlretrieve(url, tmp)
    tmp.rename(dest)
    return dest


def extract(deb, sysroot):
    subprocess.run(["dpkg-deb", "-x", str(deb), str(sysroot)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("release", help="kernel release, e.g. 6.8.0-100-generic")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--suite", help="archive pocket holding this build, e.g. noble-updates")
    group.add_argument("--version", help="exact package version, e.g. 6.8.0-100.100 (fetched from Launchpad)")
    parser.add_argument("--common-headers", help="name of the arch-independent headers package when it is "
                        "not linux-headers-<abi> (HWE: linux-hwe-6.8-headers-<abi>); only with --version")
    args = parser.parse_args()

    release = args.release
    abi = release.removesuffix("-generic")
    debdir = CACHE / "debs" / release
    sysroot = CACHE / "sysroots" / release
    debdir.mkdir(parents=True, exist_ok=True)
    sysroot.mkdir(parents=True, exist_ok=True)

    wanted = [f"linux-image-{release}", f"linux-modules-{release}", f"linux-modules-extra-{release}",
              f"linux-headers-{release}"]
    if args.suite:
        main_index = index(args.suite, "main")
        # The arch-independent headers package is named after the source package
        # (linux-headers-<abi>, linux-hwe-6.8-headers-<abi>, ...).
        common = [n for n in main_index if n.endswith(f"-headers-{abi}") and "riscv" not in n
                  and "lowlatency" not in n and "realtime" not in n]
        for name in wanted + common:
            if name not in main_index:
                print(f"skip {name} (not in {args.suite}; 7.x has no -extra package)")
                continue
            filename = main_index[name]["Filename"]
            extract(download(f"{MIRROR}/{filename}", debdir / Path(filename).name), sysroot)
    else:
        common = args.common_headers or f"linux-headers-{abi}"
        for name, arch in [(n, "amd64") for n in wanted] + [(common, "all")]:
            filename = f"{name}_{args.version}_{arch}.deb"
            try:
                extract(download(f"{LAUNCHPAD}/{filename}", debdir / filename), sysroot)
            except urllib.error.HTTPError as err:
                if "modules-extra" in name and err.code == 404:
                    print(f"skip {name} (not published for this kernel)")
                    continue
                sys.exit(f"cannot fetch {filename}: {err}")

    user_index = {}
    for component in ("main", "universe"):
        user_index.update(index(USERSPACE["suite"], component))
    for name in USERSPACE["packages"]:
        filename = user_index[name]["Filename"]
        extract(download(f"{MIRROR}/{filename}", CACHE / "debs" / Path(filename).name), sysroot)

    # 26.04 packages ship modules under /usr/lib only (merged /usr).
    if not (sysroot / "lib").exists() and (sysroot / "usr/lib/modules").exists():
        (sysroot / "lib").symlink_to("usr/lib")
    if not (sysroot / "boot" / f"vmlinuz-{release}").exists():
        sys.exit(f"missing boot/vmlinuz-{release}")
    subprocess.run(["depmod", "-b", str(sysroot), "-a", release], check=True)
    print(f"sysroot ready: {sysroot.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
