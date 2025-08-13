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
* Pre-determine and reserve the ip for bootstrap node (From any AZ1 or AZ2 ) master0 (From AZ1), master1 (from AZ1), and master2 (From AZ2). It's recommended to do an explicit reservation for these ip addresses in AWS VCP -> Subnets -> Actions -> Edit IPv4 CIDR Reservation section.
* Configure external LoadBalncer to listen on 6443 and 22623 for api, api-int using the above nodes (1 bootstrap and 3 master) as the backend nodes.
* Pre-determine and reserve the ip for infra nodes infra1 (From AZ1), infra2 (from AZ1), and infra3 (From AZ2). It's recommended to do an explicit reservation for these ip addresses in AWS VCP -> Subnets -> Actions -> Edit IPv4 CIDR Reservation section.
* Configure external LoadBalncer to listen on 443 and 80 for *.apps and configure the infra nodes as its backend nodes.
* DNS should be managed outside of Openshift. There will be no route53 integration.
* Set up DNS to resolve api., api-int. and *.apps. to the respective LoadBalancer ips.

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
export INFRA_ID=$(jq -r .infraID install-dir/metadata.json)
echo $INFRA_ID
```

* Create s3 bucket and push ignition for bootstrap node to the s3 bucket.
```
aws s3 mb s3://${INFRA_ID}
aws s3 cp install-dir/bootstrap.ign s3://${INFRA_ID}/bootstrap.ign
```
# Create Security Groups and IAM roles

* Set VPC ID into a variable
```
export VPC_ID=<vpc_id>
```
* Set VPC CIDR into a variable
```
export VPC_CIDR=<vpc_cidr>
```
* Replace Variables in CloudFormation Parameter file to create security group and IAM roles.
```
sed -i "s/infra_id/$INFRA_ID/g" security-group-and-role-parameter.json
sed -i "s/vpc_id/$VPC_ID/g" security-group-and-role-parameter.json
sed -i "s#vpc_cidr#$VPC_CIDR#g" security-group-and-role-parameter.json
```
* Create the resources via CloudFormation Template 

```
aws cloudformation create-stack --stack-name security-group-role --template-body file://create-security-group-and-role.yaml --parameters file://security-group-and-role-parameter.json --capabilities CAPABILITY_NAMED_IAM
```
* Once CloudFormation stack creation is successful, set below variables after getting values from AWS Console -> CloudFormation Stack -> Select the Stack -> Outputs

~~~
export MasterSecurityGroupId=<master_sg_id>
export WorkerSecurityGroupId=<worker_sg_id>
~~~

# Create Bootstrap Node
* Get the rhcos AMI ID for your region and for the version of openshift going to be installed from official DOC. An example for 4.18 the list is here - https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/installing_on_aws/user-provisioned-infrastructure#installation-aws-user-infra-rhcos-ami_installing-restricted-networks-aws
```
export RHCOS_AMI_ID=<rhcos_ami_id>
```
* Set the private ip of bootstrap node into a variable.
```
export BOOTSTRAP_PRIVATE_IP=<bootstrap_private_ip>
```
* Set Subnet ID for AZ1 to a variable.
```
export SUBNET_ID_AZ1=<subnet_id_of_az1>
```
* Replace the variables in bootstrap-parameters.json
```
sed -i "s/infra_id/$INFRA_ID/g" bootstrap-parameters.json
sed -i "s/vpc_id/$VPC_ID/g" bootstrap-parameters.json
sed -i "s/subnet_id/$SUBNET_ID_AZ1/g" bootstrap-parameters.json
sed -i "s/master_sg_id/$MasterSecurityGroupId/g" bootstrap-parameters.json
sed -i "s/rhcos_ami_id/$RHCOS_AMI_ID/g" bootstrap-parameters.json
sed -i "s/bootstrap_private_ip/$BOOTSTRAP_PRIVATE_IP/g" bootstrap-parameters.json
```

* Create the stack to deploy bootstrap node
```
aws cloudformation create-stack --stack-name bootstrap --template-body file://create-bootstrap.yaml --parameters file://bootstrap-parameters.json --capabilities CAPABILITY_NAMED_IAM
```

* The API will now be available via Load Balancer if DNS and LB is already set up to have bootstrap node as the backend.

# Create ControlPlane Nodes
* Set Cluster Name into a variable.
```
export CLUSTER_NAME=<cluster-name>
```
* Set Cluster Domain Name into a variable.
```
export CLUSTER_DOMAIN_NAME=<cluster-domain-name>
```
* Set Subnet ID for AZ1 to a variable.
```
export SUBNET_ID_AZ1=<subnet_id_of_az1>
```
* Set Subnet ID for AZ2 to a variable.
```
export SUBNET_ID_AZ2=<subnet_id_of_az2>
```
* Set the private ip of master0 into a variable
```
export MASTER0_PRIVATE_IP=<private_ip_of_master0>
```
* Set the private ip of master1 into a variable
```
export MASTER1_PRIVATE_IP=<private_ip_of_master1>
```
* Set the private ip of master2 into a variable
```
export MASTER2_PRIVATE_IP=<private_ip_of_master2>
```
* Extract certfiicate from master.ign and set into a variable.
```
export CERTIFICATE_AUTHORITY=$(cat install-dir/master.ign | cut -f8 -d{ | cut -f2,3 -d: | cut -f1 -d})

````
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
sed -i "s/master0_private_ip/$MASTER0_PRIVATE_IP/g" control-plane-parameters.json
sed -i "s/master1_private_ip/$MASTER1_PRIVATE_IP/g" control-plane-parameters.json
sed -i "s/master2_private_ip/$MASTER2_PRIVATE_IP/g" control-plane-parameters.json
```

* Create the stack to deploy ControlPlane node
```
aws cloudformation create-stack --stack-name control-plane --template-body file://create-control-plane.yaml --parameters file://control-plane-parameters.json
```

# Create Infra Nodes
* Set Cluster Name into a variable.
```
export CLUSTER_NAME=<cluster-name>
```
* Set Cluster Domain Name into a variable.
```
export CLUSTER_DOMAIN_NAME=<cluster-domain-name>
```
* Set Subnet ID of AZ1 to a variable.
```
export SUBNET_ID_AZ1=<subnet_id_of_az1>
```
* Set Subnet ID of AZ2 to a variable.
```
export SUBNET_ID_AZ2=<subnet_id_of_az2>
```
* Set the private ip of inra1 into a variable
```
export INFRA1_PRIVATE_IP==<private_ip_of_infra1>
```
* Set the private ip of infra2 into a variable
```
export INFRA3_PRIVATE_IP=<private_ip_of_infra2>
```
* Set the private ip of infra3 into a variable
```
export INFRA3_PRIVATE_IP==<private_ip_of_infra3>
```
* Extract certfiicate from worker.ign and set into a variable.
```
export CERTIFICATE_AUTHORITY_WORKER=$(cat install-dir/worker.ign | cut -f8 -d{ | cut -f2,3 -d: | cut -f1 -d})
````
* Replace the variables in control plane parameters.json file.
```
sed -i "s/infra_id/$INFRA_ID/g" infra1-parameters.json infra2-parameters.json infra3-parameters.json
sed -i "s/rhcos_ami_id/$RHCOS_AMI_ID/g"  infra1-parameters.json  infra2-parameters.json  infra3-parameters.json
sed -i "s/worker_sg_id/$WorkerSecurityGroupId/g" infra1-parameters.json infra2-parameters.json infra3-parameters.json
sed -i "s/subnet_id/$SUBNET_ID_AZ1/g" infra1-parameters.json infra2-parameters.json
sed -i "s/subnet_id/$SUBNET_ID_AZ2/g" infra3-parameters.json
sed -i "s/clustername/$CLUSTER_NAME/g"  infra1-parameters.json infra2-parameters.json infra3-parameters.json
sed -i "s/domainname/$CLUSTER_DOMAIN_NAME/g"  infra1-parameters.json infra2-parameters.json infra3-parameters.json
sed -i "s#certificate_authority#$CERTIFICATE_AUTHORITY_WORKER#g" infra1-parameters.json infra2-parameters.json infra3-parameters.json
sed -i "s/infra_private_ip/$INFRA1_PRIVATE_IP/g" infra1-parameters.json
sed -i "s/infra_private_ip/$INFRA2_PRIVATE_IP/g" infra2-parameters.json
sed -i "s/infra_private_ip/$INFRA3_PRIVATE_IP/g" infra3-parameters.json
```

* Create the stack to deploy Infra1 node
```
aws cloudformation create-stack --stack-name infra1 --template-body file://create-infra.yaml --parameters file://infra1-parameters.json
```
* Create the stack to deploy Infra1 node
```
aws cloudformation create-stack --stack-name infra2 --template-body file://create-infra.yaml --parameters file://infra2-parameters.json
```
* Create the stack to deploy Infra1 node
```
aws cloudformation create-stack --stack-name infra3 --template-body file://create-infra.yaml --parameters file://infra3-parameters.json
```
* Approve Pending CSR
```
for i in `oc get csr| grep Pending | awk '{print $1}'`; do oc adm certificate approve $i; done
sleep 30
for i in `oc get csr| grep Pending | awk '{print $1}'`; do oc adm certificate approve $i; done
```
* Add infra label to the newly created infra ndoes. Repeat it for each node after gettign it from "oc get nodes". Right node can be identified by looking its ip address.
```
oc label node <node> node-role.kubernetes.io/infra=
```
* Add proper taints to the infra nodes to avoid user workloads from going there.
```
oc adm taint nodes <node>  node-role.kubernetes.io/infra=reserved:NoSchedule
```
* Add additinal Ingress controllers using a different domain name.
```
oc create -f additional-ingress-controller.yaml
```
* Change the default ingress controller to use HostNetwork instead of LoadBalancerService. Need to figure out how to do this. WIP

* Research cloudformation template customization to open up 443, 80 and 1936 on infra node security group from external load balancer. WIP

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
