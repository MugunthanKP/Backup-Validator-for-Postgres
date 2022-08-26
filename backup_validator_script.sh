#!/bin/bash
 
PGHOME="/home/sas/postgres"
LOG_DIR="/var/log/sas.log"
PROVISION_PROPERTIES_FILE="distdb-workernode.properties"
NOTES="Notes"
BACKGROUND_PROCESS_NAME="run_installation_in_background_helper"
PSQL="$PGHOME/bin/psql"
PG_ISREADY="$PGHOME/bin/pg_isready"

backupValidatorLog(){
        echo "`date`::$@" >> $NOTES
}

giveExitForCurrentServer(){
	backupValidatorLog $1:$2
echo "<=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><=><>" >> $NOTES
}

getLogTime(){
	eval $2log_time=$(date -d"$1" +%s)
}

checkBackgroundProcessIsAlive(){
	if [ -z $1 ];then
		return
	fi 
	background_process_pid=$(ps aux|grep $1| grep -v grep| awk '{print $2}')	

}

getPg_isreadyExitStatus(){
	$($PG_ISREADY -d sasdb -U $postgres_readonly_username 1>/dev/null)
	pg_isready_exit_status=$?
}

setVariables(){
	if [[ -f $PROVISION_PROPERTIES_FILE ]];then
		DONE=false
                until $DONE; do
                read s || DONE=true
                first=`echo $s | cut -d"=" -f1`
                second=`echo $s | cut -d"=" -f2`
                eval  $first='$second'
                done < $PROVISION_PROPERTIES_FILE
	else
		giveExitForCurrentServer "No Property File" "leaving BACKUPVALIDATION !!!!!!!!"
		exit
	fi
}

doBackupValidation(){

setVariables
script_started_time=`date +%s`			  
backupValidatorLog "cluster_ip=$cluster_ip" 
#script_started_time=`date -d'Aug 23 12:00:00' +%s`
backupValidatorLog "master_ip=$master_ip" 
./distdbmi-distdb-workernode.sh install
PSQL_MASTER_CONNECT="$PSQL -d sasdb -U $postgres_readonly_username -h $master_ip"
PSQL_SLAVE_CONNECT="$PSQL -d sasdb -U $postgres_readonly_username -h $slave_ip"
background_process_pid=
status_log_time=0
status_log=

while [ $status_log_time -le $script_started_time ];do
    checkBackgroundProcessIsAlive $BACKGROUND_PROCESS_NAME
    status_log=$(grep -E 'Installation success!|Install Failed' $LOG_DIR| tail -1)
    if [ -n "$status_log" ];then
        Time=$(echo $status_log |awk '{print $1,$2,$3}')
	getLogTime "$Time" status_
    fi
    if [[ -z $background_process_pid ]] && [[ $status_log_time -le $script_started_time ]];then
        backupValidatorLog "Background Process is Not running. So leaving this server"
        status_log=
        break
    fi
    sleep 2
done

if [[ -z $status_log ]] || [[ "$status_log" == *"Install Failed" ]];then
	giveExitForCurrentServer "Install Failed" "Process Completed Unsuccessfull"
	return
else
	backupValidatorLog $(echo $status_log | awk '{print $1,$2,$3,$7,$8}') 	#  taking Notes of Status Log
	getPg_isreadyExitStatus
	if [ $pg_isready_exit_status -ne 0 ];then
		giveExitForCurrentServer "Postgres is not running" "Process Completed Unsuccessful"
		return
	else
		backupValidatorLog "Postgres is running"
		current_wal_lsn=$(export PGPASSWORD=$postgres_readonly_password;$PSQL_MASTER_CONNECT -At -c "SELECT pg_current_wal_lsn()")
		backupValidatorLog current_wal_lsn=$current_wal_lsn
		replayed_wal_lsn=$(export PGPASSWORD=$postgres_readonly_password;$PSQL_SLAVE_CONNECT -At -c "SELECT pg_last_wal_replay_lsn()")
		backupValidatorLog replayed_wal_lsn=$replayed_wal_lsn
		wal_difference_in_mib=$(export PGPASSWORD=$postgres_readonly_password;$PSQL_SLAVE_CONNECT -At -c "SELECT round(TEMP.wal_lsn_difference/pow(1024,2.0),2) FROM (SELECT pg_wal_lsn_diff('$current_wal_lsn','$replayed_wal_lsn') AS wal_lsn_difference) TEMP")
		backupValidatorLog wal_lsn_difference=$wal_difference_in_mib
	fi
fi
giveExitForCurrentServer "Replication Lag is Checked" "Process Completed Successfully"
}

if [[ -f $PROVISION_PROPERTIES_FILE ]] && [[ -f $NOTES ]];then
json=$(curl --request GET --url "distdbmi.localzoho.com/distdbapi/zac/getClusterBackupInformation?serviceId=628949a5-4dba-4b55-84b6-1a22163d88da"  -H "DistDBAuthToken: 8e9b43a9-5900-4ed2-b03d-7000f30aa325")

read -a cluster_details <<< $(echo $json | python -c "import sys,json
list = ['|'.join([i['IPAddress'],i['ClusterIP']]) 
        for i in json.load(sys.stdin)['clusters'] 
            if i['Role'] == 'MASTER' and i['NodeType'] == 'WORKERNODE' and i['dcRole'] == 'MAIN']
print(' '.join(list))
")

for val in "${cluster_details[@]}"
do
    master_ip=$(echo $val | cut -d'|' -f1)
    cluster_ip=$(echo $val | cut -d'|' -f2)
    sed -i -e /"master_ip="/d -e /"cluster_ip="/d $PROVISION_PROPERTIES_FILE
    echo -e "master_ip=$master_ip\ncluster_ip=$cluster_ip" >> $PROVISION_PROPERTIES_FILE
    doBackupValidation
done
else
echo "Please provide Required Files" "leaving BACKUPVALIDATION !!!!!!!!"
fi
