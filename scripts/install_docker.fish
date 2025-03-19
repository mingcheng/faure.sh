#!/usr/bin/env fish
# Copyright (c) 2025 Hangzhou Guanwaii Technology Co,.Ltd.
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: install_docker.fish
# Author: mingcheng (mingcheng@apache.org)
# File Created: 2025-03-20 11:44:32
#
# Modified By: mingcheng (mingcheng@apache.org)
# Last Modified: 2025-03-20 14:45:08
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

# add Docker's official GPG key:
apt update && apt install -y apt-transport-https ca-certificates curl gnupg lsb-release
install -m 0755 -d /etc/apt/keyrings
# curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
# echo \
# "deb [arch=(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
# (lsb_release -cs) stable" | \
# sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
echo \
    "deb [arch="(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.asc] https://mirrors.aliyun.com/docker-ce/linux/debian \
  "(lsb_release -cs)" stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

# update the package database
apt update

# uninstall docker compose if exists
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc
    sudo apt-get remove -y $pkg
end

# install Docker Engine
apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# start and enable the Docker service
systemctl enable --now docker

# clean up
apt autoremove -y
