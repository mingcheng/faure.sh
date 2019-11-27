#!/usr/bin/env bash
###
# File: random-pick.sh
# Author: Ming Cheng<mingcheng@outlook.com>
#
# Created Date: Thursday, August 8th 2019, 3:32:38 pm
# Last Modified: Friday, August 9th 2019, 6:19:24 pm
#
# http://www.opensource.org/licenses/MIT
###

CONFIGS_DIR="$HOME/ssr-confs"
TARGET_CONFIG="$HOME/shadowsocksr.json"

files=($CONFIGS_DIR/*.json)
target_file=$(printf "%s\n" "${files[RANDOM % ${#files[@]}]}")

if [ -f $target_file ]; then
  config_file=$(realpath $target_file)
  echo "Using $config_file"
  ln -sf $config_file $TARGET_CONFIG
  sudo supervisorctl restart ss-local
fi
