#!/bin/bash
# SPDX-License-Identifier: MIT
# GCC 14 from Ubuntu 24.04 .debs, extracted into .cache/gcc-14 (no root). Needed to build
# modules for kernels compiled with GCC >= 14 (e.g. 7.0, which uses -fmin-function-alignment).
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
G=$ROOT/.cache/gcc-14
mkdir -p "$G/debs"
(cd "$G/debs" && apt-get download gcc-14 gcc-14-x86-64-linux-gnu cpp-14 cpp-14-x86-64-linux-gnu libgcc-14-dev gcc-14-base)
for deb in "$G"/debs/*.deb; do dpkg-deb -x "$deb" "$G"; done
cat >"$G/gcc14" <<EOF
#!/bin/sh
exec $G/usr/bin/x86_64-linux-gnu-gcc-14 -B$G/usr/libexec/gcc/x86_64-linux-gnu/14/ -B$G/usr/lib/gcc/x86_64-linux-gnu/14/ "\$@"
EOF
chmod +x "$G/gcc14"
"$G/gcc14" --version | head -1
