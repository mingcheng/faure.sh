#!/usr/bin/env bash
# Copyright (c) 2025 Hangzhou Guanwaii Technology Co., Ltd.
#
# Verification script for faure.sh installation
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: verify.sh
# Author: mingcheng <mingcheng@apache.org>
# File Created: 2025-12-28 16:32:18
#
# Modified By: mingcheng <mingcheng@apache.org>
# Last Modified: 2025-12-28 16:36:02
##

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_info() {
    echo -e "[INFO] $1"
}

# 1. Check Root
if [[ $EUID -ne 0 ]]; then
   log_fail "This script must be run as root"
   exit 1
else
   log_pass "Running as root"
fi

# 2. System Checks
log_info "--- System Checks ---"

# Check OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" == "debian" || "$ID" == "ubuntu" || "$ID_LIKE" == *"debian"* ]]; then
        log_pass "OS is Debian-based ($PRETTY_NAME)"
    else
        log_warn "OS ($PRETTY_NAME) might not be fully supported. Debian/Ubuntu recommended."
    fi
else
    log_warn "Cannot detect OS version."
fi

# Check Kernel
KERNEL_VERSION=$(uname -r)
log_info "Kernel Version: $KERNEL_VERSION"
# Simple check for 4.9+ for BBR
MAJOR_VER=$(echo "$KERNEL_VERSION" | cut -d. -f1)
MINOR_VER=$(echo "$KERNEL_VERSION" | cut -d. -f2)
if [ "$MAJOR_VER" -gt 4 ] || ([ "$MAJOR_VER" -eq 4 ] && [ "$MINOR_VER" -ge 9 ]); then
    log_pass "Kernel version supports BBR"
else
    log_warn "Kernel version might be too old for BBR (requires 4.9+)"
fi

# 3. Dependency Checks
log_info "--- Dependency Checks ---"
REQUIRED_CMDS=("docker" "fish" "netplan" "iptables" "ip" "sysctl")

for cmd in "${REQUIRED_CMDS[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
        log_pass "Command '$cmd' found"
    else
        log_fail "Command '$cmd' NOT found. Please install it."
    fi
done

# 4. Network Checks
log_info "--- Network Checks ---"
# Check for interfaces other than lo
INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo")
if [ -n "$INTERFACES" ]; then
    log_pass "Network interfaces detected: $(echo $INTERFACES | tr '\n' ' ')"
else
    log_fail "No network interfaces found (excluding lo)"
fi

# Check Netplan config
if ls /etc/netplan/*.yaml >/dev/null 2>&1; then
    log_pass "Netplan configurations found in /etc/netplan/"
else
    log_warn "No Netplan configurations found in /etc/netplan/"
fi

# 5. Configuration Verification
log_info "--- Configuration Verification ---"

# Check BBR
CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
if [ "$CURRENT_CC" == "bbr" ]; then
    log_pass "TCP Congestion Control is set to BBR"
else
    log_warn "TCP Congestion Control is '$CURRENT_CC' (expected 'bbr')"
fi

# Check IP Forwarding
IP_FWD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
if [ "$IP_FWD" == "1" ]; then
    log_pass "IPv4 Forwarding is enabled"
else
    log_warn "IPv4 Forwarding is disabled (expected 1)"
fi

# 6. Service Status
log_info "--- Service Status ---"
SERVICES=(
    "monitor-uplink.service"
    "monitor-uplink.timer"
    "multipath-routing.service"
    "tproxy-routing.service"
)

for service in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$service"; then
        log_pass "Service $service is active"
    elif systemctl is-enabled --quiet "$service" 2>/dev/null; then
        log_warn "Service $service is enabled but NOT active"
    else
        log_fail "Service $service is not active or enabled"
    fi
done

log_info "Verification complete."
