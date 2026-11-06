#!/bin/bash
# ==============================================================================
# run_stress_curve.sh: Stress Curve Experiment Orchestrator for KIDDS
#
# Varies Slowloris attackers: 100, 500, 1000, 2500, 5000 (or custom list)
# Evaluates:
#   1. Baseline (Unprotected / Kernel Forwarding)
#   2. In-Kernel XDP (Stage 1 + Stage 2 BPF)
#   3. AF_XDP Zero-Copy Busy-Polling (Userspace ML Bridge)
#
# Collects:
#   - HTTP Throughput (RPS), Success Rate (%), and Latency quantiles (p50, p95, p99) via wrk_report.lua
#   - Microarchitecture: Cycles/packet, IPC, Cache Miss Rate, Energy/Joules via profile_hardware.py
#   - Generates consolidated CSV and JSON datasets ready for article plotting.
#
# Usage:
#   ./scripts/run_stress_curve.sh [duration_per_step] ["attackers_list"]
# ==============================================================================

set -euo pipefail

DURATION="${1:-30}"
ATTACKERS_LIST="${2:-100 500 1000 2500 5000}"
ATTACK_MODE="${3:-headers}"
ENV_FILE="${HOME}/KIDDS/cloudlab.env"

if [ -f "${ENV_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
else
    echo "ERRO: ${ENV_FILE} nao encontrado. Execute bootstrap.sh primeiro."
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
RESULTS_DIR="${HOME}/KIDDS/results/stress_curve_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${RESULTS_DIR}"

SSH_CLIENT="ssh -o StrictHostKeyChecking=accept-new ${PEER_A_IP}"
SSH_SERVER="ssh -o StrictHostKeyChecking=accept-new ${PEER_B_IP}"

# Distribute wrk_report.lua and slowloris_suite.py to client
scp -o StrictHostKeyChecking=accept-new "${SCRIPT_DIR}/wrk_report.lua" "${PEER_A_IP}:/tmp/wrk_report.lua" >/dev/null 2>&1 || true
scp -o StrictHostKeyChecking=accept-new "${SCRIPT_DIR}/slowloris_suite.py" "${PEER_A_IP}:/tmp/slowloris_suite.py" >/dev/null 2>&1 || true

source "${SCRIPT_DIR}/bench_env.sh"
bench_env_setup 0

cleanup() {
    sudo pkill -9 xsk_daemon 2>/dev/null || true
    sudo ip link set dev "${DEV_A}" xdp off 2>/dev/null || true
    sudo ip link set dev "${DEV_B}" xdp off 2>/dev/null || true
    ${SSH_CLIENT} "sudo pkill -9 slowhttptest; sudo pkill -9 wrk" 2>/dev/null || true
}
trap 'cleanup; bench_env_restore' EXIT INT TERM

CSV_OUT="${RESULTS_DIR}/stress_curve_consolidated.csv"
echo "Attackers,Scenario,RPS,SuccessRatePct,LatAvgMs,LatP50Ms,LatP95Ms,LatP99Ms,CyclesPerPkt,IPC,CacheMissPct,PowerWatts,JoulesPerMPkt,ProcLatNs" > "${CSV_OUT}"

echo "======================================================================"
echo "          INICIANDO CURVA DE SATURACAO DO KIDDS (STRESS CURVE)        "
echo "======================================================================"
echo "Atacantes a testar: ${ATTACKERS_LIST}"
echo "Duracao de cada rodada: ${DURATION}s"
echo "Saida consolidada: ${CSV_OUT}"
echo "======================================================================"

for ATTACKERS in ${ATTACKERS_LIST}; do
    echo ""
    echo "######################################################################"
    echo ">>> NIVEL DE ESTRESSE: ${ATTACKERS} ATACANTES SLOWLORIS SIMULTANEOS <<<"
    echo "######################################################################"

    for SCENARIO in baseline xdp afxdp; do
        echo ""
        echo "--> [Atacantes: ${ATTACKERS}] Cenário: ${SCENARIO}"
        cleanup
        sleep 2

        # 1. Configura middlebox
        if [ "${SCENARIO}" = "xdp" ]; then
            echo "[KIDDS] Anexando XDP In-Kernel em ${DEV_A}..."
            sudo xdp-loader load -m native "${DEV_A}" "${HOME}/KIDDS/bin/xdp_flow_tracker.o" -s slowloris 2>/dev/null || \
            sudo ip link set dev "${DEV_A}" xdpgeneric obj "${HOME}/KIDDS/bin/xdp_flow_tracker.o" sec slowloris
        elif [ "${SCENARIO}" = "afxdp" ]; then
            echo "[KIDDS] Iniciando AF_XDP Zero-Copy Busy-Polling Bridge..."
            sudo "${HOME}/KIDDS/bin/xsk_daemon" \
                --mode bridge \
                --dev-a "${DEV_A}" \
                --dev-b "${DEV_B}" \
                --model slowloris \
                --peer-a "${PEER_A_MAC}" \
                --peer-b "${PEER_B_MAC}" > "${RESULTS_DIR}/afxdp_${ATTACKERS}.log" 2>&1 &
            sleep 2
        else
            echo "[KIDDS] Baseline ativo (roteamento limpo de kernel)."
        fi

        # 2. Inicia ataque no Cliente conforme o modo selecionado
        echo "[CLIENT] Disparando ataque Slow HTTP (${ATTACK_MODE}) com ${ATTACKERS} conexoes..."
        case "${ATTACK_MODE}" in
            body|rudy)
                ${SSH_CLIENT} "nohup slowhttptest -c ${ATTACKERS} -B -g -i 5 -r 200 -t POST -u http://${SERVER_IP}:80/ -s 1000000 -l $((DURATION + 5)) > /dev/null 2>&1 &"
                ;;
            read)
                ${SSH_CLIENT} "nohup slowhttptest -c ${ATTACKERS} -X -g -i 5 -r 200 -t GET -u http://${SERVER_IP}:80/large.bin -l $((DURATION + 5)) > /dev/null 2>&1 &"
                ;;
            mixed)
                local half=$((ATTACKERS / 2))
                ${SSH_CLIENT} "nohup slowhttptest -c ${half} -H -g -i 5 -r 200 -t GET -u http://${SERVER_IP}:80/ -l $((DURATION + 5)) > /dev/null 2>&1 &"
                ${SSH_CLIENT} "nohup slowhttptest -c ${half} -B -g -i 5 -r 200 -t POST -u http://${SERVER_IP}:80/ -s 1000000 -l $((DURATION + 5)) > /dev/null 2>&1 &"
                ;;
            stealth)
                ${SSH_CLIENT} "nohup python3 /tmp/slowloris_suite.py ${SERVER_IP} -p 80 -m stealth -s ${ATTACKERS} -i 6 -d $((DURATION + 5)) > /dev/null 2>&1 &"
                ;;
            headers|*)
                ${SSH_CLIENT} "nohup slowhttptest -c ${ATTACKERS} -H -g -i 5 -r 200 -t GET -u http://${SERVER_IP}:80/ -x 24 -p 3 -l $((DURATION + 5)) > /dev/null 2>&1 &"
                ;;
        esac
        sleep 3

        # 3. Dispara perfilador de hardware em paralelo com a carga legítima do wrk
        local_step_json="${RESULTS_DIR}/hw_${SCENARIO}_${ATTACKERS}.json"
        local_step_csv="${RESULTS_DIR}/hw_${SCENARIO}_${ATTACKERS}.csv"
        client_wrk_log="${RESULTS_DIR}/wrk_${SCENARIO}_${ATTACKERS}.log"

        echo "[KIDDS] Perfilando ciclos de CPU, IPC e energia..."
        sudo python3 "${SCRIPT_DIR}/profile_hardware.py" \
            --duration "${DURATION}" \
            --iface "${DEV_A}" \
            --output-json "${local_step_json}" \
            --output-csv "${local_step_csv}" > /dev/null 2>&1 &
        HW_PID=$!

        echo "[CLIENT] Gerando carga legitima com wrk (-s wrk_report.lua)..."
        ${SSH_CLIENT} "wrk -s /tmp/wrk_report.lua -t4 -c200 -d${DURATION}s http://${SERVER_IP}:80/" > "${client_wrk_log}" 2>&1 || true

        wait ${HW_PID} 2>/dev/null || true
        ${SSH_CLIENT} "sudo pkill -9 slowhttptest" 2>/dev/null || true

        # 4. Parse e consolidação dos resultados
        python3 - <<EOF
import json, re, csv, os

def parse_wrk(path):
    if not os.path.isfile(path):
        return {}
    res = {}
    with open(path, 'r') as f:
        for line in f:
            m = re.match(r"^([\w_]+):\s+([\d\.]+)", line.strip())
            if m:
                res[m.group(1)] = float(m.group(2))
    return res

def parse_hw(path):
    if not os.path.isfile(path):
        return {}
    with open(path, 'r') as f:
        return json.load(f)

wrk = parse_wrk("${client_wrk_log}")
hw = parse_hw("${local_step_json}")

rps = wrk.get("requests_per_sec", 0.0)
succ = wrk.get("success_rate_pct", 0.0)
lat_avg = wrk.get("latency_avg_ms", 0.0)
lat_p50 = wrk.get("latency_p50_ms", 0.0)
lat_p95 = wrk.get("latency_p95_ms", 0.0)
lat_p99 = wrk.get("latency_p99_ms", 0.0)

cycles_pkt = hw.get("cycles_per_packet", 0.0)
ipc = hw.get("ipc", 0.0)
cache_miss = hw.get("cache_miss_rate_pct", 0.0)
watts = hw.get("avg_power_watts", 0.0)
joules_mpkt = hw.get("joules_per_mpacket", 0.0)

proc_ns = 0.0
if "${SCENARIO}" == "xdp":
    proc_ns = hw.get("ebpf", {}).get("ebpf_avg_proc_ns", 0.0)
elif "${SCENARIO}" == "afxdp":
    proc_ns = hw.get("afxdp", {}).get("eval_latency_ns_avg", 0.0)

row = [
    "${ATTACKERS}", "${SCENARIO}", f"{rps:.2f}", f"{succ:.2f}",
    f"{lat_avg:.2f}", f"{lat_p50:.2f}", f"{lat_p95:.2f}", f"{lat_p99:.2f}",
    f"{cycles_pkt:.2f}", f"{ipc:.3f}", f"{cache_miss:.2f}",
    f"{watts:.2f}", f"{joules_mpkt:.4f}", f"{proc_ns:.1f}"
]

with open("${CSV_OUT}", "a", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(row)

print(f"   [RESULTADO] RPS: {rps:.1f} | Sucesso: {succ:.1f}% | Lat p99: {lat_p99:.2f}ms | Ciclos/Pkt: {cycles_pkt:.1f}")
EOF

    done
done

echo ""
echo "======================================================================"
echo "          CURVA DE SATURACAO CONCLUIDA COM SUCESSO!                   "
echo "======================================================================"
echo "Dataset final consolidado salvo em:"
echo "  -> ${CSV_OUT}"
echo ""
