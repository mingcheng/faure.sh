#!/usr/bin/env bash

###
# File: dmz.sh
# Author: Ming Cheng<mingcheng@outlook.com>
#
# Created Date: Tuesday, August 6th 2019, 5:00:44 pm
# Last Modified: Friday, August 9th 2019, 6:16:47 pm
#
# http://www.opensource.org/licenses/MIT
###



iptables -t nat -A PREROUTING -i eth1 -p tcp --dport 80 -j DNAT --to-destination 172.16.0.1
iptables -t nat -A PREROUTING -i eth1 -p tcp --dport 80 -j DNAT --to-destination 172.16.0.250
iptables -t nat -A PREROUTING -i eth1 -p tcp --dport 21 -j DNAT --to-destination 172.16.0.250
iptables -t nat -A PREROUTING -i eth1 -p tcp --dport 10000:10100 -j DNAT --to-destination 172.16.0.250
#iptables -t nat -A PREROUTING -i eth2 -p tcp -d 172.16.1.1 --dport 80 -j DNAT --to-destination 172.16.1.1
#iptables -t nat -A PREROUTING -i eth2 -p tcp --dport 80 -j DNAT --to-destination 192.168.2.144

