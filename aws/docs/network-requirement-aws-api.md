# OpenShift 4.20 Network Requirements For AWS API 

Reference: [OpenShift Container Platform 4.20: Configuring your firewall](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/installation_configuration/configuring-firewall)

AWS introduced support for cross-region VPC endpoints in November 2025. Should one create cross-region VPC endpoints for IAM and Route53, it becomes nearly feasible to deploy an OpenShift cluster without necessitating internet access for the bastion node and the cluster to access AWS API, while still acknowledging the caveats detailed in the last section of this doc.

This document outlines the required outbound Internet-facing URLs and internal AWS VPC Endpoints necessary to deploy, manage, and destroy a Red Hat OpenShift cluster on Amazon Web Services (AWS). It reflects a hardened configuration utilizing cross-region VPC endpoints for global services like IAM and Route 53.

The cluster must be deployed in STS mode with `credentialsMode: manual`

## 1. Bastion Node (Deploying & Destroying the Cluster)

The Bastion node is the jump host used to initiate the OpenShift installer for the cluster. This bastion node is typically an EC2 instance, which allows for convenient utilization of VPC endpoints for API access.

| Access Type | Required Endpoints / URLs |
| :--- | :--- |
| **Public Internet Access** | • `aws.amazon.com` (Temporary requirement due to OCPBUGS-77830)<br>• `tagging.us-east-1.amazonaws.com` (Required for cluster deletion only; not needed for installation) |
| **AWS VPC Endpoints** | • `com.amazonaws.iam` (IAM - Cross-Region)<br>• `com.amazonaws.route53` (Route 53 - Cross-Region)<br>• `com.amazonaws.[region].servicequotas` (Service Quotas)<br>• `com.amazonaws.[region].ec2` (EC2)<br>• `com.amazonaws.[region].sts` (STS)<br>• `com.amazonaws.[region].elasticloadbalancing` (ELB)<br>• `com.amazonaws.[region].s3` (S3 Gateway Endpoint)<br>• `com.amazonaws.[region].tagging` (Tagging - Regional) |

## 2. Cluster (To complete its Installation)

Once the Bastion node provisions the control plane and initial worker nodes, the cluster itself needs specific access to finish its own installation, verify its infrastructure, and pull necessary operators.

| Access Type | Required Endpoints / URLs |
| :--- | :--- |
| **Public Internet Access** | `tagging.us-east-1.amazonaws.com` (This requirement can be worked around if a manual action can be agreed to add `*.apps` entry to route53 manually midway cluster installation) |
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