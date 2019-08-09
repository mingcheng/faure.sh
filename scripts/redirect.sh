#!/usr/bin/env bash

###
# File: redirect.sh
# Author: Ming Cheng<mingcheng@outlook.com>
#
# Created Date: Monday, July 22nd 2019, 7:59:40 pm
# Last Modified: Friday, August 9th 2019, 6:19:41 pm
#
# http://www.opensource.org/licenses/MIT
###

ipset -N gfwlist hash:net hashsize 65536 maxelem 1065536
ipset -N chnroute hash:net hashsize 65536 maxelem 1065536

iptables -A FORWARD -m state --state INVALID -j DROP
iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

iptables -A OUTPUT -m state --state INVALID -j DROP
iptables -A OUTPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

iptables -A INPUT -m state --state INVALID -j DROP
iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

iptables -t nat -N SHADOWSOCKS

iptables -t nat -A SHADOWSOCKS -d 0.0.0.0 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 0.0.0.0/254.0.0.0 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 0.0.0.0/8 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 10.0.0.0/8 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 127.0.0.0/8 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 127.0.0.1 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 169.254.0.0/16 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 172.16.0.0/12 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 192.168.0.0/16 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 192.168.0.0/16 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 224.0.0.0/4 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 240.0.0.0/4 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 8.8.0.0/16 -j RETURN

iptables -t nat -A SHADOWSOCKS -p tcp -m set --match-set gfwlist dst -j REDIRECT --to-port 8848
iptables -t nat -A SHADOWSOCKS -p tcp -m set --match-set chnroute dst -j RETURN
iptables -t nat -A SHADOWSOCKS -p tcp -j RETURN

iptables -t nat -A PREROUTING -p tcp -j SHADOWSOCKS
iptables -t nat -A OUTPUT -p tcp -j SHADOWSOCKS

iptables -t nat -A POSTROUTING -o br0 -j MASQUERADE
iptables -t nat -A POSTROUTING -o eth1 -j MASQUERADE
iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE

# Use iptables to anti-dns poison on linux or openwrt
# 	@from https://gist.github.com/scola/eed6772117df7eccd560
iptables -N dnsfilter -t mangle
iptables -t mangle -I dnsfilter -p udp -m udp -m u32 --u32 "0&0x0F000000=0x05000000 && 22&0xFFFF@16=0x042442b2,0x0807c62d,0x253d369e,0x2e52ae44,0x3b1803ad,0x402158a1,0x4021632f,0x4042a3fb,0x4168cafc,0x41a0db71" -j DROP
iptables -t mangle -I dnsfilter -p udp -m udp -m u32 --u32 "0&0x0F000000=0x05000000 && 22&0xFFFF@16=0x422dfced,0x480ecd63,0x480ecd68,0x4e10310f,0x5d2e0859,0x80797e8b,0x9f6a794b,0xa9840d67,0xc043c606,0xca6a0102" -j DROP
iptables -t mangle -I dnsfilter -p udp -m udp -m u32 --u32 "0&0x0F000000=0x05000000 && 22&0xFFFF@16=0xcab50755,0xcb620741,0xcba1e6ab,0xcf0c5862,0xd0381f2b,0xd1244921,0xd1913632,0xd1dc1eae,0xd35e4293,0xd5a9fb23" -j DROP
iptables -t mangle -I dnsfilter -p udp -m udp -m u32 --u32 "0&0x0F000000=0x05000000 && 22&0xFFFF@16=0xd8ddbcb6,0xd8eab30d,0xf3b9bb27,0x4a7d7f66,0x4a7d9b66,0x4a7d2771,0x4a7d2766,0xd155e58a" -j DROP
iptables -t mangle -I PREROUTING -m udp -p udp --sport 53 -j dnsfilter
