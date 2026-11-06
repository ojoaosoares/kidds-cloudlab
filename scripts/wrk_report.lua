-- wrk_report.lua: Detailed Latency Distribution & Metrics Extractor for KIDDS
-- Emits structured metrics including p50, p75, p90, p95, p99, p99.9, min, avg, and socket errors.

done = function(summary, latency, requests)
    io.write("--- WRK_METRICS_START ---\n")
    local duration_s = summary.duration / 1000000.0
    if duration_s <= 0 then duration_s = 0.001 end

    local rps = summary.requests / duration_s
    local transfer_mb_s = (summary.bytes / (1024.0 * 1024.0)) / duration_s
    local bytes_read_mb = summary.bytes / (1024.0 * 1024.0)

    io.write(string.format("requests_per_sec: %.4f\n", rps))
    io.write(string.format("transfer_per_sec_mb: %.4f\n", transfer_mb_s))
    io.write(string.format("total_requests: %d\n", summary.requests))
    io.write(string.format("duration_s: %.4f\n", duration_s))
    io.write(string.format("bytes_read_mb: %.4f\n", bytes_read_mb))

    -- Latency distribution in milliseconds
    io.write(string.format("latency_min_ms: %.4f\n", latency.min / 1000.0))
    io.write(string.format("latency_avg_ms: %.4f\n", latency.mean / 1000.0))
    io.write(string.format("latency_max_ms: %.4f\n", latency.max / 1000.0))
    io.write(string.format("latency_stdev_ms: %.4f\n", latency.stdev / 1000.0))

    io.write(string.format("latency_p50_ms: %.4f\n", latency:percentile(50.0) / 1000.0))
    io.write(string.format("latency_p75_ms: %.4f\n", latency:percentile(75.0) / 1000.0))
    io.write(string.format("latency_p90_ms: %.4f\n", latency:percentile(90.0) / 1000.0))
    io.write(string.format("latency_p95_ms: %.4f\n", latency:percentile(95.0) / 1000.0))
    io.write(string.format("latency_p99_ms: %.4f\n", latency:percentile(99.0) / 1000.0))
    io.write(string.format("latency_p99_9_ms: %.4f\n", latency:percentile(99.9) / 1000.0))

    -- Transport & Socket Errors
    local err_conn = summary.errors.connect or 0
    local err_read = summary.errors.read or 0
    local err_write = summary.errors.write or 0
    local err_timeout = summary.errors.timeout or 0
    local socket_errors = err_conn + err_read + err_write + err_timeout

    io.write(string.format("errors_connect: %d\n", err_conn))
    io.write(string.format("errors_read: %d\n", err_read))
    io.write(string.format("errors_write: %d\n", err_write))
    io.write(string.format("errors_timeout: %d\n", err_timeout))
    io.write(string.format("socket_errors: %d\n", socket_errors))

    local total_attempts = summary.requests + socket_errors
    local success_rate_pct = 100.0
    if total_attempts > 0 then
        success_rate_pct = (summary.requests / total_attempts) * 100.0
    end
    io.write(string.format("success_rate_pct: %.4f\n", success_rate_pct))
    io.write("--- WRK_METRICS_END ---\n")
end
