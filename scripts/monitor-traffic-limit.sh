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
# This source code is licensed under the MIT License.

set -u

# --- Configuration ---
IFACE="${1:-}"
LIMIT_GB="${2:-}"
WARNING_PERCENT="${3:-80}"
ALERT_SCRIPT="${4:-}"

STATE_DIR="/var/lib/faure/traffic"
STATE_FILE="$STATE_DIR/${IFACE}.state"
LOCK_FILE="/var/run/traffic_monitor_${IFACE}.lock"

# --- Validation ---
if [ -z "$IFACE" ] || [ -z "$LIMIT_GB" ]; then
    echo "Usage: $0 <interface> <limit_gb> [warning_percent] [alert_script]"
    exit 1
fi

if [ ! -d "/sys/class/net/$IFACE" ]; then
    echo "Error: Interface $IFACE not found."
    exit 1
fi

# Ensure state directory exists
mkdir -p "$STATE_DIR"

# --- Helper Functions ---

# Get current RX and TX bytes
get_bytes() {
    local rx=$(cat "/sys/class/net/$IFACE/statistics/rx_bytes")
    local tx=$(cat "/sys/class/net/$IFACE/statistics/tx_bytes")
    echo "$((rx + tx))"
}

# Get traffic from vnStat if available
get_vnstat_bytes() {
    if ! command -v vnstat >/dev/null 2>&1; then
        return 1
    fi

    # Check if interface is monitored
    if ! LC_ALL=C vnstat -i "$IFACE" --oneline >/dev/null 2>&1; then
        return 1
    fi

    # Try JSON output (vnStat 2.x)
    if LC_ALL=C vnstat --json -i "$IFACE" >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        local current_year=$(date +%Y)
        local current_month=$(date +%m | sed 's/^0//')

        local bytes=$(LC_ALL=C vnstat --json -i "$IFACE" | jq -r --arg y "$current_year" --arg m "$current_month" '
            .interfaces[0].traffic.month[] | select(.date.year == ($y|tonumber) and .date.month == ($m|tonumber)) | .rx + .tx
        ')

        if [ -n "$bytes" ] && [ "$bytes" != "null" ]; then
            echo "$bytes"
            return 0
        fi
    fi

    # Fallback to oneline output parsing
    local output=$(LC_ALL=C vnstat -i "$IFACE" --oneline 2>/dev/null)
    if [ -n "$output" ]; then
        # Field 10 is month total (e.g., "10.50 GiB")
        local month_total_str=$(echo "$output" | cut -d';' -f10)

        # Convert to bytes
        echo "$month_total_str" | awk '
            function to_bytes(val, unit) {
                if (unit ~ /KiB/) return val * 1024;
                if (unit ~ /MiB/) return val * 1024 * 1024;
                if (unit ~ /GiB/) return val * 1024 * 1024 * 1024;
                if (unit ~ /TiB/) return val * 1024 * 1024 * 1024 * 1024;
                if (unit ~ /KB/) return val * 1000;
                if (unit ~ /MB/) return val * 1000 * 1000;
                if (unit ~ /GB/) return val * 1000 * 1000 * 1000;
                if (unit ~ /TB/) return val * 1000 * 1000 * 1000 * 1000;
                return val;
            }
            {
                print sprintf("%.0f", to_bytes($1, $2))
            }
        '
        return 0
    fi

    return 1
}

# Log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Block interface
block_interface() {
    log "Blocking internet access for $IFACE..."

    # Block forwarding
    iptables -C FORWARD -i "$IFACE" -j DROP 2>/dev/null || iptables -I FORWARD -i "$IFACE" -j DROP
    iptables -C FORWARD -o "$IFACE" -j DROP 2>/dev/null || iptables -I FORWARD -o "$IFACE" -j DROP

    # Block output (optional, depending on if we want to block the host itself using this interface)
    # iptables -C OUTPUT -o "$IFACE" -j DROP 2>/dev/null || iptables -I OUTPUT -o "$IFACE" -j DROP

    # Execute alert script if provided
    if [ -n "$ALERT_SCRIPT" ] && [ -x "$ALERT_SCRIPT" ]; then
        "$ALERT_SCRIPT" "BLOCK" "$IFACE" "$CURRENT_USAGE_GB" "$LIMIT_GB"
    fi
}

# Unblock interface
unblock_interface() {
    log "Unblocking internet access for $IFACE..."

    iptables -D FORWARD -i "$IFACE" -j DROP 2>/dev/null || true
    iptables -D FORWARD -o "$IFACE" -j DROP 2>/dev/null || true
    # iptables -D OUTPUT -o "$IFACE" -j DROP 2>/dev/null || true
}

# Send warning
send_warning() {
    log "Warning: Traffic usage for $IFACE is at ${1}% ($CURRENT_USAGE_GB GB / $LIMIT_GB GB)"
    if [ -n "$ALERT_SCRIPT" ] && [ -x "$ALERT_SCRIPT" ]; then
        "$ALERT_SCRIPT" "WARNING" "$IFACE" "$CURRENT_USAGE_GB" "$LIMIT_GB"
    fi
}

# --- Main Logic ---

# Acquire lock to prevent concurrent runs
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "Script is already running."; exit 1; }

CURRENT_BYTES=$(get_bytes)
CURRENT_MONTH=$(date +%Y-%m)

# Load state
# State file format: MONTH LAST_BYTES ACCUMULATED_BYTES BLOCKED_STATUS WARNING_SENT
if [ -f "$STATE_FILE" ]; then
    read -r STORED_MONTH LAST_BYTES ACCUMULATED_BYTES BLOCKED_STATUS WARNING_SENT < "$STATE_FILE"
else
    STORED_MONTH="$CURRENT_MONTH"
    LAST_BYTES="$CURRENT_BYTES"
    ACCUMULATED_BYTES="0"
    BLOCKED_STATUS="0"
    WARNING_SENT="0"
fi

# Handle Month Reset
if [ "$CURRENT_MONTH" != "$STORED_MONTH" ]; then
    log "New month detected. Resetting counters for $IFACE."
    STORED_MONTH="$CURRENT_MONTH"
    ACCUMULATED_BYTES="0"
    LAST_BYTES="$CURRENT_BYTES" # Reset baseline
    BLOCKED_STATUS="0"
    WARNING_SENT="0"
    unblock_interface
fi

# Try to get traffic from vnStat
VNSTAT_BYTES=$(get_vnstat_bytes)
if [ $? -eq 0 ] && [ -n "$VNSTAT_BYTES" ]; then
    # Use vnStat data
    ACCUMULATED_BYTES="$VNSTAT_BYTES"
    # We still update LAST_BYTES to keep the internal counter in sync for potential fallback
    LAST_BYTES="$CURRENT_BYTES"
else
    # Fallback to internal calculation
    # Calculate Delta
    if [ "$CURRENT_BYTES" -lt "$LAST_BYTES" ]; then
        # Reboot or counter overflow detected
        DELTA="$CURRENT_BYTES"
    else
        DELTA=$((CURRENT_BYTES - LAST_BYTES))
    fi

    # Update Accumulator
    ACCUMULATED_BYTES=$((ACCUMULATED_BYTES + DELTA))
    LAST_BYTES="$CURRENT_BYTES"
fi

# Convert to GB for comparison (1 GB = 1073741824 bytes)
CURRENT_USAGE_GB=$(awk "BEGIN {printf \"%.2f\", $ACCUMULATED_BYTES / 1073741824}")

# Check Limits
LIMIT_BYTES=$((LIMIT_GB * 1073741824))
WARNING_BYTES=$(awk "BEGIN {printf \"%.0f\", $LIMIT_BYTES * $WARNING_PERCENT / 100}")

# 1. Check Block Limit
if [ "$ACCUMULATED_BYTES" -ge "$LIMIT_BYTES" ]; then
    if [ "$BLOCKED_STATUS" -eq "0" ]; then
        log "Limit exceeded ($CURRENT_USAGE_GB GB >= $LIMIT_GB GB). Initiating block."
        block_interface
        BLOCKED_STATUS="1"
    fi
# 2. Check Warning Threshold
elif [ "$ACCUMULATED_BYTES" -ge "$WARNING_BYTES" ]; then
    if [ "$WARNING_SENT" -eq "0" ]; then
        send_warning "$WARNING_PERCENT"
        WARNING_SENT="1"
    fi
    # Ensure we are unblocked if we are below limit (e.g. limit increased manually)
    if [ "$BLOCKED_STATUS" -eq "1" ]; then
         unblock_interface
         BLOCKED_STATUS="0"
    fi
else
    # Normal operation
    if [ "$BLOCKED_STATUS" -eq "1" ]; then
         unblock_interface
         BLOCKED_STATUS="0"
    fi
fi

# Save State
echo "$STORED_MONTH $LAST_BYTES $ACCUMULATED_BYTES $BLOCKED_STATUS $WARNING_SENT" > "$STATE_FILE"

# Output status
echo "Interface: $IFACE"
echo "Month: $STORED_MONTH"
echo "Usage: $CURRENT_USAGE_GB GB / $LIMIT_GB GB"
echo "Status: $([ "$BLOCKED_STATUS" -eq 1 ] && echo "BLOCKED" || echo "ACTIVE")"
