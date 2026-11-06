#!/bin/bash
# Prepares a CloudLab node for KIDDS benchmark experiments.
#
# Roles:
#   node-setup.sh client
#   node-setup.sh kidds
#   node-setup.sh server
#
# Logs: /local/logs/setup.log
# State: /local/setup-state/done

set -euo pipefail

ROLE="${1:?client, kidds, or server}"
STATE=/local/setup-state
LOGDIR=/local/logs
BASE=/local/tools

mkdir -p "${STATE}" "${LOGDIR}" "${BASE}"
exec >>"${LOGDIR}/setup.log" 2>&1
echo "=== $(date -Is) node-setup ${ROLE} (kernel $(uname -r))"

export DEBIAN_FRONTEND=noninteractive
APT="apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

done_() { touch "${STATE}/$1"; echo "--- stage $1 done"; }
has() { [ -e "${STATE}/$1" ]; }

# 1. Ensure modern HWE Kernel
if ! has kernel; then
    if [ "$(uname -r | cut -d. -f1)" -lt 6 ]; then
        ${APT} update
        ${APT} install linux-generic-hwe-24.04
        echo "--- rebooting into the HWE kernel"
        touch "${STATE}/kernel-installed"
        sync
        reboot
        exit 0
    fi
    done_ kernel
fi

# 2. Base packages required by all nodes
if ! has packages; then
    ${APT} update
    ${APT} install build-essential git clang llvm libelf-dev zlib1g-dev \
        libbpf-dev libssl-dev pkg-config dwarves bison flex \
        "linux-headers-$(uname -r)" "linux-tools-$(uname -r)" linux-tools-common \
        ethtool iproute2 tmux rsync jq curl numactl python3 python3-pip \
        python3-numpy python3-scipy python3-matplotlib net-tools
    systemctl disable --now irqbalance 2>/dev/null || true
    done_ packages
fi

# 3. Role: KIDDS Intermediary Appliance
if [ "${ROLE}" = "kidds" ] && ! has kidds_deps; then
    # Install libxdp
    ${APT} install libxdp-dev libxdp1 xdp-tools || true

    # Middlebox kernel tuning for AF_XDP and XDP line-rate
    cat > /etc/sysctl.d/99-kidds.conf <<EOF
net.ipv4.ip_forward=1
net.core.busy_poll=50
net.core.busy_read=50
kernel.bpf_stats_enabled=1
vm.nr_hugepages=1024
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.core.netdev_max_backlog=250000
net.core.somaxconn=65535
EOF
    sysctl --system || true
    done_ kidds_deps
fi

# 4. Role: Server (Protected Target)
if [ "${ROLE}" = "server" ] && ! has server_deps; then
    ${APT} install nginx
    systemctl stop nginx 2>/dev/null || true

    # Tune server network stack and nginx limits
    cat > /etc/sysctl.d/99-server.conf <<EOF
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=65535
net.core.netdev_max_backlog=250000
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
EOF
    sysctl --system || true

    # Optimized nginx configuration for high concurrency benchmark
    cat > /etc/nginx/sites-available/kidds-bench <<'EOF'
server {
    listen 80 default_server reuseport backlog=65535;
    listen [::]:80 default_server reuseport backlog=65535;
    server_name _;

    access_log off;
    error_log /var/log/nginx/error.log crit;

    location / {
        return 200 "OK - KIDDS Benchmark Backend\n";
        add_header Content-Type text/plain;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/kidds-bench /etc/nginx/sites-enabled/default
    systemctl restart nginx
    done_ server_deps
fi

# 5. Role: Client (Load & Attack Generator)
if [ "${ROLE}" = "client" ] && ! has client_deps; then
    ${APT} install slowhttptest apache2-utils hping3

    # Build wrk and wrk2
    for r in wrk wrk2; do
        repo="https://github.com/wg/wrk.git"
        [ "$r" = "wrk2" ] && repo="https://github.com/giltene/wrk2.git"
        rm -rf "${BASE}/${r}"
        git clone --depth 1 "${repo}" "${BASE}/${r}"
        make -C "${BASE}/${r}" -j"$(nproc)"
        install -m 755 "${BASE}/${r}/wrk" "/usr/local/bin/${r}"
    done

    # Client networking tuning to avoid ephemeral port exhaustion
    cat > /etc/sysctl.d/99-client.conf <<EOF
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.core.somaxconn=65535
EOF
    sysctl --system || true
    done_ client_deps
fi

done_ done
echo "=== $(date -Is) node ${ROLE} ready"
