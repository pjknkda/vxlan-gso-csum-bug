#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Build dist/vxlan-gso-csum-fix_<version>_amd64.deb: the DKMS source package.
# Installing it registers the module with DKMS, builds it for every kernel that
# has headers, loads it, and loads it at boot. Needs only dpkg-deb (no root).
set -euo pipefail
umask 022

# Debian requires "Name <email>"; override with MAINTAINER if needed.
MAINTAINER=${MAINTAINER:-"Elice Inc. <cloud-dev@elicer.com>"}

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(cd -- "$HERE/../.." && pwd)
NAME=$(sed -n 's/^PACKAGE_NAME="\(.*\)"/\1/p' "$HERE/dkms.conf")
VERSION=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$HERE/dkms.conf")
MODULE=$(sed -n 's/^BUILT_MODULE_NAME\[0\]="\(.*\)"/\1/p' "$HERE/dkms.conf")
OUT=$ROOT/dist
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

src=$STAGE/usr/src/$NAME-$VERSION
chmod 0755 "$STAGE"
mkdir -p "$src" "$STAGE/usr/lib/modules-load.d" "$STAGE/usr/share/doc/$NAME" "$STAGE/DEBIAN"
install -m 0644 "$HERE/dkms.conf" "$HERE/Makefile" "$HERE/$MODULE.c" "$src/"
# Vendor directory, not /etc: owned by the package and removed with it.
echo "$MODULE" >"$STAGE/usr/lib/modules-load.d/$NAME.conf"
{
    echo "Copyright (c) 2026 Elice Inc."
    echo "License: GPL-2.0"
    echo
    cat "$ROOT/LICENSES/GPL-2.0"
} >"$STAGE/usr/share/doc/$NAME/copyright"

cat >"$STAGE/DEBIAN/control" <<EOF
Package: $NAME
Version: $VERSION
Architecture: amd64
Maintainer: $MAINTAINER
Depends: dkms (>= 2.1)
Recommends: linux-headers-generic | linux-headers
Section: kernel
Priority: optional
Homepage: https://elice.io
Description: fix corrupted outer UDP checksums of re-segmented UDP tunnel GSO skbs (DKMS)
 A Linux host forwarding TCP into a VXLAN tunnel with outer UDP
 checksums can send packets with wrong outer checksums when a stacked device
 such as macvlan or bond splits a GRO skb into several GSO skbs and a lower
 device segments them again in software. This package installs a small kernel
 module, built by DKMS for every installed kernel, that normalises the checksum
 through a kprobe on __skb_udp_tunnel_segment(). It is loaded at boot.
EOF

cat >"$STAGE/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
if [ "\$1" = configure ]; then
    # Standard DKMS registration/build for all kernels with headers (as dh-dkms does).
    /usr/lib/dkms/common.postinst $NAME $VERSION "" "" "\$2"
    if [ -d "/lib/modules/\$(uname -r)/build" ]; then
        modprobe $MODULE || echo "$NAME: could not load $MODULE now; see dmesg" >&2
    else
        echo "$NAME: headers for the running kernel are missing; install them and run:" >&2
        echo "    sudo apt install linux-headers-\$(uname -r) && sudo modprobe $MODULE" >&2
    fi
fi
exit 0
EOF

cat >"$STAGE/DEBIAN/prerm" <<EOF
#!/bin/sh
set -e
case "\$1" in
remove|upgrade|deconfigure)
    modprobe -r $MODULE 2>/dev/null || true
    if [ -n "\$(dkms status -m $NAME -v $VERSION)" ]; then
        dkms remove -m $NAME -v $VERSION --all || true
    fi
    ;;
esac
exit 0
EOF
chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"

mkdir -p "$OUT"
dpkg-deb --root-owner-group --build "$STAGE" "$OUT/${NAME}_${VERSION}_amd64.deb" >/dev/null
echo "built ${OUT#$ROOT/}/${NAME}_${VERSION}_amd64.deb"
