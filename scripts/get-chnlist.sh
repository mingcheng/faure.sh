#!/usr/bin/env bash

###
# File: get-chnlist.sh
# Author: Ming Cheng<mingcheng@outlook.com>
#
# Created Date: Tuesday, July 23rd 2019, 5:59:10 pm
# Last Modified: Wednesday, July 24th 2019, 5:10:12 pm
#
# http://www.opensource.org/licenses/MIT
# for more information @see https://github.com/17mon/china_ip_list
###

if [ ! -n "$1" ]; then
    echo "usage $0 [output-file]"
    exit -1
fi

echo "downloading to $1"
curl -sL 'https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt' -o $1

curl -sL 'https://raw.githubusercontent.com/ym/chnroutes2/master/chnroutes.txt' -o /tmp/tmp.txt
cat /tmp/tmp.txt >> $1 && rm -f /tmp/tmp.txt

curl -sL 'https://raw.githubusercontent.com/metowolf/IPList/master/data/special/china.txt' -o /tmp/tmp.txt
cat /tmp/tmp.txt >> $1 && rm -f /tmp/tmp.txt

echo "download is finished, update git"
if [ -d $HOME/china-operator-ip ]; then
	cd $HOME/china-operator-ip && git pull && cd -
	for entry in "$HOME/china-operator-ip"/*.txt
	do
	  cat "$entry" >> $1
	done
fi

sed -i 's:#.*$::g' $1
sed -i '$!N; /^\(.*\)\n\1$/!P; D' $1
sed -i '/^[ \t]*$/d' $1
