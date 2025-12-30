#!/usr/bin/env bash
# Copyright (c) 2025 mingcheng <mingcheng@apache.org>
#
# Verify network configuration for multipath routing and TProxy
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: verify-network.sh
# Author: mingcheng <mingcheng@apache.org>
# File Created: 2025-12-27 23:53:23
#
# Modified By: mingcheng <mingcheng@apache.org>
# Last Modified: 2025-12-29 08:22:06
##

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_info() { echo -e "       $1"; }

echo "=============================================="
echo "Network Configuration Verification"
echo "=============================================="

# 1. Check Multipath Route
echo ""
echo "--- 1. Multipath Default Route ---"
ROUTE_OUTPUT=$(ip route show default)
if echo "$ROUTE_OUTPUT" | grep -q "nexthop"; then
    log_pass "Multipath default route detected."
    echo "$ROUTE_OUTPUT" | sed 's/^/       /'
else
    log_fail "No multipath default route found."
    log_info "Current default route: $ROUTE_OUTPUT"
fi

# 2. Check Routing Rules
echo ""
echo "--- 2. Policy Routing Rules ---"
RULES=$(ip rule show)

check_rule() {
    local prio=$1
    local desc=$2
    if echo "$RULES" | grep -q "^$prio:"; then
        log_pass "Priority $prio ($desc) exists."
    else
        log_fail "Priority $prio ($desc) MISSING."
    fi
}

check_rule "90" "Fwmark 0x100 -> Table 100"
check_rule "91" "Fwmark 0x200 -> Table 101"
check_rule "99" "Fwmark 0x1 -> TProxy Table"
check_rule "100" "Source IP1 -> Table 100"
check_rule "101" "Source IP2 -> Table 101"

# 3. Check IPTables
echo ""
echo "--- 3. IPTables Mangle Rules ---"

if iptables -t mangle -L MULTIPATH_MARK -n >/dev/null 2>&1; then
    log_pass "Chain MULTIPATH_MARK exists."
else
    log_fail "Chain MULTIPATH_MARK missing."
fi

if iptables -t mangle -L SINGBOX_TPROXY -n >/dev/null 2>&1; then
    log_pass "Chain SINGBOX_TPROXY exists."
else
    log_warn "Chain SINGBOX_TPROXY missing (TProxy might not be running)."
fi

# Check PREROUTING hooks
PREROUTING=$(iptables -t mangle -L PREROUTING -n)
if echo "$PREROUTING" | grep -q "MULTIPATH_MARK"; then
    log_pass "MULTIPATH_MARK hooked in PREROUTING."
else
    log_fail "MULTIPATH_MARK NOT hooked in PREROUTING."
fi

# 4. Connectivity Test
echo ""
echo "--- 4. Connectivity Test ---"
TEST_URL="http://cp.cloudflare.com/generate_204"
IP_API="http://ifconfig.me/ip"

check_iface() {
    local iface=$1

    # Check if interface exists
    if ! ip link show "$iface" >/dev/null 2>&1; then
        log_warn "Interface $iface does not exist. Skipping."
        return
    fi

    local ip_addr=$(ip -4 addr show $iface | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)

    if [ -z "$ip_addr" ]; then
        log_warn "Interface $iface has no IP address."
        return
    fi

    echo "Testing interface: $iface ($ip_addr)..."

    # Test basic connectivity
    if curl --interface $iface --connect-timeout 3 -s -o /dev/null $TEST_URL; then
        log_pass "$iface can reach Internet."

        # Test External IP (Optional)
        EXT_IP=$(curl --interface $iface --connect-timeout 5 -s $IP_API)
        if [ -n "$EXT_IP" ]; then
            log_info "External IP via $iface: $EXT_IP"
        else
            log_warn "Could not fetch external IP via $iface."
        fi
    else
        log_fail "$iface CANNOT reach Internet."
    fi
}

check_iface "eth0"
check_iface "eth1"

echo ""
echo "=============================================="
echo "Verification Finished"
echo "=============================================="
