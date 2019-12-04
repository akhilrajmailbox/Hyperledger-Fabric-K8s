#!/bin/bash
export PROD_DIR="./"

if [[ ! -d ${PROD_DIR}/helm_values/custom_values ]] ; then
    echo "Custom Helm Values Store Creating...!"
    mkdir ${PROD_DIR}/helm_values/custom_values
fi

#######################################
## Cloud Provider
function Cloud_Provider() {
    export CLOUD_PROVIDER=""
    until [[ ${CLOUD_PROVIDER} == "AWS" ]] || [[ ${CLOUD_PROVIDER} == "Azure" ]] ; do
        echo "Enter Either AWS or Azure"
        read -r -p "Enter your Cloud Provider :: " CLOUD_PROVIDER </dev/tty
        export CLOUD_PROVIDER=$CLOUD_PROVIDER
    done
}

#######################################
## helm and tiller
function Helm_Configure() {
    echo "Configuring Helm in the k8s..!"
    # kubectl create -f helm-rbac.yaml
    # helm init --service-account tiller
    kubectl create serviceaccount --namespace kube-system tiller
    kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller
    kubectl patch deploy --namespace kube-system tiller-deploy -p '{"spec":{"template":{"spec":{"serviceAccount":"tiller"}}}}'      
    helm init --service-account tiller --upgrade
}


#######################################
## configure storageclass
function Storageclass_Configure() {
    Cloud_Provider
    echo "Configuring custom Fast storage class for the deployment...!"
    if [[ ${CLOUD_PROVIDER} == "AWS" ]] ; then
        echo "Configuring fast storageclass on ${CLOUD_PROVIDER}"
    elif [[ ${CLOUD_PROVIDER} == "Azure" ]] ; then
        echo "Configuring fast storageclass on ${CLOUD_PROVIDER}"
    else
        echo "CLOUD_PROVIDER not found..!, task aborting..!"
        exit 1
    fi
    
    if kubectl get storageclass | grep fast >/dev/null ; then
        echo "fast storageclass already available on your K8s Cluster"
    else
        kubectl create -f ${PROD_DIR}/extra/${CLOUD_PROVIDER}-storageclass.yaml
    fi
}

#######################################
## NGINX Ingress controller
function Nginx_Configure() {
    echo "Configure Ingress server for the deployment...!"
    Setup_Namespace ingress-controller
    helm install stable/nginx-ingress -n nginx-ingress ${namespace_options}
    Pod_Status_Wait
}


#######################################
## Check pod status
function Pod_Status_Wait() {
    echo "Checking pod status on : ${namespace_options} for the pod : ${1}"
    Pod_Name=$(kubectl ${namespace_options} get pods ${1} | awk '{if(NR>1)print $1}')

    for i in ${Pod_Name} ; do
        Pod_Status=""
        until [[ ${Pod_Status} == "true" ]] ; do
            echo "Waiting for the pod : ${i} to start...!"
            sleep 2
            export Pod_Status=$(kubectl ${namespace_options} get pods ${i} -o jsonpath="{.status.containerStatuses[0].ready}")
        done
        echo "The pod : ${i} started and running...!"
    done
}


#######################################
## Certificate manager
function Cert_Manager_Configure() {
    echo "CA Mager Configuration...!"
    Setup_Namespace cert-manager

    # kubectl apply -f ${PROD_DIR}/extra/CRDs.yaml
    kubectl apply --validate=false -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.12/deploy/manifests/00-crds.yaml
    helm repo add jetstack https://charts.jetstack.io
    sleep 3
    # helm install stable/cert-manager -n cert-manager ${namespace_options}
    helm install jetstack/cert-manager -n cert-manager ${namespace_options}
    Pod_Status_Wait
    kubectl apply -f ${PROD_DIR}/extra/certManagerCI_staging.yaml
    kubectl apply -f ${PROD_DIR}/extra/certManagerCI_production.yaml
}


#######################################
## Initial setup
function Setup_Namespace() {
    echo "Custom NameSpace Configuration : ${1}"

    if [[ ${1} == "create" ]] ; then
        kubectl create ns cas
        kubectl create ns orderers
        kubectl create ns peers
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
    elif [[ ${1} == "cert-manager" ]] ; then
        export K8S_NAMESPACE=cert-manager
        namespace_options="--namespace=${K8S_NAMESPACE}"
        echo ${namespace_options}
    elif [[ ${1} == "ingress-controller" ]] ; then
        export K8S_NAMESPACE=ingress-controller
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
        until [[ "${ORDERER_NUM}" == "1" ]] || [[ "${ORDERER_NUM}" == "2" ]] || [[ "${ORDERER_NUM}" == "3" ]] || [[ "${ORDERER_NUM}" == "4" ]] || [[ "${ORDERER_NUM}" == "5" ]] ; do
        read -r -p "Enter Orderer ID (integers only : 1 , 2 , 3 , 4 or 5) :: " ORDERER_NUM </dev/tty
        done
        echo "Configuring Orderer with ID :: ${ORDERER_NUM}"
        export ORDERER_NUM="${ORDERER_NUM}"
    elif [[ ${1} == "peer_number" ]] ; then
        export PEER_NUM=""
        # until [[ "${PEER_NUM}" =~ ^[0-9]+$ ]] ; do
        until [[ "${PEER_NUM}" == "1" ]] || [[ "${PEER_NUM}" == "2" ]] || [[ "${PEER_NUM}" == "3" ]] || [[ "${PEER_NUM}" == "4" ]] ; do
        read -r -p "Enter Peer ID (integers only : 1 , 2 , 3 or 4) :: " PEER_NUM </dev/tty
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
    elif [[ ${1} == "channel_opt" ]] ; then
        export CHANNEL_OPT=""
        until [[ "${CHANNEL_OPT}" == "Org1Channel" ]] || [[ "${CHANNEL_OPT}" == "Org2Channel" ]] || [[ "${CHANNEL_OPT}" == "TwoOrgsChannel" ]] ; do
        read -r -p "Enter Channel Option (Org1Channel, Org2Channel or TwoOrgsChannel) :: " CHANNEL_OPT </dev/tty
        done
        echo "Configuring Channel with Option :: ${CHANNEL_OPT}"
        export CHANNEL_OPT="${CHANNEL_OPT}"
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

    until kubectl logs ${namespace_options} ${CA_POD} | grep "Listening on" > /dev/null 2>&1 ; do
        sleep 2
        echo "waiting for CA to be up and running..!"
    done
    Pod_Status_Wait ${CA_POD}

    ## Check that we don't have a certificate
    if $(kubectl exec ${namespace_options} ${CA_POD} -- cat /var/hyperledger/fabric-ca/msp/signcerts/cert.pem > /dev/null 2>&1) ; then
        echo "Certificates are already available...!"
    else
        kubectl exec ${namespace_options} ${CA_POD} -- bash -c 'fabric-ca-client enroll -d -u http://${CA_ADMIN}:${CA_PASSWORD}@${SERVICE_DNS}:7054'
    fi

    ## Check that ingress works correctly
    export CA_INGRESS=$(kubectl get ingress ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].spec.rules[0].host}")
    curl https://${CA_INGRESS}/cainfo
}


#######################################
## Org Orderer Organisation Identities
function Orgadmin_Orderer_Configure() {

    if [[ -d ${PROD_DIR}/config/OrdererMSP ]] ; then
        echo "Orderer Admin already configured...!"
        echo "Please move/rename the folder ${PROD_DIR}/config/OrdererMSP, then try to run this command again...!"
        echo ""
        echo -e "Delete the secrets also. \n kubectl -n peers delete secrets hlf--ord-admincert hlf--ord-adminkey hlf--ord-ca-cert"
        echo ""
        echo "Warning :: I sure hope you know what you're doing...!"
        echo ""
        exit 1
    else
        echo "Configuring Org Orderer Admin...!"
        export ORDERER_ADMIN_PASS=$(base64 <<< ${K8S_NAMESPACE}-ord-admin)

        ## getting CA_INGRESS
        Setup_Namespace cas
        export CA_INGRESS=$(kubectl get ingress ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].spec.rules[0].host}")
        export CA_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].metadata.name}")

        export Admin_Conf=Orderer
        ## Get identity of ord-admin (this should not exist at first)
        if $(kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity list --id ord-admin > /dev/null 2>&1) ; then
            echo "identity of ord-admin already there...!"
            echo "If you really want to recreate the identity , the run the following command to remove the identiry : ord-admin from CA Server, then run the same command again to create it"
            echo "kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity remove ord-admin"
            echo ""
            echo "Warning :: I sure hope you know what you're doing...!"
            echo ""
            exit 1
        else
            ## Register Orderer Admin if the previous command did not work
            kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client register --id.name ord-admin --id.secret ${ORDERER_ADMIN_PASS} --id.attrs 'admin=true:ecert'

            ## Enroll the Organisation Admin identity
            FABRIC_CA_CLIENT_HOME=${PROD_DIR}/config fabric-ca-client enroll -u https://ord-admin:${ORDERER_ADMIN_PASS}@${CA_INGRESS} -M OrdererMSP
            mkdir -p ${PROD_DIR}/config/OrdererMSP/admincerts
            cp ${PROD_DIR}/config/OrdererMSP/signcerts/* ${PROD_DIR}/config/OrdererMSP/admincerts
            Save_Admin_Crypto
        fi
    fi
}


#######################################
## Org Peer Organisation Identities
function Orgadmin_Peer_Configure() {
    
    Choose_Env org_number
    if [[ -d ${PROD_DIR}/config/Org${ORG_NUM}MSP ]] ; then
        echo "Peer Admin already configured...!"
        echo "Please move/rename the folder ${PROD_DIR}/config/Org${ORG_NUM}MSP, then try to run this command again...!"
        echo ""
        echo -e "Delete the secrets also. \n kubectl -n peers delete secrets hlf--peer-org${ORG_NUM}-admincert hlf--peer-org${ORG_NUM}-adminkey hlf--peer-org${ORG_NUM}-ca-cert"
        echo ""
        echo "Warning :: I sure hope you know what you're doing...!"
        echo ""
        exit 1
    else
        echo "Configuring Org Peer Admin...!"
        export PEER_ADMIN_PASS=$(base64 <<< ${K8S_NAMESPACE}-peer-org${ORG_NUM}-admin)

        ## getting CA_INGRESS
        Setup_Namespace cas
        export CA_INGRESS=$(kubectl get ingress ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].spec.rules[0].host}")
        export CA_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].metadata.name}")

        export Admin_Conf=Peer
        ## Get identity of peer-org${ORG_NUM}-admin (this should not exist at first)
        if $(kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity list --id peer-org${ORG_NUM}-admin > /dev/null 2>&1) ; then
            echo "identity of peer-org${ORG_NUM}-admin already there...!"
            echo "If you really want to recreate the identity , the run the following command to remove the identiry : peer-org${ORG_NUM}-admin from CA Server, then run the same command again to create it"
            echo "kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity remove peer-org${ORG_NUM}-admin"
            echo ""
            echo "Warning :: I sure hope you know what you're doing...!"
            echo ""
            exit 1
        else
            ## Register Peer Admin if the previous command did not work
            kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client register --id.name peer-org${ORG_NUM}-admin --id.secret ${PEER_ADMIN_PASS} --id.attrs 'admin=true:ecert'

            ## Enroll the Organisation Admin identity
            FABRIC_CA_CLIENT_HOME=${PROD_DIR}/config fabric-ca-client enroll -u https://peer-org${ORG_NUM}-admin:${PEER_ADMIN_PASS}@${CA_INGRESS} -M Org${ORG_NUM}MSP
            mkdir -p ${PROD_DIR}/config/Org${ORG_NUM}MSP/admincerts
            cp ${PROD_DIR}/config/Org${ORG_NUM}MSP/signcerts/* ${PROD_DIR}/config/Org${ORG_NUM}MSP/admincerts
            Save_Admin_Crypto
        fi
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

    Setup_Namespace orderers
    if [[ -f ${PROD_DIR}/config/genesis.block ]] ; then
        echo "genesis block already created...!"
        echo -e "Please move the file ${PROD_DIR}/config/genesis.block. \n Delete the secrets from orderer namespace : kubectl ${namespace_options} delete secrets hlf--genesis. \n then try to run this command again...!"
        echo ""
        echo "Warning :: I sure hope you know what you're doing...!"
        echo ""
        exit 1
    else
        echo "Create Genesis Block...!"
        export P_W_D=${PWD} ; cd ${PROD_DIR}/config
        ## Create Genesis block
        configtxgen -profile OrdererGenesis -channelID systemchannel -outputBlock ./genesis.block
        ## Save them as secrets
        kubectl create secret generic ${namespace_options} hlf--genesis --from-file=genesis.block
        cd ${P_W_D}
    fi
}


#######################################
## Genesis and channel
function Channel_Create() {
    
    Setup_Namespace peers
    Choose_Env channel_name
    Choose_Env channel_opt
    if [[ -f ${PROD_DIR}/config/${CHANNEL_NAME}.tx ]] ; then
        echo "Channel block already created...!"
        echo -e "Please move the file ${PROD_DIR}/config/${CHANNEL_NAME}.tx. \n Delete the secrets from orderer namespace : kubectl ${namespace_options} delete secrets hlf--channel. \n then try to run this command again...!"
        echo ""
        echo "Warning :: I sure hope you know what you're doing...!"
        echo ""
        exit 1
    else
        echo "Create Channel Block...!"

        export P_W_D=${PWD} ; cd ${PROD_DIR}/config
        ## Create Channel
        configtxgen -profile ${CHANNEL_OPT} -channelID ${CHANNEL_NAME} -outputCreateChannelTx ./${CHANNEL_NAME}.tx
        ## Save them as secrets
        kubectl create secret generic ${namespace_options} hlf--channel --from-file=${CHANNEL_NAME}.tx
        cd ${P_W_D}
    fi
}


#######################################
## Fabric Orderer nodes Creation
function Orderer_Conf() {

    Choose_Env order_number
    if [[ -d ${PROD_DIR}/config/ord${ORDERER_NUM}_MSP ]] ; then
        echo "ord${ORDERER_NUM} already configured...!"
        echo "Please move/rename the folder ${PROD_DIR}/config/ord${ORDERER_NUM}_MSP, then try to run this command again...!"
        echo ""
        echo -e "Delete the secrets also. \n kubectl -n orderers delete secrets hlf--ord${ORDERER_NUM}-idcert hlf--ord${ORDERER_NUM}-idkey"
        echo ""
        echo "Warning :: I sure hope you know what you're doing...!"
        echo ""
        exit 1
    else
        echo "Create and Add Orderer node...!"
        export ORDERER_NODE_PASS=$(base64 <<< ${K8S_NAMESPACE}-ord-${ORDERER_NUM})

        ## getting CA_INGRESS value and Gatering cas pod name
        Setup_Namespace cas
        export CA_INGRESS=$(kubectl get ingress ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].spec.rules[0].host}")
        export CA_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].metadata.name}")

        ## Register orderer with CA
        Setup_Namespace cas
        ## Get identity of ord${ORDERER_NUM} (this should not exist at first)
        if $(kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity list --id ord${ORDERER_NUM} > /dev/null 2>&1) ; then
            echo "identity of ord${ORDERER_NUM} already there...!"
            echo "If you really want to recreate the identity , the run the following command to remove the identiry : ord${ORDERER_NUM} from CA Server, then run the same command again to create it"
            echo "kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity remove ord${ORDERER_NUM}"
            echo ""
            echo "Warning :: I sure hope you know what you're doing...!"
            echo ""
            exit 1
        else
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
            envsubst < ${PROD_DIR}/helm_values/ord.yaml > ${PROD_DIR}/helm_values/custom_values/ord${ORDERER_NUM}.yaml
            helm install stable/hlf-ord -n ord${ORDERER_NUM} ${namespace_options} -f ${PROD_DIR}/helm_values/custom_values/ord${ORDERER_NUM}.yaml

            ## Get logs from orderer to check it's actually started
            export ORD_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-ord,release=ord${ORDERER_NUM}" -o jsonpath="{.items[0].metadata.name}")

            until kubectl logs ${namespace_options} ${ORD_POD} | grep 'completeInitialization' > /dev/null 2>&1 ; do
                echo "checking for completeInitialization ; waiting for ${ORD_POD} to start...!"
                sleep 2
            done
            Pod_Status_Wait ${ORD_POD}
            echo "Orderer nodes ord${ORDERER_NUM} started...! : ${ORD_POD}"
        fi
    fi
}


#######################################
## Fabric Peer nodes Creation
function Peer_Conf() {

    Choose_Env org_number
    Choose_Env peer_number
    if [[ -d ${PROD_DIR}/config/peer${PEER_NUM}-org${ORG_NUM}_MSP ]] ; then
        echo "peer${PEER_NUM}-org${ORG_NUM} already configured...!"
        echo "Please move/rename the folder ${PROD_DIR}/config/peer${PEER_NUM}-org${ORG_NUM}_MSP, then try to run this command again...!"
        echo ""
        echo -e "Delete the secrets also. \n kubectl -n peers delete secrets hlf--peer${PEER_NUM}-org${ORG_NUM}-idcert hlf--peer${PEER_NUM}-org${ORG_NUM}-idkey"
        echo ""
        echo "Warning :: I sure hope you know what you're doing...!"
        echo ""
        exit 1
    else
        echo "Create and Add Peer node...!"

        export PEER_NODE_PASS=$(base64 <<< ${K8S_NAMESPACE}-peer${PEER_NUM}-org${ORG_NUM})

        ## getting CA_INGRESS value and Gatering cas pod name
        Setup_Namespace cas
        export CA_INGRESS=$(kubectl get ingress ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].spec.rules[0].host}")
        export CA_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].metadata.name}")

        ## Install CouchDB chart
        Setup_Namespace peers
        envsubst < ${PROD_DIR}/helm_values/cdb-peer.yaml > ${PROD_DIR}/helm_values/custom_values/cdb-peer${PEER_NUM}-org${ORG_NUM}.yaml
        helm install stable/hlf-couchdb -n cdb-peer${PEER_NUM}-org${ORG_NUM} ${namespace_options} -f ${PROD_DIR}/helm_values/custom_values/cdb-peer${PEER_NUM}-org${ORG_NUM}.yaml

        ## Check that CouchDB is running
        export CDB_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-couchdb,release=cdb-peer${PEER_NUM}-org${ORG_NUM}" -o jsonpath="{.items[*].metadata.name}")

        until kubectl logs ${namespace_options} $CDB_POD | grep 'Apache CouchDB has started on' > /dev/null 2>&1 ; do
            echo "waiting for ${CDB_POD} to start...!"
            sleep 2
        done
        Pod_Status_Wait ${CDB_POD}
        echo "CouchDB started...! : ${CDB_POD}"


        ## Register Peer with CA
        Setup_Namespace cas
        ## Get identity of peer${PEER_NUM}-org${ORG_NUM} (this should not exist at first)
        if $(kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity list --id peer${PEER_NUM}-org${ORG_NUM} > /dev/null 2>&1) ; then
            echo "identity of peer${PEER_NUM}-org${ORG_NUM} already there...!"
            echo "If you really want to recreate the identity , the run the following command to remove the identiry : peer${PEER_NUM}-org${ORG_NUM} from CA Server, then run the same command again to create it"
            echo "kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity remove peer${PEER_NUM}-org${ORG_NUM}"
            echo ""
            echo "Warning :: I sure hope you know what you're doing...!"
            echo ""
            exit 1
        else
            kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client register --id.name peer${PEER_NUM}-org${ORG_NUM} --id.secret ${PEER_NODE_PASS} --id.type peer
            FABRIC_CA_CLIENT_HOME=${PROD_DIR}/config fabric-ca-client enroll -d -u https://peer${PEER_NUM}-org${ORG_NUM}:${PEER_NODE_PASS}@${CA_INGRESS} -M peer${PEER_NUM}-org${ORG_NUM}_MSP


            ## Save the Peer certificate in a secret
            Setup_Namespace peers
            export NODE_CERT=$(ls ${PROD_DIR}/config/peer${PEER_NUM}-org${ORG_NUM}_MSP/signcerts/*.pem)
            kubectl create secret generic ${namespace_options} hlf--peer${PEER_NUM}-org${ORG_NUM}-idcert --from-file=cert.pem=${NODE_CERT}

            ## Save the Peer private key in another secret
            export NODE_KEY=$(ls ${PROD_DIR}/config/peer${PEER_NUM}-org${ORG_NUM}_MSP/keystore/*_sk)
            kubectl create secret generic ${namespace_options} hlf--peer${PEER_NUM}-org${ORG_NUM}-idkey --from-file=key.pem=${NODE_KEY}

            ## Install Peer using helm
            envsubst < ${PROD_DIR}/helm_values/peer.yaml > ${PROD_DIR}/helm_values/custom_values/peer${PEER_NUM}-org${ORG_NUM}.yaml
            helm install stable/hlf-peer -n peer${PEER_NUM}-org${ORG_NUM} ${namespace_options} -f ${PROD_DIR}/helm_values/custom_values/peer${PEER_NUM}-org${ORG_NUM}.yaml

            ## check that Peer is running
            export PEER_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-peer,release=peer${PEER_NUM}-org${ORG_NUM}" -o jsonpath="{.items[0].metadata.name}")

            until kubectl logs ${namespace_options} $PEER_POD | grep 'Starting peer' > /dev/null 2>&1 ; do
                echo "waiting for ${PEER_POD} to start...!"
                sleep 2
            done
            Pod_Status_Wait ${PEER_POD}
            echo "Peer node peer${PEER_NUM}-org${ORG_NUM} started...! : ${PEER_POD}"
        fi
    fi
}



#######################################
## Create channel
function Create_Channel_On_Peer() {

    Choose_Env channel_name
    if [[ -f ${PROD_DIR}/config/${CHANNEL_NAME}.tx ]] ; then
        echo "Create channel : ${CHANNEL_NAME} in peer node : Peer1"
        Setup_Namespace peers
        ## Create channel (do this only once in Peer 1)
        export PEER_NUM="1"
        Choose_Env org_number

        echo "Configuring Channel with name :: $CHANNEL_NAME on peer : peer${PEER_NUM}-org${ORG_NUM}"
        export PEER_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-peer,release=peer${PEER_NUM}-org${ORG_NUM}" -o jsonpath="{.items[0].metadata.name}")
        Pod_Status_Wait ${PEER_POD}
        kubectl ${namespace_options} cp ${PROD_DIR}/config/${CHANNEL_NAME}.tx ${PEER_POD}:/${CHANNEL_NAME}.tx
        echo "kubectl exec ${namespace_options} ${PEER_POD} -- bash -c 'CORE_PEER_MSPCONFIGPATH=\$ADMIN_MSP_PATH peer channel create -o ord1-hlf-ord.orderers.svc.cluster.local:7050 -c ${CHANNEL_NAME} -f /${CHANNEL_NAME}.tx'" | bash
    else
        echo "Channel ${CHANNEL_NAME}.block for channel ${CHANNEL_NAME} not created yet...!"
        echo "Please run channel-block for create your channel..!"
        exit 1
    fi

}


# CORE_PEER_LOCALMSPID=Org1MSP
# CORE_PEER_MSPCONFIGPATH=/var/hyperledger/admin_msp/
# peer channel create -o ord1-hlf-ord.orderers.svc.cluster.local:7050 -c kogxchannel -f /kogxchannel.tx

#######################################
## Join and Fetch channel
function Join_Channel() {
    Setup_Namespace peers
    Choose_Env org_number
    Choose_Env peer_number
    Choose_Env channel_name

    echo "Join Channel in peer : peer${PEER_NUM}-org${ORG_NUM}"
    export PEER_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-peer,release=peer${PEER_NUM}-org${ORG_NUM}" -o jsonpath="{.items[0].metadata.name}")
    Pod_Status_Wait ${PEER_POD}
    echo "Connecting with Peer : peer${PEER_NUM}-org${ORG_NUM}on pod : ${PEER_POD}"
    echo "Fetching and joining Channel with name :: $CHANNEL_NAME on peer : peer${PEER_NUM}-org${ORG_NUM} wich has name : ${PEER_POD}"

    ## Fetch and join channel
    kubectl exec ${namespace_options} ${PEER_POD} -- rm -rf /var/hyperledger/${CHANNEL_NAME}.block
    kubectl exec ${namespace_options} ${PEER_POD} -- peer channel fetch config /var/hyperledger/${CHANNEL_NAME}.block -c ${CHANNEL_NAME} -o ord1-hlf-ord.orderers.svc.cluster.local:7050
    echo "kubectl exec ${namespace_options} ${PEER_POD} -- bash -c 'CORE_PEER_MSPCONFIGPATH=\$ADMIN_MSP_PATH peer channel join -b /var/hyperledger/${CHANNEL_NAME}.block'" | bash
    echo "I'm Waiting for the peer to join to my channel...." ; sleep 5
    if [[ $(kubectl exec ${PEER_POD} ${namespace_options} -- peer channel list | grep ${CHANNEL_NAME}) ]] ; then
        echo "peer peer${PEER_NUM}-org${ORG_NUM} successfully joined to channel : ${CHANNEL_NAME}"
    else
        echo "Channel : ${CHANNEL_NAME} not found..!, please check it manually or debug the issue..!"
        echo "Use this command to confirm : kubectl exec ${PEER_POD} ${namespace_options} -- peer channel list | grep ${CHANNEL_NAME}"
        exit 1
    fi
}


#######################################
## List channel
function List_Channel() {
    Setup_Namespace peers
    Choose_Env org_number
    Choose_Env peer_number

    export PEER_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-peer,release=peer${PEER_NUM}-org${ORG_NUM}" -o jsonpath="{.items[0].metadata.name}")
    echo "List Channels which peer : peer${PEER_NUM}-org${ORG_NUM} has joined...!"
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
    echo "sleeping for 2 sec" ; sleep 2
    Storageclass_Configure
    Nginx_Configure
    Setup_Namespace create
    echo "sleeping for 2 sec" ; sleep 2
elif [[ $option = cert-manager ]]; then
    Cert_Manager_Configure
    echo "sleeping for 2 sec" ; sleep 2
elif [[ $option = fabric-ca ]]; then
    echo "Configure CA Domain Name in file /helm_values/ca.yaml"
    Fabric_CA_Configure
    echo "sleeping for 2 sec" ; sleep 2
elif [[ $option = org-orderer-admin ]]; then
    Orgadmin_Orderer_Configure
    echo "sleeping for 2 sec" ; sleep 2
elif [[ $option = org-peer-admin ]]; then
    Orgadmin_Peer_Configure
    echo "sleeping for 2 sec" ; sleep 2
elif [[ $option = genesis-block ]]; then
    Genesis_Create
    echo "sleeping for 2 sec" ; sleep 2
elif [[ $option = channel-block ]]; then
    Channel_Create
    echo "sleeping for 2 sec" ; sleep 2
elif [[ $option = orderer-create ]]; then
    Orderer_Conf
    echo "sleeping for 2 sec" ; sleep 2
elif [[ $option = peer-create ]]; then
    Peer_Conf
    echo "sleeping for 2 sec" ; sleep 2
elif [[ $option = channel-create ]]; then
    Create_Channel_On_Peer
    echo "sleeping for 2 sec" ; sleep 2
elif [[ $option = channel-join ]]; then
    Join_Channel
    echo "sleeping for 2 sec" ; sleep 2
elif [[ $option = channel-ls ]]; then
    List_Channel
    echo "sleeping for 2 sec" ; sleep 2
else
	echo "$Command_Usage"
cat << EOF
_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_

Main modes of operation:

initial             :   Initialisation for the HLF Cluster, It will create fast storageclass, nginx ingress and namespaces
cert-manager        :   CA Mager Configuration
fabric-ca           :   Deploy Fabric CA on namespace ca 
org-orderer-admin   :   Orderer Admin certs creation and store it in the K8s secrets on namespace orderers
org-peer-admin      :   Peer Admin certs creation and store it in the K8s secrets on namespace peers
genesis-block       :   Genesis block creation
channel-block       :   Creating the Channel
orderer-create      :   Create the Orderers certs and configure it in the K8s secrets, Deploying the Orderers nodes on namespace orderers
peer-create         :   Create the Orderers certs and configure it in the K8s secrets, Deploying the Peers nodes on namespace peers
channel-create      :   One time configuraiton on first peer (peer-org1-1 / peer-org2-1) on each organisation ; Creating the channel in one peer
channel-join        :   Join to the channel which we created before
channel-ls          :   List all channels which a particular peer has joined

_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_
EOF
fi
