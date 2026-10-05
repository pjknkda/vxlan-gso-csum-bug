#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Install vxlan-gso-csum-fix with DKMS, load it now and on every boot.
# DKMS rebuilds the module automatically for each newly installed kernel.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
NAME=$(sed -n 's/^PACKAGE_NAME="\(.*\)"/\1/p' "$HERE/dkms.conf")
VERSION=$("$HERE/version.sh")
MODULE=$(sed -n 's/^BUILT_MODULE_NAME\[0\]="\(.*\)"/\1/p' "$HERE/dkms.conf")

[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0" >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo "only x86_64 is supported" >&2; exit 1; }
command -v dkms >/dev/null || { echo "dkms is missing: apt install dkms" >&2; exit 1; }
[[ -d /lib/modules/$(uname -r)/build ]] || {
    echo "headers for the running kernel are missing: apt install linux-headers-$(uname -r)" >&2
    exit 1
}

# Reinstall cleanly: drop every registered version (this one or an older one).
"$HERE/uninstall.sh" >/dev/null
mkdir -p "/usr/src/$NAME-$VERSION"
for f in dkms.conf Makefile "$MODULE.c"; do
    sed "s/@VERSION@/$VERSION/g" "$HERE/$f" >"/usr/src/$NAME-$VERSION/$f"
done

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
