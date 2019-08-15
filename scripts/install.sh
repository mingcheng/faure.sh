#!/bin/sh
###
# File: install.sh
# Author: Ming Cheng<mingcheng@outlook.com>
#
# Created Date: Wednesday, July 24th 2019, 12:07:21 pm
# Last Modified: Tuesday, August 13th 2019, 11:13:17 am
#
# http://www.opensource.org/licenses/MIT
###

apt install -y build-essential autoconf \
  libtool libssl-dev gawk debhelper dh-systemd init-system-helpers \
  pkg-config asciidoc xmlto apg libpcre3-dev zlib1g-dev \
  libsodium-dev libev-dev libcork-dev libudns-dev

apt install -y ipset dnsmasq supervisor proxychains hostapd
