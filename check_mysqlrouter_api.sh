#!/bin/bash

set -o pipefail

P=''
U='nagios'
H='localhost'
PORT=8081
declare -i V=20190715
declare -i ro_dest=2
declare -i rw_dest=1
declare -i max_refresh_delay_seconds=300

usage () {
	echo "$0 -u <user> -p <password> -H <host> -P <port> -V <api_version> -R <RO route number of required destinations> -W <RW route number of required destinations> -D <metadata refresh max delay>"
}

while getopts p:H:P:u:V:R:W:D:h opt; do
	case "${opt}" in
		p) P=${OPTARG} ;;
		H) H=${OPTARG} ;;
		P) PORT=${OPTARG} ;;
		u) U=${OPTARG} ;;
		V) V=${OPTARG} ;;
		R) ro_dest=${OPTARG} ;;
		W) rw_dest=${OPTARG} ;;
		D) max_refresh_delay_seconds=${OPTARG} ;;
		\?|h) usage && exit 3 ;;
	esac
done

ro_route_match='_ro$'

req_connect_timeout=2
req_max_time=5

api="http://$U:$P@$H:$PORT/api/$V"

routes=`curl --silent --connect-timeout $req_connect_timeout --max-time $req_max_time $api/routes | jq -r '.items[].name'`
metadata=`curl --silent --connect-timeout $req_connect_timeout --max-time $req_max_time $api/metadata | jq -r '.items[].name'`

( [ -z  "$routes" ] || [ -z "$metadata" ] ) && echo "Unable to query mysqlrouter API at '$H'" && exit 2

msg=''
perf=''

declare -i required_dest
declare -i dest_count
is_alive=''
declare -i aliveness
blocked=''
declare -i blocked_count=0
for route in $routes; do
    is_alive=`curl --silent --connect-timeout $req_connect_timeout --max-time $req_max_time $api/routes/$route/health | jq '.isAlive'`
    if [ "$is_alive" == 'true' ]; then
        aliveness=0
    else
        aliveness=1
    fi

    dest_count=`curl --silent --connect-timeout $req_connect_timeout --max-time $req_max_time $api/routes/$route/destinations | jq '.items | length'`

    blocked=`curl --silent --connect-timeout $req_connect_timeout --max-time $req_max_time $api/routes/$route/blockedHosts | jq '.items | @sh' | tr -d '"'`
    if [ -z "$blocked" ]; then
	blocked_count=0
    else
	blocked_count=`echo "$blocked" | tr ' ' '\n' | wc -l`
    fi

    perf="${perf}alive_${route}=$aliveness dest_${route}=$dest_count block_${route}=$blocked_count "

    [ $aliveness -ne 0 ] && msg="${msg}'$route' not alive "

    if [[ "$route" =~ $ro_route_match ]]; then
        required_dest=$ro_dest
    else
        required_dest=$rw_dest
    fi
    [ $dest_count != $required_dest ] && msg="${msg}'$route' has '$dest_count' destinations instead of '$required_dest' "

    [ $blocked_count -gt 0 ] && msg="${msg}'$route' block: $blocked "
done

declare -i now_ts
declare -i last_refresh_ts
declare -i refresh_delay
for metadatas in $metadata; do
    last_refresh_ts=`curl --silent --connect-timeout $req_connect_timeout --max-time $req_max_time $api/metadata/$metadatas/status | jq '.timeLastRefreshSucceeded ' | xargs -I{} date -d{} '+%s'`
    [ $? -ne 0 ] && last_refresh_ts=0
    now_ts=`date '+%s'`
    refresh_delay=$(( $now_ts - $last_refresh_ts ))
 
    perf="${perf}delay_$metadatas=$refresh_delay "

    [ $refresh_delay -gt $max_refresh_delay_seconds ] && msg="${msg}refresh delay is ${refresh_delay}s "
done

[ ! -z "$msg" ] && echo "CRITICAL: $msg|$perf" && exit 2
echo "OK|$perf" && exit 0
