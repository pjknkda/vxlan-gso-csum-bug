#!/bin/bash
# SPDX-License-Identifier: MIT
# Translate the user's two-node iperf reproducer into one kernel / five netns.
# Only creates private namespaces and virtual links. No existing NIC is changed.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${OUT:-$ROOT/results/single-$(date -u +%Y%m%dT%H%M%SZ)-$$}
DURATION=${DURATION:-10}
PARALLEL=${PARALLEL:-4}
MSS=${MSS:-1200}
SEGS=${SEGS:-"13 14 65535"}
TX_MODES=${TX_MODES:-"on off"}
RX_MODE=${RX_MODE:-off}
CAPTURE=${CAPTURE:-1}
TRANSIT_MTU=${TRANSIT_MTU:-1500}
SOURCE_GSO_SIZE=${SOURCE_GSO_SIZE:-65536}
NA_GRO=${NA_GRO:-off}
NA_FRAGLIST=${NA_FRAGLIST:-on}
VLAN_SG=${VLAN_SG:-on}
# veth: all-virtual fabric. igb: QEMU-emulated 82576 NICs whose driver advertises
# tx-gso-partial for UDP tunnels, like mlx5 does (see qemu-test.py --underlay).
UNDERLAY=${UNDERLAY:-veth}
BOND=${BOND:-0}
NA_MACS=${NA_MACS:-"52:54:00:47:00:01 52:54:00:47:00:02"}
COMPUTE_MAC=${COMPUTE_MAC:-52:54:00:47:00:10}
TRACE=${TRACE:-0}
# Topology/feature knobs for finding the minimal reproducing combination.
NA_VLAN=${NA_VLAN:-1}          # sender: VLAN between macvlan and NIC/bond
NA_MACVLAN=${NA_MACVLAN:-1}    # sender: macvlan between VXLAN and VLAN/NIC
VXLAN_UDPCSUM=${VXLAN_UDPCSUM:-1}
VXLAN_TSO=${VXLAN_TSO:-on}     # off = the old workaround: segment TCP before encapsulation
NIC_K=${NIC_K:-}               # extra "ethtool -K" args for sender NICs, e.g. "tx-gso-partial off"
# Same, but applied once before any VLAN/macvlan exists. A NIC feature change after
# a VLAN is created resets the VLAN's hw_enc_features (drops SG), so ordering matters.
NIC_K_SETUP=${NIC_K_SETUP:-}
COMPUTE_GRO=${COMPUTE_GRO:-off}  # receiver GRO off keeps pcap frames as on the wire
# Hold GRO packets across NAPI polls so aggregates reach 64K (deterministic frag_list split).
NA_GRO_FLUSH_NS=${NA_GRO_FLUSH_NS:-0}
NA_NAPI_DEFER=${NA_NAPI_DEFER:-0}
# iperf: original TCP generator. burst: deterministic same-flow segment bursts (lab/burst.c).
TRAFFIC=${TRAFFIC:-iperf}
BURST_SEGS=${BURST_SEGS:-40}
BURST_COUNT=${BURST_COUNT:-200}
BURST_LEN=${BURST_LEN:-1188}
BURST_PROTO=${BURST_PROTO:-tcp}  # tcp or udp (inner traffic carried in VXLAN)
NA_UDP_GRO_FWD=${NA_UDP_GRO_FWD:-}  # router NIC rx-udp-gro-forwarding on/off (empty: leave default)
NA_GRO_LIST=${NA_GRO_LIST:-}        # router NIC rx-gro-list on/off (empty: leave default)
# TRAFFIC=vm: a "VM" behind a tap device on the router sends TCP into the VXLAN tunnel.
VM_TSO=${VM_TSO:-1}     # 1: the VM sends TSO frames (virtio GSO); 0: MSS-size frames
VM_NAPI=${VM_NAPI:-0}   # 1: tap opened with IFF_NAPI, so tap RX goes through GRO
VM_IP=192.0.2.2
VM_GW=192.0.2.1
NA_RX_USECS=${NA_RX_USECS:-}   # igb interrupt coalescing on the sender NIC (burst mode: one NAPI poll per burst)
TRACE_FUNCS=${TRACE_FUNCS:-"skb_udp_tunnel_segment __skb_udp_tunnel_segment skb_segment __pskb_pull_tail skb_checksum_help"}
TRACEFS=/sys/kernel/tracing

ME=198.51.100.1        # router underlay address (documentation range)
COMPUTE=198.51.100.2   # client / VXLAN receiver underlay address
TESTIP=198.18.0.2
GW=198.18.0.1
PORT=15201
TAG=vgs-$$
FABRIC=$TAG-wire
NA_ROOT=$TAG-na
EVN=$TAG-evn
COMPUTE_NS=$TAG-compute
SERVER_NS=$TAG-server
CREATED=()
SERVER_PID=
CAPTURE_PID=

cleanup() {
    local ns
    trap - EXIT INT TERM
    [[ -z "$CAPTURE_PID" ]] || kill "$CAPTURE_PID" 2>/dev/null || true
    [[ -z "$SERVER_PID" ]] || kill "$SERVER_PID" 2>/dev/null || true
    [[ -z "$CAPTURE_PID" ]] || wait "$CAPTURE_PID" 2>/dev/null || true
    [[ -z "$SERVER_PID" ]] || wait "$SERVER_PID" 2>/dev/null || true
    for ns in "${CREATED[@]}"; do ip netns del "$ns" 2>/dev/null || true; done
}

[[ $EUID -eq 0 ]] || { echo "Run inside the test VM as root, or sudo this script." >&2; exit 1; }
for bin in ip ethtool iperf3 sysctl awk timeout; do
    command -v "$bin" >/dev/null || { echo "Missing command: $bin" >&2; exit 1; }
done
[[ $DURATION =~ ^[1-9][0-9]*$ ]] || { echo "Invalid DURATION" >&2; exit 1; }
[[ $PARALLEL =~ ^[1-9][0-9]*$ ]] || { echo "Invalid PARALLEL" >&2; exit 1; }
[[ $MSS =~ ^[1-9][0-9]*$ ]] || { echo "Invalid MSS" >&2; exit 1; }
[[ $RX_MODE == on || $RX_MODE == off ]] || { echo "Invalid RX_MODE" >&2; exit 1; }
for toggle in "$NA_GRO" "$NA_FRAGLIST" "$VLAN_SG"; do
    [[ $toggle == on || $toggle == off ]] || { echo "Invalid offload toggle" >&2; exit 1; }
done
[[ $SOURCE_GSO_SIZE =~ ^[0-9]+$ ]] && (( SOURCE_GSO_SIZE >= 2048 && SOURCE_GSO_SIZE <= 65536 )) || {
    echo "SOURCE_GSO_SIZE must be between 2048 and 65536" >&2; exit 1;
}
[[ $TRANSIT_MTU =~ ^[0-9]+$ ]] && (( TRANSIT_MTU >= 1500 && TRANSIT_MTU <= 9000 )) || {
    echo "TRANSIT_MTU must be between 1500 and 9000" >&2; exit 1;
}
mkdir -p "$OUT"
OUT=$(cd -- "$OUT" && pwd)
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Kernel: $(uname -r)"
echo "Artifacts: $OUT"
echo "One machine: compute(client) -> NA(EVN) -> VXLAN -> compute(bridge) -> server"
uname -a >"$OUT/kernel.txt"
iperf3 --version >"$OUT/iperf-version.txt" 2>&1

for ns in "$FABRIC" "$NA_ROOT" "$EVN" "$COMPUTE_NS" "$SERVER_NS"; do
    ip netns add "$ns"
    CREATED+=("$ns")
    ip -n "$ns" link set lo up
done

by_mac() {
    local mac=$1 path
    for path in /sys/class/net/*; do
        [[ $(cat "$path/address") == "$mac" ]] && { basename "$path"; return; }
    done
    echo "No interface with MAC $mac" >&2
    return 1
}

NA_SLAVES=(nic0)
NA_DEV=nic0
if [[ $UNDERLAY == igb ]]; then
# The QEMU hub replaces the cable/switch; move the emulated NICs into the lab.
i=0
NA_SLAVES=()
for mac in $NA_MACS; do
    (( i == 0 || BOND == 1 )) || break
    dev=$(by_mac "$mac")
    ip link set "$dev" down
    ip link set "$dev" netns "$NA_ROOT"
    ip -n "$NA_ROOT" link set "$dev" name "nic$i"
    NA_SLAVES+=("nic$i")
    i=$((i + 1))
done
dev=$(by_mac "$COMPUTE_MAC")
ip link set "$dev" down
ip link set "$dev" netns "$COMPUTE_NS"
ip -n "$COMPUTE_NS" link set "$dev" name nic0
for dev in "${NA_SLAVES[@]}"; do ip -n "$NA_ROOT" link set "$dev" mtu 9000; done
if [[ $BOND == 1 ]]; then
    NA_DEV=bond0
    ip -n "$NA_ROOT" link add bond0 type bond mode active-backup miimon 100
    for dev in "${NA_SLAVES[@]}"; do ip -n "$NA_ROOT" link set "$dev" master bond0; done
fi
else
# An isolated Ethernet fabric replaces the cable/switch between the two nodes.
ip -n "$FABRIC" link add wire0 type bridge
ip -n "$FABRIC" link set wire0 mtu 9000 up
ip -n "$NA_ROOT" link add nic0 type veth peer name na-wire netns "$FABRIC"
ip -n "$COMPUTE_NS" link add nic0 type veth peer name compute-wire netns "$FABRIC"
for dev in na-wire compute-wire; do
    ip -n "$FABRIC" link set "$dev" mtu 9000 master wire0
    ip -n "$FABRIC" link set "$dev" up
done
# Keep both endpoint VLAN/macvlan/VXLAN MTUs at the original values; lower
# only the transit egress port, as a controlled attempt to cause segmentation.
ip -n "$FABRIC" link set compute-wire mtu "$TRANSIT_MTU"
fi

# Sender: [VLAN] -> [macvlan in EVN namespace] -> VXLAN, as vxgso-na.sh.
for dev in "${NA_SLAVES[@]}" "$NA_DEV"; do ip -n "$NA_ROOT" link set "$dev" mtu 9000 up; done
# The original physical driver did not accept every virtual offload feature.
# These are ordinary ethtool controls on private test devices, not kernel changes.
# igb has no fraglist feature; report instead of aborting when a toggle is fixed.
for dev in "${NA_SLAVES[@]}"; do
    [[ -z $NA_UDP_GRO_FWD ]] || ip netns exec "$NA_ROOT" ethtool -K "$dev" rx-udp-gro-forwarding "$NA_UDP_GRO_FWD"
    [[ -z $NA_GRO_LIST ]] || ip netns exec "$NA_ROOT" ethtool -K "$dev" rx-gro-list "$NA_GRO_LIST"
    ip netns exec "$NA_ROOT" ethtool -K "$dev" gro "$NA_GRO" ||
        echo "WARN: $dev gro $NA_GRO not applied"
    ip netns exec "$NA_ROOT" ethtool -K "$dev" tx-scatter-gather-fraglist "$NA_FRAGLIST" 2>/dev/null ||
        echo "WARN: $dev tx-scatter-gather-fraglist $NA_FRAGLIST not applied"
done
for dev in "${NA_SLAVES[@]}"; do
    ip netns exec "$NA_ROOT" sh -c "echo $NA_GRO_FLUSH_NS > /sys/class/net/$dev/gro_flush_timeout &&
        echo $NA_NAPI_DEFER > /sys/class/net/$dev/napi_defer_hard_irqs"
done
if [[ -n $NA_RX_USECS ]]; then
    for dev in "${NA_SLAVES[@]}"; do
        ip netns exec "$NA_ROOT" ethtool -C "$dev" rx-usecs "$NA_RX_USECS" || echo "WARN: $dev rx-usecs not applied"
    done
fi
if [[ -n $NIC_K_SETUP ]]; then
    for dev in "${NA_SLAVES[@]}"; do ip netns exec "$NA_ROOT" ethtool -K "$dev" $NIC_K_SETUP; done
fi
FEATURE_DEVS=()
for dev in "${NA_SLAVES[@]}"; do FEATURE_DEVS+=("$NA_ROOT:$dev"); done
[[ $NA_DEV == "${NA_SLAVES[0]}" ]] || FEATURE_DEVS+=("$NA_ROOT:$NA_DEV")
NA_UL=$NA_DEV
VLAN_NS=
if [[ $NA_VLAN == 1 ]]; then
    ip -n "$NA_ROOT" link add link "$NA_DEV" name vlan444 type vlan id 444
    ip -n "$NA_ROOT" link set vlan444 mtu 9000 up
    NA_UL=vlan444
    VLAN_NS=$NA_ROOT
fi
DIRECT=0
if [[ $NA_VLAN != 1 && $NA_MACVLAN != 1 ]]; then
    # VXLAN directly on the NIC/bond: run the router side in the NIC's namespace.
    DIRECT=1
    EVN=$NA_ROOT
    EVN_UL=$NA_DEV
elif [[ $NA_MACVLAN == 1 ]]; then
    ip -n "$NA_ROOT" link add mvlan-vxgso link "$NA_UL" type macvlan mode bridge
    EVN_UL=mvlan-vxgso
else
    # VXLAN sits directly on the VLAN (or NIC); move that device to EVN.
    EVN_UL=$NA_UL
    [[ $NA_UL != vlan444 ]] || VLAN_NS=$EVN
fi
[[ $EVN_UL == "$NA_UL" ]] || FEATURE_DEVS+=("${VLAN_NS:-$NA_ROOT}:$NA_UL")
[[ $DIRECT == 1 ]] || FEATURE_DEVS+=("$EVN:$EVN_UL")
FEATURE_DEVS+=("$EVN:vxgso-test")
[[ $DIRECT == 1 ]] || ip -n "$NA_ROOT" link set "$EVN_UL" netns "$EVN"
[[ -z $VLAN_NS ]] || ip netns exec "$VLAN_NS" ethtool -K vlan444 sg "$VLAN_SG"
ip -n "$EVN" link set "$EVN_UL" mtu 9000 up
ip -n "$EVN" addr add "$ME/24" dev "$EVN_UL"
CSUMOPT=udpcsum
[[ $VXLAN_UDPCSUM == 1 ]] || CSUMOPT=noudpcsum
ip -n "$EVN" link add vxgso-test type vxlan id 100 local "$ME" remote "$COMPUTE" \
    dev "$EVN_UL" dstport 4789 $CSUMOPT
ip -n "$EVN" addr add "$GW/30" dev vxgso-test
ip -n "$EVN" link set vxgso-test mtu 8950 up
ip netns exec "$EVN" ethtool -K vxgso-test tso "$VXLAN_TSO"
ip netns exec "$EVN" sysctl -qw net.ipv4.ip_forward=1
ip netns exec "$EVN" sysctl -qw net.ipv4.conf.all.rp_filter=0
ip netns exec "$EVN" sysctl -qw "net.ipv4.conf.$EVN_UL.rp_filter=0"
ip netns exec "$EVN" sysctl -qw net.ipv4.conf.vxgso-test.rp_filter=0
if [[ $TRAFFIC == vm ]]; then
    VM_FLAGS=
    if [[ $VM_NAPI == 1 ]]; then VM_FLAGS=-N; fi
    ip netns exec "$EVN" tapinject -i vmtap0 -c $VM_FLAGS
    ip -n "$EVN" addr add "$VM_GW/24" dev vmtap0
    ip -n "$EVN" link set vmtap0 up
    ip netns exec "$EVN" sysctl -qw net.ipv4.conf.vmtap0.rp_filter=0
    FEATURE_DEVS+=("$EVN:vmtap0")
fi

# Receiver: [VLAN] -> VXLAN bridge -> veth -> separate iperf server namespace.
ip -n "$COMPUTE_NS" link set nic0 mtu 9000 up
CMP_UL=nic0
if [[ $NA_VLAN == 1 ]]; then
    ip -n "$COMPUTE_NS" link add link nic0 name vlan444 type vlan id 444
    ip -n "$COMPUTE_NS" link set vlan444 mtu 9000 up
    CMP_UL=vlan444
fi
ip -n "$COMPUTE_NS" addr add "$COMPUTE/24" dev "$CMP_UL"
ip -n "$COMPUTE_NS" link set nic0 gso_max_size "$SOURCE_GSO_SIZE"
ip -n "$COMPUTE_NS" link set "$CMP_UL" gso_max_size "$SOURCE_GSO_SIZE"
ip -n "$COMPUTE_NS" link add br-vxgso type bridge
ip -n "$COMPUTE_NS" link set br-vxgso mtu 8950 up
ip -n "$COMPUTE_NS" link add vxgso-rx type vxlan id 100 local "$COMPUTE" remote "$ME" \
    dev "$CMP_UL" dstport 4789 $CSUMOPT
ip -n "$COMPUTE_NS" link set vxgso-rx mtu 8950 master br-vxgso
ip -n "$COMPUTE_NS" link set vxgso-rx up
ip -n "$COMPUTE_NS" link add veth-vxgso type veth peer name eth0 netns "$SERVER_NS"
ip -n "$COMPUTE_NS" link set veth-vxgso mtu 8950 master br-vxgso
ip -n "$COMPUTE_NS" link set veth-vxgso up
ip -n "$SERVER_NS" link set eth0 mtu 8950 up
ip -n "$SERVER_NS" addr add "$TESTIP/30" dev eth0
ip -n "$SERVER_NS" route add default via "$GW"

# Select the same table as the original compute script; add its implicit rule.
# The server IP belongs to a different netns, so traffic cannot take a local shortcut.
ip -n "$COMPUTE_NS" route add table 444 "$TESTIP/32" via "$ME" dev "$CMP_UL" src "$COMPUTE"
ip -n "$COMPUTE_NS" rule add priority 100 to "$TESTIP/32" lookup 444
ip netns exec "$COMPUTE_NS" ethtool -K nic0 rx "$RX_MODE"
# QEMU's igb model does not honour csum_start for VXLAN-encapsulated frames
# (inner TCP keeps its pseudo-header seed). Receiver TX checksum is not under test.
if [[ $UNDERLAY == igb ]]; then
    ip netns exec "$COMPUTE_NS" ethtool -K nic0 tx "${COMPUTE_TX:-off}" gro "$COMPUTE_GRO"
fi

for ns in "$FABRIC" "$NA_ROOT" "$EVN" "$COMPUTE_NS" "$SERVER_NS"; do
    {
        ip -n "$ns" -d link show
        ip -n "$ns" addr show
        ip -n "$ns" route show table all
        ip -n "$ns" rule show
    } >"$OUT/$ns-topology.txt"
done

# Emulated NICs take a moment to report link; KVM boots fast enough to race them.
for pair in "${NA_SLAVES[@]/#/$NA_ROOT:}" "$COMPUTE_NS:nic0"; do
    for _ in $(seq 100); do
        [[ $(ip netns exec "${pair%%:*}" cat "/sys/class/net/${pair#*:}/carrier" 2>/dev/null) == 1 ]] && break
        sleep 0.1
    done
done
ip netns exec "$COMPUTE_NS" ping -c 3 -W 3 "$ME" >"$OUT/underlay-ping.txt" ||
    ip netns exec "$COMPUTE_NS" ping -c 1 -W 3 "$ME" >>"$OUT/underlay-ping.txt"
ip netns exec "$EVN" ping -c 1 -W 3 "$TESTIP" >"$OUT/overlay-ping.txt"
ip -n "$COMPUTE_NS" route get "$TESTIP" from "$COMPUTE" >"$OUT/client-route.txt"
# Whole client -> NA -> VXLAN -> server path, small and jumbo (diagnostic only).
for size in 56 1400 8000; do
    ip netns exec "$COMPUTE_NS" ping -c 2 -W 3 -s "$size" -I "$COMPUTE" "$TESTIP" 2>&1 |
        sed "s/^/[path-ping $size] /" || true
done | tee "$OUT/path-ping.txt"
ip netns exec "$SERVER_NS" iperf3 -s -B "$TESTIP" -p "$PORT" >"$OUT/server.log" 2>&1 &
SERVER_PID=$!
sleep 1
kill -0 "$SERVER_PID"

udp_counter() {   # udp_counter <netns> <field>: one "Udp:" field from /proc/net/snmp
    ip netns exec "$1" awk -v want="$2" '
        /^Udp:/ && !header { for(i=2;i<=NF;i++) if($i==want) col=i; header=1; next }
        /^Udp:/ && header { if(col) print $col; else exit 1; found=1; exit }
        END { if(!found) exit 1 }
    ' /proc/net/snmp
}
csum_errors() { udp_counter "$COMPUTE_NS" InCsumErrors; }
# Inner UDP (BURST_PROTO=udp) ends at the server: nothing listens, so it shows up as NoPorts.
inner_udp() { echo "$(udp_counter "$SERVER_NS" InCsumErrors) $(( $(udp_counter "$SERVER_NS" NoPorts) + $(udp_counter "$SERVER_NS" InDatagrams) ))"; }

if [[ $TRACE == 1 ]]; then
    [[ -e $TRACEFS/function_profile_enabled ]] || mount -t tracefs nodev "$TRACEFS" 2>/dev/null || true
    if [[ -e $TRACEFS/function_profile_enabled ]]; then
        for f in $TRACE_FUNCS; do echo "$f" >>"$TRACEFS/set_ftrace_filter" || echo "WARN: cannot trace $f"; done
    else
        echo "WARN: function profiler unavailable"; TRACE=0
    fi
fi

printf 'kernel\tunderlay\tbond\ttransit_mtu\tgso_max_segs\ttx_csum\trx_csum\tUdpInCsumErrors\tiperf_rc\tstatus\tinner_udp_csum_errors\tinner_udp_delivered\n' >"$OUT/summary.tsv"
for tx in $TX_MODES; do
    [[ $tx == on || $tx == off ]] || { echo "Invalid TX_MODES" >&2; exit 1; }
    # Change only this lab's sender underlay veth. VLAN/macvlan inherit features.
    for dev in "${NA_SLAVES[@]}"; do
        ip netns exec "$NA_ROOT" ethtool -K "$dev" tx "$tx"
        [[ -z $NIC_K ]] || ip netns exec "$NA_ROOT" ethtool -K "$dev" $NIC_K
    done
    [[ -z $VLAN_NS ]] || ip netns exec "$VLAN_NS" ethtool -K vlan444 sg "$VLAN_SG"
    for segs in $SEGS; do
        [[ $segs =~ ^[0-9]+$ ]] && (( segs >= 1 && segs <= 65535 )) || {
            echo "Invalid SEGS: $segs" >&2; exit 1;
        }
        ip -n "$EVN" link set vxgso-test gso_max_segs "$segs"
        label="gso${segs}-tx${tx}-rx${RX_MODE}"
        {
            for pair in "${FEATURE_DEVS[@]}" "$COMPUTE_NS:nic0"; do
                echo "$pair"
                ip netns exec "${pair%%:*}" ethtool -k "${pair#*:}"
            done
            ip -n "$EVN" -d link show vxgso-test
        } >"$OUT/$label-features.txt"
        CAPTURE_PID=
        if [[ $CAPTURE == 1 ]] && command -v tcpdump >/dev/null; then
            ip netns exec "$COMPUTE_NS" tcpdump -Z root -n -i "$CMP_UL" -s 0 -U \
                -w "$OUT/$label.pcap" ${CAPTURE_FILTER:-'udp dst port 4789'} >"$OUT/$label-capture.log" 2>&1 &
            CAPTURE_PID=$!
            sleep 0.3
            kill -0 "$CAPTURE_PID"
        fi
        if [[ $TRACE == 1 ]]; then
            echo 0 >"$TRACEFS/function_profile_enabled"
            echo 1 >"$TRACEFS/function_profile_enabled"
        fi
        before=$(csum_errors)
        read -r inner_err0 inner_rx0 <<<"$(inner_udp)"
        rc=0
        if [[ $TRAFFIC == vm ]]; then
            tap_mac=$(ip netns exec "$EVN" cat /sys/class/net/vmtap0/address)
            ip netns exec "$EVN" timeout 300 tapinject -i vmtap0 -s "$VM_IP" -d "$TESTIP" -m "$tap_mac" \
                $VM_FLAGS $([[ $VM_TSO == 1 ]] && echo -G) -n "$BURST_SEGS" -b "$BURST_COUNT" \
                >"$OUT/$label-vm.log" 2>&1 || rc=$?
            cat "$OUT/$label-vm.log"
            sleep 1
        elif [[ $TRAFFIC == burst ]]; then
            na_mac=$(ip -n "$COMPUTE_NS" neigh show "$ME" dev "$CMP_UL" | awk '{print $3; exit}')
            ip netns exec "$COMPUTE_NS" timeout 300 burst -i "$CMP_UL" -s "$COMPUTE" -d "$TESTIP" \
                -m "$na_mac" -n "$BURST_SEGS" -b "$BURST_COUNT" -l "$BURST_LEN" \
                $([[ $BURST_PROTO == udp ]] && echo -u) \
                >"$OUT/$label-burst.log" 2>&1 || rc=$?
            cat "$OUT/$label-burst.log"
            sleep 1
        else
        # Exactly the original generator: -P 4 -M 1200 -Z -t 10 --json by default.
        ip netns exec "$COMPUTE_NS" timeout "$((DURATION + 20))" \
            iperf3 -c "$TESTIP" -B "$COMPUTE" -p "$PORT" \
            -P "$PARALLEL" -M "$MSS" -Z -t "$DURATION" --json \
            >"$OUT/$label-iperf.json" 2>"$OUT/$label-iperf.stderr" || rc=$?
        fi
        after=$(csum_errors)
        read -r inner_err1 inner_rx1 <<<"$(inner_udp)"
        for ns in "$NA_ROOT" "$EVN" "$COMPUTE_NS" "$SERVER_NS"; do
            echo "== $ns"
            ip netns exec "$ns" cat /proc/net/snmp /proc/net/netstat
            ip -n "$ns" -s link
        done >"$OUT/$label-counters.txt" 2>&1
        if [[ $TRACE == 1 ]]; then
            cat "$TRACEFS"/trace_stat/function* >"$OUT/$label-fprofile.txt" 2>/dev/null || true
            echo "VXGSO_FPROFILE $label"
            awk '$1 != "Function" && $1 !~ /^-/ && NF >= 2 { n[$1] += $2 }
                 END { for (f in n) printf "  %-28s %d\n", f, n[f] }' "$OUT/$label-fprofile.txt"
        fi
        delta=$((after - before))
        if [[ -n $CAPTURE_PID ]]; then
            kill -INT "$CAPTURE_PID" 2>/dev/null || true
            wait "$CAPTURE_PID" || true
            CAPTURE_PID=
        fi
        status=NOT_REPRODUCED
        if ((delta > 0)); then status=REPRODUCED; elif ((rc != 0)); then status=INCONCLUSIVE; fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(uname -r)" "$UNDERLAY" "$BOND" "$TRANSIT_MTU" "$segs" "$tx" "$RX_MODE" \
            "$delta" "$rc" "$status" "$((inner_err1 - inner_err0))" "$((inner_rx1 - inner_rx0))" | tee -a "$OUT/summary.tsv"
        if [[ $TRAFFIC == iperf ]]; then
            echo "VXGSO_JSON_BEGIN $label"
            cat "$OUT/$label-iperf.json"
            echo "VXGSO_JSON_END $label"
        fi
    done
done
echo "VXGSO_SUMMARY_BEGIN"
cat "$OUT/summary.tsv"
echo "VXGSO_SUMMARY_END"
echo "Finished. A zero counter means this topology did not reproduce the bug; it does not prove a kernel fix."
