# Production Deployment


## Prerequisite

* go version 1.13.4
* envsubt
* GOHOME in your PATH Environment variable # export PATH=/Users/akhil/go/bin:$PATH
* [fabric-tools](https://github.com/hyperledger/homebrew-fabric/tree/master/Formula) for "configtxgen"
* kubectl
* [helm](https://helm.sh/docs/intro/install/)


### Install fabric-ca-client on your Mac / Linux system

```
go version
go get -u github.com/hyperledger/fabric-ca/cmd/...
```

### Install Fabric-tools on your Mac

[here](https://github.com/hyperledger/homebrew-fabric/tree/master/Formula)

```
brew tap aidtechnology/homebrew-fabric
xcode-select --install
brew install aidtechnology/fabric/fabric-tools@1.3.0

which cryptogen
which configtxgen
which configtxlator
```

[Configure Cert-manager with Let's Encrypt](https://cert-manager.io/docs/tutorials/acme/ingress/)

### Debug Cert-manager; You can actually find error messages in each of these, like so:

```
kubectl get certificaterequest
kubectl describe certificaterequest X
kubectl get order
kubectl describe order X
kubectl get challenge
kubectl describe challenge X
```

[link](https://github.com/jetstack/cert-manager/issues/2020)

[configtx-example](https://github.com/hyperledger/fabric-sdk-go/blob/master/test/fixtures/fabric/v1.3/config/configtx.yaml)



## K8s Deployment


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





## First Time Deployment :

```
./hlf.sh -o initial
./hlf.sh -o cert-manager
./hlf.sh -o fabric-ca
./hlf.sh -o org-orderer-admin
./hlf.sh -o org-peer-admin ---> ("N" peer admin configuration for "N" organisation)
./hlf.sh -o genesis-block
./hlf.sh -o channel-block
./hlf.sh -o orderer-create (Create "N" number of orderers which mentioned in "configtx.yaml")
./hlf.sh -o peer-create ---> (Create "N" Number of peers for "N" Orderers == "N*N")
./hlf.sh -o channel-create (One time configuration, run this only on one peer per Organisation [ peer-org1-1 / peer-org2-1 ])
./hlf.sh -o channel-join ---> (Run on "N" Peers on all Organisation)
```