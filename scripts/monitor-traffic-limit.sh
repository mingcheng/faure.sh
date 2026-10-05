#!/usr/bin/env bash
# Copyright (c) 2025 mingcheng <mingcheng@apache.org>
#
# Monitor network traffic for a specific interface and take action if limits are exceeded.
# Features:
# - Monthly traffic reset
# - Warning threshold
# - Blocking internet access when limit exceeded
#
# Usage: ./monitor-traffic-limit.sh <interface> <limit_gb> [warning_percent] [alert_script]
# Example: ./monitor-traffic-limit.sh eth0 1000 80 /path/to/alert.sh
#
# The alert script (if executable) is called as:
#   <alert_script> <WARNING|BLOCK> <interface> <usage_gb> <limit_gb>
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: monitor-traffic-limit.sh
# Author: mingcheng <mingcheng@apache.org>
#
# Modified By: mingcheng <mingcheng@apache.org>
# Last Modified: 2026-10-05 10:00:00
##

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$SCRIPT_DIR/utils.sh"

# --- Configuration ---
IFACE="${1:-}"
LIMIT_GB="${2:-}"
WARNING_PERCENT="${3:-80}"
ALERT_SCRIPT="${4:-}"
BYTES_PER_GB=1073741824

# --- Validation ---
if [ -z "$IFACE" ] || [ -z "$LIMIT_GB" ]; then
    echo "Usage: $0 <interface> <limit_gb> [warning_percent] [alert_script]"
    exit 1
fi

# IFACE is used to build file paths below, so reject anything but a name.
if ! [[ $IFACE =~ ^[A-Za-z0-9_.:@-]+$ ]] || [ "$IFACE" = "." ] || [ "$IFACE" = ".." ] \
    || [ ! -d "/sys/class/net/$IFACE" ]; then
    log_error "Interface '$IFACE' not found."
    exit 1
fi

if ! [[ $LIMIT_GB =~ ^[0-9]+$ ]] || ! [[ $WARNING_PERCENT =~ ^[0-9]+$ ]]; then
    log_error "limit_gb and warning_percent must be non-negative integers."
    exit 1
fi

STATE_DIR="/var/lib/faure/traffic"
STATE_FILE="$STATE_DIR/${IFACE}.state"
LOCK_FILE="/run/traffic_monitor_${IFACE}.lock"

mkdir -p "$STATE_DIR"

# --- Helper Functions ---

# Current RX + TX byte counters of $IFACE (reset on reboot).
get_bytes() {
    local rx tx
    rx=$(cat "/sys/class/net/$IFACE/statistics/rx_bytes")
    tx=$(cat "/sys/class/net/$IFACE/statistics/tx_bytes")
    echo "$((rx + tx))"
}

# Print this month's RX + TX bytes for $IFACE from vnStat. Returns 1 when
# vnStat (or its data for $IFACE) is unavailable.
get_vnstat_bytes() {
    command -v vnstat >/dev/null 2>&1 || return 1

    local json bytes
    # vnStat 2.x JSON (jsonversion 2) reports plain bytes.
    if command -v jq >/dev/null 2>&1 && json=$(LC_ALL=C vnstat --json m -i "$IFACE" 2>/dev/null); then
        bytes=$(jq -r --argjson y "$(date +%Y)" --argjson m "$(date +%-m)" '
            .interfaces[0].traffic.month[]?
            | select(.date.year == $y and .date.month == $m) | .rx + .tx
        ' <<<"$json" 2>/dev/null)
        if [[ $bytes =~ ^[0-9]+$ ]]; then
            echo "$bytes"
            return 0
        fi
    fi

    # Fallback: --oneline field 11 is the current month's total, e.g. "10.50 GiB".
    local output
    output=$(LC_ALL=C vnstat -i "$IFACE" --oneline 2>/dev/null) || return 1
    [ -n "$output" ] || return 1
    echo "$output" | cut -d';' -f11 | awk '
        {
            v = $1; u = $2
            if (u == "KiB") v *= 1024; else if (u == "MiB") v *= 1024^2
            else if (u == "GiB") v *= 1024^3; else if (u == "TiB") v *= 1024^4
            else if (u == "KB") v *= 1000; else if (u == "MB") v *= 1000^2
            else if (u == "GB") v *= 1000^3; else if (u == "TB") v *= 1000^4
            printf "%.0f\n", v
        }'
}

# Docker compatibility: these rules are intentionally inserted at the TOP of
# the builtin FORWARD chain so they preempt the jump to DOCKER-USER. Once the
# cap is hit we want to stop ALL forwarded traffic for that uplink,
# including container egress.
block_interface() {
    log_info "Blocking internet access for $IFACE..."
    iptables -C FORWARD -i "$IFACE" -j DROP 2>/dev/null || iptables -I FORWARD -i "$IFACE" -j DROP
    iptables -C FORWARD -o "$IFACE" -j DROP 2>/dev/null || iptables -I FORWARD -o "$IFACE" -j DROP
    run_alert "BLOCK"
}

unblock_interface() {
    log_info "Unblocking internet access for $IFACE..."
    while iptables -D FORWARD -i "$IFACE" -j DROP 2>/dev/null; do :; done
    while iptables -D FORWARD -o "$IFACE" -j DROP 2>/dev/null; do :; done
}

send_warning() {
    log_warn "Traffic usage for $IFACE is at or above ${WARNING_PERCENT}% ($CURRENT_USAGE_GB GB / $LIMIT_GB GB)"
    run_alert "WARNING"
}

run_alert() {
    if [ -n "$ALERT_SCRIPT" ] && [ -x "$ALERT_SCRIPT" ]; then
        "$ALERT_SCRIPT" "$1" "$IFACE" "$CURRENT_USAGE_GB" "$LIMIT_GB" || log_warn "Alert script exited non-zero."
    fi
}

# --- Main Logic ---

# Prevent concurrent runs for the same interface.
exec 9>"$LOCK_FILE"
flock -n 9 || {
    log_warn "Another instance is already running for $IFACE."
    exit 1
}

CURRENT_BYTES=$(get_bytes)
CURRENT_MONTH=$(date +%Y-%m)

# State file format: MONTH LAST_BYTES ACCUMULATED_BYTES BLOCKED_STATUS WARNING_SENT
STORED_MONTH="" LAST_BYTES="" ACCUMULATED_BYTES="" BLOCKED_STATUS="" WARNING_SENT=""
if [ -f "$STATE_FILE" ]; then
    read -r STORED_MONTH LAST_BYTES ACCUMULATED_BYTES BLOCKED_STATUS WARNING_SENT <"$STATE_FILE"
fi
# Fall back to fresh values for a missing or corrupted state file.
[[ $STORED_MONTH =~ ^[0-9]{4}-[0-9]{2}$ ]] || STORED_MONTH="$CURRENT_MONTH"
[[ $LAST_BYTES =~ ^[0-9]+$ ]] || LAST_BYTES="$CURRENT_BYTES"
[[ $ACCUMULATED_BYTES =~ ^[0-9]+$ ]] || ACCUMULATED_BYTES=0
[[ $BLOCKED_STATUS =~ ^[01]$ ]] || BLOCKED_STATUS=0
[[ $WARNING_SENT =~ ^[01]$ ]] || WARNING_SENT=0

if [ "$CURRENT_MONTH" != "$STORED_MONTH" ]; then
    log_info "New month detected. Resetting counters for $IFACE."
    STORED_MONTH="$CURRENT_MONTH"
    ACCUMULATED_BYTES=0
    LAST_BYTES="$CURRENT_BYTES"
    BLOCKED_STATUS=0
    WARNING_SENT=0
    unblock_interface
fi

if VNSTAT_BYTES=$(get_vnstat_bytes) && [[ $VNSTAT_BYTES =~ ^[0-9]+$ ]]; then
    ACCUMULATED_BYTES="$VNSTAT_BYTES"
else
    # Internal accounting: a counter that went backwards means a reboot or
    # a re-created interface, so count from zero.
    if [ "$CURRENT_BYTES" -lt "$LAST_BYTES" ]; then
        DELTA="$CURRENT_BYTES"
    else
        DELTA=$((CURRENT_BYTES - LAST_BYTES))
    fi
    ACCUMULATED_BYTES=$((ACCUMULATED_BYTES + DELTA))
fi
# Always track the raw counter so a later vnStat outage resumes cleanly.
LAST_BYTES="$CURRENT_BYTES"

CURRENT_USAGE_GB=$(awk -v b="$ACCUMULATED_BYTES" -v g="$BYTES_PER_GB" 'BEGIN { printf "%.2f", b / g }')
LIMIT_BYTES=$((LIMIT_GB * BYTES_PER_GB))
WARNING_BYTES=$((LIMIT_BYTES / 100 * WARNING_PERCENT))

if [ "$ACCUMULATED_BYTES" -ge "$LIMIT_BYTES" ]; then
    if [ "$BLOCKED_STATUS" -eq 0 ]; then
        log_warn "Limit exceeded ($CURRENT_USAGE_GB GB >= $LIMIT_GB GB). Initiating block."
        block_interface
        BLOCKED_STATUS=1
    fi
else
    if [ "$ACCUMULATED_BYTES" -ge "$WARNING_BYTES" ] && [ "$WARNING_SENT" -eq 0 ]; then
        send_warning
        WARNING_SENT=1
    fi
    # Below the cap (e.g. limit raised manually): lift any previous block.
    if [ "$BLOCKED_STATUS" -eq 1 ]; then
        unblock_interface
        BLOCKED_STATUS=0
    fi
fi

echo "$STORED_MONTH $LAST_BYTES $ACCUMULATED_BYTES $BLOCKED_STATUS $WARNING_SENT" >"$STATE_FILE"

echo "Interface: $IFACE"
echo "Month: $STORED_MONTH"
echo "Usage: $CURRENT_USAGE_GB GB / $LIMIT_GB GB"
echo "Status: $([ "$BLOCKED_STATUS" -eq 1 ] && echo "BLOCKED" || echo "ACTIVE")"
