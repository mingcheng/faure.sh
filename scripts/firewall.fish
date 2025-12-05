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
set -gx FAURE_ADDR_RANGE "172.16.1.1/24"
set -gx FAURE_INTERFACE eth0
set -gx FAURE_TPORT 8848

# cleanup function to remove existing rules
function cleanup_firewall
    iptables -t mangle -D PREROUTING -j SINGBOX_TPROXY 2>/dev/null || true
    iptables -t mangle -F SINGBOX_TPROXY 2>/dev/null || true
    iptables -t mangle -X SINGBOX_TPROXY 2>/dev/null || true
    ip rule del fwmark 0x1 iif $FAURE_INTERFACE lookup 100 2>/dev/null || true
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
    # Note: Removing individual DROP rules is complex; consider flushing chains if needed
end

# call cleanup before setting up
cleanup_firewall

# set the tproxy chain to the mangle table
iptables -t mangle -N SINGBOX_TPROXY
iptables -t mangle -A SINGBOX_TPROXY -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A SINGBOX_TPROXY -d $FAURE_ADDR_RANGE -j RETURN
iptables -t mangle -A SINGBOX_TPROXY -p tcp -j MARK --set-mark 0x1
iptables -t mangle -A SINGBOX_TPROXY -p tcp -j TPROXY --tproxy-mark 0x1/0x1 --on-port $FAURE_TPORT
iptables -t mangle -A SINGBOX_TPROXY -p udp -j MARK --set-mark 0x1
iptables -t mangle -A SINGBOX_TPROXY -p udp -j TPROXY --tproxy-mark 0x1/0x1 --on-port $FAURE_TPORT
iptables -t mangle -A PREROUTING -j SINGBOX_TPROXY

# set the rule to route the tproxy packet
ip rule add fwmark 0x1 iif $FAURE_INTERFACE lookup 100
ip route add local 0.0.0.0/0 dev lo table 100

# redirect dns request to local dns
iptables -t nat -A PREROUTING -s $FAURE_ADDR_RANGE -p udp --dport 53 -j REDIRECT --to-ports 53
iptables -t nat -A PREROUTING -s $FAURE_ADDR_RANGE -p tcp --dport 53 -j REDIRECT --to-ports 53
