#!/bin/bash
# ==============================================================================
# bench_env.sh: Deterministic Hardware & Network Environment for KIDDS
#
# Eliminates run-to-run variance caused by:
#   - CPU frequency scaling (forces 'performance' governor)
#   - Turbo Boost frequency spikes (disables boost on AMD EPYC / Intel Xeon)
#   - Deep CPU sleep states (C-states > 10us disabled to remove tail latency jitter)
#   - irqbalance moving network interrupts across cores
#
# Usage:
#   source scripts/bench_env.sh
#   bench_env_setup [core_id]
#   ... run benchmark ...
#   bench_env_restore
# ==============================================================================

BENCH_STATE_DIR="/tmp/kidds_bench_env_state"

bench_env_setup() {
    local target_core="${1:-0}"
    mkdir -p "${BENCH_STATE_DIR}"
    echo "=== [bench_env] Configurando ambiente deterministico de hardware ==="

    # 1. Stop irqbalance
    if systemctl is-active --quiet irqbalance 2>/dev/null; then
        echo "1" > "${BENCH_STATE_DIR}/had_irqbalance"
        sudo systemctl stop irqbalance 2>/dev/null || true
    fi

    # 2. Set CPU Governor to performance
    if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
        for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            [ -f "${gov}" ] || continue
            local cpu_id
            cpu_id=$(basename "$(dirname "$(dirname "${gov}")")")
            cat "${gov}" > "${BENCH_STATE_DIR}/${cpu_id}_gov" 2>/dev/null || true
            echo "performance" | sudo tee "${gov}" >/dev/null 2>&1 || true
        done
        echo "   -> CPU Governors travados em 'performance'"
    fi

    # 3. Disable Turbo Boost (AMD EPYC / Intel Xeon)
    if [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
        cat /sys/devices/system/cpu/cpufreq/boost > "${BENCH_STATE_DIR}/amd_boost" 2>/dev/null || true
        echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost >/dev/null 2>&1 || true
        echo "   -> AMD Turbo Boost desligado"
    elif [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        cat /sys/devices/system/cpu/intel_pstate/no_turbo > "${BENCH_STATE_DIR}/intel_no_turbo" 2>/dev/null || true
        echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null 2>&1 || true
        echo "   -> Intel Turbo Boost desligado"
    fi

    # 4. Disable Deep C-States (> 10us exit latency)
    for idle_dir in /sys/devices/system/cpu/cpu*/cpuidle/state*; do
        [ -d "${idle_dir}" ] || continue
        if [ -f "${idle_dir}/latency" ] && [ -f "${idle_dir}/disable" ]; then
            local lat
            lat=$(cat "${idle_dir}/latency" 2>/dev/null || echo 0)
            if [ "${lat}" -gt 10 ]; then
                local state_key
                state_key=$(echo "${idle_dir}" | tr '/' '_')
                cat "${idle_dir}/disable" > "${BENCH_STATE_DIR}/${state_key}" 2>/dev/null || true
                echo 1 | sudo tee "${idle_dir}/disable" >/dev/null 2>&1 || true
            fi
        fi
    done
    echo "   -> C-states profundos (>10us) desativados para eliminar jitter de cauda"

    # 5. Kernel busy polling & BPF stats
    sudo sysctl -w net.core.busy_poll=50 net.core.busy_read=50 kernel.bpf_stats_enabled=1 >/dev/null 2>&1 || true
    echo "   -> Busy polling e estatisticas de eBPF ativadas no kernel"
}

bench_env_restore() {
    echo "=== [bench_env] Restaurando configuracoes de hardware ==="
    [ -d "${BENCH_STATE_DIR}" ] || return 0

    # 1. Restore irqbalance
    if [ -f "${BENCH_STATE_DIR}/had_irqbalance" ]; then
        sudo systemctl start irqbalance 2>/dev/null || true
    fi

    # 2. Restore governors
    for gov_file in "${BENCH_STATE_DIR}"/cpu*_gov; do
        [ -f "${gov_file}" ] || continue
        local cpu_id
        cpu_id=$(basename "${gov_file}" _gov)
        local orig_gov
        orig_gov=$(cat "${gov_file}")
        echo "${orig_gov}" | sudo tee "/sys/devices/system/cpu/${cpu_id}/cpufreq/scaling_governor" >/dev/null 2>&1 || true
    done

    # 3. Restore Turbo
    if [ -f "${BENCH_STATE_DIR}/amd_boost" ]; then
        cat "${BENCH_STATE_DIR}/amd_boost" | sudo tee /sys/devices/system/cpu/cpufreq/boost >/dev/null 2>&1 || true
    elif [ -f "${BENCH_STATE_DIR}/intel_no_turbo" ]; then
        cat "${BENCH_STATE_DIR}/intel_no_turbo" | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null 2>&1 || true
    fi

    # 4. Restore C-states
    for state_file in "${BENCH_STATE_DIR}"/_sys_devices_system_cpu_*; do
        [ -f "${state_file}" ] || continue
        local orig_val
        orig_val=$(cat "${state_file}")
        local orig_path
        orig_path=$(basename "${state_file}" | tr '_' '/')
        echo "${orig_val}" | sudo tee "/${orig_path}" >/dev/null 2>&1 || true
    done

    rm -rf "${BENCH_STATE_DIR}"
    echo "   -> Restauracao concluida com sucesso."
}
