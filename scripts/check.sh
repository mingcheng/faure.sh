#!/usr/bin/env bash
###
# File: check.sh
# Author: Ming Cheng<mingcheng@outlook.com>
#
# Created Date: Thursday, August 15th 2019, 2:17:58 pm
# Last Modified: Thursday, August 15th 2019, 2:31:34 pm
#
# http://www.opensource.org/licenses/MIT
###

if [ -z "$PROXY_ADDR" ]; then
  PROXY_ADDR="localhost:1080"
fi

curl_command="curl -sSkL -w %{http_code} \
	-x socks5://${PROXY_ADDR} \
	-o /dev/null \
	--connect-timeout 3 --max-time 5 \
	https://zh.wikipedia.org"

if [ $($curl_command) == "200" ]; then
  echo "Check OK"
  exit 0
else
  echo "Check Faild, $PROXY_ADDR not available"
  if [ ! -z $1 ] && [ -x $1 ]; then
    echo "Execute $1"
    echo $1
  fi
  exit -1
fi
