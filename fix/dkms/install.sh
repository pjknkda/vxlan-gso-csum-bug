#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Install vxlan-gso-csum-fix with DKMS, load it now and on every boot.
# DKMS rebuilds the module automatically for each newly installed kernel.
set -euo pipefail

NAME=vxlan-gso-csum-fix
VERSION=1.0.0
MODULE=vxlan_gso_csum_fix
HERE=$(cd -- "$(dirname -- "$0")" && pwd)

[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0" >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo "only x86_64 is supported" >&2; exit 1; }
command -v dkms >/dev/null || { echo "dkms is missing: apt install dkms" >&2; exit 1; }
[[ -d /lib/modules/$(uname -r)/build ]] || {
    echo "headers for the running kernel are missing: apt install linux-headers-$(uname -r)" >&2
    exit 1
}

# Reinstall cleanly if an older copy is registered.
# (Not "dkms status | grep -q": with pipefail, dkms may die of SIGPIPE and fail the test.)
if [[ -n $(dkms status -m "$NAME" -v "$VERSION") ]]; then
    modprobe -r "$MODULE" 2>/dev/null || true
    dkms remove -m "$NAME" -v "$VERSION" --all
fi
rm -rf "/usr/src/$NAME-$VERSION"
mkdir -p "/usr/src/$NAME-$VERSION"
cp "$HERE/dkms.conf" "$HERE/Makefile" "$HERE/$MODULE.c" "/usr/src/$NAME-$VERSION/"

dkms add -m "$NAME" -v "$VERSION"
dkms build -m "$NAME" -v "$VERSION"
dkms install -m "$NAME" -v "$VERSION"

echo "$MODULE" >/etc/modules-load.d/$NAME.conf
modprobe "$MODULE"

if [[ -d /sys/module/$MODULE ]]; then
    echo "$NAME $VERSION installed and loaded (kernel $(uname -r))."
    echo "It is loaded at boot via /etc/modules-load.d/$NAME.conf."
else
    echo "installed, but the module did not load; see: dmesg | grep $MODULE" >&2
    exit 1
fi
