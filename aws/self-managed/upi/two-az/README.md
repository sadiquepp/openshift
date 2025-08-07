# Introduction
This doc will cover deployment of disconnected OpenShift using UPI in just two availability zones for special use cases using an external manually managed load balancer for API and Ingress.

# Pre-Requisites Knowledge
* Understanding of AWS
* Understanding of OpenShift
* Understanding of difference between IPI and UPI
* Have experience of installing standard IPI and UPI on AWS on standard three Availability Zones
* Have a good understanding of how STS works with OpenShift using AssumeRoleWithWebIdentity
* Understanding of requirements for disconnected ocp on AWS

# Requirements
* A disconnected vpc with all the required vpc endpoints like s3, ec2, sts, elasticloadbalancing
* A mirror registry with the required release images and operator images alread mirrored and accessible from the vpc.
* DNS should be managed outside of Openshift. There will be no route53 integration. 
* DNS must be set up to resolve api.<clustername>.<cluster-domain>, api-int.<clustername>.<cluster-domain>  and *.apps.<clustername>.<cluster-domain> to the LoadBalancer.
* External LoadBalncer for api, api-int and *.apps must be set up while backend nodes will be configured during the installation. A better way is to give predictive IP address to bootstrap node and master nodes so that LoadBalancer can be configured upfront. Current CloudFormation templates do not set pre-determined ips to these nodes. Feel free to customize CF templates if that is desired.
* LoadBalancer should accept 6443 for api and api-int and be able to forward to bootstrap and master nodes during the deployment when those backend nodes are added.
* LoadBalancer should accept 22623 for api and api-int and be able to forward to bootstrap and master nodes during the deployment when those backend nodes are added.

# Generate STS resources on AWS and openshift artifacts.
* Extract openshift-install from mirror registry.
```
oc adm release extract -a <pull-secret-file> --icsp-file=<icsp-file.yaml> --command=openshift-install mirror.hub.mylab.com:8443/openshift/release-images:4.18.5-x86_64
```

* Extract ccoctl from the release image on mirror registry.
```
mkdir sts
cd sts
RELEASE_IMAGE=$(~/openshift-install version | awk '/release image/ {print $3}')
CCO_IMAGE=$(oc adm release info -a pull-secret.json --image-for='cloud-credential-operator' $RELEASE_IMAGE)
oc image extract $CCO_IMAGE --file="/usr/bin/ccoctl" -a /home/ec2-user/pull-secret.txt
chmod 755 ccoctl
```

* Extract credential requests
```
oc adm release extract --credentials-requests \
      --cloud=aws \
      --to=credrequests \
      -a pull-secret.json \
      mirror.mylab.com:8443/openshift/release-images:4.18.5-x86_64
```

* Set up STS. Below will create keypair, cloudfront, s3 bucket, identity provider, IAM roles and required manifests that needs to be injected to the cluster.
```
./ccoctl aws create-all --name <cluster-name-xxx> --credentials-requests-dir credrequests/ --region ap-southeast-1 --create-private-s3-bucket
cd ..
```

# Create Openshift Manifests and Ignition.
* Develop install-config.yaml using the example given. Update baseDomain, machineNetwork, pullSecret, imageContentSource, sshKey and additionalTrustBundle as needed.

* Crate a directory and copy install-config.yaml to that directory
```
mkdir install-dir
cp install-config.yaml install-dir
```
* Create openshift manifests
```
./openshift-install create manifests --dir install-dir/
```
* Copy STS manifests to the manifests directory

```
cp -prv sts/tls/ install-dir
cp sts/manifests/* install-dir/manifests/
```

* Delete manifests that creates master nodes and worker machine pool in third Availability zone

```
rm -f install-dir/openshift/99_openshift-cluster-api_master-machines-*.yaml
rm -f install-dir/openshift/99_openshift-machine-api_master-control-plane-machine-set.yaml
rm -f install-dir/openshift/99_openshift-cluster-api_worker-machineset-2.yaml
```
* Remvoe HostedZone details from DNS manifests
```
vi install-dir/manifests/cluster-dns-02-config.yml
```

* Create Ignition
```
./openshift-install create ignition-configs --dir install-dir
```

* Get the infraId
```
INFRA_ID=$(jq -r .infraID install-dir/metadata.json)
echo $INFRA_ID
```

* Create s3 bucket and push ignition for bootstrap node to the s3 bucket.
```
aws s3 mb s3://${INFRA_ID}
aws s3 cp install-dir/bootstrap.ign s3://${INFRA_ID}/bootstrap.ign
```
# Create Security Groups and IAM roles

* Set Variables

```
VPC_ID=<vpc_id>
VPC_CIDR=<vpc_cidr>
SUBNET_ID=<subnet_id_from_any_az>
```

* Replace Variables in CloudFormation Parameter file to create security group and IAM roles.
```
sed -i "s/infra_id/$INFRA_ID/g" security-group-and-role-parameter.json
sed -i "s/vpc_id/$VPC_ID/g" security-group-and-role-parameter.json
sed -i "s#vpc_cidr#$VPC_CIDR#g" security-group-and-role-parameter.json
sed -i "s/subnet_id/$SUBNET_ID/g" security-group-and-role-parameter.json
```
* Create the resources via CloudFormation Template 

```
aws cloudformation create-stack --stack-name security-group-role --template-body file://create-security-group-and-role.yaml --parameters file://security-group-and-role-parameter.json --capabilities CAPABILITY_NAMED_IAM
```
* Once CloudFormation stack creation is successful, set below variables after getting values from AWS Console -> CloudFormation Stack -> Select the Stack -> Outputs

~~~
MasterInstanceProfile=<master_instance_profile>
MasterSecurityGroupId=<master_sg_id>
WorkerInstanceProfile=<worker_instance_profile>
WorkerSecurityGroupId=<worker_sg_id>
~~~

# Create Bootstrap Node
* Get the rhcos AMI ID for your region and for the version of openshift going to be installed from official DOC. An example for 4.18 the list is here - https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/installing_on_aws/user-provisioned-infrastructure#installation-aws-user-infra-rhcos-ami_installing-restricted-networks-aws
```
RHCOS_AMI_ID=<rhcos_ami_id>
```

* Replace the variables in bootstrap-parameters.json
```
sed -i "s/infra_id/$INFRA_ID/g" bootstrap-parameters.json
sed -i "s/vpc_id/$VPC_ID/g" bootstrap-parameters.json
sed -i "s/subnet_id/$SUBNET_ID/g" bootstrap-parameters.json
sed -i "s/master_sg_id/$MasterSecurityGroupId/g" bootstrap-parameters.json
sed -i "s/rhcos_ami_id/$RHCOS_AMI_ID/g" bootstrap-parameters.json
```

* Create the stack to deploy bootstrap node
```
aws cloudformation create-stack --stack-name bootstrap --template-body file://create-bootstrap.yaml --parameters file://bootstrap-parameters.json --capabilities CAPABILITY_NAMED_IAM
```
* Once CloudFormation stack creation is successful, set below variables after getting values from AWS Console -> CloudFormation Stack -> Select the Stack -> Outputs

~~~
BootstrapPrivateIp=<boot_strap_private_ip>
~~~

* Once bootstrap private IP is available, Configure LoadBalancer to route 6443 and 22623 for both api and api-int to that ip address. Please do not proceed to next step before the LoadBalancer shows the bootstrap node as a healthy target and it's ready to send request to bootstrap node.

# Create ControlPlane Nodes
* Set required variables
```
CLUSTER_NAME=<cluster-name>
CLUSTER_DOMAIN_NAME=<cluster-domain-name>
SUBNET_ID_AZ1=<subnet_id_of_az1>
SUBNET_ID_AZ2=<subnet_id_of_az2>
CERTIFICATE_AUTHORITY=$(cat install-dir/master.ign | cut -f8 -d{ | cut -f2,3 -d: | cut -f1 -d})

````
* Inspect install-dir/master.ign
* Replace the variables in control plane parameters.json file.
```
sed -i "s/infra_id/$INFRA_ID/g" control-plane-parameters.json
sed -i "s/rhcos_ami_id/$RHCOS_AMI_ID/g" control-plane-parameters.json
sed -i "s/master_sg_id/$MasterSecurityGroupId/g" control-plane-parameters.json
sed -i "s/subnet_id_az1/$SUBNET_ID_AZ1/g" control-plane-parameters.json
sed -i "s/subnet_id_az2/$SUBNET_ID_AZ2/g" control-plane-parameters.json
sed -i "s/clustername/$CLUSTER_NAME/g" control-plane-parameters.json
sed -i "s/domainname/$CLUSTER_DOMAIN_NAME/g" control-plane-parameters.json
sed -i "s#certificate_authority#$CERTIFICATE_AUTHORITY#g" control-plane-parameters.json
```

* Create the stack to deploy ControlPlane node
```
aws cloudformation create-stack --stack-name control-plane --template-body file://create-control-plane.yaml --parameters file://control-plane-parameters.json
```

* Once CloudFormation stack creation is successful, get the private ip of the master nodes from AWS Console -> CloudFormation Stack -> Select the Stack -> Outputs

* Configure LoadBalancer to route 6443 and 22623 for both api and api-int to those ip addresses too in addition to he bootstrap nodes.

# Monitoring Cluster Status

* Once master nodes are created, machine-api will automatically deploy worker nodes in two AZs.

* Once ingress controller deploys Classic LB, update DNS for *.apps to route to that loadBalancer. More work needs to be done to set Ingress Controller use Externl Load Balancer which is still pending.

* Monitor cluster status by sourcing kubeconfig
```
export KUBECONFIG=install-dir/auth/kubeconfig
oc get co
oc get nodes
```

* Once the cluster is up and running with 3 masters and workers, you can terminate the bootstrap node by deleting bootstrap cloudformation stack.