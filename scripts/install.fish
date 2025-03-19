#!/usr/bin/env fish
# Copyright (c) 2025 Hangzhou Guanwaii Technology Co,.Ltd.
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: install.fish
# Author: mingcheng (mingcheng@apache.org)
# File Created: 2025-03-20 10:01:34
#
# Modified By: mingcheng (mingcheng@apache.org)
# Last Modified: 2025-03-20 14:35:52
##

# check if running as root
if test (id -u) -ne 0
    echo "Please run this script as root"
    exit 1
end

# check if running on Linux
if test (uname -s | string lower) != linux
    echo "This script only supports Linux"
    exit 1
end

# update the install the nested packages
apt update && apt install stow -y

echo "stow -t /etc -d $PWD apt, install apt config"
stow -t /etc/apt apt
if test $status -ne 0
    echo "stow failed"
    exit 1
end

echo "update and upgrade system, by using the new apt config"
apt update && apt upgrade -y

echo "install the new packages"
apt install -y vim git curl wget fish net-tools dnsutils htop iptables netplan.io rsync

echo "cleaning up"
apt autoremove -y

stow -t /etc/netplan netplan
if test $status -ne 0
    echo "stow failed with link netplan"
    exit 1
end

stow -t /usr/local/sbin sbin
if test $status -ne 0
    echo "stow failed with link sbin"
    exit 1
end

stow -t /etc/sysctl.d sysctl.d
if test $status -ne 0
    echo "stow failed with link sysctl.d"
    exit 1
end

# generate the netplan config
netplan generate
