# Automating the Kafka export

Ansible automation of [`../README.md`](../README.md) — every observability signal the cluster
produces, written to a Kafka topic, end to end, on a fresh connected cluster.

The runbook stays the source of truth for *why* each resource looks the way it does. This directory
is the executable form of it: same resources, same order, same caveats, with the waits and the
idempotency that a copy-paste session does not give you.

## Contents
- [How this differs from ../../ansible](#how-this-differs-from-ansible)
- [What it deploys](#what-it-deploys)
- [Prerequisites](#prerequisites)
  - [Ansible and Python versions](#ansible-and-python-versions)
  - [Pointing at the right cluster](#pointing-at-the-right-cluster)
- [Telling it about your broker](#telling-it-about-your-broker)
- [Running it](#running-it)
- [The two Kafka modes](#the-two-kafka-modes)
- [Variables](#variables)
- [Running part of the stack](#running-part-of-the-stack)
- [Verifying](#verifying)
- [Layout](#layout)
- [Where this deviates from the runbook](#where-this-deviates-from-the-runbook)
- [Re-running and idempotency](#re-running-and-idempotency)
- [Troubleshooting](#troubleshooting)
- [Teardown](#teardown)

## How this differs from ../../ansible

[`../../ansible`](../../ansible) automates the full stack with its storage layers. This one
automates the same signals with the storage removed.

| | `../../ansible` | here |
|---|---|---|
| Playbooks | `aws-prereqs.yml` + `cluster.yml`, or `site.yml` | `site.yml`, and that is all |
| Collections | `amazon.aws` + `kubernetes.core` | `kubernetes.core` only |
| Python libraries | `boto3`, `botocore`, `kubernetes` | `kubernetes` only |
| AWS credentials | required — buckets, IAM users, access keys | **none** |
| Handoff file | `s3-credentials.yml`, minted by phase 1 | `kafka-credentials.yml`, which you write — nobody mints it for you |
| Default StorageClass | required, for two LokiStacks and a TempoStack | not required |
| External dependency | an AWS account | a Kafka cluster |
| Operators installed | Loki, Cluster Logging, COO, NetObserv, Tempo, OpenTelemetry | Streams for Apache Kafka, Cluster Logging, NetObserv, OpenTelemetry |

**There is no AWS phase because there is nothing to store.** That is the single structural
difference, and it is why this is one playbook rather than two.

## What it deploys

| Layer | Components | Topic |
|---|---|---|
| Kafka platform | Streams for Apache Kafka operator; the topics; optionally a KRaft lab broker | — |
| Logs | Cluster Logging Operator, collector SA + RBAC, `ClusterLogForwarder` with a `kafka` output | `cluster-logs` |
| Network flows | NetObserv Operator, `FlowCollector` with a Kafka **exporter**, console plugin registration | `network-flows` |
| Traces + span metrics + metrics | OpenTelemetry Operator, collector SA + RBAC, user workload monitoring, one `OpenTelemetryCollector` with three pipelines | `otlp-traces`, `otlp-spanmetrics`, `federated-metrics` |
| Test workload | Online Boutique via the `tracing` overlay, repointed at this collector | — |

The collector ships **with the spanmetrics connector and the federation scrapes from the start**.
The runbook builds them up in stages for readability; there is no reason to deploy the intermediate
versions.

## Prerequisites

- A **connected** OpenShift cluster and `cluster-admin` on it — preflight checks by attempting a
  `SelfSubjectAccessReview` for creating Subscriptions.
- A Kafka cluster the pods can reach, its CA, and a SASL user that may create and produce to the
  topics. Or `-e kafka_mode=incluster`, which deploys a lab broker instead.
- `oc` on `PATH`. Used **only** to render the workload's kustomize overlay — it never contacts the
  cluster, so `oc login` is not a prerequisite. Not needed at all with
  `-e workload_enabled=false`.
- **ansible-core 2.17 in a virtualenv on Python 3.11/3.12**, the collection and one Python library.
- **No default StorageClass is required**, and no AWS credentials at all.

### Ansible and Python versions

**The supported setup is ansible-core 2.17 in a virtualenv on Python 3.11 or 3.12.** A venv keeps
this off the system Python entirely, so an existing `ansible-core` RPM — and anything else on the
box that depends on it — is untouched.

```bash
sudo dnf install -y python3.11
```

```bash
python3.11 -m venv ~/.venv/obs-kafka && ~/.venv/obs-kafka/bin/pip install --upgrade pip
```

```bash
~/.venv/obs-kafka/bin/pip install 'ansible-core~=2.17.0' kubernetes
```

```bash
source ~/.venv/obs-kafka/bin/activate && ansible-galaxy collection install -r requirements.yml
```

Two details that are easy to get wrong:

- **Python 3.11 or 3.12, not 3.13.** ansible-core 2.17 supports controller Python 3.10–3.12 only.
  RHEL 9 AppStream carries `python3.11` and `python3.12`.
- **Pin ansible-core.** A bare `pip install ansible-core` resolves to the newest release the
  interpreter supports, which on Python 3.11 is well past 2.17. `~=2.17.0` keeps you on the 2.17
  series.

`inventory.yml` sets `ansible_python_interpreter: "{{ ansible_playbook_python }}"` so modules always
run under the interpreter running `ansible-playbook` — install `kubernetes` next to Ansible and it
is found. That line is load-bearing in a venv: Ansible's *implicit* localhost gets `sys.executable`
for free, but this inventory declares `localhost` explicitly, which falls back to interpreter
discovery and lands on `/usr/bin/python3`.

#### Fallback: system ansible-core 2.13–2.16

```bash
ansible-galaxy collection install -r requirements-legacy.yml --force
```

```bash
/usr/bin/python3 -m pip install kubernetes
```

`--force` matters: galaxy will not *downgrade* to satisfy a constraint an already-installed newer
version also meets, so without it you get `Nothing to do. All requested collections are already
installed.`

### Pointing at the right cluster

The `kubernetes.core` modules resolve the connection in this order:

1. the `kubeconfig` / `context` module parameters — set from the `kubeconfig` and `kube_context`
   variables,
2. `K8S_AUTH_KUBECONFIG`,
3. the Python client's default, which reads `KUBECONFIG` and otherwise falls back to
   `~/.kube/config`'s current-context.

So **if `~/.kube/config` already points at the target cluster, you need to do nothing.** Otherwise:

```bash
ansible-playbook site.yml -e kubeconfig=~/clusters/lab/auth/kubeconfig
```

Preflight prints the cluster **and the broker** before creating anything, then pauses:

```
About to make cluster-wide changes to:

    https://api.lab.example.com:6443
    OpenShift 4.18.20

and stream every signal it produces to:

    kafka-1.example.com:9093  (SASL_SSL)

Ctrl-C then 'A' to abort if that is not the cluster you meant.
```

The broker is named as prominently as the cluster on purpose: sending a production cluster's audit
logs to the wrong Kafka is the more expensive of the two mistakes, and it is the one a kubeconfig
check will not catch.

```bash
ansible-playbook site.yml -e confirm_pause_seconds=0     # unattended
```

## Telling it about your broker

Four things have no default. Put them in `kafka-credentials.yml`, which is gitignored:

```yaml
---
kafka_bootstrap_servers:
  - kafka-1.example.com:9093
  - kafka-2.example.com:9093
kafka_sasl_username: observability
kafka_sasl_password: "<the SASL password>"
kafka_ca_cert_file: ~/kafka-ca.crt
```

```bash
ansible-playbook site.yml -e @kafka-credentials.yml
```

Encrypt it if it has to travel, and add `--ask-vault-pass`:

```bash
ansible-vault encrypt kafka-credentials.yml
```

`kafka_ca_cert_file` is read from the control node at preflight time; use `kafka_ca_cert` instead to
paste the PEM inline. Everything that touches the password is `no_log: true`.

## Running it

```bash
ansible-playbook site.yml -e @kafka-credentials.yml
```

Roughly 20–30 minutes on a healthy cluster, most of it waiting for four operators to install and for
the eBPF agent to roll out on every node. Considerably less than the storage-backed stack, which
spends most of its time waiting for two LokiStacks and a TempoStack.

## The two Kafka modes

```bash
# external (the default) - a broker you already run
ansible-playbook site.yml -e @kafka-credentials.yml
```

```bash
# incluster - a lab broker, for a cluster with no Kafka to point at
ansible-playbook site.yml -e kafka_mode=incluster
```

|  | `external` | `incluster` |
|---|---|---|
| Broker | yours, off-cluster | a KRaft cluster deployed by the operator |
| Topics created by | a Job running `bin/kafka-topics.sh` | `KafkaTopic` resources, reconciled by the Topic Operator |
| Listener | whatever you configured | one plain internal listener on 9092 |
| TLS / SASL | as you set them | **neither** — the `kafka_tls_enabled` and `kafka_sasl_enabled` toggles do not apply, and `kafka_*_effective` reflects that |
| Storage | not this cluster's problem | `ephemeral` by default |
| Credentials needed | bootstrap, user, password, CA | none |

`incluster` exists so the whole pipeline can be proven on a cluster with nothing to point at. Its
storage is ephemeral on purpose: it is a bus to demonstrate the wiring with, not somewhere to keep
data. Switch it with `-e kafka_storage_type=persistent-claim -e kafka_storage_size=50Gi` if you want
the lab bus to survive a restart.

## Variables

Everything lives in [`group_vars/all.yml`](group_vars/all.yml), commented. The ones worth knowing:

| Variable | Default | Notes |
|---|---|---|
| `kafka_bootstrap_servers` | `[]` | **Required in `external` mode.** A list of `host:port`. |
| `kafka_sasl_username` / `_password` | `""` | Required when `kafka_sasl_enabled`. |
| `kafka_ca_cert_file` / `kafka_ca_cert` | `""` | Required when `kafka_tls_enabled`, unless skipping verification. |
| `kafka_mode` | `external` | `external` or `incluster`. |
| `kafka_tls_enabled` / `kafka_sasl_enabled` | `true` | Together they pick the `security.protocol`. |
| `kafka_sasl_mechanism` | `SCRAM-SHA-512` | `PLAIN`, `SCRAM-SHA-256` or `SCRAM-SHA-512`. NetObserv supports only the first and last. |
| `kafka_tls_insecure_skip_verify` | `false` | Lab escape hatch when you cannot get the CA. |
| `kafka_topic_*` | `otlp-traces`, … | One per signal. |
| `kafka_topic_partitions` | `3` | Logs and flows get double. |
| `kafka_topic_replication_factor` | `3` | Clamped to the broker count in `incluster` mode. |
| `kafka_topic_config` | `retention.ms=24h` | Applied to every topic this creates. |
| `kafka_admin_image` | `""` | Empty means "read `STRIMZI_KAFKA_IMAGES` off the running operator". Set it for a disconnected cluster. |
| `logging_enabled` / `netobserv_enabled` / `tracing_enabled` / `metrics_federation_enabled` / `workload_enabled` | `true` | Layer toggles. A disabled layer also stops its topic being created. |
| `spanmetrics_enabled` | `true` | The `spanmetrics` connector and its topic. |
| `logging_include_audit` | `true` | Audit logs. Roughly doubles the volume on a busy API server. |
| `netobserv_sampling` | `50` | One flow in fifty. `1` exports everything. |
| `otel_kafka_topic_style` | `per_signal` | `per_signal` nests `topic`/`encoding` under `traces:`/`metrics:`; `flat` keeps them top-level. Collector builds differ. |
| `otel_kafka_auth_style` | `nested` | `nested` puts TLS/SASL under `auth:`; `flat` puts them top-level. A separate axis from the above. |
| `netobserv_kafka_egress_policy` | `true` | Adds a NetworkPolicy letting the flow processor reach the broker. NetObserv's own policy blocks it otherwise. |
| `netobserv_kafka_egress_cidrs` | `[]` | Narrows that rule to specific destinations. Empty means any destination on the broker port. |
| `platform_federate_match` / `uwm_federate_match` | curated selectors | What `/federate` returns on every scrape. Widen carefully. |
| `confirm_pause_seconds` | `30` | Hold before the first change. `0` for unattended runs. |
| `kubeconfig` / `kube_context` | `""` | Empty falls back to `KUBECONFIG`, then `~/.kube/config`. |

## Running part of the stack

```bash
ansible-playbook site.yml -e @kafka-credentials.yml --tags logs
```

Tags: `kafka`, `logs`, `flows`, `otel` (also `traces` / `metrics`), `workload`. Preflight is tagged
`always` and runs regardless.

Layers can also be switched off entirely, which is what you want if the cluster already has one of
them:

```bash
ansible-playbook site.yml -e @kafka-credentials.yml -e netobserv_enabled=false
```

Turning a layer off also drops its topic from the list — so `-e tracing_enabled=false` means
`otlp-traces` and `otlp-spanmetrics` are neither created nor produced to.

## Verifying

```bash
ansible-playbook verify.yml -e @kafka-credentials.yml
```

Runs `bin/kafka-get-offsets.sh` against every topic and prints the end offset per partition. A
non-zero total means records have landed. Give the load generator a few minutes first — federated
metrics appear within one scrape interval, but traces need traffic through an instrumented workload.

Offsets rather than a console consumer on purpose: the payloads are protobuf, so consuming them
prints a screen of binary and proves the same one thing.

## Layout

```
requirements.yml         kubernetes.core, for ansible-core 2.17 in a venv - the supported setup
requirements-legacy.yml  Fallback pin for system ansible-core 2.13-2.16

site.yml              Everything, in order. There is no second playbook.
verify.yml            End offsets on every topic
cleanup.yml           Teardown, guarded

group_vars/all.yml    Every tunable, commented
kafka-credentials.yml Your broker's address and credentials (gitignored, you write it)

roles/
  preflight             Fail early: broker, credentials, cluster reachable, admin
  olm_operator          Reusable: Namespace + OperatorGroup + Subscription + waits
  kafka_platform        Streams for Apache Kafka, the topics, optionally a lab broker
  kafka_client_secrets  Reusable: the CA and SASL Secrets, once per producing namespace
  logs_kafka            Cluster Logging Operator + ClusterLogForwarder kafka output
  netflows_kafka        NetObserv Operator + FlowCollector Kafka exporter
  otel_kafka            OpenTelemetry Operator + collector: traces, spanmetrics, federation
  test_workload         Online Boutique, repointed at this collector
```

Three roles are deliberately generic. `olm_operator` installs all four operators, so the "wait until
it is actually usable" logic — resolve the Subscription, read `status.currentCSV`, wait for that CSV
to reach `Succeeded`, then wait for the CRDs to be `Established` — exists once. `kafka_client_secrets`
creates the same two Secrets in each of the four namespaces that need them. `kafka_platform` covers
both broker modes behind one interface.

## Where this deviates from the runbook

1. **The Kafka admin image is discovered, not pinned.** The runbook has you read
   `STRIMZI_KAFKA_IMAGES` off the operator with `jq`; the automation does the same thing through the
   API, finding the Deployment by that environment variable rather than by name (the name carries
   the operator version). The result is a digest-pinned image that always matches the operator you
   just installed. Override with `-e kafka_admin_image=...` on a disconnected cluster.

   That variable comes in **two shapes** and both are handled. Older builds set it inline as
   `value:`. Recent ones set it through the downward API — `valueFrom.fieldRef.fieldPath:
   "metadata.annotations['kafka-images']"` — so `value` is null and the map is an annotation on the
   operator's own pod. The annotation *name* is taken from the `fieldPath` rather than assumed, so a
   rename does not break it either; if the map cannot be resolved at all, the failure names the
   Deployment and tells you to pass `kafka_admin_image` yourself.

2. **`otel_kafka_auth_style` is a variable, and the runbook only shows one of the two layouts.**
   The Kafka exporter's TLS and SASL settings live under `auth:` in the build the Red Hat OpenTelemetry
   operator currently ships; upstream moved them to top-level `tls:` / `sasl:` keys, and newer builds
   will eventually require that. This is a startup failure rather than a silent misconfiguration, so
   the collector role reads the pod's logs on a failed rollout and says which one to try.

3. **The collector ships complete.** Spanmetrics connector and both federation scrapes are in the
   first `OpenTelemetryCollector` applied, rather than added in later sections. The final state is
   identical.

4. **A supplementary NetworkPolicy is created in the netobserv namespace.** The runbook covers it
   as its own step, because it is not optional: NetObserv installs a policy on its own namespace
   whose egress rules do not include Kafka, so the flow processor cannot reach any broker,
   in-cluster or external, until something allows it. This adds a second policy rather than editing
   NetObserv's — policies are additive, so nothing has to race the operator's reconcile loop, and it
   does not depend on a `spec.networkPolicy` field older FlowCollector versions lack.

5. **`replicas` on a `KafkaTopic` is clamped to the broker count** in `incluster` mode. A topic
   asking for more replicas than there are brokers is accepted by the API and then fails to
   reconcile with an unhelpful message.

## Re-running and idempotency

Safe to re-run. Specifics worth knowing:

- **Topic creation is `--if-not-exists`.** A re-run is a no-op at the broker — which also means an
  existing topic keeps its **current** partition count and config. Changing either afterwards is
  deliberate work for whoever operates the broker: `kafka-topics.sh --alter` can add partitions but
  never remove them, and re-partitioning changes which key lands on which partition.
- **The admin Jobs are deleted before being recreated.** A Job's pod template is immutable, so
  re-applying a changed one fails with `field is immutable` rather than re-running.
- **`cluster-monitoring-config` is read-modify-written**, so an existing Alertmanager or retention
  configuration survives having `enableUserWorkload` added.
- **Console plugin registration appends** to `spec.plugins` and only when `netobserv-plugin` is
  missing, so anything already registered is preserved and the console is not rolled on every run.
- **Rotating the SASL password** means re-running (which rewrites all four Secrets) and restarting
  the three producers — none of them re-read a Secret in place.
- **The `FlowCollector` is cluster-scoped and singular.** If `../../ansible` deployed one on this
  cluster, re-applying here replaces its Loki configuration. The two stacks cannot both have their
  way with that one object.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Preflight: "must be a non-empty list of host:port entries" | `kafka_bootstrap_servers` is unset. Pass `-e @kafka-credentials.yml`, or `-e kafka_mode=incluster`. |
| Preflight: "so `kafka_sasl_username` and `kafka_sasl_password` must be set" | The credentials file was not passed, or is vault-encrypted — add `--ask-vault-pass`. |
| Preflight: "the CA that signed the broker's serving certificate must be supplied" | Set `kafka_ca_cert_file`, or `-e kafka_tls_enabled=false`, or `-e kafka_tls_insecure_skip_verify=true`. |
| "Failed to import the required Python library (kubernetes)" | Not installed next to Ansible. The message names the exact interpreter used. |
| "Collection kubernetes.core does not support Ansible version 2.14.x" | You are on the system ansible-core, not the 2.17 venv. Activate it, or install `requirements-legacy.yml --force`. |
| "Failed to get client due to Invalid kube-config file" | No usable kubeconfig. Nothing has been created at that point. |
| "could not resolve its value - it is neither an inline `value` nor an annotation this can read" | The operator moved `STRIMZI_KAFKA_IMAGES` again. Read it off the Deployment yourself and pass `-e kafka_admin_image=...`. |
| "wait for the Subscription to resolve" times out | Almost always a wrong channel. `oc describe subscription <name> -n <ns>` and look for `ResolutionFailed`. |
| The topic-admin Job fails | The playbook prints the Job's own output, which is the Java client's error — `TimeoutException` (address/firewall), `SSL handshake failed` (CA), `Authentication failed` (SASL), `INVALID_REPLICATION_FACTOR` (fewer brokers than replicas). This is the first task that talks to the broker, so it is where all of those surface. |
| Collector rollout fails, `'kafkaexporter.Config' has invalid keys: encoding, topic` | Flip `-e otel_kafka_topic_style=flat` (or to `per_signal` if it named `traces, metrics`). The role prints the collector's log on failure with both settings and what each message means. |
| Collector rollout fails, `invalid keys: auth` / `invalid keys: tls, sasl` | The other axis: `-e otel_kafka_auth_style=flat` or `=nested`. |
| `encodeKafka error: dial tcp <ip>:<port>: i/o timeout` in the flow processor | NetObserv's own NetworkPolicy allows egress only to same-namespace pods, the API server, DNS and monitoring. `netobserv_kafka_egress_policy` (default true) adds the supplementary rule; if you set it false, add your own. Affects an external broker too. |
| Vector: `too old resource version ... Expired, code: 410` | Benign — a watch fell behind and the reflector re-lists. Check the `cluster-logs` offsets to see whether logs are actually flowing. |
| `federated-metrics` stays at offset 0 | A `403` on `/federate` — check the `cluster-monitoring-view` binding — or user workload monitoring never came up. |
| `otlp-traces` stays at offset 0 | Nothing is producing spans. `-e workload_enabled=true`, and check `COLLECTOR_SERVICE_ADDR` on the app Deployments. |
| ClusterLogForwarder `Valid=False` | A referenced Secret is missing or has the wrong key. Not fatal to the run by design; `oc get clusterlogforwarder instance -n openshift-logging -o yaml`. |

## Teardown

Producers and Secrets only:

```bash
ansible-playbook cleanup.yml -e cleanup_confirm=yes
```

Producers **and the topics on the broker**:

```bash
ansible-playbook cleanup.yml -e cleanup_confirm=yes -e cleanup_topics=yes -e @kafka-credentials.yml
```

`cleanup_topics` is a second, separate flag on purpose. **Deleting the topics deletes data that is
not on this cluster** — on an external broker they may be shared, may hold records nobody has
consumed yet, and are not this cluster's to remove. Producers come down first either way: deleting a
topic while Vector and the flow processor are still producing to it either has the broker recreate
it or has them retry forever.

Operators, Subscriptions and CSVs are left in place: removing them is rarely what you want
mid-iteration and they cost nothing idle.
