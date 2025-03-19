#!/usr/bin/env fish
# Copyright (c) 2025 Hangzhou Guanwaii Technology Co,.Ltd.
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: ca.fish
# Author: mingcheng (mingcheng@apache.org)
# File Created: 2025-03-19 14:39:58
#
# Modified By: mingcheng (mingcheng@apache.org)
# Last Modified: 2025-03-19 15:11:46
##

openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout 1.key -out 1.crt
