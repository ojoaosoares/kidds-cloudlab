#!/usr/bin/env python3
"""
Hardware & Performance Profiler for KIDDS (CloudLab & Bare-Metal)

Captures:
  - CPU cycles, instructions, IPC (Instructions Per Cycle)
  - Cache misses & references (LLC, L1-dcache)
  - RAPL energy / Joules (via perf power/energy-pkg/ if available)
  - Network PPS (packets/sec), Gbps line-rate, and dropped frames
  - Cycles per packet: (cycles / total_rx_packets)
  - Sub-microsecond packet processing latency (eBPF run_time_ns & AF_XDP JSON telemetry)

Usage:
  sudo python3 profile_hardware.py --duration 30 --iface eth1 --output-json result.json --output-csv result.csv
"""

import sys
import os
import time
import subprocess
import argparse
import json
import csv
import re


def read_net_dev(iface):
    """Reads /proc/net/dev for iface, returning (rx_bytes, rx_pkts, rx_drops, tx_bytes, tx_pkts, tx_drops)."""
    try:
        with open("/proc/net/dev", "r") as f:
            for line in f:
                if iface in line:
                    parts = line.strip().split()
                    # format: iface: rx_bytes rx_pkts rx_errs rx_drop ... tx_bytes tx_pkts tx_errs tx_drop
                    # If iface name is attached to first number (e.g. eth0:1234), clean it
                    data = parts[1:] if ":" not in parts[0] else [parts[0].split(":")[1]] + parts[1:]
                    rx_bytes = int(data[0])
                    rx_pkts  = int(data[1])
                    rx_drop  = int(data[3])
                    tx_bytes = int(data[8])
                    tx_pkts  = int(data[9])
                    tx_drop  = int(data[11])
                    return rx_bytes, rx_pkts, rx_drop, tx_bytes, tx_pkts, tx_drop
    except Exception:
        pass
    return 0, 0, 0, 0, 0, 0


def detect_rapl_event():
    """Detects if power/energy-pkg/ perf event is supported."""
    try:
        res = subprocess.run(["perf", "list", "power"], capture_output=True, text=True, check=False)
        if "energy-pkg" in res.stdout:
            return "power/energy-pkg/"
    except Exception:
        pass
    return None


def run_perf_stat(duration, events):
    """Runs perf stat for duration seconds on system-wide (-a) or specified events."""
    cmd = ["perf", "stat", "-a", "-x", ";", "-e", ",".join(events), "--", "sleep", str(duration)]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, check=False)
        return res.stderr
    except Exception as e:
        print(f"[profile_hardware] Warning: perf stat failed: {e}", file=sys.stderr)
        return ""


def parse_perf_output(perf_output):
    """Parses semicolon-delimited perf stat output."""
    stats = {}
    for line in perf_output.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(";")
        if len(parts) >= 3:
            raw_val = parts[0].strip().replace(",", "")
            event_name = parts[2].strip()
            try:
                stats[event_name] = float(raw_val)
            except ValueError:
                pass
    return stats


def get_ebpf_prog_stats(prog_name="xdp_slowloris"):
    """Reads eBPF kernel runtime statistics via bpftool."""
    try:
        res = subprocess.run(["bpftool", "prog", "show", "name", prog_name, "--json"],
                             capture_output=True, text=True, check=False)
        if res.returncode == 0 and res.stdout.strip():
            data = json.loads(res.stdout)
            if isinstance(data, list) and len(data) > 0:
                data = data[0]
            run_time_ns = data.get("run_time_ns", 0)
            run_cnt     = data.get("run_cnt", 0)
            avg_ns = (run_time_ns / run_cnt) if run_cnt > 0 else 0.0
            return {
                "ebpf_run_cnt": run_cnt,
                "ebpf_total_ns": run_time_ns,
                "ebpf_avg_proc_ns": round(avg_ns, 2)
            }
    except Exception:
        pass
    return {"ebpf_run_cnt": 0, "ebpf_total_ns": 0, "ebpf_avg_proc_ns": 0.0}


def get_afxdp_telemetry(json_path="/tmp/kidds_xsk_latency.json"):
    """Reads telemetry dumped by xsk_daemon."""
    if os.path.isfile(json_path):
        try:
            with open(json_path, "r") as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def main():
    parser = argparse.ArgumentParser(description="KIDDS Hardware and Microarchitecture Profiler")
    parser.add_argument("--duration", type=int, default=10, help="Profiling duration in seconds")
    parser.add_argument("--iface", type=str, default="", help="Network interface to monitor")
    parser.add_argument("--output-json", type=str, default="hardware_profile.json", help="Output JSON path")
    parser.add_argument("--output-csv", type=str, default="hardware_profile.csv", help="Output CSV path")
    args = parser.parse_args()

    events = [
        "cycles",
        "instructions",
        "cache-references",
        "cache-misses",
        "L1-dcache-load-misses",
        "context-switches"
    ]
    rapl_event = detect_rapl_event()
    if rapl_event:
        events.append(rapl_event)

    print(f"=== [profile_hardware] Iniciando perfilamento ({args.duration}s em {args.iface or 'todas as interfaces'}) ===")

    # Initial network snapshot
    rx_b0, rx_p0, rx_d0, tx_b0, tx_p0, tx_d0 = (0,0,0,0,0,0)
    if args.iface:
        rx_b0, rx_p0, rx_d0, tx_b0, tx_p0, tx_d0 = read_net_dev(args.iface)

    t_start = time.time()
    perf_raw = run_perf_stat(args.duration, events)
    t_end = time.time()
    actual_duration = max(t_end - t_start, 0.001)

    # Final network snapshot
    rx_b1, rx_p1, rx_d1, tx_b1, tx_p1, tx_d1 = (0,0,0,0,0,0)
    if args.iface:
        rx_b1, rx_p1, rx_d1, tx_b1, tx_p1, tx_d1 = read_net_dev(args.iface)

    total_rx_pkts = max(rx_p1 - rx_p0, 0)
    total_rx_bytes = max(rx_b1 - rx_b0, 0)
    total_rx_drops = max(rx_d1 - rx_d0, 0)
    total_tx_pkts = max(tx_p1 - tx_p0, 0)
    total_tx_bytes = max(tx_b1 - tx_b0, 0)

    throughput_mpps = (total_rx_pkts / actual_duration) / 1e6
    throughput_gbps = (total_rx_bytes * 8 / actual_duration) / 1e9

    perf_stats = parse_perf_output(perf_raw)

    cycles       = perf_stats.get("cycles", 0.0)
    instructions = perf_stats.get("instructions", 0.0)
    cache_refs   = perf_stats.get("cache-references", 0.0)
    cache_misses = perf_stats.get("cache-misses", 0.0)
    l1_misses    = perf_stats.get("L1-dcache-load-misses", 0.0)
    cswitches    = perf_stats.get("context-switches", 0.0)
    energy_j     = perf_stats.get(rapl_event, 0.0) if rapl_event else 0.0

    ipc = (instructions / cycles) if cycles > 0 else 0.0
    cache_miss_pct = ((cache_misses / cache_refs) * 100.0) if cache_refs > 0 else 0.0
    cycles_per_pkt = (cycles / total_rx_pkts) if total_rx_pkts > 0 else 0.0
    joules_per_mpacket = (energy_j / (total_rx_pkts / 1e6)) if total_rx_pkts > 0 and energy_j > 0 else 0.0
    avg_power_watts = (energy_j / actual_duration) if energy_j > 0 else 0.0

    bpf_stats = get_ebpf_prog_stats()
    afxdp_stats = get_afxdp_telemetry()

    summary = {
        "duration_sec": round(actual_duration, 2),
        "interface": args.iface,
        "throughput_mpps": round(throughput_mpps, 4),
        "throughput_gbps": round(throughput_gbps, 4),
        "total_rx_packets": total_rx_pkts,
        "total_rx_bytes": total_rx_bytes,
        "total_rx_dropped": total_rx_drops,
        "total_tx_packets": total_tx_pkts,
        "cpu_cycles": int(cycles),
        "cpu_instructions": int(instructions),
        "ipc": round(ipc, 3),
        "cycles_per_packet": round(cycles_per_pkt, 2),
        "cache_miss_rate_pct": round(cache_miss_pct, 2),
        "cache_misses": int(cache_misses),
        "l1_dcache_misses": int(l1_misses),
        "context_switches": int(cswitches),
        "energy_joules": round(energy_j, 2),
        "avg_power_watts": round(avg_power_watts, 2),
        "joules_per_mpacket": round(joules_per_mpacket, 4),
        "ebpf": bpf_stats,
        "afxdp": afxdp_stats
    }

    # Write JSON
    with open(args.output_json, "w") as f:
        json.dump(summary, f, indent=2)

    # Write CSV
    with open(args.output_csv, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["Metric", "Value", "Unit"])
        writer.writerow(["Throughput", f"{throughput_mpps:.4f}", "Mpps"])
        writer.writerow(["Bandwidth", f"{throughput_gbps:.4f}", "Gbps"])
        writer.writerow(["Total RX Packets", total_rx_pkts, "packets"])
        writer.writerow(["Total RX Dropped", total_rx_drops, "packets"])
        writer.writerow(["Cycles / Packet", f"{cycles_per_pkt:.2f}", "cycles/pkt"])
        writer.writerow(["IPC", f"{ipc:.3f}", "insn/cycle"])
        writer.writerow(["Cache Miss Rate", f"{cache_miss_pct:.2f}", "%"])
        if avg_power_watts > 0:
            writer.writerow(["Average Power", f"{avg_power_watts:.2f}", "Watts"])
            writer.writerow(["Energy per Mpps", f"{joules_per_mpacket:.4f}", "Joules/Mpacket"])
        if bpf_stats.get("ebpf_avg_proc_ns", 0) > 0:
            writer.writerow(["eBPF Avg Packet Latency", bpf_stats["ebpf_avg_proc_ns"], "ns"])
        if "eval_latency_ns_avg" in afxdp_stats:
            writer.writerow(["AF_XDP Avg ML Latency", afxdp_stats["eval_latency_ns_avg"], "ns"])

    print(f"=== [profile_hardware] Resultados salvos em {args.output_json} e {args.output_csv} ===")
    print(f"   Vazao: {throughput_mpps:.3f} Mpps | {throughput_gbps:.3f} Gbps")
    print(f"   Ciclos por Pacote: {cycles_per_pkt:.1f} | IPC: {ipc:.3f}")
    if avg_power_watts > 0:
        print(f"   Potencia Media: {avg_power_watts:.1f} W | {joules_per_mpacket:.3f} J/Mpps")


if __name__ == "__main__":
    main()
