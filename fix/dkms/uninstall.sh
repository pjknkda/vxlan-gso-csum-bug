#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Unload vxlan-gso-csum-fix and remove every registered version from all kernels.
set -euo pipefail

NAME=vxlan-gso-csum-fix
MODULE=vxlan_gso_csum_fix

[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0" >&2; exit 1; }
modprobe -r "$MODULE" 2>/dev/null || true
rm -f "/etc/modules-load.d/$NAME.conf"
if command -v dkms >/dev/null; then
    # "name/version, kernel, arch: state" (or "name/version: added"); captured, not piped
    # into grep, so pipefail cannot trip over SIGPIPE.
    status=$(dkms status -m "$NAME")
    for version in $(sed -n "s#^$NAME/\([^,:]*\).*#\1#p" <<<"$status" | sort -u); do
        dkms remove -m "$NAME" -v "$version" --all
    done
fi
rm -rf "/usr/src/$NAME"-*
echo "$NAME removed."
