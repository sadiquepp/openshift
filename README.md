# Artefacts to support various OpenShift Use Cases

Terraform, Ansible, shell scripts and raw Kubernetes/OpenShift YAML for standing
up and configuring OpenShift clusters across clouds and use cases. There is no
build or test suite — correctness is validated by running `terraform
plan/apply`, `ansible-playbook` or `oc apply` against real infrastructure.

Each top-level directory is self-contained and carries its own `README.md` or
`.md` runbook with the authoritative prerequisites and procedures. The sections
below map what lives where; **read the subdirectory's own README first**.

Manifests are examples with placeholders (`example.com`,
`mirror.hub.mylab.com`, dummy account IDs) — substitute real values before
applying. Never commit `terraform.tfvars`, secrets, SSH keys or an
`install-dir/`.

## Quick reference

| Directory | Covers |
|---|---|
| [`aws/`](aws) | Self-managed IPI/UPI, ROSA, load balancers, IAM policies |
| [`azure/`](azure), [`gcp/`](gcp), [`ibmcloud/`](ibmcloud) | Connected/disconnected environments |
| [`cloud/`](cloud) | Generic multi-cloud Ansible role variant |
| [`hcp/`](hcp) | Hosted Control Planes (HyperShift), disconnected |
| [`sno/`](sno), [`assisted-installer/`](assisted-installer), [`acm/`](acm) | SNO, Assisted Installer, Hive clusters |
| [`disconnected/`](disconnected), [`quay/`](quay) | Mirroring, image policies, registry |
| [`observability/`](observability), [`networking/`](networking) | Logs/metrics/traces/flows, two-VLAN ingress |
| [`service-mesh/`](service-mesh), [`acs/`](acs), [`coco/`](coco) | Service Mesh 3, ACS, Confidential Containers |
| [`test-workloads/`](test-workloads), [`collections/`](collections) | Shared demo app, Galaxy requirements |

## Common pattern: per-cloud environments

`aws/`, `azure/`, `gcp/` and `ibmcloud/` share a three-layer shape under
`self-managed/{connected,disconnected}/`:

1. **`deploy.sh`** — entry point; runs Terraform then Ansible, e.g.
   `./deploy.sh --pull-secret-file ~/pull-secret.json --openshift-version 4.18.20`.
   Extra args pass through to the playbook.
2. **`terraform/`** — VPC/VNet, subnets, NAT/IGW (or Transit Gateway when
   disconnected), IAM/identity, and a bastion VM. Driven by a local
   `terraform.tfvars`; outputs feed the Ansible layer.
3. **`setup-bastion-*.yaml`** — installs `oc`, `openshift-install`, `ccoctl`,
   `rosa` and (disconnected) a mirror registry on the bastion, then renders an
   `install-dir/`.

Disconnected variants also run `oc mirror` to sync release images (30–60 min)
before the install directory is usable.

### Teardown

**Order matters:** destroy the OpenShift cluster first
(`openshift-install destroy cluster`, `rosa delete cluster`, or delete the
`HostedCluster`), *then* `terraform destroy`. Destroying infrastructure first
orphans DNS records, RAM shares and Route 53 associations.

## aws/

### `self-managed/connected/`, `self-managed/disconnected/`
The reference implementation of the pattern above: network, IAM role and a
bastion EC2 instance with STS credentials ready for `openshift-install`. The
connected environment also supports self-managed HCP. The disconnected one adds
a mirror registry and mirrored release images.
[`connected/az-resilience/`](aws/self-managed/connected/az-resilience) holds
manifests and a runbook proving an app survives the loss of one Availability
Zone — 9 replicas spread 3/3/3, rescheduled and rebalanced.

### `self-managed/upi/`
Five User-Provisioned-Infrastructure walkthroughs for disconnected installs with
an externally managed load balancer: `two-az/`, `two-az-infra/`,
`standard-three-az/` and `three-az-worker-infra/` are CloudFormation-era
runbooks; [`terraform-three-az/`](aws/self-managed/upi/terraform-three-az)
replaces the five stacks with one Terraform deployment and gives UPI clusters
their own `upi.<base_domain>` DNS namespace so they can coexist with IPI
clusters.

### `self-managed/` policies and machines
`install-policies/` and `4.18/` are the IAM policies for installing, deleting
and `ccoctl`-minting credentials (installer role, bootstrap role, minimal-
permissions mode). `operator-policies/` holds the per-operator STS policies and
the trust-relationship template. `machineset/` is an infra MachineSet example,
and `aws_ec2.yaml` is the dynamic Ansible inventory.

### `rosa/`
`create-cluster.sh` for classic ROSA, `terraform/rosa-byo-oidc-roles/` for
bring-your-own OIDC roles, and
[`tf-rosa-platform/`](aws/rosa/tf-rosa-platform) — a Terraform root module that
deploys ROSA HCP in a disconnected, shared-VPC, cross-account architecture. It
applies four child modules across a VPC-owner account and a ROSA account in
strict dependency order, with a `Makefile` for stepping through them via named
AWS profiles.

### `albo/`, `ingress/`, `docs/`
`albo/` is the AWS Load Balancer Operator IAM policy plus an NLB Service
example. `ingress/` holds private, cross-zone and default NLB Service and
IngressController examples. `docs/` documents the outbound network requirements
for the AWS API and the security groups an API NLB needs.

## azure/, gcp/, ibmcloud/

The same `self-managed/` pattern on each cloud: Terraform for VNet/VPC,
identity and bastion, plus a bastion playbook and install templates. Azure and
GCP ship both `connected/` and `disconnected/` (mirror registry) variants; IBM
Cloud ships `connected/` only, building a VPC with public gateways, security
groups and a bastion VSI carrying CCO credentials.

## cloud/

An older, generic variant of the per-cloud environments: one Ansible role tree
(`bastion_base`, `installer_prep_connected`, `openshift_installer_prep`,
`mirror_registry`, `hcp_provisioning`, `letsencrypt_certs`,
`olm_catalog_suppression`) with per-cloud templates for AWS, Azure, GCP and IBM
Cloud, driven by `setup-bastion-vm-connected.yaml` or `setup-bastion.yaml`.
`moved-to-roles/` keeps the pre-refactor task files. Prefer the per-cloud
directories for new work.

## hcp/

Hosted Control Plane (HyperShift) manifests for disconnected deployments:
`HostedCluster` and `NodePool`, `ClusterImageSet`, agent service, ICSP, the MCE
mirror ConfigMap, registry CA bundle and CA-cert image, namespace and roles,
plus an `ImageSetConfiguration` and an `install-config.yaml.j2` template.

## sno/, assisted-installer/, acm/

`sno/` holds Single Node OpenShift `install-config`/`agent-config` examples,
including a bonded-NIC variant. `assisted-installer/` is a cluster-creation
manifest for the Assisted Installer. `acm/` holds Advanced Cluster Management
Hive `ClusterDeployment` manifests for provisioning managed clusters — a
standard and a disconnected variant, a database MachinePool, and notes on the
security group an API NLB needs.

## disconnected/, quay/

`disconnected/` carries the generic mirroring artefacts: `ImageSetConfiguration`,
`IDMS`, CatalogSource, a pull-through-cache `install-config`, per-release
operator lists (4.20–4.22), and `docs/` with the mirroring and pull-through
cache guides. `quay/` holds the Quay registry admin, config and `QuayRegistry`
manifests used as the mirror target.

## observability/

[`observability/README.md`](observability/README.md) is the runbook: OpenShift
Logging (Loki on S3), Network Observability (FlowCollector with or without
Loki), distributed tracing (Tempo, OpenTelemetry), metrics, and the Cluster
Observability Operator UIPlugins.

- [`ansible/`](observability/ansible) — the executable form of that runbook, in
  two phases (AWS buckets/IAM, then cluster), with the waits and idempotency a
  copy-paste session lacks.
- [`kafka/`](observability/kafka) — the same signals streamed to Kafka topics
  instead of on-cluster storage: no LokiStack, TempoStack, S3 or IAM user.
- [`demo/`](observability/demo) — a five-part, ~35-minute walkthrough driven by
  Online Boutique: one application, four signals, and what each one answers
  that the others cannot.

## networking/

Four runbooks for two-VLAN ingress on OpenShift: a second IngressController
with MetalLB, and the same with User-Defined Networks (UDN) and
Cluster-scoped UDN (CUDN).

## service-mesh/

OpenShift Service Mesh 3 (Sail operator) — the same Online Boutique
walkthrough built two ways, install through mTLS to L4 and L7 authorization
policy. [`ambient/`](service-mesh/ambient) uses a per-node ztunnel plus
waypoint Envoys and explains how ztunnel works;
[`sidecar/`](service-mesh/sidecar) uses the classic injected Envoy and adds a
side-by-side comparison. Both can run on one cluster — an ambient istiod also
injects sidecars — in `online-boutique-ambient` and `online-boutique-sidecar`.

## acs/

Red Hat Advanced Cluster Security: the RHACS operator, `Central` and
`SecuredCluster` manifests numbered in apply order, plus `acs-scan.sh`, which
scans the two hardened Online Boutique namespaces (Red Hat Hardened Images vs
UBI 9) and diffs the results. The README documents a VEX-feed gap in hardened
image reporting to verify rather than assume on your version.

## coco/

Confidential Containers on bare metal, with a detailed runbook: a disconnected
SNO install, then Trustee/KBS attestation (`trustee/` 0.2.0 and 0.3.0),
OpenShift Sandboxed Containers Operator (`osc/`), Node Feature Discovery
(`nfd/`) and `local-storage/`. `testing/` holds Kata/CoCo pod examples —
including raw block PVC and direct in-pod NFS mounts, the latter documented in
[`nfs/`](coco/nfs) — and `debug/` keeps captured failure output.

## test-workloads/

[`online-boutique/`](test-workloads/online-boutique) is
GoogleCloudPlatform/microservices-demo `v0.10.6`, vendored and patched for
OpenShift: 11 gRPC services across 5 languages, no PVCs, with a load generator
so dashboards are never empty. Kustomize overlays cover `default`, `ambient`,
`sidecar`, `tracing`, `ubi`, `hardened` and `no-loadgenerator`. `hardened/`
documents the Red Hat Hardened Images rebuild and a CVE demo.

## collections/

`requirements.yml` — the Ansible Galaxy collections the playbooks in this repo
need (`amazon.aws`, `community.aws`, `community.general`). Install with
`ansible-galaxy collection install -r collections/requirements.yml`.
