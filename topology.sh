#!/usr/bin/env bash
# KIDDS CloudLab topology script (single client -> kidds -> server -> client)
# Usage: sudo ./topology.sh up [N_ATTACKERS]   # builds bridge and namespaces
#        sudo ./topology.sh down               # tears everything down

set -euo pipefail

BR=kidds-br
SUBNET=10.77.0
SERVER_IP=$SUBNET.2
KIDDSSERVER_NS=server
KIDDSSERVER_IP=$SERVER_IP
KIDDSSERVER_PEER=v${KIDDSSERVER_NS}p

make_ns() {
    local ns=$1 ip=$2 peer=$3
    ip netns add "$ns"
    ip link add "v${ns}h" type veth peer "${peer}"
    ip link set "v${ns}h" master "$BR"
    ip link set "v${ns}h" up
    ip link set "${peer}" netns "$ns"
    ip netns exec "$ns" ip link set lo up
    ip netns exec "$ns" ip link set "${peer}" name eth0
    ip netns exec "$ns" ip addr add "$ip/24" dev eth0
    ip netns exec "$ns" ip link set eth0 up
    ip netns exec "$ns" sysctl -w net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.eth0.rp_filter=0 net.ipv4.conf.all.accept_local=1 net.ipv4.conf.eth0.accept_local=1 >/dev/null 2>&1 || true
    # client will route via kidds bridge; server has direct route to client via bridge
    ip netns exec "$ns" ip route add default via "$SERVER_IP" >/dev/null 2>&1 || true
}

up() {
    local n_atk=${1:-3}
    ip link add "$BR" type bridge
    ip link set "$BR" up
    # server namespace (kidds sits between client and server)
    make_ns server "$SERVER_IP" "$KIDDSSERVER_PEER"
    # attackers
    for i in $(seq 1 "$n_atk"); do
        make_ns "atk$(printf %02d $i)" "$SUBNET.$((10 + i))" "vatk${i}p"
    done
    # single client (uploads only)
    make_ns cli01 "$SUBNET.101" "vcli01p"
    echo "Topology up: server $SERVER_IP, $n_atk attackers, 1 client (cli01) on $SUBNET.0/24"
}

down() {
    for ns in $(ip netns list | awk '{print $1}' | grep -E '^(server|atk|cli)'); do
        ip netns del "$ns" >/dev/null 2>&1 || true
    done
    ip link del "$BR" >/dev/null 2>&1 || true
    for v in $(ip -o link show | awk -F': ' '/vserverh|vatk|vcli/{print $2}' | cut -d@ -f1); do
        ip link del "$v" >/dev/null 2>&1 || true
    done
    echo down
}

case "${1:-}" in
    up) shift; up "$@" ;;
    down) down ;;
    *) echo "usage: $0 up [n_attackers] | down" >&2; exit 1 ;;
esac
