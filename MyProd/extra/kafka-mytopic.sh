#!/bin/bash
export Command_Usage="Usage: ./kafka-mytopic.sh -o [OPTION...]"
export ZOOKEEPER=10.1.118.195:2181,10.1.136.246:2181,10.1.104.102:2181
export topics=${3}

if [[ ! -z ${ZOOKEEPER} ]] ; then 

#######################################
function TopicList() {
     ./kafka-topics.sh --list --zookeeper $ZOOKEEPER
}


#######################################
function TopicDelete() {
   for topic in ${topics}; do
     ./kafka-topics.sh --zookeeper $ZOOKEEPER --delete --topic $topic
   done
}


while getopts ":o:" opt
   do
     case $opt in
        o ) option=$OPTARG;;
     esac
done




if [[ $option = list ]]; then
	TopicList
elif [[ $option = delete ]]; then
    TopicDelete
else
	echo "$Command_Usage"
cat << EOF
_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_

Main modes of operation:

   list 		        :   List all topics in kafka
   delete <<topic>>     :   Delete topics from kafka

_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_
EOF
fi
else
    echo "ZOOKEEPER need to provide"
    echo "task aborting.....!"
    exit 1
fi