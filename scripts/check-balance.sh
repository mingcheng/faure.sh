#!/bin/bash

echo "========================================"
echo "Network Traffic Balance Monitor"
echo "========================================"
echo ""

# 获取初始统计
ETH0_TX_START=$(cat /sys/class/net/eth0/statistics/tx_bytes)
ETH1_TX_START=$(cat /sys/class/net/eth1/statistics/tx_bytes)
ETH0_RX_START=$(cat /sys/class/net/eth0/statistics/rx_bytes)
ETH1_RX_START=$(cat /sys/class/net/eth1/statistics/rx_bytes)

echo "Monitoring for 10 seconds..."
echo "Please generate some traffic (browse websites, download files, etc.)"
echo ""

sleep 10

# 获取结束统计
ETH0_TX_END=$(cat /sys/class/net/eth0/statistics/tx_bytes)
ETH1_TX_END=$(cat /sys/class/net/eth1/statistics/tx_bytes)
ETH0_RX_END=$(cat /sys/class/net/eth0/statistics/rx_bytes)
ETH1_RX_END=$(cat /sys/class/net/eth1/statistics/rx_bytes)

# 计算差值
ETH0_TX_DIFF=$((ETH0_TX_END - ETH0_TX_START))
ETH1_TX_DIFF=$((ETH1_TX_END - ETH1_TX_START))
ETH0_RX_DIFF=$((ETH0_RX_END - ETH0_RX_START))
ETH1_RX_DIFF=$((ETH1_RX_END - ETH1_RX_START))

# 转换为人类可读格式
function human_readable() {
    local bytes=$1
    if [ $bytes -lt 1024 ]; then
        echo "${bytes} B"
    elif [ $bytes -lt 1048576 ]; then
        echo "$(($bytes / 1024)) KB"
    else
        echo "$(($bytes / 1048576)) MB"
    fi
}

echo "=== Traffic in last 10 seconds ==="
echo ""
echo "eth0 (172.16.1.1):"
echo "  TX (Upload):   $(human_readable $ETH0_TX_DIFF)"
echo "  RX (Download): $(human_readable $ETH0_RX_DIFF)"
echo ""
echo "eth1 (192.168.66.1):"
echo "  TX (Upload):   $(human_readable $ETH1_TX_DIFF)"
echo "  RX (Download): $(human_readable $ETH1_RX_DIFF)"
echo ""

# 计算总流量和比例
TOTAL_TX=$((ETH0_TX_DIFF + ETH1_TX_DIFF))
TOTAL_RX=$((ETH0_RX_DIFF + ETH1_RX_DIFF))

if [ $TOTAL_TX -gt 0 ]; then
    ETH0_TX_PERCENT=$((ETH0_TX_DIFF * 100 / TOTAL_TX))
    ETH1_TX_PERCENT=$((ETH1_TX_DIFF * 100 / TOTAL_TX))
    echo "Upload Distribution:"
    echo "  eth0: ${ETH0_TX_PERCENT}%"
    echo "  eth1: ${ETH1_TX_PERCENT}%"
    echo ""
fi

if [ $TOTAL_RX -gt 0 ]; then
    ETH0_RX_PERCENT=$((ETH0_RX_DIFF * 100 / TOTAL_RX))
    ETH1_RX_PERCENT=$((ETH1_RX_DIFF * 100 / TOTAL_RX))
    echo "Download Distribution:"
    echo "  eth0: ${ETH0_RX_PERCENT}%"
    echo "  eth1: ${ETH1_RX_PERCENT}%"
fi

echo ""
echo "========================================"
