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

# https://zhuanlan.zhihu.com/p/423684520
iptables -t nat -N CLASH
iptables -t nat -A CLASH -d 127.0.0.0/8 -j RETURN
iptables -t nat -A CLASH -d 192.168.0.0/24 -j RETURN
iptables -t nat -I CLASH -p udp -j RETURN
iptables -t nat -A CLASH -p tcp -j REDIRECT --to-port 8848
iptables -t nat -A CLASH -p icmp -j REDIRECT --to-port 8848
iptables -t nat -A PREROUTING -j CLASH
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

function block_port -d "firewall rules to block the external tcp request"
    iptables -I DOCKER-USER ! -s 192.168.0.0/24 -p tcp -m conntrack --ctorigdstport $argv[1] --ctdir ORIGINAL -j DROP
    iptables -I INPUT -i eth0 -p tcp --dport $argv[1] ! -s 192.168.0.0/24 -j DROP
end

for x in 22 53 80 443 1080 1086 3389 3551 5200 5353 7890 8848 8849 8080 9100 9090
    block_port $x
end
