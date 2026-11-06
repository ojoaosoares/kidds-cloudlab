#!/bin/bash
# Executes comprehensive DDoS / Slowloris comparative benchmark on CloudLab.
#
# Runs across 3 nodes:
#   1. Baseline (Standard Kernel IP Forwarding / No filter)
#   2. In-Kernel XDP Filter (Stage 1 + Stage 2 mitigation)
#   3. AF_XDP Zero-Copy Busy-Polling Bridge (Userspace ML)
#
# Usage:
#   Run directly on the KIDDS intermediary node, or via bootstrap coordinator.
#   ./scripts/run_cloudlab_benchmark.sh [duration_sec]

set -euo pipefail

DURATION="${1:-30}"
ENV_FILE="${HOME}/KIDDS/cloudlab.env"

if [ -f "${ENV_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
else
    echo "ERRO: ${ENV_FILE} nao encontrado. Execute bootstrap.sh primeiro."
    exit 1
fi

RESULTS_DIR="${HOME}/KIDDS/results/cloudlab_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${RESULTS_DIR}"

SSH_CLIENT="ssh -o StrictHostKeyChecking=accept-new ${PEER_A_IP}"
SSH_SERVER="ssh -o StrictHostKeyChecking=accept-new ${PEER_B_IP}"

echo "======================================================================"
echo "         INICIANDO SUITE DE BENCHMARK KIDDS (CLOUDLAB 100G)           "
echo "======================================================================"
echo "Topologia: Client (${PEER_A_IP}) -> KIDDS (${DEV_A}/${DEV_B}) -> Server (${SERVER_IP})"
echo "Duracao de cada cenario: ${DURATION}s"
echo "Diretorio de resultados: ${RESULTS_DIR}"
echo "======================================================================"

cleanup() {
    echo "Limpando processos e desanexando XDP..."
    sudo pkill -9 xsk_daemon 2>/dev/null || true
    sudo ip link set dev "${DEV_A}" xdp off 2>/dev/null || true
    sudo ip link set dev "${DEV_B}" xdp off 2>/dev/null || true
    ${SSH_CLIENT} "sudo pkill -9 slowhttptest; sudo pkill -9 wrk" 2>/dev/null || true
}
trap cleanup EXIT

run_scenario() {
    local SCENARIO_NAME="$1"
    local SCENARIO_KEY="$2"
    echo ""
    echo "----------------------------------------------------------------------"
    echo ">>> Executando Cenario: [${SCENARIO_NAME}]"
    echo "----------------------------------------------------------------------"

    cleanup
    sleep 2

    # Configure middlebox mode
    if [ "${SCENARIO_KEY}" = "xdp" ]; then
        echo "[KIDDS] Anexando filtro eBPF/XDP na interface ${DEV_A}..."
        sudo xdp-loader load -m native "${DEV_A}" "${HOME}/KIDDS/bin/xdp_flow_tracker.o" -s slowloris 2>/dev/null || \
        sudo ip link set dev "${DEV_A}" xdpgeneric obj "${HOME}/KIDDS/bin/xdp_flow_tracker.o" sec slowloris
    elif [ "${SCENARIO_KEY}" = "afxdp" ]; then
        echo "[KIDDS] Iniciando Daemon AF_XDP Zero-Copy Busy-Polling Bridge..."
        sudo "${HOME}/KIDDS/bin/xsk_daemon" \
            --mode bridge \
            --dev-a "${DEV_A}" \
            --dev-b "${DEV_B}" \
            --model slowloris \
            --peer-a "${PEER_A_MAC}" \
            --peer-b "${PEER_B_MAC}" > "${RESULTS_DIR}/afxdp_daemon.log" 2>&1 &
        sleep 2
    else
        echo "[KIDDS] Modo Baseline: Encaminhamento padrao de kernel ativo."
    fi

    # Start CPU and Telemetry monitoring on KIDDS
    mpstat -P ALL 1 "${DURATION}" > "${RESULTS_DIR}/cpu_${SCENARIO_KEY}.log" 2>&1 &
    local MPSTAT_PID=$!

    # Start Slowloris Attack from Client
    echo "[CLIENT] Disparando ataque Slowloris..."
    ${SSH_CLIENT} "nohup slowhttptest -c 1000 -H -g -i 5 -r 200 -t GET -u http://${SERVER_IP}:80/ -x 24 -p 3 -l $((DURATION + 5)) > /dev/null 2>&1 &"

    sleep 3

    # Start Legitimate Benchmark from Client
    echo "[CLIENT] Disparando carga legitima com wrk (4 threads, 200 conns, ${DURATION}s)..."
    ${SSH_CLIENT} "wrk -t4 -c200 -d${DURATION}s --latency http://${SERVER_IP}:80/" > "${RESULTS_DIR}/wrk_${SCENARIO_KEY}.log"

    wait ${MPSTAT_PID} 2>/dev/null || true
    ${SSH_CLIENT} "sudo pkill -9 slowhttptest" 2>/dev/null || true

    echo "[KIDDS] Coletando metricas de processamento..."
    if [ "${SCENARIO_KEY}" = "xdp" ]; then
        sudo bpftool prog show name xdp_slowloris > "${RESULTS_DIR}/bpf_stats_${SCENARIO_KEY}.log" 2>/dev/null || true
    elif [ "${SCENARIO_KEY}" = "afxdp" ]; then
        if [ -f "/tmp/kidds_xsk_latency.json" ]; then
            cp /tmp/kidds_xsk_latency.json "${RESULTS_DIR}/afxdp_lat.json"
        fi
    fi
}

# 1. Baseline
run_scenario "Baseline (Sem Filtro / Kernel Forwarding)" "baseline"

# 2. In-Kernel XDP
run_scenario "In-Kernel XDP (Stage 1 + Stage 2 Filter)" "xdp"

# 3. AF_XDP Zero-Copy Busy-Polling
run_scenario "AF_XDP Zero-Copy (Userspace ML Bridge)" "afxdp"

echo ""
echo "======================================================================"
echo "              RESULTADOS CONSOLIDADOS DO BENCHMARK                   "
echo "======================================================================"

python3 - <<EOF
import os, re, sys

results_dir = "${RESULTS_DIR}"

def parse_wrk(logfile):
    if not os.path.isfile(logfile):
        return {"rps": "N/A", "lat_avg": "N/A", "errors": "N/A"}
    with open(logfile, 'r') as f:
        content = f.read()
    rps_match = re.search(r"Requests/sec:\s+([\d\.]+)", content)
    lat_match = re.search(r"Latency\s+([\d\.]+)(\w+)", content)
    err_match = re.search(r"Non-2xx or 3xx responses:\s+(\d+)", content)
    
    rps = rps_match.group(1) if rps_match else "0"
    lat = (lat_match.group(1) + lat_match.group(2)) if lat_match else "N/A"
    err = err_match.group(1) if err_match else "0"
    return {"rps": rps, "lat_avg": lat, "errors": err}

def parse_cpu(logfile):
    if not os.path.isfile(logfile):
        return "N/A"
    idle_vals = []
    with open(logfile, 'r') as f:
        for line in f:
            if "all" in line:
                parts = line.split()
                try:
                    idle_vals.append(float(parts[-1]))
                except ValueError:
                    pass
    if idle_vals:
        avg_idle = sum(idle_vals) / len(idle_vals)
        return f"{100.0 - avg_idle:.1f}%"
    return "N/A"

res_base  = parse_wrk(os.path.join(results_dir, "wrk_baseline.log"))
res_xdp   = parse_wrk(os.path.join(results_dir, "wrk_xdp.log"))
res_afxdp = parse_wrk(os.path.join(results_dir, "wrk_afxdp.log"))

cpu_base  = parse_cpu(os.path.join(results_dir, "cpu_baseline.log"))
cpu_xdp   = parse_cpu(os.path.join(results_dir, "cpu_xdp.log"))
cpu_afxdp = parse_cpu(os.path.join(results_dir, "cpu_afxdp.log"))

print(f"{'Metrica':<30} | {'Baseline':<18} | {'In-Kernel XDP':<18} | {'AF_XDP (Busy-Poll)':<18}")
print("-" * 92)
print(f"{'Requisicoes / seg (RPS)':<30} | {res_base['rps']:<18} | {res_xdp['rps']:<18} | {res_afxdp['rps']:<18}")
print(f"{'Latencia Media HTTP':<30} | {res_base['lat_avg']:<18} | {res_xdp['lat_avg']:<18} | {res_afxdp['lat_avg']:<18}")
print(f"{'Erros / Timeout HTTP':<30} | {res_base['errors']:<18} | {res_xdp['errors']:<18} | {res_afxdp['errors']:<18}")
print(f"{'Uso Médio de CPU':<30} | {cpu_base:<18} | {cpu_xdp:<18} | {cpu_afxdp:<18}")
EOF

echo ""
echo "Relatorio detalhado e logs brutos disponiveis em: ${RESULTS_DIR}"
