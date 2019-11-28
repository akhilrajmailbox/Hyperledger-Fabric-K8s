#!/bin/bash
export PROD_DIR="./"


#######################################
## Cloud Provider
function Cloud_Provider() {
    export CLOUD_PROVIDER=""
    until [[ ${CLOUD_PROVIDER} == "AWS" ]] || [[${CLOUD_PROVIDER} == "Azure" ]] ; do
        echo "Enter Either AWS or Azure"
        read -r -p "Enter your Cloud Provider :: " CLOUD_PROVIDER </dev/tty
        export CLOUD_PROVIDER=$CLOUD_PROVIDER
    done
}

#######################################
## helm and tiller
function Helm_Configure() {
    echo "Configuring Helm in the k8s..!"
    kubectl create -f helm-rbac.yaml
    helm init --service-account tiller
}


#######################################
## configure storageclass
function Storageclass_Configure() {
    Cloud_Provider
    echo "Configuring custom Fast storage class for the deployment...!"
    if [[ ${CLOUD_PROVIDER} == "AWS" ]] ; then
        kubectl create -f ${PROD_DIR}/extra/AWS-storageclass.yaml
    elif [[ ${CLOUD_PROVIDER} == "Azure" ]] ; then
        kubectl create -f ${PROD_DIR}/extra/Azure-storageclass.yaml
    else
        echo "CLOUD_PROVIDER not found..!, task aborting..!"
        exit 1
    fi
}

#######################################
## NGINX Ingress controller
function Nginx_Configure() {
    echo "Configure Ingress server for the deployment...!"
    helm install stable/nginx-ingress -n nginx-ingress --namespace ingress-controller
}


#######################################
## Certificate manager
function Cert_Manager_Configure() {
    echo "CA Mager Configuration...!"
    helm install stable/cert-manager -n cert-manager --namespace cert-manager
    envsubst < ${PROD_DIR}/extra/certManagerCI_staging.yaml    |    kubectl apply -f -
    envsubst < ${PROD_DIR}/extra/certManagerCI_production.yaml    |    kubectl apply -f -
}


#######################################
## Initial setup
function Setup_Namespace() {
    echo "Custom NameSpace Configuration : ${1}"

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
        echo "User input for Setup_Namespace is mandatory"
    fi
}


#######################################
## Initial setup
function Choose_Env() {
    echo "Choose Env Configuration : ${1}"

    if [[ ${1} == "org_number" ]] ; then
        export ORG_NUM=""
        # until [[ "${ORG_NUM}" =~ ^[0-9]+$ ]] ; do
        until [[ "${ORG_NUM}" == "1" ]] || [[ "${ORG_NUM}" == "2" ]] ; do
        read -r -p "Enter Organisation Num (integers only : 1 or 2) :: " ORG_NUM </dev/tty
        done
        echo "Configuring Organisation with Num :: ${ORG_NUM}"
        export ORG_NUM=${ORG_NUM}
    elif [[ ${1} == "order_number" ]] ; then
        export ORDERER_NUM=""
        # until [[ "${ORDERER_NUM}" =~ ^[0-9]+$ ]] ; do
        until [[ "${ORDERER_NUM}" == "1" ]] || [[ "${ORDERER_NUM}" == "2" ]] || [[ "${ORDERER_NUM}" == "3" ]] ; do
        read -r -p "Enter Orderer ID (integers only : 1 , 2 or 3) :: " ORDERER_NUM </dev/tty
        done
        echo "Configuring Orderer with ID :: ${ORDERER_NUM}"
        export ORDERER_NUM="${ORDERER_NUM}"
    elif [[ ${1} == "peer_number" ]] ; then
        export PEER_NUM=""
        # until [[ "${PEER_NUM}" =~ ^[0-9]+$ ]] ; do
        until [[ "${PEER_NUM}" == "1" ]] || [[ "${PEER_NUM}" == "2" ]] || [[ "${PEER_NUM}" == "3" ]] ; do
        read -r -p "Enter Peer ID (integers only : 1 , 2 or 3) :: " PEER_NUM </dev/tty
        done
        echo "Configuring Peer with ID :: ${PEER_NUM}"
        export PEER_NUM="${PEER_NUM}"
    elif [[ ${1} == "channel_name" ]] ; then
        export CHANNEL_NAME=""
        until [[ ! -z "${CHANNEL_NAME}" ]] ; do
        read -r -p "Enter Channel name :: " CHANNEL_NAME </dev/tty
        done
        echo "Configuring Channel with name :: ${CHANNEL_NAME}"
        export CHANNEL_NAME="${CHANNEL_NAME}"
    else
        echo "User input for Choose_Env is mandatory"
    fi
}


#######################################
## Fabric CA
function Fabric_CA_Configure() {
    echo "Fabric CA Deployment...!"
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
    echo "Org Admin Configuration...!"
    export ORDERER_ADMIN_PASS=$(base64 <<< ${K8S_NAMESPACE}-ord-admin)
    export PEER_ADMIN_PASS=$(base64 <<< ${K8S_NAMESPACE}-peer-org${ORG_NUM}-admin)

    ## getting CA_INGRESS
    Setup_Namespace cas
    export CA_INGRESS=$(kubectl get ingress ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].spec.rules[0].host}")
    export CA_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].metadata.name}")

    ## Orderer Organisation
    ######################
    echo "Configuring Orderer Admin...!"
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
    echo "Configuring Peer Admin...!"
    export Admin_Conf=Peer
    Setup_Namespace cas
    Choose_Env org_number

    ## Get identity of peer-org${ORG_NUM}-admin (this should not exist at first)
    if $(kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity list --id peer-org${ORG_NUM}-admin) ; then
        echo "identity of peer-org${ORG_NUM}-admin already there...!"
    else
        ## Register Peer Admin if the previous command did not work
        kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client register --id.name peer-org${ORG_NUM}-admin --id.secret ${PEER_ADMIN_PASS} --id.attrs 'admin=true:ecert'

        ## Enroll the Organisation Admin identity
        FABRIC_CA_CLIENT_HOME=${PROD_DIR}/config fabric-ca-client enroll -u https://peer-org${ORG_NUM}-admin:${PEER_ADMIN_PASS}@${CA_INGRESS} -M ${PROD_DIR}/Org${ORG_NUM}MSP
        mkdir -p ${PROD_DIR}/config/Org${ORG_NUM}MSP/admincerts
        cp ${PROD_DIR}/config/Org${ORG_NUM}MSP/signcerts/* ${PROD_DIR}/config/Org${ORG_NUM}MSP/admincerts
        Save_Admin_Crypto
    fi
}


#######################################
## Save Crypto Material
function Save_Admin_Crypto() {
    if [[ ${Admin_Conf} == Orderer ]] ; then
        echo "Saving Orderer Crypto to K8s"
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
        echo "Saving Peer Crypto to K8s"
        ## Peer Organisation
        Setup_Namespace peers
        echo "Saving Crypto Material for ${Admin_Conf} with namespace_options : ${namespace_options}"

        ## Create a secret to hold the admincert:
        export ORG_CERT=$(ls ${PROD_DIR}/config/Org${ORG_NUM}MSP/admincerts/cert.pem)
        kubectl create secret generic ${namespace_options} hlf--peer-org${ORG_NUM}-admincert --from-file=cert.pem=${ORG_CERT}

        ## Create a secret to hold the admin key:
        export ORG_KEY=$(ls ${PROD_DIR}/config/Org${ORG_NUM}MSP/keystore/*_sk)
        kubectl create secret generic ${namespace_options} hlf--peer-org${ORG_NUM}-adminkey --from-file=key.pem=${ORG_KEY}

        ## Create a secret to hold the CA certificate:
        export CA_CERT=$(ls ${PROD_DIR}/config/Org${ORG_NUM}MSP/cacerts/*.pem)
        kubectl create secret generic ${namespace_options} hlf--peer-org${ORG_NUM}-ca-cert --from-file=cacert.pem=${CA_CERT}

    else
        echo "Admin_Conf can't be empty...!"
    fi
}


#######################################
## Genesis and channel
function Genesis_Create() {
    echo "Create Genesis Block...!"
    export P_W_D=${PWD} ; cd ${PROD_DIR}/config
    ## Create Genesis block
    configtxgen -profile OrdererGenesis -outputBlock ./genesis.block
    ## Save them as secrets
    Setup_Namespace orderers && kubectl create secret generic ${namespace_options} hlf--genesis --from-file=genesis.block
    cd ${P_W_D}
}


#######################################
## Genesis and channel
function Channel_Create() {
    echo "Create Channel Block...!"
    Choose_Env channel_name

    export P_W_D=${PWD} ; cd ${PROD_DIR}/config
    ## Create Channel
    configtxgen -profile ${CHANNEL_NAME} -channelID ${CHANNEL_NAME} -outputCreateChannelTx ./${CHANNEL_NAME}.tx
    ## Save them as secrets
    Setup_Namespace peers && kubectl create secret generic ${namespace_options} hlf--channel --from-file=${CHANNEL_NAME}.tx
    cd ${P_W_D}
}


#######################################
## Fabric Orderer nodes Creation
function Orderer_Conf() {
    echo "Create and Add Orderer node...!"
    Choose_Env order_number

    export ORDERER_NODE_PASS=$(base64 <<< ${K8S_NAMESPACE}-ord-${ORDERER_NUM})

    ## getting CA_INGRESS value and Gatering cas pod name
    Setup_Namespace cas
    export CA_INGRESS=$(kubectl get ingress ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].spec.rules[0].host}")
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
    echo "Create and Add Peer node...!"

    Choose_Env org_number
    Choose_Env peer_number

    export PEER_NODE_PASS=$(base64 <<< ${K8S_NAMESPACE}-peer-org${ORG_NUM}-${PEER_NUM})

    ## getting CA_INGRESS value and Gatering cas pod name
    Setup_Namespace cas
    export CA_INGRESS=$(kubectl get ingress ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].spec.rules[0].host}")
    export CA_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].metadata.name}")

    ## Install CouchDB chart
    Setup_Namespace peers
    envsubst < ${PROD_DIR}/helm_values/cdb-peer.yaml > ${PROD_DIR}/helm_values/cdb-peer-org${ORG_NUM}-${PEER_NUM}.yaml
    helm install stable/hlf-couchdb -n cdb-peer-org${ORG_NUM}-${PEER_NUM} ${namespace_options} -f ${PROD_DIR}/helm_values/cdb-peer-org${ORG_NUM}-${PEER_NUM}.yaml

    ## Check that CouchDB is running
    export CDB_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-couchdb,release=cdb-peer-org${ORG_NUM}-${PEER_NUM}" -o jsonpath="{.items[*].metadata.name}")

    until $(kubectl logs ${namespace_options} $CDB_POD | grep 'Apache CouchDB has started on') ; do
        echo "waiting for ${CDB_POD} to start...!"
        sleep 2
    done
    echo "CouchDB started...! : ${CDB_POD}"


    ## Register Peer with CA
    kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client register --id.name peer-org${ORG_NUM}-${PEER_NUM} --id.secret ${PEER_NODE_PASS} --id.type peer
    FABRIC_CA_CLIENT_HOME=${PROD_DIR}/config fabric-ca-client enroll -d -u https://peer-org${ORG_NUM}-${PEER_NUM}:${PEER_NODE_PASS}@${CA_INGRESS} -M peer-org${ORG_NUM}-${PEER_NUM}_MSP


    ## Save the Peer certificate in a secret
    Setup_Namespace peers
    export NODE_CERT=$(ls ${PROD_DIR}/config/peer-org${ORG_NUM}-${PEER_NUM}_MSP/signcerts/*.pem)
    kubectl create secret generic ${namespace_options} hlf--peer-org${ORG_NUM}-${PEER_NUM}-idcert --from-file=cert.pem=${NODE_CERT}

    ## Save the Peer private key in another secret
    export NODE_KEY=$(ls ${PROD_DIR}/config/peer-org${ORG_NUM}-${PEER_NUM}_MSP/keystore/*_sk)
    kubectl create secret generic ${namespace_options} hlf--peer-org${ORG_NUM}-${PEER_NUM}-idkey --from-file=key.pem=${NODE_KEY}

    ## Install Peer using helm
    envsubst < ${PROD_DIR}/helm_values/peer.yaml > ${PROD_DIR}/helm_values/peer-org${ORG_NUM}-${PEER_NUM}.yaml
    helm install stable/hlf-peer -n peer-org${ORG_NUM}-${PEER_NUM} ${namespace_options} -f ${PROD_DIR}/helm_values/peer-org${ORG_NUM}-${PEER_NUM}.yaml

    ## check that Peer is running
    export PEER_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-peer,release=peer-org${ORG_NUM}-${PEER_NUM}" -o jsonpath="{.items[0].metadata.name}")

    until $(kubectl logs ${namespace_options} $PEER_POD | grep 'Starting peer') ; do
        echo "waiting for ${PEER_POD} to start...!"
        sleep 2
    done
    echo "Orderer nodes ord${PEER_NUM} started...! : ${PEER_POD}"
}



#######################################
## Create channel
function Create_Channel() {
    echo "Create channel in peer node : Peer1"
    Setup_Namespace peers
    ## Create channel (do this only once in Peer 1)
    export PEER_NUM="1"

    Choose_Env org_number
    Choose_Env channel_name

    echo "Configuring Channel with name :: $CHANNEL_NAME on peer : peer-org${ORG_NUM}-${PEER_NUM}"

    export PEER_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-peer,release=peer-org${ORG_NUM}-${PEER_NUM}" -o jsonpath="{.items[0].metadata.name}")
    kubectl exec ${namespace_options} ${PEER_POD} -- peer channel create -o ord1-hlf-ord.orderers.svc.cluster.local:7050 -c ${CHANNEL_NAME} -f /hl_config/channel/${CHANNEL_NAME}.tx

}


#######################################
## Join and Fetch channel
function Join_Channel() {
    Setup_Namespace peers
    Choose_Env org_number
    Choose_Env peer_number
    Choose_Env channel_name

    echo "Join Channel in peer : peer-org${ORG_NUM}-${PEER_NUM}"
    export PEER_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-peer,release=peer-org${ORG_NUM}-${PEER_NUM}" -o jsonpath="{.items[0].metadata.name}")
    echo "Connecting with Peer : peer-org${ORG_NUM}-${PEER_NUM} on pod : ${PEER_POD}"

    export CHANNEL_NAME=""
    until [[ ! -z "${CHANNEL_NAME}" ]] ; do
      read -r -p "Enter Channel name to join from peer peer-org${ORG_NUM}-${PEER_NUM} :: " CHANNEL_NAME </dev/tty
    done

      export FIRST_PEER_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-peer,release=peer-org${ORG_NUM}-1" -o jsonpath="{.items[0].metadata.name}")
      if [[ kubectl exec ${FIRST_PEER_POD} ${namespace_options} -- peer channel list | grep ${CHANNEL_NAME} ]] ; then
        echo "channel ${CHANNEL_NAME} found...! ; joining from peer peer-org${ORG_NUM}-${PEER_NUM}"
      else
        echo "channel ${CHANNEL_NAME} not found...!, please give the correct chaneel name which exist..!"
        CHANNEL_LIST=$(kubectl exec ${FIRST_PEER_POD} ${namespace_options} -- peer channel list)
        echo "these are the channels available in the ${FIRST_PEER_POD}"
        for channellist in ${CHANNEL_LIST[@]} ; do
            echo "$channellist"
        done
        exit 1
      fi

    echo "Fetching and joining Channel with name :: $CHANNEL_NAME on peer : peer-org${ORG_NUM}-${PEER_NUM} wich has name : ${PEER_POD}"

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
elif [[ $option = cert-manager ]]; then
    echo "Configure CA Domain Name in file /helm_values/ca.yaml"
    Cert_Manager_Configure
    echo "sleeping for 10 sec" ; sleep 10
elif [[ $option = fabric-ca ]]; then
    Fabric_CA_Configure
    echo "sleeping for 10 sec" ; sleep 10
elif [[ $option = orgadmin ]]; then
    Orgadmin_Configure
    echo "sleeping for 10 sec" ; sleep 10
elif [[ $option = genesis-block ]]; then
    Genesis_Create
    echo "sleeping for 10 sec" ; sleep 10
elif [[ $option = channel-block ]]; then
    Channel_Create
    echo "sleeping for 10 sec" ; sleep 10
elif [[ $option = orderer-create ]]; then
    Orderer_Conf
    echo "sleeping for 10 sec" ; sleep 10
elif [[ $option = peer-create ]]; then
    Peer_Conf
    echo "sleeping for 10 sec" ; sleep 10
elif [[ $option = channel-create ]]; then
    Create_Channel
    echo "sleeping for 10 sec" ; sleep 10
elif [[ $option = channel-join ]]; then
    Join_Channel
    echo "sleeping for 10 sec" ; sleep 10
else
	echo "$Command_Usage"
cat << EOF
_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_

Main modes of operation:

initial         :   Initialisation for the HLF Cluster, It will create fast storageclass, nginx ingress and namespaces
cert-manager    :   CA Mager Configuration
fabric-ca       :   Deploy Fabric CA on namespace ca 
orgadmin        :   Orderer and Peer Admin certs creation and store it in the K8s secrets on namespace orderers and peers
genesis-block   :   Genesis block creation
channel-block   :   Creating the Channel
orderer-create  :   Create the Orderers certs and configure it in the K8s secrets, Deploying the Orderers nodes on namespace orderers
peer-create     :   Create the Orderers certs and configure it in the K8s secrets, Deploying the Peers nodes on namespace peers
channel-create  :   One time configuraiton on first peer (peer-org1-1 / peer-org2-1) on each organisation ; Creating the channel in one peer
channel-join    :   Join to the channel which we created before


First Time Deployment :
+++++++++++++++++++++++

initial
cert-manager
fabric-ca
orgadmin --- (1 orderer admin configuration, "N" peer admin configuration for "N" organisation)
genesis-block
channel-block
orderer-create (Create "N" number of orderers which mentioned in "configtx.yaml")
peer-create --- (Create "N" Number of peers for "N" Orderers == "N*N")
channel-create (One time configuration, run this only on one peer per Organisation [ peer-org1-1 / peer-org2-1 ])
channel-join --- (Run on "N" Peers on all Organisation)
_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_
EOF
fi