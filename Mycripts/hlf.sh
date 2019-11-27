#!/bin/bash
export PROD_DIR="../MyProd"


#######################################
## helm and tiller
function Helm_Configure() {
    kubectl create -f ../helm-rbac.yaml
    helm init --service-account tiller
}


#######################################
## configure storageclass
function Storageclass_Configure() {
    kubectl create -f ../storageclass.yaml
}

#######################################
## NGINX Ingress controller
function Nginx_Configure() {
    helm install stable/nginx-ingress -n nginx-ingress --namespace ingress-controller
}


#######################################
## Certificate manager
function Cert_Manager_Configure() {
    helm install stable/cert-manager -n cert-manager --namespace cert-manager
    envsubst < ${PROD_DIR}/extra/certManagerCI_staging.yaml    |    kubectl apply -f -
    envsubst < ${PROD_DIR}/extra/certManagerCI_production.yaml    |    kubectl apply -f -
}


#######################################
## Initial setup
function Setup_Namespace() {
    if [[ ${1} == "create" ]] ; then
        kubectl create ns cas orderers peers
    elif [[ ${1} == "cas" ]] ; then
        export K8S_NAMESPACE=cas
        namespace_options="--namespace=${K8S_NAMESPACE}"
        echo ${namespace_options}
    elif [[ ${1} == "orderers" ]] ; then
        export K8S_NAMESPACE=orderers
        namespace_options="--namespace=${K8S_NAMESPACE}"
        echo ${namespace_options}
    elif [[ ${1} == "peers" ]] ; then
        export K8S_NAMESPACE=peers
        namespace_options="--namespace=${K8S_NAMESPACE}"
        echo ${namespace_options}
    else
        echo "User input is mandatory"
    fi
}


#######################################
## Fabric CA
function Fabric_Configure() {
    ## configuring namespace for fabric ca
    Setup_Namespace cas

    helm install stable/hlf-ca -n ca ${namespace_options} -f ${PROD_DIR}/helm_values/ca.yaml
    export CA_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].metadata.name}")

    until $(kubectl logs ${namespace_options} ${CA_POD} | grep "Listening on") ; do
        sleep 2
        echo "waiting for CA to be up and running..!"
    done

    ## Check that we don't have a certificate
    kubectl exec ${namespace_options} ${CA_POD} -- cat /var/hyperledger/fabric-ca/msp/signcerts/cert.pem
    kubectl exec ${namespace_options} ${CA_POD} -- bash -c 'fabric-ca-client enroll -d -u http://${CA_ADMIN}:${CA_PASSWORD}@${SERVICE_DNS}:7054'

    ## Check that ingress works correctly
    export CA_INGRESS=$(kubectl get ingress ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].spec.rules[0].host}")
    curl https://${CA_INGRESS}/cainfo
}


#######################################
## Org Admin Identities
function Orgadmin_Configure() {

    export ORDERER_ADMIN_PASS=$(base64 <<< ${K8S_NAMESPACE}-ord-admin)
    export PEER_ADMIN_PASS=$(base64 <<< ${K8S_NAMESPACE}-peer-admin)

    ## getting CA_INGRESS
    Setup_Namespace cas
    export CA_INGRESS=$(kubectl get ingress ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].spec.rules[0].host}")

    ## Orderer Organisation
    ######################
    export Admin_Conf=Orderer
    Setup_Namespace cas
    ## Get identity of ord-admin (this should not exist at first)
    if $(kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity list --id ord-admin) ; then
        echo "identity of ord-admin already there...!"
    else
        ## Register Orderer Admin if the previous command did not work
        kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client register --id.name ord-admin --id.secret ${ORDERER_ADMIN_PASS} --id.attrs 'admin=true:ecert'

        ## Enroll the Organisation Admin identity
        FABRIC_CA_CLIENT_HOME=${PROD_DIR}/config fabric-ca-client enroll -u https://ord-admin:${ORDERER_ADMIN_PASS}@${CA_INGRESS} -M ${PROD_DIR}/OrdererMSP
        mkdir -p ${PROD_DIR}/config/OrdererMSP/admincerts
        cp ${PROD_DIR}/config/OrdererMSP/signcerts/* ${PROD_DIR}/config/OrdererMSP/admincerts
        Save_Admin_Crypto
    fi


    ## Peer Organisation
    ######################
    export Admin_Conf=Peer
    Setup_Namespace cas
    ## Get identity of peer-admin (this should not exist at first)
    if $(kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity list --id peer-admin) ; then
        echo "identity of peer-admin already there...!"
    else
        ## Register Peer Admin if the previous command did not work
        kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client register --id.name peer-admin --id.secret ${PEER_ADMIN_PASS} --id.attrs 'admin=true:ecert'

        ## Enroll the Organisation Admin identity
        FABRIC_CA_CLIENT_HOME=${PROD_DIR}/config fabric-ca-client enroll -u https://peer-admin:${PEER_ADMIN_PASS}@${CA_INGRESS} -M ${PROD_DIR}/PeerMSP
        mkdir -p ${PROD_DIR}/config/PeerMSP/admincerts
        cp ${PROD_DIR}/config/PeerMSP/signcerts/* ${PROD_DIR}/config/PeerMSP/admincerts
        Save_Admin_Crypto
    fi
}


#######################################
## Save Crypto Material
function Save_Admin_Crypto() {

    if [[ ${Admin_Conf} == Orderer ]] ; then
        ## Orderer Organisation
        Setup_Namespace orderers
        echo "Saving Crypto Material for ${Admin_Conf} with namespace_options : ${namespace_options}"

        ## Create a secret to hold the admin certificate:
        export ORG_CERT=$(ls ${PROD_DIR}/config/OrdererMSP/admincerts/cert.pem)
        kubectl create secret generic ${namespace_options} hlf--ord-admincert --from-file=cert.pem=${ORG_CERT}

        ## Create a secret to hold the admin key:
        export ORG_KEY=$(ls ${PROD_DIR}/config/OrdererMSP/keystore/*_sk)
        kubectl create secret generic ${namespace_options} hlf--ord-adminkey --from-file=key.pem=${ORG_KEY}

        ## Create a secret to hold the admin key CA certificate:
        export CA_CERT=$(ls ${PROD_DIR}/config/OrdererMSP/cacerts/*.pem)
        kubectl create secret generic ${namespace_options} hlf--ord-ca-cert --from-file=cacert.pem=${CA_CERT}

    elif [[ ${Admin_Conf} == Peer ]] ; then
        ## Peer Organisation
        Setup_Namespace peers
        echo "Saving Crypto Material for ${Admin_Conf} with namespace_options : ${namespace_options}"

        ## Create a secret to hold the admincert:
        export ORG_CERT=$(ls ${PROD_DIR}/config/PeerMSP/admincerts/cert.pem)
        kubectl create secret generic ${namespace_options} hlf--peer-admincert --from-file=cert.pem=${ORG_CERT}

        ## Create a secret to hold the admin key:
        export ORG_KEY=$(ls ${PROD_DIR}/config/PeerMSP/keystore/*_sk)
        kubectl create secret generic ${namespace_options} hlf--peer-adminkey --from-file=key.pem=${ORG_KEY}

        ## Create a secret to hold the CA certificate:
        export CA_CERT=$(ls ${PROD_DIR}/config/PeerMSP/cacerts/*.pem)
        kubectl create secret generic ${namespace_options} hlf--peer-ca-cert --from-file=cacert.pem=${CA_CERT}

    else
        echo "Admin_Conf can't be empty...!"
    fi
}


#######################################
## Genesis and channel
function Genesis_Channel() {

    export CHANNEL_NAME=""
    until [[ ! -z "$CHANNEL_NAME" ]] ; do
      read -r -p "Enter Channel name :: " CHANNEL_NAME </dev/tty
    done
    echo "Configuring Channel with name :: $CHANNEL_NAME"

    export P_W_D=${PWD} ; cd ${PROD_DIR}/config
    ## Create Genesis block and Channel
    configtxgen -profile OrdererGenesis -outputBlock ./genesis.block
    configtxgen -profile ${CHANNEL_NAME} -channelID ${CHANNEL_NAME} -outputCreateChannelTx ./${CHANNEL_NAME}.tx
    ## Save them as secrets
    Setup_Namespace orderers && kubectl create secret generic ${namespace_options} hlf--genesis --from-file=genesis.block
    Setup_Namespace peers && kubectl create secret generic ${namespace_options} hlf--channel --from-file=${CHANNEL_NAME}.tx
    cd ${P_W_D}
}




#######################################
## Fabric Orderer nodes Creation
function Orderer_Conf() {

    export ORDERER_NUM=""
    until [[ "$ORDERER_NUM" =~ ^[0-9]+$ ]] ; do
      read -r -p "Enter Orderer ID (integers only) :: " ORDERER_NUM </dev/tty
    done
    echo "Configuring Orderer with ID :: $ORDERER_NUM"

    export ORDERER_NODE_PASS=$(base64 <<< ${K8S_NAMESPACE}-ord-${ORDERER_NUM})

    ## getting CA_INGRESS
    Setup_Namespace cas
    export CA_INGRESS=$(kubectl get ingress ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].spec.rules[0].host}")

    ## Gatering cas pod name
    Setup_Namespace cas
    export CA_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].metadata.name}")

    ## Register orderer with CA
    kubectl exec ${namespace_options} $CA_POD -- fabric-ca-client register --id.name ord${ORDERER_NUM} --id.secret ${ORDERER_NODE_PASS} --id.type orderer
    FABRIC_CA_CLIENT_HOME=${PROD_DIR}/config fabric-ca-client enroll -d -u https://ord${ORDERER_NUM}:${ORDERER_NODE_PASS}@${CA_INGRESS} -M ord${ORDERER_NUM}_MSP

    ## Save the Orderer certificate in a secret
    Setup_Namespace orderers
    export NODE_CERT=$(ls ${PROD_DIR}/config/ord${ORDERER_NUM}_MSP/signcerts/*.pem)
    kubectl create secret generic ${namespace_options} hlf--ord${ORDERER_NUM}-idcert --from-file=cert.pem=${NODE_CERT}

    ## Save the Orderer private key in another secret
    export NODE_KEY=$(ls ${PROD_DIR}/config/ord${ORDERER_NUM}_MSP/keystore/*_sk)
    kubectl create secret generic ${namespace_options} hlf--ord${ORDERER_NUM}-idkey --from-file=key.pem=${NODE_KEY}

    ## Install orderers using helm
    envsubst < ${PROD_DIR}/helm_values/ord.yaml > ${PROD_DIR}/helm_values/ord${ORDERER_NUM}.yaml
    helm install stable/hlf-ord -n ord${ORDERER_NUM} ${namespace_options} -f ${PROD_DIR}/helm_values/ord${ORDERER_NUM}.yaml

    ## Get logs from orderer to check it's actually started
    export ORD_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-ord,release=ord${ORDERER_NUM}" -o jsonpath="{.items[0].metadata.name}")

    until $(kubectl logs ${namespace_options} ${ORD_POD} | grep 'completeInitialization') ; do
        echo "waiting for ${ORD_POD} to start...!"
        sleep 2
    done
    echo "Orderer nodes ord${ORDERER_NUM} started...! : ${ORD_POD}"
}


#######################################
## Fabric Peer nodes Creation
function Peer_Conf() {

    export PEER_NUM=""
    until [[ "$PEER_NUM" =~ ^[0-9]+$ ]] ; do
      read -r -p "Enter Peer ID (integers only) :: " PEER_NUM </dev/tty
    done
    echo "Configuring Peer with ID :: $PEER_NUM"

    export PEER_NODE_PASS=$(base64 <<< ${K8S_NAMESPACE}-ord-${PEER_NUM})

    ## getting CA_INGRESS
    Setup_Namespace cas
    export CA_INGRESS=$(kubectl get ingress ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].spec.rules[0].host}")

    ## Install CouchDB chart
    Setup_Namespace peers
    envsubst < ${PROD_DIR}/helm_values/cdb-peer.yaml > ${PROD_DIR}/helm_values/cdb-peer${PEER_NUM}.yaml
    helm install stable/hlf-couchdb -n cdb-peer${PEER_NUM} ${namespace_options} -f ${PROD_DIR}/helm_values/cdb-peer${PEER_NUM}.yaml

    ## Check that CouchDB is running
    export CDB_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-couchdb,release=cdb-peer${PEER_NUM}" -o jsonpath="{.items[*].metadata.name}")

    until $(kubectl logs ${namespace_options} $CDB_POD | grep 'Apache CouchDB has started on') ; do
        echo "waiting for ${CDB_POD} to start...!"
        sleep 2
    done
    echo "CouchDB started...! : ${CDB_POD}"


    ## Gatering cas pod name
    Setup_Namespace cas
    export CA_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].metadata.name}")

    ## Register Peer with CA
    kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client register --id.name peer${PEER_NUM} --id.secret ${PEER_NODE_PASS} --id.type peer
    FABRIC_CA_CLIENT_HOME=${PROD_DIR}/config fabric-ca-client enroll -d -u https://peer${PEER_NUM}:${PEER_NODE_PASS}@${CA_INGRESS} -M peer${PEER_NUM}_MSP


    ## Save the Peer certificate in a secret
    Setup_Namespace peers
    export NODE_CERT=$(ls ${PROD_DIR}/config/peer${PEER_NUM}_MSP/signcerts/*.pem)
    kubectl create secret generic ${namespace_options} hlf--peer${PEER_NUM}-idcert --from-file=cert.pem=${NODE_CERT}

    ## Save the Peer private key in another secret
    export NODE_KEY=$(ls ${PROD_DIR}/config/peer${PEER_NUM}_MSP/keystore/*_sk)
    kubectl create secret generic ${namespace_options} hlf--peer${PEER_NUM}-idkey --from-file=key.pem=${NODE_KEY}

    ## Install Peer using helm
    envsubst < ${PROD_DIR}/helm_values/peer.yaml > ${PROD_DIR}/helm_values/peer${PEER_NUM}.yaml
    helm install stable/hlf-peer -n peer${PEER_NUM} ${namespace_options} -f ${PROD_DIR}/helm_values/peer${PEER_NUM}.yaml

    ## check that Peer is running
    export PEER_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-peer,release=peer${PEER_NUM}" -o jsonpath="{.items[0].metadata.name}")

    until $(kubectl logs ${namespace_options} $PEER_POD | grep 'Starting peer') ; do
        echo "waiting for ${PEER_POD} to start...!"
        sleep 2
    done
    echo "Orderer nodes ord${PEER_NUM} started...! : ${PEER_POD}"
}



#######################################
## Create channel
function Create_Channel() {
    Setup_Namespace peers
    ## Create channel (do this only once in Peer 1)
    export PEER_NUM="1"

    export CHANNEL_NAME=""
    until [[ ! -z "$CHANNEL_NAME" ]] ; do
      read -r -p "Enter Channel name :: " CHANNEL_NAME </dev/tty
    done
    echo "Configuring Channel with name :: $CHANNEL_NAME on peer : peer${PEER_NUM}"

    export PEER_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-peer,release=peer${PEER_NUM}" -o jsonpath="{.items[0].metadata.name}")
    kubectl exec ${namespace_options} ${PEER_POD} -- peer channel create -o ord1-hlf-ord.orderers.svc.cluster.local:7050 -c ${CHANNEL_NAME} -f /hl_config/channel/${CHANNEL_NAME}.tx

}


#######################################
## Join and Fetch channel
function Join_Channel() {
    Setup_Namespace peers

    export PEER_NUM=""
    until [[ "$PEER_NUM" =~ ^[0-9]+$ ]] ; do
      read -r -p "Enter Peer ID (integers only) :: " PEER_NUM </dev/tty
    done
    export PEER_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-peer,release=peer${PEER_NUM}" -o jsonpath="{.items[0].metadata.name}")
    echo "Connecting with Peer : peer${PEER_NUM} on pod : ${PEER_POD}"

    export CHANNEL_NAME=""
    until [[ ! -z "${CHANNEL_NAME}" ]] ; do
      read -r -p "Enter Channel name to join from peer peer${PEER_NUM} :: " CHANNEL_NAME </dev/tty
      export FIRST_PEER_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-peer,release=peer1" -o jsonpath="{.items[0].metadata.name}")
      if [[ kubectl exec ${FIRST_PEER_POD} ${namespace_options} -- peer channel list | grep ${CHANNEL_NAME} ]] ; then
        echo "channel ${CHANNEL_NAME} found...!"
      else
        echo "channel ${CHANNEL_NAME} not found...!, please give the correct chaneel name which exist..!"
        CHANNEL_LIST=$(kubectl exec ${FIRST_PEER_POD} ${namespace_options} -- peer channel list)
        echo "these are the channels available in the ${FIRST_PEER_POD}"
        for channellist in ${CHANNEL_LIST[@]} ; do
            echo "$channellist"
        done
        exit 0
      fi
    done
    echo "Fetching and joining Channel with name :: $CHANNEL_NAME on peer : peer${PEER_NUM} wich has name : ${PEER_POD}"

    ## Fetch and join channel
    kubectl exec ${namespace_options} ${PEER_POD} -- peer channel fetch config /var/hyperledger/${CHANNEL_NAME}.block -c ${CHANNEL_NAME} -o ord1-hlf-ord.orderers.svc.cluster.local:7050
    kubectl exec ${namespace_options} ${PEER_POD} -- bash -c 'CORE_PEER_MSPCONFIGPATH=$ADMIN_MSP_PATH peer channel join -b /var/hyperledger/${CHANNEL_NAME}.block'

    ## check the channel
    kubectl exec ${PEER_POD} ${namespace_options} -- peer channel list
}





export Command_Usage="Usage: ./hgf.sh -o [OPTION...]"

while getopts ":o:" opt
   do
     case $opt in
        o ) option=$OPTARG;;
     esac
done




if [[ $option = initial ]]; then
    Helm_Configure
    echo "sleeping for 10 sec" ; sleep 10
    Storageclass_Configure
    Nginx_Configure
    Setup_Namespace create
    echo "sleeping for 20 sec" ; sleep 20
elif [[ $option = ca ]]; then
    echo "Configure CA Domain Name in file /helm_values/ca.yaml"
    Cert_Manager_Configure
    echo "sleeping for 10 sec" ; sleep 10
elif [[ $option = fabric ]]; then
    Fabric_Configure
    echo "sleeping for 10 sec" ; sleep 10
elif [[ $option = orgadmin ]]; then
    Orgadmin_Configure
    echo "sleeping for 10 sec" ; sleep 10
elif [[ $option = genesis-channel ]]; then
    Genesis_Channel
    echo "sleeping for 10 sec" ; sleep 10
elif [[ $option = orderer-create ]]; then
    Orderer_Conf
    echo "sleeping for 10 sec" ; sleep 10
elif [[ $option = peer-create ]]; then
    Peer_Conf
    echo "sleeping for 10 sec" ; sleep 10
elif [[ $option = channel-conf ]]; then
    Create_Channel
    echo "sleeping for 10 sec" ; sleep 10
elif [[ $option = cp-srv ]]; then
    Join_Channel
    echo "sleeping for 10 sec" ; sleep 10
else
	echo "$Command_Usage"
cat << EOF
_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_

Main modes of operation:

   
_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_
EOF
fi