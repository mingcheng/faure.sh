#!/usr/bin/env bash
###
# File: bootstrap.sh
# Author: Ming Cheng<mingcheng@outlook.com>
#
# Created Date: Wednesday, July 24th 2019, 2:35:51 pm
# Last Modified: Friday, August 9th 2019, 6:16:37 pm
#
# http://www.opensource.org/licenses/MIT
###

export FAURE_HOME="$HOME/faure.sh"
export FAURE_DATA="$FAURE_HOME/data"
export FAURE_BIN="$FAURE_HOME/bin/$(uname -m)"
export PATH="$FAURE_BIN:$PATH"

if [ ! -f $FAURE_DATA/chnlist.txt ]; then
  echo "downloading or update $FAURE_DATA/chnlist.txt"
  $FAURE_HOME/scripts/get-chnlist.sh $FAURE_DATA/chnlist.txt
fi

$FAURE_HOME/scripts/redirect.sh

if [ -x $FAURE_HOME/scripts/dump-ipsets.sh ]; then
	$FAURE_HOME/scripts/dump-ipsets.sh &
fi

exit 0
