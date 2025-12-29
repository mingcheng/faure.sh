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
# Last Modified: 2025-12-29 08:21:09
##

# Configuration
IFACE1="${1:-eth0}"
IFACE2="${2:-eth1}"
DURATION="${3:-10}"

# Check if interfaces exist
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

# Function to get bytes
get_tx_bytes() { cat "/sys/class/net/$1/statistics/tx_bytes"; }
get_rx_bytes() { cat "/sys/class/net/$1/statistics/rx_bytes"; }

# Get initial statistics
I1_TX_START=$(get_tx_bytes "$IFACE1")
I2_TX_START=$(get_tx_bytes "$IFACE2")
I1_RX_START=$(get_rx_bytes "$IFACE1")
I2_RX_START=$(get_rx_bytes "$IFACE2")

sleep "$DURATION"

# Get final statistics
I1_TX_END=$(get_tx_bytes "$IFACE1")
I2_TX_END=$(get_tx_bytes "$IFACE2")
I1_RX_END=$(get_rx_bytes "$IFACE1")
I2_RX_END=$(get_rx_bytes "$IFACE2")

# Calculate differences
I1_TX_DIFF=$((I1_TX_END - I1_TX_START))
I2_TX_DIFF=$((I2_TX_END - I2_TX_START))
I1_RX_DIFF=$((I1_RX_END - I1_RX_START))
I2_RX_DIFF=$((I2_RX_END - I2_RX_START))

# Convert to human readable format
function human_readable() {
    local bytes=$1
    if [ -z "$bytes" ]; then echo "0 B"; return; fi
    awk -v b="$bytes" 'BEGIN {
        split("B KB MB GB TB", units);
        u=1;
        while(b >= 1024 && u < 5) { b/=1024; u++ }
        printf "%.2f %s", b, units[u]
    }'
}

echo "=== Traffic in last $DURATION seconds ==="
echo ""
echo "$IFACE1:"
echo "  TX (Upload):   $(human_readable $I1_TX_DIFF)"
echo "  RX (Download): $(human_readable $I1_RX_DIFF)"
echo ""
echo "$IFACE2:"
echo "  TX (Upload):   $(human_readable $I2_TX_DIFF)"
echo "  RX (Download): $(human_readable $I2_RX_DIFF)"
echo ""

# Calculate total traffic and percentages
TOTAL_TX=$((I1_TX_DIFF + I2_TX_DIFF))
TOTAL_RX=$((I1_RX_DIFF + I2_RX_DIFF))

if [ $TOTAL_TX -gt 0 ]; then
    I1_TX_PERCENT=$(awk "BEGIN {printf \"%.1f\", $I1_TX_DIFF * 100 / $TOTAL_TX}")
    I2_TX_PERCENT=$(awk "BEGIN {printf \"%.1f\", $I2_TX_DIFF * 100 / $TOTAL_TX}")
    echo "Upload Distribution:"
    echo "  $IFACE1: ${I1_TX_PERCENT}%"
    echo "  $IFACE2: ${I2_TX_PERCENT}%"
    echo ""
fi

if [ $TOTAL_RX -gt 0 ]; then
    I1_RX_PERCENT=$(awk "BEGIN {printf \"%.1f\", $I1_RX_DIFF * 100 / $TOTAL_RX}")
    I2_RX_PERCENT=$(awk "BEGIN {printf \"%.1f\", $I2_RX_DIFF * 100 / $TOTAL_RX}")
    echo "Download Distribution:"
    echo "  $IFACE1: ${I1_RX_PERCENT}%"
    echo "  $IFACE2: ${I2_RX_PERCENT}%"
fi

echo ""
echo "========================================"
