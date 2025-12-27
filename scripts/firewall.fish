#!/usr/bin/env fish
# Copyright (c) 2025 Hangzhou Guanwaii Technology Co,.Ltd.
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: firewall.fish
# Author: mingcheng (mingcheng@apache.org)
# File Created: 2025-03-19 14:32:47
#
# Modified By: mingcheng (mingcheng@apache.org)
# Last Modified: 2025-04-03 10:01:01
##

# modify the FAURE_ADDR_RANGE and FAURE_INTERFACE to your own
set -gx FAURE_ADDR_RANGE "172.16.1.0/24"
set -gx FAURE_INTERFACE eth0
set -gx FAURE_TPORT 8848
set -gx TPROXY_TABLE 200  # 使用不同的路由表避免冲突

# cleanup function to remove existing rules
function cleanup_firewall
    echo "Cleaning up existing firewall rules..."

    # Remove mangle table rules
    iptables -t mangle -D PREROUTING -j SINGBOX_TPROXY 2>/dev/null
    iptables -t mangle -F SINGBOX_TPROXY 2>/dev/null
    iptables -t mangle -X SINGBOX_TPROXY 2>/dev/null

    # Remove routing rules (使用新的表编号)
    ip rule del fwmark 0x1 lookup $TPROXY_TABLE 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table $TPROXY_TABLE 2>/dev/null

    # Remove NAT DNS redirect rules
    iptables -t nat -D PREROUTING -s $FAURE_ADDR_RANGE -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null
    iptables -t nat -D PREROUTING -s $FAURE_ADDR_RANGE -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null

    echo "Cleanup completed."
end

# call cleanup before setting up
cleanup_firewall

echo "Setting up TPROXY firewall rules..."

# Create SINGBOX_TPROXY chain
iptables -t mangle -N SINGBOX_TPROXY

# Exclude local and private networks
iptables -t mangle -A SINGBOX_TPROXY -d 0.0.0.0/8 -j RETURN
iptables -t mangle -A SINGBOX_TPROXY -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A SINGBOX_TPROXY -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A SINGBOX_TPROXY -d 169.254.0.0/16 -j RETURN
iptables -t mangle -A SINGBOX_TPROXY -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A SINGBOX_TPROXY -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A SINGBOX_TPROXY -d 224.0.0.0/4 -j RETURN
iptables -t mangle -A SINGBOX_TPROXY -d 240.0.0.0/4 -j RETURN

# Exclude broadcast
iptables -t mangle -A SINGBOX_TPROXY -d 255.255.255.255/32 -j RETURN

# Mark and TPROXY for TCP
iptables -t mangle -A SINGBOX_TPROXY -p tcp -j MARK --set-mark 0x1
iptables -t mangle -A SINGBOX_TPROXY -p tcp -j TPROXY --tproxy-mark 0x1/0x1 --on-port $FAURE_TPORT

# Mark and TPROXY for UDP
iptables -t mangle -A SINGBOX_TPROXY -p udp -j MARK --set-mark 0x1
iptables -t mangle -A SINGBOX_TPROXY -p udp -j TPROXY --tproxy-mark 0x1/0x1 --on-port $FAURE_TPORT

# Apply TPROXY chain only to traffic from FAURE_ADDR_RANGE
iptables -t mangle -A PREROUTING -i $FAURE_INTERFACE -s $FAURE_ADDR_RANGE -j SINGBOX_TPROXY

# Set up routing for marked packets (使用优先级 99，在多路径规则之前)
ip rule add fwmark 0x1 lookup $TPROXY_TABLE priority 99
ip route add local 0.0.0.0/0 dev lo table $TPROXY_TABLE

# Redirect DNS requests to local DNS server
iptables -t nat -A PREROUTING -i $FAURE_INTERFACE -s $FAURE_ADDR_RANGE -p udp --dport 53 -j REDIRECT --to-ports 53
iptables -t nat -A PREROUTING -i $FAURE_INTERFACE -s $FAURE_ADDR_RANGE -p tcp --dport 53 -j REDIRECT --to-ports 53

echo "TPROXY firewall rules configured successfully."

# Display current rules
echo ""
echo "=== Current mangle PREROUTING rules ==="
iptables -t mangle -L PREROUTING -n -v

echo ""
echo "=== Current SINGBOX_TPROXY chain ==="
iptables -t mangle -L SINGBOX_TPROXY -n -v

echo ""
echo "=== Current routing rules ==="
ip rule show

echo ""
echo "=== TPROXY routing table ==="
ip route show table $TPROXY_TABLE
