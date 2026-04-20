# Disconnected OpenShift UPI on AWS — Terraform

Deploys a self-managed OpenShift cluster using **User Provisioned Infrastructure (UPI)** in a disconnected AWS VPC across three availability zones, with an externally managed load balancer for API and Ingress. This repository replaces the original five CloudFormation stacks and their parameter JSON files with a single unified Terraform deployment.

---

## Pre-requisite knowledge

- AWS networking and IAM
- OpenShift IPI vs UPI distinctions
- STS / AssumeRoleWithWebIdentity with OpenShift
- Disconnected OCP on AWS requirements

---

## Requirements

- A disconnected VPC with all required VPC endpoints (S3, EC2, STS, ELB). See [Network Requirements for Disconnected OpenShift on AWS](https://github.com/sadiquepp/openshift/blob/main/aws/docs/network-requirement-aws-api.md#2-cluster-to-complete-its-installation).
- A mirror registry with the required release and operator images already mirrored and accessible from the VPC.
- An external load balancer configured to:
  - Listen on **6443** and **22623** for API traffic, with bootstrap + 3 master nodes as backends.
  - Listen on **443** and **80** for `*.apps` traffic, using **1936** (HTTP `/healthz`) for health checks. Use only infra nodes as backends if dedicated infra nodes are deployed, otherwise use worker nodes.
- DNS (managed outside OpenShift — no Route53 integration):
  - `api.<cluster>.<domain>` → external LB
  - `api-int.<cluster>.<domain>` → external LB
  - `*.apps.<cluster>.<domain>` → external LB
- Pre-determined and **reserved** private IPs for all nodes in AWS VPC → Subnets → Actions → **Edit IPv4 CIDR Reservation**:
  - 1 bootstrap (any AZ), 3 masters (one per AZ), 3 workers (one per AZ), 3 infra nodes (one per AZ) if applicable.

---

## What Terraform replaces

| CloudFormation stack | Terraform file |
|---|---|
| `create-security-group-and-role.yaml` | `security_groups.tf` + `iam.tf` |
| `create-bootstrap.yaml` | `bootstrap.tf` |
| `create-control-plane.yaml` | `control_plane.tf` |
| `create-worker.yaml` | `workers.tf` |
| `create-infra.yaml` | `infra_nodes.tf` |
| All `*-parameters.json` files | `variables.tf` + `terraform.tfvars` |

The five CloudFormation stacks had to be created manually in sequence, with outputs retrieved from the AWS console and re-entered as parameters. Terraform resolves all dependencies automatically through the resource graph — a single `terraform apply` creates everything in the correct order.

---

## Repository structure

```
tf-ocp-upi/
├── main.tf                   # Provider configuration
├── variables.tf              # All input variables
├── locals.tf                 # Derived values (ignition URLs, profile names, tags)
├── iam.tf                    # Master, worker and bootstrap IAM roles + instance profiles
├── security_groups.tf        # Master SG, worker SG, and all cross-SG ingress rules
├── bootstrap.tf              # Bootstrap security group and EC2 instance
├── control_plane.tf          # Three master EC2 instances (one per AZ)
├── workers.tf                # Three worker EC2 instances (one per AZ)
├── infra_nodes.tf            # Three infra EC2 instances (optional, toggled by variable)
├── outputs.tf                # SG IDs, IPs, and useful post-install commands
└── terraform.tfvars.example  # Copy to terraform.tfvars and fill in values
```

---

## Generate STS resources and OpenShift artifacts

These steps run on the bastion EC2 before `terraform apply`.

**Extract `openshift-install` from the mirror registry:**
```bash
export REGISTRY_URL=mirror.hub.mylab.com
export REGISTRY_PORT=8443
export OPENSHIFT_VERSION=4.18.5-x86_64
oc adm release extract -a <pull-secret-file> \
  --idms-file=<idms-file.yaml> \
  --command=openshift-install \
  $REGISTRY_URL:$REGISTRY_PORT/openshift/release-images:$OPENSHIFT_VERSION
```

**Extract `ccoctl`:**
```bash
mkdir sts && cd sts
RELEASE_IMAGE=$(../openshift-install version | awk '/release image/ {print $3}')
CCO_IMAGE=$(oc adm release info -a ../pull-secret.json --image-for='cloud-credential-operator' $RELEASE_IMAGE)
oc image extract $CCO_IMAGE --file="/usr/bin/ccoctl" -a ../pull-secret.json
chmod 755 ccoctl
```

**Extract credential requests and remove unwanted ones:**
```bash
oc adm release extract --credentials-requests \
  --cloud=aws --to=credrequests \
  -a pull-secret.json \
  $REGISTRY_URL:8443/openshift/release-images:$OPENSHIFT_VERSION

# Remove any operators you are not deploying
rm -f credrequests/0000_50_cloud-credential-operator_05-iam-ro-credentialsrequest.yaml
```

**Create STS resources:**
```bash
./ccoctl aws create-all \
  --name <cluster-name-xxx> \
  --credentials-requests-dir credrequests/ \
  --region ap-southeast-1 \
  --create-private-s3-bucket
cd ..
```
> Required permissions: see [ccoctl-policy.json](https://github.com/sadiquepp/openshift/blob/main/aws/4.18/ccoctl-policy.json)

---

## Generate OpenShift manifests and ignition

**Prepare `install-config.yaml`** using the provided example. Update `baseDomain`, `machineNetwork`, `pullSecret`, `imageContentSources`, `sshKey`, and `additionalTrustBundle`.

```bash
mkdir install-dir
cp install-config.yaml install-dir/
./openshift-install create manifests --dir install-dir/
```
> Required permissions: see [create-manifest-only.json](https://github.com/sadiquepp/openshift/blob/main/aws/self-managed/install-policies/create-manifest-only.json)

**Copy STS manifests:**
```bash
cp -prv sts/tls/ install-dir/
cp sts/manifests/* install-dir/manifests/
```

**Remove machine-managed resources** (UPI manages nodes directly):
```bash
rm -f install-dir/openshift/99_openshift-cluster-api_master-machines-*.yaml
rm -f install-dir/openshift/99_openshift-machine-api_master-control-plane-machine-set.yaml
rm -f install-dir/openshift/99_openshift-cluster-api_worker-machineset-*.yaml
```

**Remove hosted zone from DNS manifest:**
```bash
vi install-dir/manifests/cluster-dns-02-config.yml
# Remove the privateZone block
```

**Set ingress to HostNetwork** (required for external LB with no cloud integration):
```bash
# Edit install-dir/manifests/cluster-ingress-default-ingresscontroller.yaml
# Set: spec.endpointPublishingStrategy.type: HostNetwork
```

**Create ignition configs:**
```bash
./openshift-install create ignition-configs --dir install-dir/
```

**Get the infrastructure ID:**
```bash
export INFRA_ID=$(jq -r .infraID install-dir/metadata.json)
echo $INFRA_ID
```

**Push bootstrap ignition to S3:**
```bash
aws s3 mb s3://${INFRA_ID}
aws s3 cp install-dir/bootstrap.ign s3://${INFRA_ID}/bootstrap.ign
```

---

## Terraform deployment

**1. Configure variables:**
```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set every value. The key ones are:

| Variable | Where to get it |
|---|---|
| `infrastructure_name` | `jq -r .infraID install-dir/metadata.json` |
| `rhcos_ami_id` | [RHCOS AMI list for your OCP version and region](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/installing_on_aws/user-provisioned-infrastructure#installation-aws-user-infra-rhcos-ami_installing-restricted-networks-aws) |
| `certificate_authority` | `cat install-dir/master.ign \| cut -f8 -d{ \| cut -f2,3 -d: \| cut -f1 -d}` |
| `vpc_id`, `subnet_id_*` | Your existing disconnected VPC outputs |
| `*_private_ip` | Pre-reserved IPs from AWS subnet CIDR reservations |

**2. Deploy:**
```bash
terraform init
terraform plan
terraform apply
```

Terraform creates all resources in the correct dependency order:
1. IAM roles and instance profiles
2. Master and worker security groups + all ingress rules
3. Bootstrap security group and EC2 instance
4. Control plane EC2 instances (all three)
5. Worker EC2 instances (all three)
6. Infra EC2 instances (if `create_infra_nodes = true`)

---

## Monitor cluster installation

Once the bootstrap and master nodes are running and DNS/LB are in place, the API becomes available. Monitor progress:

```bash
export KUBECONFIG=install-dir/auth/kubeconfig
./openshift-install wait-for bootstrap-complete --dir install-dir --log-level debug
```

**Approve pending CSRs** as workers join:
```bash
for i in $(oc get csr | grep Pending | awk '{print $1}'); do oc adm certificate approve $i; done
sleep 30
for i in $(oc get csr | grep Pending | awk '{print $1}'); do oc adm certificate approve $i; done
```

**Monitor cluster operators:**
```bash
oc get co
oc get nodes
```

---

## Terminate the bootstrap node

Once the cluster is healthy and masters have formed a quorum, the bootstrap node is no longer needed:

```bash
# Terraform targeted destroy — leaves all other resources intact
terraform destroy \
  -target=aws_instance.bootstrap \
  -target=aws_network_interface.bootstrap \
  -target=aws_security_group.bootstrap
```

> The output `bootstrap_terminate_command` prints this exact command after `terraform apply`.

Also remove the bootstrap node from the external load balancer backends for ports 6443 and 22623.

---

## Configure infra nodes (if deployed)

After infra nodes have joined and their CSRs are approved:

**Label as infra:**
```bash
for IP in $INFRA1_PRIVATE_IP $INFRA2_PRIVATE_IP $INFRA3_PRIVATE_IP; do
  NODE=$(oc get nodes -o wide | grep $IP | awk '{print $1}')
  oc label node $NODE node-role.kubernetes.io/infra=
done
```

**Taint to prevent user workloads:**
```bash
for IP in $INFRA1_PRIVATE_IP $INFRA2_PRIVATE_IP $INFRA3_PRIVATE_IP; do
  NODE=$(oc get nodes -o wide | grep $IP | awk '{print $1}')
  oc adm taint nodes $NODE node-role.kubernetes.io/infra=reserved:NoSchedule
done
```

**Move the default IngressController to infra nodes:**
```bash
oc edit ingresscontroller default -n openshift-ingress-operator
```
Add to `spec`:
```yaml
nodePlacement:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/infra: ""
  tolerations:
  - effect: NoSchedule
    key: node-role.kubernetes.io/infra
    value: reserved
```

**Confirm ingress pods moved:**
```bash
oc get po -n openshift-ingress -o wide
```

---

## Teardown

```bash
# Destroy all cluster EC2/SG/IAM resources
terraform destroy
```

> This does **not** remove the S3 bootstrap bucket, the STS resources created by `ccoctl`, or the VPC infrastructure. Remove those separately.
