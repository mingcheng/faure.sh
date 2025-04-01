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
# Last Modified: 2025-03-19 14:32:55
##

set -gx FAURE_ADDR_RANGE "192.168.0.0/16"
set -gx FAURE_INTERFACE eth0

# https://zhuanlan.zhihu.com/p/423684520
iptables -t nat -N CLASH
iptables -t nat -A CLASH -d 127.0.0.0/8 -j RETURN
iptables -t nat -A CLASH -d $FAURE_ADDR_RANGE -j RETURN
iptables -t nat -I CLASH -p udp -j RETURN
iptables -t nat -A CLASH -p tcp -j REDIRECT --to-port 8848
iptables -t nat -A CLASH -p icmp -j REDIRECT --to-port 8848
iptables -t nat -A PREROUTING -j CLASH
iptables -t nat -A POSTROUTING -o $FAURE_INTERFACE -j MASQUERADE

function block_port -d "firewall rules to block the external tcp request"
    iptables -I DOCKER-USER ! -s $FAURE_ADDR_RANGE -p tcp -m conntrack --ctorigdstport $argv[1] --ctdir ORIGINAL -j DROP
    iptables -I DOCKER-USER ! -s $FAURE_ADDR_RANGE -p udp -m conntrack --ctorigdstport $argv[1] --ctdir ORIGINAL -j DROP
    iptables -I INPUT -i $FAURE_INTERFACE -p tcp --dport $argv[1] ! -s $FAURE_ADDR_RANGE -j DROP
    iptables -I INPUT -i $FAURE_INTERFACE -p udp --dport $argv[1] ! -s $FAURE_ADDR_RANGE -j DROP
end

for x in 22 53 80 443 1080 1086 3000 3389 3551 5200 5201 5353 7890 8848 8849 8080 9100 9090
    block_port $x
end

iptables -t nat -A PREROUTING -s $FAURE_ADDR_RANGE -p udp --dport 53 -j REDIRECT --to-ports 53
iptables -t nat -A PREROUTING -s $FAURE_ADDR_RANGE -p tcp --dport 53 -j REDIRECT --to-ports 53
