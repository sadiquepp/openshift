# OpenShift 4.20 Network Requirements For AWS API 

Reference: [OpenShift Container Platform 4.20: Configuring your firewall](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/installation_configuration/configuring-firewall)

AWS introduced support for cross-region VPC endpoints in November 2025. Should one create cross-region VPC endpoints for IAM and Route53, it becomes nearly feasible to deploy an OpenShift cluster without necessitating internet access for the bastion node and the cluster to access AWS API, while still acknowledging the caveats detailed in the last section of this doc.

This document outlines the required outbound Internet-facing URLs and internal AWS VPC Endpoints necessary to deploy, manage, and destroy a Red Hat OpenShift cluster on Amazon Web Services (AWS). It reflects a hardened configuration utilizing cross-region VPC endpoints for global services like IAM and Route 53.

The cluster must be deployed in STS mode with `credentialsMode: manual`

This document assumes that the required images are mirrored to an internal registry and the cluster is deployed in a disconnected manner by pulling images from that registry.

## 1. Bastion Node (Deploying & Destroying the Cluster)

The Bastion node is the jump host used to initiate the OpenShift installer for the cluster. This bastion node is typically an EC2 instance, which allows for convenient utilization of VPC endpoints for API access.

| Access Type | Required Endpoints / URLs |
| :--- | :--- |
| **Public Internet Access** | • `aws.amazon.com` (Temporary requirement due to OCPBUGS-77830)<br>• `tagging.us-east-1.amazonaws.com` (Required for cluster deletion only; not needed for installation. Also check if [Workaround for Public Endpoint Requirement for tagging.us-east-1.amazonaws.com](#workaround-for-public-endpoint-requirement-for-taggingus-east-1amazonawscom) can be implemented) |
| **AWS VPC Endpoints** | • `com.amazonaws.iam` (IAM - Cross-Region)<br>• `com.amazonaws.route53` (Route 53 - Cross-Region)<br>• `com.amazonaws.[region].servicequotas` (Service Quotas)<br>• `com.amazonaws.[region].ec2` (EC2)<br>• `com.amazonaws.[region].sts` (STS)<br>• `com.amazonaws.[region].elasticloadbalancing` (ELB)<br>• `com.amazonaws.[region].s3` (S3 Gateway Endpoint)<br>• `com.amazonaws.[region].tagging` (Tagging - Regional) |

## 2. Cluster (To complete its Installation)

Once the Bastion node provisions the control plane and initial worker nodes, the cluster itself needs specific access to finish its own installation, verify its infrastructure, and pull necessary operators.

| Access Type | Required Endpoints / URLs |
| :--- | :--- |
| **Public Internet Access** | `tagging.us-east-1.amazonaws.com` (This requirement can be worked around if a manual action can be agreed to add `*.apps` entry to route53 manually midway cluster installation or check [Workaround for Public Endpoint Requirement for tagging.us-east-1.amazonaws.com](#workaround-for-public-endpoint-requirement-for-taggingus-east-1amazonawscom) can be implemented) |
| **AWS VPC Endpoints** | • `com.amazonaws.route53` (Route 53 - Cross-Region)<br>• `com.amazonaws.[region].ec2` (EC2)<br>• `com.amazonaws.[region].sts` (STS)<br>• `com.amazonaws.[region].elasticloadbalancing` (ELB)<br>• `com.amazonaws.[region].s3` (S3 Gateway Endpoint) |

## Important Caveats

- **Known Bug OCPBUGS-77830 (`aws.amazon.com`):** Currently, the OpenShift installer follows HTTP redirects when validating AWS endpoint accessibility, requiring access to `aws.amazon.com` even when utilizing private VPC endpoints. Once [OCPBUGS-77830](https://issues.redhat.com/browse/OCPBUGS-77830) (which skips this redirect) is merged and released, `aws.amazon.com` will no longer be required and can be safely removed from your firewall allow-lists.
- **Cluster Deletion (`tagging.us-east-1.amazonaws.com`):** The OpenShift installer relies on the AWS Resource Groups Tagging API globally strictly during the destroy cluster command to identify and purge all AWS resources stamped with the cluster's infrastructure ID. If you block this URL during installation, the build will still succeed, but cluster deletion will fail.
- **Cross-Region Endpoints:** IAM and Route 53 are global services hosted in `us-east-1`. To access them privately from another region, you must create a cross-region vpc endpoint.
- **S3 Gateway Endpoint:** Unlike the other interface endpoints, S3 utilizes a Gateway Endpoint. This requires adding a route to your VPC route tables rather than utilizing a private IP with a security group.
- To preclude the cluster from establishing a connection with `tagging.us-east-1.amazonaws.com`, it is necessary to modify the cluster manifest file, specifically `cluster-dns-02-config.yml`, and delete the pertinent lines prior to commencing the cluster installation. This measure ensures that the ingress controller does not attempt to append the `*.apps` entry to the Route 53 hosted zone, a procedure contingent upon `tagging.us-east-1.amazonaws.com`. Following this modification, the `*.apps` entry must be manually incorporated as an Alias to the provisioned Ingress Load Balancer to successfully conclude the cluster installation. Below line needs to be deleted from the manifest file `cluster-dns-02-config.yml`:

```yaml
privateZone:
  id: ID
```
## Workaround for Public Endpoint Requirement for tagging.us-east-1.amazonaws.com

To resolve the internet access requirement for the `tagging.us-east-1.amazonaws.com` endpoint without providing public internet access, you can route the traffic through a private endpoint in `us-east-1` via VPC peering. Follow these steps:

**Step 1: Create a VPC and Subnet in `us-east-1`**
* Navigate to the AWS VPC Dashboard in the `us-east-1` (N. Virginia) region.
* Create a new VPC with a CIDR block that does not overlap with your primary cluster VPC (e.g., `10.200.0.0/16`).
* Create at least one subnet within this new VPC (e.g., `10.200.1.0/24`).
* Ensure **DNS Resolution** and **DNS Hostnames** are enabled for this VPC.

**Step 2: Create a Private Endpoint for `tagging.us-east-1.amazonaws.com`**
* Still in the `us-east-1` VPC Dashboard, navigate to **Endpoints** and click **Create endpoint**.
* Select **AWS services** as the service category.
* Under Services, search for and select `com.amazonaws.us-east-1.tagging`.
* Select the VPC and subnet created in Step 1.
* Attach a security group that allows inbound HTTPS (port 443) traffic from your primary cluster VPC CIDR.

**Step 3: Retrieve the Private Endpoint IP Address**
* Once the endpoint state is *Available*, select it and navigate to the **Subnets** (or Network Interfaces) tab.
* Note down the **Private IP address** associated with the network interface created for this endpoint (e.g., `10.200.1.15`). 

**Step 4: Set up VPC Peering or Transit Gateway**
* Navigate to **VPC Peering Connections** (or Transit Gateway attachments).
* Create a peering connection from your primary VPC (e.g., in `ap-southeast-1`) to the new `us-east-1` VPC.
* Accept the peering connection request in the `us-east-1` region.
* **Update Route Tables:**
  * In your primary cluster VPC route tables (especially those associated with the control plane and bastion subnets), add a route pointing the `us-east-1` VPC CIDR (`10.200.0.0/16`) to the VPC Peering Connection.
  * In your `us-east-1` VPC route table, add a route pointing your primary cluster VPC CIDR back to the same VPC Peering Connection to allow return traffic.

**Step 5: Create a Private Hosted Zone and Alias Record**
* Navigate to the Route 53 Dashboard.
* Click **Create hosted zone** and enter `tagging.us-east-1.amazonaws.com` as the Domain Name.
* Select **Private hosted zone** as the type.
* Associate this hosted zone with your **primary cluster VPC** (the VPC in your installation region).
* Inside the newly created hosted zone, click **Create record**.
* Leave the Record name empty (this creates an apex record for the domain itself).
* Change the Record type to **A - Routes traffic to an IPv4 address and some AWS resources**.
* Enter the **Private IP Address** retrieved in Step 3 into the value field.
* Save the record.

With this setup, traffic originating from your cluster destined for the `tagging.us-east-1.amazonaws.com` endpoint will resolve to the `us-east-1` private endpoint IP, traverse the VPC peer, and securely hit the AWS API without requiring outbound internet access.
