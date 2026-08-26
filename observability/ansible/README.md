# Automating the observability runbook

Ansible automation of [`../README.md`](../README.md) — the OpenShift Logging,
Network Observability, distributed tracing and test workload sections, end to
end, on a fresh connected cluster.

The runbook stays the source of truth for *why* each resource looks the way it
does. This directory is the executable form of it: same resources, same order,
same caveats, with the waits and the idempotency that a copy-paste session does
not give you.

## Contents
- [Why Ansible](#why-ansible)
- [What it deploys](#what-it-deploys)
- [Prerequisites](#prerequisites)
  - [Ansible and Python versions](#ansible-and-python-versions)
  - [Python libraries](#python-libraries)
  - [Which AWS credentials get used](#which-aws-credentials-get-used)
  - [Pointing at the right cluster](#pointing-at-the-right-cluster)
- [The two phases](#the-two-phases)
  - [Phase 1 — AWS (an AWS admin can run this alone)](#phase-1--aws-an-aws-admin-can-run-this-alone)
  - [Phase 2 — cluster](#phase-2--cluster)
  - [Both at once](#both-at-once)
- [Choosing Network Observability with or without Loki](#choosing-network-observability-with-or-without-loki)
- [Variables](#variables)
- [Running part of the stack](#running-part-of-the-stack)
- [The OpenTelemetry log-correlation demo](#the-opentelemetry-log-correlation-demo)
- [Layout](#layout)
- [Where this deviates from the runbook](#where-this-deviates-from-the-runbook)
- [Re-running and idempotency](#re-running-and-idempotency)
- [Troubleshooting](#troubleshooting)
- [Teardown](#teardown)

## Why Ansible

The runbook is a long sequence of `aws` and `oc` commands with ordering
constraints, waits that are described in prose, and three near-identical S3
backends. That is the shape Ansible is good at, and it is what the rest of this
repository already uses.

The specific things it buys here:

- **The AWS phase separates cleanly.** `aws-prereqs.yml` touches nothing but
  AWS, so an AWS admin with no kubeconfig can run it and hand over one file.
- **Waits become real.** "Verify the CSV is created" in the runbook is a
  `oc get csv` you run until it looks right. Here it is a retry loop with a
  deadline, and the deadline failing tells you which operator got stuck.
- **The Loki/no-Loki choice becomes one variable** instead of two divergent
  paths you follow by hand.
- **Re-running is safe.** Every task is an apply or a read-modify-write, and the
  AWS phase reuses access keys it already minted rather than rotating them.

Terraform was the alternative and is the wrong tool: two of the three layers
here are Kubernetes custom resources whose readiness is a status condition, not
a resource that either exists or does not.

## What it deploys

| Layer | Components |
|---|---|
| OpenShift Logging | Loki Operator, LokiStack on S3, Cluster Logging Operator, collector SA + RBAC, `ClusterLogForwarder`, `LogFileMetricExporter`, Logging `UIPlugin` |
| Cluster Observability Operator | The operator behind all three console `UIPlugin`s |
| Network Observability | Operator, `FlowCollector` (Path A **or** Path B), the flows LokiStack + cross-namespace CA rolebindings on Path B, console plugin registration, Troubleshooting Panel |
| Distributed tracing | Tempo Operator, `TempoStack` on S3, DistributedTracing `UIPlugin`, OpenTelemetry Operator, collector SA + Tempo tenant RBAC, `OpenTelemetryCollector` with the spanmetrics connector, user workload monitoring, two `ServiceMonitor`s |
| Test workload | Online Boutique via the `tracing` overlay, plus the `Instrumentation` CR and the `adservice` probe/resource patches that make auto-instrumentation work |

The collector is deployed **with the spanmetrics connector from the start**. The
runbook builds a traces-only collector first and replaces it later; there is no
reason to deploy the intermediate one.

## Prerequisites

- A fresh **connected** OpenShift cluster with a **default StorageClass** and
  enough headroom (two LokiStacks at `1x.pico`, a TempoStack, a collector, the
  eBPF agent on every node, and 12 application Deployments).
- `cluster-admin` on it — preflight checks by attempting a `SelfSubjectAccessReview`
  for creating Subscriptions.
- AWS credentials that can create S3 buckets, IAM policies, IAM users and access
  keys — see [Which AWS credentials get used](#which-aws-credentials-get-used).
- `oc` on `PATH`. It is used **only** to render the workload's kustomize overlay
  and to check its own version — it never contacts the cluster, so `oc login` is
  not a prerequisite.
- **ansible-core 2.17 in a virtualenv on Python 3.11/3.12**, the collections and
  two Python libraries — see below. `ansible-galaxy` will not pick compatible
  collection versions on its own.

### Ansible and Python versions

**The supported setup is ansible-core 2.17 in a virtualenv on Python 3.11 or
3.12.** A venv keeps this off the system Python entirely, so an existing
`ansible-core` RPM — and anything else on the box that depends on it — is
untouched.

```bash
sudo dnf install -y python3.11
```

```bash
python3.11 -m venv ~/.venv/observability && ~/.venv/observability/bin/pip install --upgrade pip
```

```bash
~/.venv/observability/bin/pip install 'ansible-core~=2.17.0' boto3 botocore kubernetes
```

```bash
source ~/.venv/observability/bin/activate && ansible-galaxy collection install -r requirements.yml
```

Activate that venv in any shell you run the playbooks from.

Two details that are easy to get wrong:

- **Python 3.11 or 3.12, not 3.13.** ansible-core 2.17 supports controller
  Python 3.10–3.12 only. RHEL 9 AppStream carries `python3.11` and `python3.12`.
- **Pin ansible-core.** A bare `pip install ansible-core` resolves to the newest
  release the interpreter supports, which on Python 3.11 is well past 2.17.
  `~=2.17.0` keeps you on the 2.17 series.

`requirements.yml` resolves to amazon.aws 11.4.0 and kubernetes.core 6.5.0,
which declare `requires_ansible >=2.17.0` and `>=2.16.0`. Its upper bounds are
deliberate: `ansible-galaxy` **does not consider `requires_ansible` when
resolving versions**, so without them a future major could install itself and
then warn that it needs a newer ansible-core than you have.

#### Fallback: system ansible-core 2.13–2.16

If a venv is not an option and you have to use the RHEL 9 AppStream
`ansible-core` (2.14), there is a pinned collection set for it:

```bash
ansible-galaxy collection install -r requirements-legacy.yml --force
```

```bash
/usr/bin/python3 -m pip install boto3 botocore kubernetes
```

It resolves amazon.aws 7.6.1 and kubernetes.core 3.3.1 — the newest releases
that genuinely support 2.14. Every module used here is present in both with the
same parameter and return names. Without the pins you get:

```
[WARNING]: Collection amazon.aws does not support Ansible version 2.14.17
```

which is a warning now and a confusing failure later. `--force` matters too:
galaxy will not *downgrade* to satisfy a constraint an already-installed newer
version also meets, so without it you get `Nothing to do. All requested
collections are already installed.`

### Python libraries

The collections are wrappers — the real work is done by Python libraries that
must be importable by **the interpreter Ansible runs modules under**:

| Library | Needed by | Phase |
|---|---|---|
| `boto3`, `botocore` | `amazon.aws` | AWS |
| `kubernetes` | `kubernetes.core` | cluster |

Both commands above install them. `inventory.yml` sets
`ansible_python_interpreter: "{{ ansible_playbook_python }}"` so that
interpreter is always the one running `ansible-playbook` — install the
libraries next to Ansible and they are found.

That line is load-bearing in a venv. Ansible's *implicit* localhost gets
`sys.executable` for free, but this inventory declares `localhost` explicitly,
which falls back to interpreter discovery and lands on `/usr/bin/python3` — so
without it you would install into the venv and Ansible would look outside it.

If a module still reports a missing library, the error names the exact
interpreter it used (`... on <host>'s Python /usr/bin/python3`). Install there,
or point Ansible elsewhere with `-e ansible_python_interpreter=…`.

### Which AWS credentials get used

A virtualenv changes **nothing** here. It isolates Python packages, not
environment variables, `$HOME`, or `~/.aws/` — so whatever works for the `aws`
CLI works for the playbooks. The tasks pass only `region`, never credentials, so
botocore's normal chain applies, in this order:

1. the `aws_profile` variable, if you set it
2. `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_PROFILE` **environment
   variables**
3. `~/.aws/credentials` and `~/.aws/config`
4. an instance role

**Step 2 silently outranks step 3**, which is the usual cause of a confusing
failure: a stale `AWS_ACCESS_KEY_ID` exported in the shell beats the profile
that actually works, and you get

```
InvalidClientTokenId: The security token included in the request is invalid
InvalidAccessKeyId: The AWS Access Key Id you provided does not exist in our records
```

Both mean credentials *were* found and are wrong — not that none were found.
This command shows which source won for each value, without printing secrets:

```bash
aws configure list
```

```bash
env | grep -i aws
```

To be explicit rather than relying on ambient state, name the profile — it is
applied to every `amazon.aws` module through `module_defaults`:

```bash
ansible-playbook site.yml -e suffix=xipio -e aws_profile=lab
```

`profile` is mutually exclusive with `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
being set, so unset those if you use it.

> **`sudo` changes `$HOME`.** Under `sudo`, `~/.aws` resolves to `/root/.aws`,
> not your user's. Be consistent about which one you populate.

> **Check the region.** `aws_region` defaults to `ap-south-1` and is passed
> explicitly, so it **overrides** the region in your AWS config rather than
> inheriting it. Buckets are created there and the Loki/Tempo S3 endpoints are
> derived from it, so a mismatch puts your buckets somewhere unexpected instead
> of failing loudly.

### Pointing at the right cluster

The `kubernetes.core` modules resolve the connection in this order:

1. the `kubeconfig` / `context` module parameters — set from the `kubeconfig`
   and `kube_context` variables,
2. `K8S_AUTH_KUBECONFIG`,
3. the Python client's default, which reads `KUBECONFIG` and otherwise falls
   back to `~/.kube/config`'s current-context.

So **if `~/.kube/config` already points at the target cluster, you need to do
nothing.** Otherwise either export it in the usual way:

```bash
export KUBECONFIG=~/clusters/lab/auth/kubeconfig
```

or pass it as a variable, which is the better option in CI and when one
`~/.kube/config` holds several clusters:

```bash
ansible-playbook cluster.yml -e suffix=xipio -e kubeconfig=~/clusters/lab/auth/kubeconfig
```

```bash
ansible-playbook cluster.yml -e suffix=xipio -e kube_context=lab-admin
```

**`aws-prereqs.yml` needs none of this** — it never contacts a cluster, which is
what lets an AWS admin run it.

The failure worth guarding against is not a *missing* kubeconfig, which fails
immediately and harmlessly. It is a *present* one whose current-context is the
wrong cluster: everything here is cluster-wide and takes about 45 minutes to
undo. So preflight prints the API server URL it resolved before creating
anything:

```
Target:    https://api.lab.example.com:6443
Version:   OpenShift 4.18.20
Deploying: logging=True, netobserv=True (loki=True), tracing=True, workload=True
```

Read that line before you walk away from the terminal.

## The two phases

### Phase 1 — AWS (an AWS admin can run this alone)

```bash
ansible-playbook aws-prereqs.yml -e suffix=xipio -e aws_region=ap-south-1
```

Creates, per enabled component, an S3 bucket (encrypted, public access blocked),
a least-privilege IAM policy scoped to that one bucket, a dedicated IAM user,
and an access key. Writes them to `s3-credentials.yml`, mode `0600`,
gitignored.

That file is the entire handoff. Encrypt it if it has to travel:

```bash
ansible-vault encrypt s3-credentials.yml
```

Phase 2 reads an encrypted file transparently with `--ask-vault-pass`.

> Pass the **same** component toggles to both phases. `-e netobserv_use_loki=false`
> in phase 1 means no netobserv bucket is created; passing it only to phase 2
> leaves an orphan bucket behind, and passing it only to phase 1 makes phase 2
> fail preflight with a missing-credentials message.

### Phase 2 — cluster

```bash
ansible-playbook cluster.yml -e suffix=xipio
```

Roughly 30–45 minutes on a healthy cluster, most of it waiting for operators to
install and for the two LokiStacks and the TempoStack to come up.

### Both at once

When the same person holds the AWS credentials and the kubeconfig:

```bash
ansible-playbook site.yml -e suffix=xipio
```

## Choosing Network Observability with or without Loki

One variable, on both phases:

```bash
# Path B - full flow records in a dedicated LokiStack on S3 (default)
ansible-playbook site.yml -e suffix=xipio -e netobserv_use_loki=true
```

```bash
# Path A - metrics only, no extra storage
ansible-playbook site.yml -e suffix=xipio -e netobserv_use_loki=false
```

|                          | `false` — Path A | `true` — Path B |
|---|---|---|
| Extra AWS resources | none | one bucket + IAM user |
| Observe → Network Traffic → Overview, Topology | yes | yes |
| Topology scope | node / namespace / owner-workload | down to pod and IP |
| Traffic flows table (raw records) | **no** | yes |
| Troubleshooting Panel netflow correlation | nothing to correlate | yes |
| Cost | baseline | ~45–65% more memory, ~10–20% more CPU |

**Switching later is supported and does not reinstall anything.** Run
`aws-prereqs.yml` again to mint the extra bucket, then `cluster.yml` again — the
`FlowCollector` is cluster-scoped and singular, so re-applying it rewrites the
`loki` block in place, which is exactly the patch the runbook describes.

## Variables

Everything lives in [`group_vars/all.yml`](group_vars/all.yml), commented. The
ones worth knowing:

| Variable | Default | Notes |
|---|---|---|
| `suffix` | — | **Required.** Makes bucket and IAM user names unique. S3 bucket names are globally unique across all of AWS. |
| `aws_profile` | `""` | Empty uses botocore's normal chain. Set it when several credential sources exist. |
| `kubeconfig` | `""` | Empty falls back to `KUBECONFIG`, then `~/.kube/config`. Ignored by the AWS phase. |
| `kube_context` | `""` | Empty uses the kubeconfig's current-context. |
| `aws_region` | `ap-south-1` | |
| `netobserv_use_loki` | `true` | Path B / Path A. |
| `storage_class_name` | `""` | Empty means "discover the cluster default". |
| `logging_enabled` / `netobserv_enabled` / `tracing_enabled` / `workload_enabled` | `true` | Layer toggles. |
| `adservice_autoinstrument` | `true` | The `Instrumentation` CR demo. Needed by the OTel log demo. |
| `grant_users` | `[]` | OpenShift usernames to grant the reader roles to. Admins already pass. |
| `loki_channel`, `cluster_logging_channel`, … | `stable-6.6`, `stable` | Operator channels. |
| `logging_uiplugin_schema` | `viaq` | See [deviations](#where-this-deviates-from-the-runbook). |

## Running part of the stack

```bash
ansible-playbook cluster.yml -e suffix=xipio --tags logging
```

Tags: `logging`, `netobserv`, `tracing`, `workload`, `coo`. Preflight is tagged
`always` and runs regardless.

Layers can also be switched off entirely, which is what you want if the cluster
already has one of them:

```bash
ansible-playbook cluster.yml -e suffix=xipio -e logging_enabled=false
```

## The OpenTelemetry log-correlation demo

The final part of [`../demo/README.md`](../demo/README.md) shows a log record
carrying its own trace ID, which needs three changes made in order. They are off
by default, because the `debug` exporter is loud enough to distort log volume on
a shared cluster.

```bash
ansible-playbook demo-otel-logs.yml -e suffix=xipio
```

```bash
ansible-playbook demo-otel-logs.yml -e suffix=xipio -e demo_state=reverted
```

## Layout

```
requirements.yml         Collections, for ansible-core 2.17 in a venv - the supported setup
requirements-legacy.yml  Collections, fallback for system ansible-core 2.13-2.16

aws-prereqs.yml       AWS only - buckets, IAM, access keys, credentials file
cluster.yml           Everything cluster-side
site.yml              Both, in order
demo-otel-logs.yml    Enable/revert the OTel log-correlation demo
cleanup.yml           Teardown, guarded

group_vars/all.yml    Every tunable, commented

roles/
  preflight           Fail early: suffix, cluster reachable, admin, StorageClass, credentials
  aws_backends        One bucket + policy + user + key per component
  olm_operator        Reusable: Namespace + OperatorGroup + Subscription + waits
  lokistack           Reusable: S3 secret + LokiStack + wait (used for logs and for flows)
  cluster_observability   The Cluster Observability Operator
  openshift_logging   LokiStack, forwarder, collector RBAC, Logging UIPlugin
  network_observability   Operator, Path A/B FlowCollector, console plugin, panel
  distributed_tracing TempoStack, OTel collector + spanmetrics, UWM, ServiceMonitors
  test_workload       Online Boutique + adservice auto-instrumentation
```

Two roles are deliberately generic. `olm_operator` installs all six operators,
so the "wait until it is actually usable" logic — resolve the Subscription, read
`status.currentCSV`, wait for that CSV to reach `Succeeded`, then wait for the
CRDs to be `Established` — exists once. `lokistack` builds both LokiStacks, which
differ only in tenant mode.

## Where this deviates from the runbook

Three places, each deliberate:

1. **`logging_uiplugin_schema` defaults to `viaq`, not `otel`.** The
   `ClusterLogForwarder` writes the default ViaQ data model, and the console
   Logging plugin's `schema` has to agree with what is actually in Loki or its
   namespace dropdown comes up empty. The runbook documents that trap under
   *"Label names depend on the data model"* and offers both fixes; this picks the
   one that leaves the console working. Set `-e logging_uiplugin_schema=otel` if
   you switch the forwarder to the OTel model.

2. **The collector ships with the spanmetrics connector immediately.** The
   runbook creates a traces-only collector and replaces it several sections
   later. The final state is identical.

3. **The Tempo tenant ID is a deterministic UUIDv5** derived from `suffix`,
   rather than a fresh `uuidgen`. A random ID would differ on every run and
   rewrite the `TempoStack` each time.

## Re-running and idempotency

Safe to re-run. Specifics worth knowing:

- **Access keys are not rotated.** If `s3-credentials.yml` holds a key that still
  exists in IAM, it is reused. Otherwise, keys the file has no secret for are
  deleted first (IAM allows two per user) and a fresh one is minted.
- **`cluster-monitoring-config` is read-modify-written**, so an existing
  Alertmanager or retention configuration survives having `enableUserWorkload`
  added.
- **Console plugin registration appends** to `spec.plugins` and only when
  `netobserv-plugin` is missing, so `logging-view-plugin` and `monitoring-plugin`
  are preserved and the console is not rolled on every run.
- **`demo-otel-logs.yml` always restarts `adservice`** — that is the point of it,
  since the `Instrumentation` CR is read only at pod admission.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `InvalidClientTokenId` / `InvalidAccessKeyId` | Credentials were found but are invalid — usually a stale `AWS_ACCESS_KEY_ID` in the environment outranking `~/.aws/credentials`. Run `aws configure list`. |
| "Failed to import the required Python library (botocore and boto3)" | Not installed next to Ansible. The message names the exact interpreter used — see [Python libraries](#python-libraries). |
| "Failed to import the required Python library (kubernetes)" | Same, for the cluster phase. |
| Library is installed in your venv but Ansible still says it is missing | Ansible ran the module under a different interpreter. Check the path in the error against `which ansible-playbook`; the `ansible_python_interpreter` line in `inventory.yml` is what normally prevents this. |
| "Collection amazon.aws does not support Ansible version 2.14.x" | You are on the system ansible-core, not the 2.17 venv. Activate it, or install `requirements-legacy.yml --force`. |
| "Failed to get client due to Invalid kube-config file" / connection refused | No usable kubeconfig. Export `KUBECONFIG` or pass `-e kubeconfig=…`. Nothing has been created at that point. |
| Preflight ran against the wrong cluster | Check the `Target:` line it prints. Pin it with `-e kube_context=…` rather than relying on current-context. |
| Preflight: "must be set to a short lowercase string" | Pass `-e suffix=…`. |
| Preflight: "No S3 credentials for the `x` backend" | Phase 1 was not run, was run with different toggles, or the file is vault-encrypted — add `--ask-vault-pass`. |
| Preflight: "No StorageClass is marked default" | Mark one, or pass `-e storage_class_name=…`. |
| "wait for the Subscription to resolve" times out | Almost always a wrong channel. `oc describe subscription <name> -n <ns>` and look for `ResolutionFailed`. |
| A LokiStack never reaches Ready | Storage or credentials. `oc get pods -n <ns> -l app.kubernetes.io/instance=<stack>` — Pending means the StorageClass cannot bind, CrashLoop means the S3 credentials are wrong. |
| `adservice` assertion: "did not inject the Java agent" | The OpenTelemetry operator's webhook is not running, or the `Instrumentation` CR is in the wrong namespace. |
| Metrics missing in the console | `up{namespace="tracing-system"}` — no series means the `ServiceMonitor` selector does not match the Service, which varies by operator version. Compare against `oc get svc -n tracing-system --show-labels`. |

## Teardown

Cluster resources only:

```bash
ansible-playbook cleanup.yml -e suffix=xipio -e cleanup_confirm=yes
```

Cluster resources **and** the AWS buckets, users and policies:

```bash
ansible-playbook cleanup.yml -e suffix=xipio -e cleanup_confirm=yes -e cleanup_aws=yes
```

Cluster first, then AWS — deleting the buckets while the operators are still
writing leaves them retrying against storage that is gone. Operators,
Subscriptions and CSVs are left in place; removing them is rarely what you want
mid-iteration and they cost nothing idle.
