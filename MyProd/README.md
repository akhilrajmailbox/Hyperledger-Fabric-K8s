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