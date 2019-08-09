#!/usr/bin/env bash

###
# File: dump-ipsets.sh
# Author: Ming Cheng<mingcheng@outlook.com>
#
# Created Date: Friday, August 9th 2019, 5:42:15 pm
# Last Modified: Friday, August 9th 2019, 6:17:07 pm
#
# http://www.opensource.org/licenses/MIT
###

if [ -f $FAURE_DATA/chnlist.txt ]; then
	for ip in $(cat $FAURE_DATA/chnlist.txt); do
		ipset add chnroute $ip
	done
fi

if [ -f $FAURE_DATA/foreign-list.txt ]; then
	for ip in $(cat $FAURE_DATA/foreign-list.txt); do
		ipset add gfwlist $ip
	done
fi

exit 0
