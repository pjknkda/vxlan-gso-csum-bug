#!/bin/bash
# SPDX-License-Identifier: MIT
# Guest side of the kprobe vs livepatch overhead comparison (run by qemu-test.py --guest-script).
set -u
F=/opt/repro/files
LP=/sys/kernel/livepatch/udp_gso_fix_lp
mount -t debugfs none /sys/kernel/debug 2>/dev/null

wait_transition() {
    for _ in $(seq 200); do [[ $(cat $LP/transition 2>/dev/null || echo 0) == 0 ]] && return; sleep 0.05; done
    echo "WARN: livepatch transition did not finish"
}
load() {
    case $1 in
    kprobe) insmod $F/vxlan_gso_csum_fix.ko && grep __skb_udp_tunnel_segment /sys/kernel/debug/kprobes/list ;;
    livepatch) insmod $F/udp_gso_fix_lp.ko && wait_transition && echo "livepatch enabled=$(cat $LP/enabled)" ;;
    esac
}
unload() {
    case $1 in
    kprobe) rmmod vxlan_gso_csum_fix ;;
    livepatch) echo 0 >$LP/enabled; wait_transition; rmmod udp_gso_fix_lp ;;
    esac
}
bench() {
    insmod $F/gso_bench.ko "$@" iters=${ITERS:-100000} rounds=${ROUNDS:-7}
    rmmod gso_bench
    dmesg | grep 'gso_bench: alloc_only' | tail -1 | sed 's/.*gso_bench: //'
}

for rep in $(seq ${REPS:-3}); do
    for v in none kprobe livepatch; do
        load $v
        for e in ${ENCAPS:-0 1}; do
            for s in ${SEGS_LIST:-2 7 14}; do
                echo "PERF rep=$rep variant=$v $(bench encap_hdr=$e segs=$s)" | tee -a /output/perf.txt
            done
        done
        unload $v
    done
done
