#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Unload and remove vxlan-gso-csum-fix from all kernels.
set -euo pipefail

NAME=vxlan-gso-csum-fix
VERSION=1.0.0
MODULE=vxlan_gso_csum_fix

[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0" >&2; exit 1; }
modprobe -r "$MODULE" 2>/dev/null || true
rm -f "/etc/modules-load.d/$NAME.conf"
if command -v dkms >/dev/null && [[ -n $(dkms status -m "$NAME" -v "$VERSION") ]]; then
    dkms remove -m "$NAME" -v "$VERSION" --all
fi
rm -rf "/usr/src/$NAME-$VERSION"
echo "$NAME removed."
