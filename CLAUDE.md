# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This is **not an application codebase** — it's a collection of infrastructure-as-code artefacts (Terraform, Ansible, shell scripts, and raw Kubernetes/OpenShift YAML manifests) for standing up and configuring OpenShift clusters across multiple clouds and use cases. There is no build, lint, or test suite; "correctness" is validated by actually running `terraform plan/apply`, `ansible-playbook`, or `oc apply` against real infrastructure.

Each top-level directory is a self-contained use case with its own `README.md` documenting prerequisites, variables, and step-by-step procedures. **Always read the relevant subdirectory's README before making changes there** — that's where the authoritative instructions live, not in this file.

## Repository layout

| Directory | Purpose |
|---|---|
| `aws/`, `azure/`, `gcp/`, `ibmcloud/`, `cloud/` | Per-cloud environments for deploying OpenShift, split into `self-managed/connected/` (internet-accessible) and `self-managed/disconnected/` (air-gapped, mirror registry) variants. `cloud/` holds an older/generic Ansible role-based variant. |
| `aws/rosa/` | ROSA (Red Hat OpenShift Service on AWS) — `create-cluster.sh` for classic ROSA, `tf-rosa-platform/` for a multi-module Terraform root deploying ROSA HCP in a disconnected, shared-VPC, cross-account architecture. |
| `aws/albo/`, `aws/ingress/` | AWS Load Balancer Operator and ingress/NLB manifests (private/cross-zone/default service examples). |
| `aws/docs/` | Standalone network/security-group requirement docs. |
| `hcp/` | Hosted Control Plane (HyperShift) manifests for disconnected deployments — HostedCluster, NodePool, ICSP, mirror configmaps. |
| `coco/` | Confidential Containers (CoCo) on bare metal — Trustee (KBS) attestation, OpenShift Sandboxed Containers Operator (OSC), NFD, local-storage, and detailed CoCo `README.md` runbook (see below). |
| `disconnected/` | Generic disconnected/mirroring artefacts (ImageSetConfiguration, IDMS, pull-through cache) and `docs/` with mirroring guides. |
| `acm/` | Advanced Cluster Management — Hive `ClusterDeployment` manifests for provisioning managed clusters (including a disconnected variant). |
| `sno/` | Single Node OpenShift install-config/agent-config examples (including bonded NIC variant). |
| `assisted-installer/` | Assisted Installer cluster creation manifest. |
| `logging/` | OpenShift Logging (Loki on S3 + Cluster Observability Operator UIPlugin) setup runbook. |
| `networking/` | Two-VLAN ingress/MetalLB/UDN/CUDN networking guides. |
| `quay/` | Quay registry admin/config/registry manifests. |
| `collections/requirements.yml` | Ansible Galaxy collections required across playbooks (`amazon.aws`, `community.aws`, `community.general`). |

## Common architectural pattern (per-cloud connected/disconnected dirs)

The `aws/`, `azure/`, `gcp/`, `ibmcloud/` `self-managed/{connected,disconnected}/` directories all follow the same three-layer pattern:

1. **`deploy.sh`** — entry point script; runs Terraform then Ansible in sequence. Typical invocation:
   ```bash
   ./deploy.sh --pull-secret-file ~/pull-secret.json --openshift-version 4.18.20
   ```
   Extra args are forwarded to the Ansible playbook (e.g. `-e "key=value"`).
2. **`terraform/`** — provisions cloud networking (VPC/VNet, subnets, NAT/IGW or Transit Gateway for disconnected), IAM/identity roles, and a bastion VM. Config is driven by a `terraform.tfvars` file the user creates locally (never commit one). Terraform outputs (bastion IP, subnet IDs, hosted zone IDs, etc.) are written to a generated vars file consumed by the Ansible layer.
3. **`setup-bastion-*.yaml`** (Ansible playbook, e.g. `setup-bastion-ec2-connected.yaml`) — installs tooling (`oc`, `openshift-install`, `rosa`, `ccoctl`, mirror registry for disconnected) on the bastion, generates STS credentials, and renders an `install-dir/` ready for `openshift-install create cluster`.

Disconnected variants additionally set up a Quay/mirror registry on the bastion and run `oc mirror` to sync release images (30–60 min) before the install directory is usable.

Teardown is always: destroy the OpenShift cluster first (`openshift-install destroy cluster` / `rosa delete cluster` / delete `HostedCluster`), *then* `terraform destroy` in that directory's `terraform/` — destroying infra first orphans DNS/RAM-share/route53 associations.

`aws/rosa/tf-rosa-platform/` is the more complex, multi-account version of this pattern: four Terraform child modules applied in strict dependency order across a VPC-owner account and a ROSA account (see its README's dependency graph), with a `Makefile` for step-by-step application via named AWS profiles as an alternative to single-shot cross-account role assumption.

## Working conventions

- Never commit `terraform.tfvars`, pull secrets, SSH private keys, or generated `install-dir/`/`ansible-vars.json` artefacts — these are meant to be created locally per deployment.
- Sensitive Terraform variables (pull secrets, mirror registry passwords, SSH keys) are passed via `TF_VAR_*` environment variables in documented examples, not written to files.
- YAML manifests in this repo are templates/examples with placeholder values (domains like `example.com`, account IDs, image references pointing at `mirror.hub.mylab.com` or `<mirror_registry>`) — expect to substitute real values before applying, and preserve that placeholder convention when adding new examples.
- Cross-references between READMEs use relative GitHub paths back to `sadiquepp/openshift` (the upstream of this repo) — keep new cross-references consistent with that style.
