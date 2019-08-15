#!/usr/bin/env bash
###
# File: firewall.sh
# Author: Ming Cheng<mingcheng@outlook.com>
#
# Created Date: Tuesday, August 6th 2019, 4:58:44 pm
# Last Modified: Tuesday, August 13th 2019, 11:14:17 am
#
# http://www.opensource.org/licenses/MIT
###

iptables -t filter -N INTERNAL
iptables -t filter -A INTERNAL -s 192.168/16 -j ACCEPT
iptables -t filter -A INTERNAL -s 172.16/16 -j ACCEPT
iptables -t filter -A INTERNAL -s 10.0/24 -j ACCEPT
iptables -t filter -A INTERNAL -i lo -j ACCEPT
iptables -t filter -A INTERNAL -j REJECT

# http://www.111cn.net/sys/linux/45525.htm
iptables -A INPUT -p tcp --dport 22 -j INTERNAL
iptables -A INPUT -p tcp --dport 1080 -j INTERNAL
iptables -A INPUT -p tcp --dport 1081 -j INTERNAL
# iptables -A INPUT -p tcp --dport 9100 -j INTERNAL

# iptables -A INPUT -p tcp --dport :8900 -j INTERNAL
#iptables -A INPUT -p tcp --dport 10000: -j INTERNAL

# iptables -A INPUT -i br0 -p tcp --dport 22 -j DROP

exit 0
