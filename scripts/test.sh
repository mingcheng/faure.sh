#!/usr/bin/env bash

###
# File: test.sh
# Author: Ming Cheng<mingcheng@outlook.com>
#
# Created Date: Wednesday, July 24th 2019, 2:14:28 pm
# Last Modified: Wednesday, July 24th 2019, 2:15:06 pm
#
# http://www.opensource.org/licenses/MIT
###

curl -o /dev/null -4qsSkL -w 'baidu \t%{time_connect} : %{time_starttransfer} : %{time_total}\n' https://www.baidu.com
curl -o /dev/null -4qsSkL -w 'google \t%{time_connect} : %{time_starttransfer} : %{time_total}\n' https://www.google.com
curl -o /dev/null -4qsSkL -w 'facebook \t%{time_connect} : %{time_starttransfer} : %{time_total}\n' https://www.facebook.com
curl -o /dev/null -4qsSkL -w 'twitter \t%{time_connect} : %{time_starttransfer} : %{time_total}\n' https://twitter.com
curl -o /dev/null -4qsSkL -w 'github \t%{time_connect} : %{time_starttransfer} : %{time_total}\n' https://github.com
curl -o /dev/null -4qsSkL -w 'wikipedia \t%{time_connect} : %{time_starttransfer} : %{time_total}\n' https://www.wikipedia.org

curl -4sSkL https://myip.ipip.net
curl -x socks5://localhost:1080 -4sSkL https://myip.ipip.net
https_proxy=http://localhost:1081 curl -4sSkL https://myip.ipip.net
