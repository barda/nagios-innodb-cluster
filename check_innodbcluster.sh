#!/bin/bash

P=''
S='/var/run/mysqld.sock'
U='nagios'
declare -i L=30

role_re='^(PRIMARY|SECONDARY)$'
state_re='^ONLINE$'

declare -A ROLE_MAP=( ['PRIMARY']=0 ['SECONDARY']=1 )
declare -A STATE_MAP=( ['ONLINE']=0 ['RECOVERING']=1 ['OFFLINE']=2 ['ERROR']=3 ['UNREACHABLE']=4 )

usage () {
	echo "$0 -u <user> -p <password> -S <socket> -L <max_lag>"
}

while getopts p:S:u:L:h opt; do
	case "${opt}" in
		p) P=${OPTARG} ;;
		S) S=${OPTARG} ;;
		u) U=${OPTARG} ;;
		L) L=${OPTARG} ;;
		\?|h) usage && exit 3 ;;
	esac
done

group_members=`echo "SELECT IFNULL(member_host,address), member_state, IFNULL(member_role,'MISSING') FROM mysql_innodb_cluster_metadata.instances I LEFT JOIN performance_schema.replication_group_members M ON I.mysql_server_uuid=M.MEMBER_ID ORDER BY member_host" | mysql --connect-timeout=5 -u $U -p$P -S$S -ABN 2>/dev/null`
[ $? -ne 0 ] && critical 'query failed'

msg=''
perf=''
declare -i primary_found=1
while read record ; do 
	member=(${record// /})
	m_host=${member[0]}
	m_state=${member[1]}
	m_role=${member[2]}

	[ "$m_role" = 'MISSING' ] && msg="${msg}$m_host MISSING" && continue

	perf="${perf}role_$m_host=${ROLE_MAP[$m_role]} state_$m_host=${STATE_MAP[$m_state]} "

	! [[ "$m_role" =~ $role_re ]] && msg="${msg}$m_host is $m_role "
	! [[ "$m_state" =~ $state_re ]] && msg="${msg}$m_host is $m_state "

	[ "$m_role" = 'PRIMARY' ] && primary_found=0
done < <(echo "$group_members")

declare -i lag=`echo "select IF( C.LAST_QUEUED_TRANSACTION='' OR C.LAST_QUEUED_TRANSACTION=W.LAST_APPLIED_TRANSACTION OR W.LAST_APPLIED_TRANSACTION_END_APPLY_TIMESTAMP < W.LAST_APPLIED_TRANSACTION_ORIGINAL_COMMIT_TIMESTAMP, NULL, TIME_TO_SEC(TIMEDIFF(LAST_APPLIED_TRANSACTION_END_APPLY_TIMESTAMP, LAST_APPLIED_TRANSACTION_ORIGINAL_COMMIT_TIMESTAMP))) AS replication_lag FROM performance_schema.replication_applier_status_by_worker W JOIN performance_schema.replication_connection_status C ON W.channel_name = C.channel_name WHERE W.channel_name = 'group_replication_applier'" | mysql --connect-timeout=5 -u $U -p$P -S$S -ABN 2>/dev/null`
[ $? -ne 0 ] && critical 'query failed'
perf="${perf}lag=$lag "
[ $lag -gt $L ] && msg="${msg}lag=${lag}s"


[ $primary_found -ne 0 ] && msg="${msg}PRIMARY not found "

[ -z "$msg" ] && echo "OK|$perf" && exit 0
echo "CRITICAL: $msg|$perf" && exit 2
