#!/usr/bin/env bash
# Copyright (c) 2025 mingcheng <mingcheng@apache.org>
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: check-balance.sh
# Author: mingcheng <mingcheng@apache.org>
# File Created: 2025-12-27 22:40:47
#
# Modified By: mingcheng <mingcheng@apache.org>
# Last Modified: 2026-10-06 19:30:00
##
#
# Sample TX/RX counters on two interfaces for N seconds and print how the
# traffic was split between them.
# Usage: ./check-balance.sh [iface1] [iface2] [seconds]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$SCRIPT_DIR/utils.sh"

# Positional args override config.sh defaults.
IFACE1="${1:-$IF1}"
IFACE2="${2:-${IF2:-}}"
DURATION="${3:-10}"

if [ $# -lt 2 ] && ! secondary_uplink_enabled; then
    echo "Single-uplink mode: no secondary interface to compare."
    echo "Tip: pass two interface names explicitly to compare traffic counters."
    exit 0
fi

if [ -z "$IFACE2" ] || [ "$IFACE2" = "$IFACE1" ]; then
    echo "Error: two distinct interfaces are required for balance comparison."
    exit 1
fi

if ! [[ $DURATION =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: duration must be a positive integer (seconds)."
    exit 1
fi

for iface in "$IFACE1" "$IFACE2"; do
    if [ ! -d "/sys/class/net/$iface" ]; then
        echo "Error: Interface $iface not found."
        exit 1
    fi
done

echo "========================================"
echo "Network Traffic Balance Monitor"
echo "========================================"
echo "Monitoring $IFACE1 and $IFACE2 for $DURATION seconds..."
echo "Please generate some traffic (browse websites, download files, etc.)"
echo ""

# Usage: get_counter <iface> <tx_bytes|rx_bytes>
get_counter() { cat "/sys/class/net/$1/statistics/$2"; }

I1_TX_START=$(get_counter "$IFACE1" tx_bytes)
I2_TX_START=$(get_counter "$IFACE2" tx_bytes)
I1_RX_START=$(get_counter "$IFACE1" rx_bytes)
I2_RX_START=$(get_counter "$IFACE2" rx_bytes)

sleep "$DURATION"

I1_TX_DIFF=$(($(get_counter "$IFACE1" tx_bytes) - I1_TX_START))
I2_TX_DIFF=$(($(get_counter "$IFACE2" tx_bytes) - I2_TX_START))
I1_RX_DIFF=$(($(get_counter "$IFACE1" rx_bytes) - I1_RX_START))
I2_RX_DIFF=$(($(get_counter "$IFACE2" rx_bytes) - I2_RX_START))

human_readable() {
    awk -v b="${1:-0}" 'BEGIN {
        split("B KB MB GB TB", units);
        u = 1;
        while (b >= 1024 && u < 5) { b /= 1024; u++ }
        printf "%.2f %s", b, units[u]
    }'
}

# Usage: print_split <title> <bytes_iface1> <bytes_iface2>
print_split() {
    local total=$(($2 + $3))
    [ "$total" -gt 0 ] || return 0
    echo "$1 Distribution:"
    awk -v a="$2" -v t="$total" -v n="$IFACE1" 'BEGIN { printf "  %s: %.1f%%\n", n, a * 100 / t }'
    awk -v a="$3" -v t="$total" -v n="$IFACE2" 'BEGIN { printf "  %s: %.1f%%\n", n, a * 100 / t }'
    echo ""
}

echo "=== Traffic in last $DURATION seconds ==="
echo ""
echo "$IFACE1:"
echo "  TX (Upload):   $(human_readable "$I1_TX_DIFF")"
echo "  RX (Download): $(human_readable "$I1_RX_DIFF")"
echo ""
echo "$IFACE2:"
echo "  TX (Upload):   $(human_readable "$I2_TX_DIFF")"
echo "  RX (Download): $(human_readable "$I2_RX_DIFF")"
echo ""

print_split "Upload" "$I1_TX_DIFF" "$I2_TX_DIFF"
print_split "Download" "$I1_RX_DIFF" "$I2_RX_DIFF"

echo "========================================"
