#!/bin/bash
# SPDX-License-Identifier: MIT
# Build QEMU 8.2.2 with lab/qemu/igb-desc-offload.patch into .cache/qemu without root.
# Build dependencies are Ubuntu 24.04 .debs extracted into .cache/qemu/deps (apt-get download).
# Result: .cache/qemu/bin/qemu-system-x86_64
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
Q=$ROOT/.cache/qemu
VER=8.2.2
DEPS="ninja-build meson pkgconf pkgconf-bin libpkgconf3 libglib2.0-dev libglib2.0-dev-bin
      libpixman-1-dev zlib1g-dev libpcre2-dev libffi-dev libmount-dev libblkid-dev
      libselinux1-dev libsepol-dev python3-pip-whl python3-setuptools-whl bzip2"

mkdir -p "$Q/debs" "$Q/deps" "$Q/bin"

if [[ ! -e $Q/deps/.done ]]; then
    (cd "$Q/debs" && apt-get download $DEPS)
    for deb in "$Q"/debs/*.deb; do dpkg-deb -x "$deb" "$Q/deps"; done
    # -dev packages ship lib*.so as symlinks to runtime libraries; point them at the host's.
    for so in "$Q"/deps/usr/lib/x86_64-linux-gnu/*.so; do
        [[ -L $so && ! -e $so ]] || continue
        target=/usr/lib/x86_64-linux-gnu/$(basename "$(readlink "$so")")
        [[ -e $target ]] && ln -sf "$target" "$so"
    done
    touch "$Q/deps/.done"
fi

D=$Q/deps
export PATH=$D/usr/bin:$PATH
export LD_LIBRARY_PATH=$D/usr/lib/x86_64-linux-gnu
export PYTHONPATH=$D/usr/lib/python3/dist-packages:$(ls "$D"/usr/share/python-wheels/pip-*.whl):$(ls "$D"/usr/share/python-wheels/setuptools-*.whl)
export PKG_CONFIG_SYSROOT_DIR=$D
export PKG_CONFIG_LIBDIR=$D/usr/lib/x86_64-linux-gnu/pkgconfig:$D/usr/share/pkgconfig

SRC=$Q/qemu-$VER
if [[ ! -d $SRC ]]; then
    [[ -f $Q/qemu-$VER.tar.xz ]] || curl -fL -o "$Q/qemu-$VER.tar.xz" "https://download.qemu.org/qemu-$VER.tar.xz"
    tar -C "$Q" -xJf "$Q/qemu-$VER.tar.xz"
    patch -d "$SRC" -p1 <"$ROOT/lab/qemu/igb-desc-offload.patch"
fi

mkdir -p "$SRC/build"
cd "$SRC/build"
[[ -f build.ninja ]] || ../configure --target-list=x86_64-softmmu --without-default-features \
    --enable-kvm --enable-virtfs --enable-attr --disable-docs --disable-werror
ninja qemu-system-x86_64
ln -sf "$SRC/build/qemu-system-x86_64" "$Q/bin/qemu-system-x86_64"
"$Q/bin/qemu-system-x86_64" -device igb,help | grep -q x-desc-offload
echo "QEMU ready: .cache/qemu/bin/qemu-system-x86_64"
