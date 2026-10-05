#!/bin/bash
# SPDX-License-Identifier: MIT
# End-to-end test of fix/dkms on a stock Ubuntu 24.04 cloud image (KVM + network):
#   boot 1 (GA 6.8 kernel): install the fix, check it loads, then install the HWE
#          kernel (DKMS must build the module for it), reboot
#   boot 2 (HWE kernel):    check the module was built and auto-loaded, remove the
#          fix, check nothing is left, power off
# MODE=deb (default) installs dist/*.deb with apt; MODE=script uses install.sh/uninstall.sh.
# Uses the system qemu-system-x86_64 (needs user networking) on a 12 GB qcow2 overlay,
# so the downloaded image is never modified. qemu-img is built from .cache/qemu if the
# host has none. Markers E2E_* are printed on the serial console.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
CLOUD=$ROOT/.cache/cloud
OUT=${OUT:-$ROOT/results/dkms-e2e-$(date -u +%Y%m%dT%H%M%SZ)}
IMG=$CLOUD/noble-server-cloudimg-amd64.img
PORT=${PORT:-8765}
MODE=${MODE:-deb}

mkdir -p "$CLOUD" "$OUT/seed"
[[ -f $IMG ]] || curl -fL -o "$IMG" https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
[[ -w /dev/kvm ]] || { echo "/dev/kvm is required" >&2; exit 1; }

QEMU_IMG=$(command -v qemu-img || true)
if [[ -z $QEMU_IMG ]]; then
    QEMU_IMG=$ROOT/.cache/qemu/build-tools/qemu-img
    if [[ ! -x $QEMU_IMG ]]; then
        [[ -d $ROOT/.cache/qemu/qemu-8.2.2 ]] || "$ROOT/scripts/setup-qemu.sh"
        D=$ROOT/.cache/qemu/deps
        mkdir -p "$ROOT/.cache/qemu/build-tools"
        (cd "$ROOT/.cache/qemu/build-tools" &&
         PATH=$D/usr/bin:$PATH LD_LIBRARY_PATH=$D/usr/lib/x86_64-linux-gnu \
         PYTHONPATH=$D/usr/lib/python3/dist-packages:$(ls "$D"/usr/share/python-wheels/pip-*.whl):$(ls "$D"/usr/share/python-wheels/setuptools-*.whl) \
         PKG_CONFIG_SYSROOT_DIR=$D PKG_CONFIG_LIBDIR=$D/usr/lib/x86_64-linux-gnu/pkgconfig:$D/usr/share/pkgconfig \
         bash -c '../qemu-8.2.2/configure --target-list= --without-default-features --enable-tools \
                  --disable-docs --disable-werror >/dev/null && ninja qemu-img >/dev/null')
    fi
fi
DISK=$OUT/disk.qcow2
"$QEMU_IMG" create -q -f qcow2 -F qcow2 -b "$IMG" "$DISK" 12G

tar -C "$ROOT/fix" -cf "$OUT/seed/dkms.tar" dkms
if [[ $MODE == deb ]]; then
    deb=$("$ROOT/fix/dkms/build-deb.sh" | sed -n 's/^built //p')
    cp "$ROOT/$deb" "$OUT/seed/fix.deb"
    INSTALL='curl -fsS http://10.0.2.2:'$PORT'/fix.deb -o /root/fix.deb && apt-get install -y -q /root/fix.deb'
    UNINSTALL='apt-get remove -y -q vxlan-gso-csum-fix'
    LOADCONF=/usr/lib/modules-load.d/vxlan-gso-csum-fix.conf
else
    INSTALL='apt-get install -y -q dkms && /root/dkms/install.sh'
    UNINSTALL='/root/dkms/uninstall.sh'
    LOADCONF=/etc/modules-load.d/vxlan-gso-csum-fix.conf
fi
printf 'instance-id: dkms-e2e\nlocal-hostname: dkms-e2e\n' >"$OUT/seed/meta-data"
cat >"$OUT/seed/user-data" <<EOF
#cloud-config
write_files:
  - path: /usr/local/sbin/e2e-boot2
    permissions: '0755'
    content: |
      #!/bin/bash
      # The serial getty owns ttyS0; report through the kernel log, which reaches the console.
      exec >/root/e2e-boot2.log 2>&1
      echo "E2E_BOOT2_KERNEL \$(uname -r)"
      dkms status vxlan-gso-csum-fix | sed 's/^/E2E_DKMS_STATUS /'
      if [ -d /sys/module/vxlan_gso_csum_fix ]; then echo E2E_BOOT2_LOADED_OK; else echo E2E_BOOT2_NOT_LOADED; fi
      $UNINSTALL
      if [ ! -d /sys/module/vxlan_gso_csum_fix ] && [ -z "\$(dkms status vxlan-gso-csum-fix)" ] \\
         && [ ! -e $LOADCONF ] && [ -z "\$(ls -d /usr/src/vxlan-gso-csum-fix-* 2>/dev/null)" ]; then echo E2E_UNINSTALL_OK; else echo E2E_UNINSTALL_FAIL; fi
      echo E2E_DONE
      { sed 's/^/boot1| /' /root/e2e-boot1.log; cat /root/e2e-boot2.log; } |
          while IFS= read -r l; do printf '<3>e2e: %s\n' "\$l" >/dev/kmsg; sleep 0.002; done
      systemctl poweroff
  - path: /etc/systemd/system/e2e-boot2.service
    content: |
      [Unit]
      Description=dkms e2e second boot check
      After=multi-user.target
      ConditionPathExists=/root/e2e-boot1-done
      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/e2e-boot2
      [Install]
      WantedBy=multi-user.target
runcmd:
  - |
    # The serial getty takes over ttyS0 during boot 1; log to a file, boot 2 prints it.
    exec >/root/e2e-boot1.log 2>&1
    set -x
    echo "E2E_BOOT1_KERNEL \$(uname -r)"
    df -h /
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q "linux-headers-\$(uname -r)"
    curl -fsS http://10.0.2.2:$PORT/dkms.tar | tar -x -C /root
    echo "E2E_MODE $MODE"
    if $INSTALL; then echo E2E_INSTALL_OK; else echo E2E_INSTALL_FAIL; fi
    if [ -d /sys/module/vxlan_gso_csum_fix ]; then echo E2E_BOOT1_LOADED_OK; fi
    apt-get install -y -q linux-generic-hwe-24.04
    dkms status vxlan-gso-csum-fix | sed 's/^/E2E_DKMS_STATUS /'
    df -h /
    touch /root/e2e-boot1-done
    systemctl enable e2e-boot2.service
    reboot
EOF

(cd "$OUT/seed" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
HTTP_PID=$!
trap 'kill $HTTP_PID 2>/dev/null || true' EXIT

echo "booting; console log: $OUT/console.log"
timeout 3600 qemu-system-x86_64 -accel kvm -cpu host -smp 4 -m 4096 -nographic \
    -drive "file=$DISK,if=virtio,format=qcow2" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -smbios "type=1,serial=ds=nocloud;s=http://10.0.2.2:$PORT/" \
    </dev/null >"$OUT/console.log" 2>&1 || true

grep -aoE 'E2E_[A-Z0-9_]+.*' "$OUT/console.log" | tr -d '\r' | tee "$OUT/markers.txt"
for m in E2E_INSTALL_OK E2E_BOOT1_LOADED_OK E2E_BOOT2_LOADED_OK E2E_UNINSTALL_OK; do
    grep -q "^$m" "$OUT/markers.txt" || { echo "FAIL: missing $m" >&2; exit 1; }
done
boot1=$(sed -n 's/^E2E_BOOT1_KERNEL //p' "$OUT/markers.txt" | head -1)
boot2=$(sed -n 's/^E2E_BOOT2_KERNEL //p' "$OUT/markers.txt" | head -1)
[[ -n $boot2 && $boot1 != "$boot2" ]] || { echo "FAIL: second boot did not use the new kernel" >&2; exit 1; }
echo "PASS: installed on $boot1, rebuilt and auto-loaded on $boot2, uninstalled cleanly"
