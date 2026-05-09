#!/usr/bin/env bash
# Copyright (c) 2026 mingcheng <mingcheng@apache.org>
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
# Last Modified: 2026-01-19 11:07:40
##

# Colors for PASS/FAIL/WARN labels
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Source shared configuration & utilities (config.sh is required).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$SCRIPT_DIR/utils.sh"

# Override utils.sh logging with verifier-style PASS/FAIL labels (no timestamp).
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_info() { echo -e "       $1"; }

echo "=============================================="
echo "Network Configuration Verification"
echo "=============================================="

HAS_SECONDARY_UPLINK=0
if secondary_uplink_enabled; then
    HAS_SECONDARY_UPLINK=1
fi

# 1. Check Default Route
echo ""
echo "--- 1. Default Route ---"
ROUTE_OUTPUT=$(ip route show default)
if echo "$ROUTE_OUTPUT" | grep -q "nexthop"; then
    log_pass "Multipath default route detected."
    echo "$ROUTE_OUTPUT" | sed 's/^/       /'
elif [ -n "$ROUTE_OUTPUT" ]; then
    log_pass "Single/failover default route detected."
    echo "$ROUTE_OUTPUT" | sed 's/^/       /'
else
    log_fail "No usable default route found."
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

check_rule "$PRIO_MARK1" "Fwmark $MARK1 -> Table $TABLE1"
if [ "$HAS_SECONDARY_UPLINK" -eq 1 ]; then
    check_rule "$PRIO_MARK2" "Fwmark $MARK2 -> Table $TABLE2"
else
    log_info "Secondary uplink disabled; skipping $MARK2 / table $TABLE2 rule checks."
fi
check_rule "$PRIO_TPROXY" "Fwmark $TPROXY_MARK -> TProxy Table"
check_rule "$PRIO_SRC1" "Source IP1 -> Table $TABLE1"
if [ "$HAS_SECONDARY_UPLINK" -eq 1 ]; then
    check_rule "$PRIO_SRC2" "Source IP2 -> Table $TABLE2"
fi

# 3. Check IPTables
echo ""
echo "--- 3. IPTables Mangle Rules ---"

if iptables -t mangle -L MULTIPATH_MARK -n >/dev/null 2>&1; then
    log_pass "Chain MULTIPATH_MARK exists."
else
    log_fail "Chain MULTIPATH_MARK missing."
fi

if iptables -t mangle -L $CHAIN_NAME -n >/dev/null 2>&1; then
    log_pass "Chain $CHAIN_NAME exists."
else
    log_warn "Chain $CHAIN_NAME missing (TProxy might not be running)."
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
# Use China Mainland optimized services
TEST_URL="http://connect.rom.miui.com/generate_204"
IP_API="http://myip.ipip.net"

check_iface() {
    local iface=$1

    # Check if interface exists
    if ! ip link show "$iface" >/dev/null 2>&1; then
        log_warn "Interface $iface does not exist. Skipping."
        return
    fi

    local ip_addr=$(ip -4 addr show dev $iface | awk '/inet / {print $2}' | cut -d/ -f1 | head -n 1)

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

check_iface "$IF1"
if [ "$HAS_SECONDARY_UPLINK" -eq 1 ]; then
    check_iface "$IF2"
else
    log_info "Secondary uplink disabled; skipping IF2 connectivity test."
fi

echo ""
echo "=============================================="
echo "Verification Finished"
echo "=============================================="
