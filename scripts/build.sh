#!/bin/bash
# SPDX-License-Identifier: MIT
# Build the guest-side binaries for one kernel release (sysroot from fetch-kernel.py):
#   .cache/bin/burst                          static GRO feeder
#   .cache/bin/tapinject                      static "VM behind a tap device" sender
#   .cache/kmod/<release>/gso_entry_reseed.ko  tracing kprobe + optional fix (mode=1)
#   .cache/kmod/<release>/gso_bench.ko         skb_gso_segment() microbenchmark
#   .cache/kmod/<release>/vxlan_gso_csum_fix.ko
#   .cache/kmod/<release>/udp_gso_fix_lp.ko    livepatch (6.8.0-100-generic only)
# Kernels built with GCC >= 14 (7.x) need scripts/setup-gcc14.sh; it is run automatically.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
REL=${1:?usage: scripts/build.sh <release>}
HDR=$ROOT/.cache/sysroots/$REL/usr/src/linux-headers-$REL
OUT=$ROOT/.cache/kmod/$REL
WORK=$ROOT/.cache/kmod-build/$REL
[[ -d $HDR ]] || { echo "missing $HDR; run scripts/fetch-kernel.py first" >&2; exit 1; }

mkdir -p "$ROOT/.cache/bin" "$OUT"
gcc -O2 -Wall -static -o "$ROOT/.cache/bin/burst" "$ROOT/lab/tools/burst.c"
gcc -O2 -Wall -static -o "$ROOT/.cache/bin/tapinject" "$ROOT/lab/tools/tapinject.c"

CC=gcc
kernel_gcc=$(sed -n 's/^CONFIG_GCC_VERSION=\([0-9]*\)/\1/p' "$HDR/.config")
if (( kernel_gcc >= 140000 )) && (( $(gcc -dumpversion | cut -d. -f1) < 14 )); then
    [[ -x $ROOT/.cache/gcc-14/gcc14 ]] || "$ROOT/scripts/setup-gcc14.sh"
    CC=$ROOT/.cache/gcc-14/gcc14
fi

build() {   # build <name> <source.c>
    local dir=$WORK/$1
    rm -rf "$dir"
    mkdir -p "$dir"
    sed "s/@VERSION@/$("$ROOT/fix/dkms/version.sh")/g" "$2" >"$dir/$(basename "$2")"
    echo "obj-m := $1.o" >"$dir/Makefile"
    if ! make -C "$HDR" M="$dir" CC="$CC" modules >"$dir/build.log" 2>&1; then
        cat "$dir/build.log" >&2
        exit 1
    fi
    cp "$dir/$1.ko" "$OUT/"
    echo "built .cache/kmod/$REL/$1.ko"
}

build gso_entry_reseed "$ROOT/lab/kmod/trace/gso_entry_reseed.c"
build gso_bench "$ROOT/lab/kmod/bench/gso_bench.c"
build vxlan_gso_csum_fix "$ROOT/fix/dkms/vxlan_gso_csum_fix.c"
if [[ $REL == 6.8.0-100-generic ]]; then
    build udp_gso_fix_lp "$ROOT/fix/livepatch-6.8.0-100/udp_gso_fix_lp.c"
fi
