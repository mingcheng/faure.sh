#!/bin/sh
###
# File: install.sh
# Author: Ming Cheng<mingcheng@outlook.com>
#
# Created Date: Wednesday, July 24th 2019, 12:07:21 pm
# Last Modified: Wednesday, July 24th 2019, 12:07:42 pm
#
# http://www.opensource.org/licenses/MIT
###

apt install build-essential autoconf \
  libtool libssl-dev gawk debhelper dh-systemd init-system-helpers \
  pkg-config asciidoc xmlto apg libpcre3-dev zlib1g-dev \
  libsodium-dev libev-dev libcork-dev libudns-dev

apt install ipset dnsmasq supervisor proxychains

