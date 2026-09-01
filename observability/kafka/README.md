# Streaming OpenShift Observability to Kafka

Every signal the cluster produces — traces, span metrics, metrics, logs and network flows —
written to a Kafka topic and to nothing else. No LokiStack, no TempoStack, no S3 bucket, no IAM
user: retention, indexing and query are the Kafka consumers' problem, off-cluster.

This is [`../README.md`](../README.md) with the storage layers removed and a Kafka producer put in
their place. The operators, the namespaces, the collector service accounts and most of the RBAC are
the same; what changes is where each pipeline terminates. Read that document for *why* a resource
looks the way it does — this one only covers what is different, and it is self-contained enough to
follow start to finish without it.

## Contents
- [What this deploys](#what-this-deploys)
- [What is deliberately missing](#what-is-deliberately-missing)
- [Pre-requisites](#pre-requisites)
  - [Variables](#variables)
- [Install the Streams for Apache Kafka operator](#install-the-streams-for-apache-kafka-operator)
- [Create the topics](#create-the-topics)
  - [Path A: an external Kafka cluster](#path-a-an-external-kafka-cluster)
  - [Path B: a lab broker on the cluster](#path-b-a-lab-broker-on-the-cluster)
- [Create the producer namespaces](#create-the-producer-namespaces)
- [Create the client Secrets](#create-the-client-secrets)
- [Logs](#logs)
  - [Install the Cluster Logging Operator](#install-the-cluster-logging-operator)
  - [Create the collector service account and RBAC](#create-the-collector-service-account-and-rbac)
  - [Create the ClusterLogForwarder](#create-the-clusterlogforwarder)
- [Network flows](#network-flows)
  - [Install the Network Observability Operator](#install-the-network-observability-operator)
  - [Let the flow processor out to the broker](#let-the-flow-processor-out-to-the-broker)
  - [Create the FlowCollector](#create-the-flowcollector)
- [Traces, span metrics and metrics](#traces-span-metrics-and-metrics)
  - [Install the OpenTelemetry Collector Operator](#install-the-opentelemetry-collector-operator)
  - [Create the collector service account and RBAC](#create-the-collector-service-account-and-rbac-1)
  - [Enable monitoring for user-defined projects](#enable-monitoring-for-user-defined-projects)
  - [Create the OpenTelemetryCollector](#create-the-opentelemetrycollector)
- [Test workload](#test-workload)
- [Verify](#verify)
  - [Is it still flowing?](#is-it-still-flowing)
  - [What the numbers mean](#what-the-numbers-mean)
- [Reading a record](#reading-a-record)
  - [A network flow](#a-network-flow)
  - [A trace](#a-trace)
- [What verification does and does not establish](#what-verification-does-and-does-not-establish)
- [What is on each topic](#what-is-on-each-topic)
- [Troubleshooting](#troubleshooting)
- [Clean up](#clean-up)

> **Automated version.** Everything in this document is automated in
> [`ansible/`](ansible/) — one playbook, no AWS phase, and the external/in-cluster
> broker choice as a single variable. This document remains the source of truth
> for *why* each resource looks the way it does.

## What this deploys

| Signal | Producer | Topic |
|---|---|---|
| Traces | `OpenTelemetryCollector` — OTLP receiver → `kafka` exporter | `otlp-traces` |
| Span metrics (RED) | the same collector — `spanmetrics` connector → `kafka` exporter | `otlp-spanmetrics` |
| Platform and user-workload metrics | the same collector — `prometheus` receiver scraping both `/federate` endpoints → `kafka` exporter | `federated-metrics` |
| Application, infrastructure and audit logs | Vector, via a `ClusterLogForwarder` with a `kafka` output | `cluster-logs` |
| Network flows | the eBPF agent → flow processor, via a `FlowCollector` Kafka **exporter** | `network-flows` |

One collector serves the three OpenTelemetry signals, with a pipeline and a topic each. Separate
topics rather than one, because the five signals have different volumes, different shapes and
different consumers — and because retention is then per signal rather than per cluster.

```
   instrumented apps ──OTLP:4317─┐
                                 ├─▶ OpenTelemetry Collector ──▶ otlp-traces
   platform Prometheus ──────────┤     otlp · prometheus            otlp-spanmetrics
   user-workload Prometheus ─────┘     spanmetrics · kafka          federated-metrics
        (both via /federate, pulled)

   app · infra · audit logs ────▶ Vector (ClusterLogForwarder) ──▶ cluster-logs

   pod & node traffic ──────────▶ eBPF agent → FLP ────────────▶ network-flows
```

## What is deliberately missing

Compared with [`../README.md`](../README.md), these are gone and their absence is the point:

| Not here | Why |
|---|---|
| Loki Operator, both `LokiStack`s, their S3 buckets and IAM users | Logs and flows leave as a stream. Nothing indexes them on the cluster. |
| Tempo Operator, the `TempoStack`, its S3 bucket and IAM user | Same, for traces. |
| The `logging-collector-logs-writer` ClusterRoleBinding | It grants write access to a LokiStack gateway that does not exist. |
| The `tempostack-traces-write` / `-reader` ClusterRoles | Same, for the Tempo gateway. |
| The Cluster Observability Operator and all three `UIPlugin`s | Logging and DistributedTracing plugins read from a LokiStack and a TempoStack; the Troubleshooting Panel correlates against Loki. With no store there is nothing for them to query. |
| The `prometheus` exporter on the collector and its `ServiceMonitor`s | Those scrape span metrics back *into* the cluster's Prometheus. Here they go to a topic instead. |
| Any AWS phase at all | No bucket, no IAM user, no access key, so nothing to hand over. |

**Two things do stay on the cluster, and cannot sensibly be removed:**

- **Prometheus keeps its own short local TSDB.** A `/federate` endpoint is a query against a local
  store — there is no federating a Prometheus that stores nothing. This document does not change
  platform monitoring's retention; it reads what is already there and republishes it.
- **Network Observability still publishes aggregated flow metrics to that Prometheus.** That is a
  few hundred series, not per-flow records, and it is what keeps **Observe → Network Traffic**
  drawing its Overview and Topology pages. The per-flow records — the ones that would have needed
  Loki — go only to Kafka.

## Pre-requisites

- A **connected** OpenShift cluster and `cluster-admin` on it.
- A Kafka cluster the pods can reach, or the willingness to have one deployed on the cluster for a
  lab (see [Path B](#path-b-a-lab-broker-on-the-cluster)).
- The CA that signed the broker's serving certificate, and a SASL user that may **produce to** and
  **create** the five topics.
- No default `StorageClass` is required. Nothing here asks for a PVC — except the optional lab
  broker, and only if you switch it off ephemeral storage.

### Variables

```bash
export KAFKA_BOOTSTRAP=kafka-1.example.com:9093    # host:port, the broker listener
export KAFKA_USER=observability
export KAFKA_PASSWORD='<the SASL password>'
export KAFKA_SASL_MECHANISM=SCRAM-SHA-512          # or PLAIN, SCRAM-SHA-256
export KAFKA_CA_FILE=~/kafka-ca.crt                # PEM, the broker's signing CA
```

```bash
export KAFKA_NAMESPACE=kafka
export LOGGING_NAMESPACE=openshift-logging
export NETOBSERV_NAMESPACE=netobserv
export OTEL_NAMESPACE=otel-collector
export APP_NAMESPACE=online-boutique
```

```bash
export TOPIC_TRACES=otlp-traces
export TOPIC_SPANMETRICS=otlp-spanmetrics
export TOPIC_METRICS=federated-metrics
export TOPIC_LOGS=cluster-logs
export TOPIC_FLOWS=network-flows
```

```bash
export CLUSTER_LOGGING_VERSION=6.6
```

> **Do not put the OpenTelemetry collector in an `openshift-*` namespace.** The restriction is
> inherited from [`../README.md`](../README.md) and holds for a different reason here: nothing
> scrapes this collector, but the operator's webhooks and the `k8sattributes` processor both behave
> better outside the reserved prefix, and a future `ServiceMonitor` in an `openshift-` namespace is
> silently ignored by user workload monitoring. `otel-collector` is used throughout.
>
> The namespace also differs from `../README.md`'s `tracing-system` on purpose, so **both stacks can
> exist on one cluster.** One resource is genuinely shared and cannot be: the `FlowCollector` is
> cluster-scoped, must be named `cluster`, and only one may exist. Applying the one below replaces
> whatever Loki configuration the other document left on it.

## Install the Streams for Apache Kafka operator

Red Hat Streams for Apache Kafka, previously AMQ Streams. The OLM package is still called
`amq-streams`.

It is installed in **both** paths below, and it earns its place in each differently. On Path B it
runs the broker and reconciles `KafkaTopic` resources. On Path A it manages nothing — but it puts
the Kafka CRDs on the cluster, and, more usefully, it is the authority on which Kafka container
image to run the admin CLI from, so the client version always matches the operator rather than
whatever tag you last saw in a blog post.

- Create the Subscription. `openshift-operators` already has a global OperatorGroup, so no
  namespace and no OperatorGroup are created here.

```bash
cat <<EOF > amq-streams-subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: amq-streams
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: amq-streams
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

```bash
oc apply -f amq-streams-subscription.yaml
```

- Verify the CSV is created.

```bash
oc get csv -n openshift-operators | grep amqstreams
```

- Create the namespace the broker and the admin Jobs live in.

```bash
oc create namespace $KAFKA_NAMESPACE --dry-run=client -o yaml | oc apply -f -
```

- Read the Kafka image the operator is willing to run. It carries a `<kafka version>=<image>` map in
  `STRIMZI_KAFKA_IMAGES`; the last entry is the newest.

```bash
KAFKA_IMAGE=$(oc get deploy -n openshift-operators -o json | jq -r '
  .items[] | .spec.template as $t
  | $t.spec.containers[].env[]?
  | select(.name == "STRIMZI_KAFKA_IMAGES")
  | if .value then .value
    else $t.metadata.annotations[
           (.valueFrom.fieldRef.fieldPath | sub("^[^\\[]*\\[."; "") | sub(".\\]$"; ""))] // empty
    end' | grep -v '^$' | tail -1 | cut -d= -f2-)
export KAFKA_IMAGE
echo "$KAFKA_IMAGE"
```

> **Why that is not just `.value`.** Recent builds do not put the map in the environment variable at
> all. They set it through the downward API, pointing at an annotation on the operator's own pod:
>
> ```json
> { "name": "STRIMZI_KAFKA_IMAGES",
>   "valueFrom": { "fieldRef": { "fieldPath": "metadata.annotations['kafka-images']" } } }
> ```
>
> So `.value` is `null` and the map lives in `.spec.template.metadata.annotations["kafka-images"]`
> instead. The `if .value then … else …` above reads the annotation **named by the `fieldPath`**
> rather than assuming `kafka-images`, so it keeps working on older builds that still set `.value`
> inline, and on a future build that renames the annotation.

- Check you got something. An empty result means the operator is not running yet, or it has moved
  the map somewhere new again — set `KAFKA_IMAGE` by hand from
  `oc get deploy -n openshift-operators -o yaml` and carry on.

```bash
test -n "$KAFKA_IMAGE" && echo OK || echo "KAFKA_IMAGE is empty - set it manually"
```

  The values are usually digest-pinned, which is exactly what you want in a Job. On a disconnected
  cluster substitute the reference from your mirror registry.

## Create the topics

Do this **before** deploying any producer. Auto-creation is off on most brokers, and where it is on
it gives you the broker's default partition count and retention rather than the ones you want.

### Path A: an external Kafka cluster

There is no Topic Operator watching this cluster, so `KafkaTopic` resources would sit there
unreconciled. Create the topics with the admin CLI instead — from a Job on the cluster, so it runs
from inside the network that can actually reach the broker.

- Build the client configuration.

```bash
case "${KAFKA_TLS:-true}/${KAFKA_SASL:-true}" in
  true/true)   PROTOCOL=SASL_SSL ;;
  true/false)  PROTOCOL=SSL ;;
  false/true)  PROTOCOL=SASL_PLAINTEXT ;;
  false/false) PROTOCOL=PLAINTEXT ;;
esac
export PROTOCOL; echo "$PROTOCOL"
```

```bash
case "$KAFKA_SASL_MECHANISM" in
  PLAIN) LOGIN_MODULE=org.apache.kafka.common.security.plain.PlainLoginModule ;;
  *)     LOGIN_MODULE=org.apache.kafka.common.security.scram.ScramLoginModule ;;
esac
```

```bash
cat <<EOF > client.properties
bootstrap.servers=$KAFKA_BOOTSTRAP
security.protocol=$PROTOCOL
ssl.truststore.type=PEM
ssl.truststore.location=/etc/kafka-ca/ca.crt
sasl.mechanism=$KAFKA_SASL_MECHANISM
sasl.jaas.config=$LOGIN_MODULE required username="$KAFKA_USER" password="$KAFKA_PASSWORD";
request.timeout.ms=30000
EOF
```

> **`ssl.truststore.type=PEM` is why there is no `keytool` step here.** PEM truststores landed in
> Kafka 2.7, so the CA can be mounted as the file it already is. Every version this operator ships
> supports it. Older instructions build a PKCS#12 with `keytool` and then have to keep it in sync
> with the CA; do not.

- Create the two Secrets the Job mounts.

```bash
oc create secret generic kafka-admin-config -n $KAFKA_NAMESPACE \
  --from-file=client.properties=client.properties \
  --dry-run=client -o yaml | oc apply -f -
```

```bash
oc create secret generic kafka-ca -n $KAFKA_NAMESPACE \
  --from-file=ca.crt=$KAFKA_CA_FILE \
  --dry-run=client -o yaml | oc apply -f -
```

```bash
rm -f client.properties
```

- Create the Job.

```bash
cat <<EOF > kafka-create-topics.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: kafka-create-topics
  namespace: $KAFKA_NAMESPACE
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: kafka-topics
        image: $KAFKA_IMAGE
        command:
        - /bin/bash
        - -c
        - |
          set -o pipefail
          CFG=/etc/kafka-admin/client.properties
          create() {
            echo "==> \$1"
            bin/kafka-topics.sh --bootstrap-server $KAFKA_BOOTSTRAP --command-config \$CFG \
              --create --if-not-exists --topic "\$1" --partitions "\$2" --replication-factor 3 \
              --config retention.ms=86400000 --config cleanup.policy=delete
          }
          rc=0
          create $TOPIC_TRACES      3 || rc=1
          create $TOPIC_SPANMETRICS 3 || rc=1
          create $TOPIC_METRICS     3 || rc=1
          create $TOPIC_LOGS        6 || rc=1
          create $TOPIC_FLOWS       6 || rc=1
          echo; echo "==> topics on the broker"
          bin/kafka-topics.sh --bootstrap-server $KAFKA_BOOTSTRAP --command-config \$CFG --list || rc=1
          exit \$rc
        volumeMounts:
        - name: admin-config
          mountPath: /etc/kafka-admin
          readOnly: true
        - name: kafka-ca
          mountPath: /etc/kafka-ca
          readOnly: true
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          capabilities: { drop: ["ALL"] }
          seccompProfile: { type: RuntimeDefault }
      volumes:
      - name: admin-config
        secret: { secretName: kafka-admin-config }
      - name: kafka-ca
        secret: { secretName: kafka-ca }
EOF
```

```bash
oc apply -f kafka-create-topics.yaml
```

- Watch it, and read what the broker said.

```bash
oc wait --for=condition=complete job/kafka-create-topics -n $KAFKA_NAMESPACE --timeout=300s
oc logs -n $KAFKA_NAMESPACE job/kafka-create-topics
```

  This is the first thing in the whole procedure that actually talks to the broker, so it is where a
  wrong address, a closed port, a wrong CA and wrong SASL credentials all surface — with the Java
  client's own error message, which is more specific than anything the producers will give you
  later. Get this green before going on.

  Logs and flows get twice the partitions: they are the two high-volume signals, and partition count
  is the ceiling on consumer parallelism. `--if-not-exists` makes a re-run a no-op, but it also
  means an existing topic keeps its **current** partitions and config — changing either afterwards
  is deliberate work for whoever operates the broker.

- Re-running: a Job's pod template is immutable, so delete before re-applying.

```bash
oc delete job kafka-create-topics -n $KAFKA_NAMESPACE --ignore-not-found
```

### Path B: a lab broker on the cluster

For a cluster with no Kafka to point at. This is a bus to prove the wiring with, **not** somewhere
to keep data: one plain internal listener, ephemeral storage, and no authentication. For anything
beyond a lab, use Path A and point at a broker somebody operates.

Repoint `KAFKA_BOOTSTRAP` at the Service the operator will create. Every later section reads it,
and the blocks marked **Path B** in each of them expect it to be this.

```bash
export KAFKA_BOOTSTRAP=observability-kafka-bootstrap.$KAFKA_NAMESPACE.svc:9092
```

`KAFKA_USER`, `KAFKA_PASSWORD` and `KAFKA_CA_FILE` are not used on this path — this broker has no
authentication and no TLS — so they can stay unset.

- Create the node pool. KRaft, so no ZooKeeper; one dual-role pool is the simplest shape that still
  gives a replicated cluster.

```bash
cat <<EOF > kafka-nodepool.yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: dual-role
  namespace: $KAFKA_NAMESPACE
  labels:
    strimzi.io/cluster: observability
spec:
  replicas: 3
  roles:
  - controller
  - broker
  storage:
    type: ephemeral
EOF
```

```bash
oc apply -f kafka-nodepool.yaml
```

- Create the cluster.

```bash
cat <<EOF > kafka-cluster.yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: observability
  namespace: $KAFKA_NAMESPACE
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
spec:
  kafka:
    listeners:
    - name: plain
      port: 9092
      type: internal
      tls: false
    config:
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 1
      default.replication.factor: 3
      min.insync.replicas: 1
      message.max.bytes: "10485760"
  entityOperator:
    topicOperator: {}
    userOperator: {}
EOF
```

```bash
oc apply -f kafka-cluster.yaml
```

  Both annotations are required. Without them the operator falls back to ZooKeeper mode and rejects
  the node pool. `message.max.bytes` is raised because the observability signals arrive as large
  batches of protobuf — the 1 MiB default rejects a busy OTLP batch outright and the producer then
  retries it forever.

- Wait for it.

```bash
oc wait kafka/observability -n $KAFKA_NAMESPACE --for=condition=Ready --timeout=600s
```

- Create the topics. Here they *are* custom resources, because the Topic Operator deployed above
  reconciles them.

```bash
for t in "$TOPIC_TRACES 3" "$TOPIC_SPANMETRICS 3" "$TOPIC_METRICS 3" "$TOPIC_LOGS 6" "$TOPIC_FLOWS 6"; do
  set -- $t
  cat <<EOF | oc apply -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: $1
  namespace: $KAFKA_NAMESPACE
  labels:
    strimzi.io/cluster: observability
spec:
  topicName: $1
  partitions: $2
  replicas: 3
  config:
    retention.ms: "86400000"
    cleanup.policy: delete
EOF
done
```

  The `strimzi.io/cluster` label is how the Topic Operator knows which cluster a topic belongs to.
  Without it the resource is created and then silently ignored.

```bash
oc get kafkatopic -n $KAFKA_NAMESPACE
```

- Create the admin client configuration. Nothing has needed it yet — the Topic Operator created the
  topics, not the CLI — but [Verify](#verify) does, and so does any later `kafka-topics.sh` run.
  There is no truststore and no SASL section, because the listener has neither.

```bash
cat <<EOF > client.properties
bootstrap.servers=$KAFKA_BOOTSTRAP
security.protocol=PLAINTEXT
request.timeout.ms=30000
EOF
```

```bash
oc create secret generic kafka-admin-config -n $KAFKA_NAMESPACE \
  --from-file=client.properties=client.properties \
  --dry-run=client -o yaml | oc apply -f -
```

```bash
rm -f client.properties
```

## Create the producer namespaces

**Both paths.** The three producers each run in their own namespace.

```bash
for ns in $LOGGING_NAMESPACE $NETOBSERV_NAMESPACE $OTEL_NAMESPACE; do
  oc create namespace $ns --dry-run=client -o yaml | oc apply -f -
done
```

Two of the three are created again later — [Logs](#logs) applies
`openshift-logging` with the `openshift.io/cluster-monitoring` label, and
[Network flows](#network-flows) applies `netobserv`. Both are `oc apply`, so
they add the label to the namespace that already exists rather than failing.
`$OTEL_NAMESPACE` is created **only here**, which is why this step is not part
of the Path A-only section below.

## Create the client Secrets

**Path A only.** Path B's broker has no authentication and no TLS, so there is nothing to create
here — skip to [Logs](#logs).

Three producers, three namespaces, and a Secret is namespaced — so the same credentials are created
three times. Only the `FlowCollector` API can name a namespace on a secret reference; the
`ClusterLogForwarder` and the collector each read from their own.

```bash
for ns in $LOGGING_NAMESPACE $NETOBSERV_NAMESPACE $OTEL_NAMESPACE; do
  oc create secret generic kafka-ca -n $ns \
    --from-file=ca.crt=$KAFKA_CA_FILE --dry-run=client -o yaml | oc apply -f -
  oc create secret generic kafka-sasl -n $ns \
    --from-literal=username=$KAFKA_USER \
    --from-literal=password="$KAFKA_PASSWORD" --dry-run=client -o yaml | oc apply -f -
done
```

Rotating the SASL password means re-running this and restarting the three producers.

## Logs

Vector is the same collector it is in [`../README.md`](../README.md). Only the output type changes:
`kafka` instead of `lokiStack`.

### Install the Cluster Logging Operator

- Create the Namespace.

```bash
cat <<EOF > openshift-logging-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: $LOGGING_NAMESPACE
  labels:
    openshift.io/cluster-monitoring: "true"
EOF
```

```bash
oc apply -f openshift-logging-namespace.yaml
```

- Create the Operator Group.

```bash
cat <<EOF > openshift-logging-operator-group.yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-logging
  namespace: $LOGGING_NAMESPACE
spec:
  upgradeStrategy: Default
EOF
```

```bash
oc apply -f openshift-logging-operator-group.yaml
```

- Create the Subscription.

```bash
cat <<EOF > openshift-logging-subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: $LOGGING_NAMESPACE
spec:
  channel: stable-$CLUSTER_LOGGING_VERSION
  installPlanApproval: Automatic
  name: cluster-logging
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

```bash
oc apply -f openshift-logging-subscription.yaml
```

- Verify the CSV is created.

```bash
oc get csv -n $LOGGING_NAMESPACE
```

### Create the collector service account and RBAC

```bash
cat <<EOF > logging-collector-rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: logging-collector
  namespace: $LOGGING_NAMESPACE
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: logging-collector:collect-application
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: collect-application-logs
subjects:
- kind: ServiceAccount
  name: logging-collector
  namespace: $LOGGING_NAMESPACE
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: logging-collector:collect-infrastructure
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: collect-infrastructure-logs
subjects:
- kind: ServiceAccount
  name: logging-collector
  namespace: $LOGGING_NAMESPACE
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: logging-collector:collect-audit
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: collect-audit-logs
subjects:
- kind: ServiceAccount
  name: logging-collector
  namespace: $LOGGING_NAMESPACE
EOF
```

```bash
oc apply -f logging-collector-rbac.yaml
```

> **`logging-collector-logs-writer` is not in that list.** It grants write access to a LokiStack
> gateway, and there is no LokiStack. Binding it would leave a ClusterRoleBinding pointing at an API
> that is not installed.
>
> **`collect-audit-logs` is,** which [`../README.md`](../README.md) does not bind. Audit is the
> input most people want off the cluster in the first place. It roughly doubles the log volume on a
> busy API server — drop that last binding and the `audit` line from the pipeline below if that is
> not the trade you want.

### Create the ClusterLogForwarder

Take the block that matches the path you followed.

- **Path A** — an authenticated broker.

```bash
cat <<EOF > clusterlogforwarder.yaml
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: instance
  namespace: $LOGGING_NAMESPACE
spec:
  serviceAccount:
    name: logging-collector
  outputs:
  - name: kafka-out
    type: kafka
    kafka:
      url: tls://$KAFKA_BOOTSTRAP/$TOPIC_LOGS
      topic: $TOPIC_LOGS
      authentication:
        sasl:
          mechanism: $KAFKA_SASL_MECHANISM
          username:
            secretName: kafka-sasl
            key: username
          password:
            secretName: kafka-sasl
            key: password
      tls:
        ca:
          secretName: kafka-ca
          key: ca.crt
  filters:
  - name: multiline-exceptions
    type: detectMultilineException
  pipelines:
  - name: all-logs-to-kafka
    inputRefs:
    - application
    - infrastructure
    - audit
    outputRefs:
    - kafka-out
    filters:
    - multiline-exceptions
EOF
```

- **Path B** — the plaintext lab broker. Same resource with no `authentication` and no `tls`, and
  `tcp://` in place of `tls://`.

```bash
cat <<EOF > clusterlogforwarder.yaml
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: instance
  namespace: $LOGGING_NAMESPACE
spec:
  serviceAccount:
    name: logging-collector
  outputs:
  - name: kafka-out
    type: kafka
    kafka:
      url: tcp://$KAFKA_BOOTSTRAP/$TOPIC_LOGS
      topic: $TOPIC_LOGS
  filters:
  - name: multiline-exceptions
    type: detectMultilineException
  pipelines:
  - name: all-logs-to-kafka
    inputRefs:
    - application
    - infrastructure
    - audit
    outputRefs:
    - kafka-out
    filters:
    - multiline-exceptions
EOF
```

- Apply whichever you wrote.

```bash
oc apply -f clusterlogforwarder.yaml
```

- The URL scheme is what carries the transport: `tls://` for an encrypted listener, `tcp://` for a
  plaintext one. That is the only difference between the two blocks beyond the two credential
  sections, and getting it wrong is a connection that hangs rather than a clear error.

- For more than one broker, add a `brokers` list alongside `url`:

```yaml
      brokers:
      - tls://kafka-1.example.com:9093
      - tls://kafka-2.example.com:9093
```

- The exact field names under `kafka` have moved between logging releases. Check yours before
  debugging anything else:

```bash
oc explain clusterlogforwarder.spec.outputs.kafka --recursive
```

- `detectMultilineException` rejoins stack traces. The container runtime delivers them one line per
  record; left alone they arrive on the topic as a dozen unrelated messages.

- Verify. `Valid=True` means the resource was accepted **and** the referenced Secrets resolve; it
  does not yet mean the broker is reachable.

```bash
oc get clusterlogforwarder instance -n $LOGGING_NAMESPACE \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
```

```bash
oc get pods -n $LOGGING_NAMESPACE -l app.kubernetes.io/component=collector
```

```bash
oc logs -n $LOGGING_NAMESPACE -l app.kubernetes.io/component=collector --tail=20
```

  Broker connection failures show up in those collector logs, not on the resource.

## Network flows

**Two entirely different things in this operator are called "Kafka", and picking the wrong one is
the usual mistake:**

| | What it is |
|---|---|
| `spec.deploymentModel: Kafka` | Kafka as **internal transport** between the eBPF agents and the flow processor. The processor still has to write somewhere afterwards. |
| `spec.exporters[].type: Kafka` | The **enriched flows leaving the cluster** — after pod, namespace, owner and zone identity have been attached. |

The second is the one that matches this document. So: `deploymentModel: Direct`, Loki disabled, one
Kafka exporter.

### Install the Network Observability Operator

- Create the Namespace.

```bash
cat <<EOF > netobserv-operator-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-netobserv-operator
  labels:
    openshift.io/cluster-monitoring: "true"
EOF
```

```bash
oc apply -f netobserv-operator-namespace.yaml
```

- Create the Operator Group.

```bash
cat <<EOF > netobserv-operator-group.yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: netobserv-operator
  namespace: openshift-netobserv-operator
spec:
  upgradeStrategy: Default
EOF
```

```bash
oc apply -f netobserv-operator-group.yaml
```

- Create the Subscription.

```bash
cat <<EOF > netobserv-subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: netobserv-operator
  namespace: openshift-netobserv-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: netobserv-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

```bash
oc apply -f netobserv-subscription.yaml
```

```bash
oc get csv -n openshift-netobserv-operator
```

```bash
oc create namespace $NETOBSERV_NAMESPACE --dry-run=client -o yaml | oc apply -f -
```

### Let the flow processor out to the broker

**Do this before creating the FlowCollector.** Recent NetObserv releases install a NetworkPolicy on
their own namespace with `policyTypes: [Ingress, Egress]`, and its egress rules allow only four
things: pods in the same namespace, the API server, `openshift-dns` and `openshift-monitoring`.

Kafka is in none of them. So the flow processor's connection is dropped, and the only symptom is
this, on repeat, in a component that otherwise looks healthy:

```
level=error msg=encodeKafka error: dial tcp 172.30.197.88:9092: i/o timeout
```

**This applies to an external broker exactly as much as to the in-cluster one** — there is no egress
rule for the outside world either. It is a timeout rather than a connection refused because the
packets are dropped, not rejected.

Network policies are **additive**: traffic allowed by any policy selecting the pod is allowed. So
this does not modify, replace or race the policy NetObserv manages — it only allows the one thing
that policy omits.

```bash
cat <<EOF > netobserv-egress-kafka.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: netobserv-egress-kafka
  namespace: $NETOBSERV_NAMESPACE
spec:
  podSelector:
    matchLabels:
      part-of: netobserv-operator
  policyTypes:
  - Egress
  egress:
  - ports:
    - port: ${KAFKA_BOOTSTRAP##*:}
      protocol: TCP
EOF
```

```bash
oc apply -f netobserv-egress-kafka.yaml
```

The pod selector matches NetObserv's own, so it covers the flow processor wherever the operator puts
it — a DaemonSet in `Direct` mode, a Deployment behind Kafka transport.

That rule is scoped to the broker **port** but not to a destination, because resolving your broker's
hostname to a CIDR is not something a runbook can do for you. Narrow it when you know the addresses:

```yaml
  egress:
  - ports:
    - port: 9093
      protocol: TCP
    to:
    - ipBlock:
        cidr: 10.0.5.0/24
```

On Path B the destination is a namespace, which is exact and worth using:

```yaml
    to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kafka
```

If your NetObserv is old enough not to install that policy, or the cluster has no policy
enforcement, this is harmless — an allow rule for traffic nothing was blocking.

### Create the FlowCollector

The `FlowCollector` is cluster-scoped and must be named `cluster`. Only one can exist per cluster.

Take the block that matches the path you followed.

- **Path A** — an authenticated broker.

```bash
cat <<EOF > flowcollector.yaml
apiVersion: flows.netobserv.io/v1beta2
kind: FlowCollector
metadata:
  name: cluster
spec:
  namespace: $NETOBSERV_NAMESPACE
  deploymentModel: Direct
  agent:
    type: eBPF
    ebpf:
      sampling: 50
      logLevel: info
      privileged: false
      resources:
        requests:
          cpu: 100m
          memory: 50Mi
        limits:
          memory: 800Mi
  processor:
    logTypes: Flows
    logLevel: info
    resources:
      requests:
        cpu: 100m
        memory: 100Mi
      limits:
        memory: 800Mi
  loki:
    enable: false
  prometheus:
    querier:
      enable: true
      mode: Auto
  exporters:
  - type: Kafka
    kafka:
      address: $KAFKA_BOOTSTRAP
      topic: $TOPIC_FLOWS
      tls:
        enable: true
        caCert:
          type: secret
          name: kafka-ca
          certFile: ca.crt
          namespace: $NETOBSERV_NAMESPACE
      sasl:
        type: ScramSHA512
        clientIDReference:
          type: secret
          name: kafka-sasl
          file: username
          namespace: $NETOBSERV_NAMESPACE
        clientSecretReference:
          type: secret
          name: kafka-sasl
          file: password
          namespace: $NETOBSERV_NAMESPACE
EOF
```

- **Path B** — the plaintext lab broker. Identical except that the exporter carries neither `tls`
  nor `sasl`.

```bash
cat <<EOF > flowcollector.yaml
apiVersion: flows.netobserv.io/v1beta2
kind: FlowCollector
metadata:
  name: cluster
spec:
  namespace: $NETOBSERV_NAMESPACE
  deploymentModel: Direct
  agent:
    type: eBPF
    ebpf:
      sampling: 50
      logLevel: info
      privileged: false
      resources:
        requests:
          cpu: 100m
          memory: 50Mi
        limits:
          memory: 800Mi
  processor:
    logTypes: Flows
    logLevel: info
    resources:
      requests:
        cpu: 100m
        memory: 100Mi
      limits:
        memory: 800Mi
  loki:
    enable: false
  prometheus:
    querier:
      enable: true
      mode: Auto
  exporters:
  - type: Kafka
    kafka:
      address: $KAFKA_BOOTSTRAP
      topic: $TOPIC_FLOWS
EOF
```

- Apply whichever you wrote.

```bash
oc apply -f flowcollector.yaml
```

> **This API spells the SASL mechanism differently from every other producer here** — `Plain` and
> `ScramSHA512`, not `PLAIN` and `SCRAM-SHA-512`. And it offers only those two: a broker that
> accepts only SCRAM-SHA-256 needs a second SASL user for the flow exporter. Confirm with
> `oc explain flowcollector.spec.exporters.kafka.sasl`.

- `sampling: 50` means one flow in fifty. Set it to `1` to export every flow, and size the topic for
  it — this is the highest-volume signal on the list by a wide margin.

- Verify.

```bash
oc wait flowcollector/cluster --for=condition=Ready --timeout=600s
```

```bash
oc get pods -n $NETOBSERV_NAMESPACE
oc get daemonset netobserv-ebpf-agent -n $NETOBSERV_NAMESPACE-privileged
```

```bash
oc logs -n $NETOBSERV_NAMESPACE -l app=flowlogs-pipeline --tail=20
```

  With Loki disabled, **Observe → Network Traffic** still draws its Overview dashboards and Topology
  from the aggregated metrics the processor publishes to the platform Prometheus. Only the raw
  "Traffic flows" table is gone — those records are on the topic instead.

## Traces, span metrics and metrics

One collector, three pipelines, three topics.

### Install the OpenTelemetry Collector Operator

- Create the Namespace.

```bash
cat <<EOF > opentelemetry-operator-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-opentelemetry-operator
  labels:
    openshift.io/cluster-monitoring: "true"
EOF
```

```bash
oc apply -f opentelemetry-operator-namespace.yaml
```

- Create the Operator Group.

```bash
cat <<EOF > opentelemetry-operator-group.yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-opentelemetry-operator
  namespace: openshift-opentelemetry-operator
spec:
  upgradeStrategy: Default
EOF
```

```bash
oc apply -f opentelemetry-operator-group.yaml
```

- Create the Subscription.

```bash
cat <<EOF > opentelemetry-subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: opentelemetry-product
  namespace: openshift-opentelemetry-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: opentelemetry-product
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

```bash
oc apply -f opentelemetry-subscription.yaml
```

```bash
oc get csv -n openshift-opentelemetry-operator
```

### Create the collector service account and RBAC

The collector needs two things, and neither is the Tempo tenant write role from
[`../README.md`](../README.md) — there is no gateway to authenticate to.

```bash
cat <<EOF > otel-collector-rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-collector
  namespace: $OTEL_NAMESPACE
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-collector-k8sattributes
rules:
- apiGroups: [""]
  resources: ["pods", "namespaces", "nodes"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["replicasets"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["extensions"]
  resources: ["replicasets"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-collector-k8sattributes
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: otel-collector-k8sattributes
subjects:
- kind: ServiceAccount
  name: otel-collector
  namespace: $OTEL_NAMESPACE
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-collector-cluster-monitoring-view
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-monitoring-view
subjects:
- kind: ServiceAccount
  name: otel-collector
  namespace: $OTEL_NAMESPACE
EOF
```

```bash
oc apply -f otel-collector-rbac.yaml
```

- **`otel-collector-k8sattributes`** is what the `k8sattributes` processor needs. It watches pods so
  it can turn the source IP of an incoming OTLP connection into `k8s.pod.name`,
  `k8s.namespace.name` and `k8s.deployment.name` resource attributes — which is what makes a span on
  the topic attributable to a workload without the application having been told its own identity.
  `replicasets` is in the list because that is how a pod is walked up to its Deployment.

- **`cluster-monitoring-view`** is what the `/federate` scrapes need. Both Prometheus instances sit
  behind a `kube-rbac-proxy` that authorises the bearer token by asking whether it may `get`
  namespaces, which is exactly what this role grants. A `403` from `/federate` means this binding is
  missing.

### Enable monitoring for user-defined projects

The user workload Prometheus is the second `/federate` endpoint. It does not exist until this is
switched on, and a scrape against a Service with no endpoints is a connection refused every interval
rather than a clear error.

```bash
oc -n openshift-monitoring get configmap cluster-monitoring-config \
  -o jsonpath='{.data.config\.yaml}' 2>/dev/null
```

Read what is there first and add to it — this ConfigMap frequently carries Alertmanager, retention
or node placement settings that must survive.

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
```

```bash
oc -n openshift-user-workload-monitoring rollout status statefulset/prometheus-user-workload --timeout=300s
```

Note what this is *not* for. [`../README.md`](../README.md) enables user workload monitoring so a
`ServiceMonitor` can scrape the collector into the cluster's own Prometheus. Here nothing is scraped
*into* the cluster; this exists only so there is a user-workload `/federate` endpoint to pull
**from**.

### Create the OpenTelemetryCollector

Take the block that matches the path you followed.

- **Path A** — an authenticated broker.

```bash
cat <<EOF > otel-collector.yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel
  namespace: $OTEL_NAMESPACE
spec:
  mode: deployment
  replicas: 2
  serviceAccount: otel-collector
  env:
  - name: KAFKA_USERNAME
    valueFrom:
      secretKeyRef: { name: kafka-sasl, key: username }
  - name: KAFKA_PASSWORD
    valueFrom:
      secretKeyRef: { name: kafka-sasl, key: password }
  volumes:
  - name: kafka-ca
    secret:
      secretName: kafka-ca
  volumeMounts:
  - name: kafka-ca
    mountPath: /etc/kafka-ca
    readOnly: true
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
      prometheus/federate:
        config:
          scrape_configs:
          - job_name: openshift-platform
            scrape_interval: 30s
            metrics_path: /federate
            honor_labels: true
            scheme: https
            tls_config:
              ca_file: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
              server_name: prometheus-k8s.openshift-monitoring.svc
            authorization:
              type: Bearer
              credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
            params:
              'match[]':
              - '{__name__=~"cluster:.+"}'
              - '{job="node-exporter",__name__=~"node_(cpu|memory|filesystem|network)_.+"}'
              - '{job="kube-state-metrics",__name__=~"kube_(pod|deployment|node|namespace)_.+"}'
              - '{job="etcd"}'
              - '{__name__=~"apiserver_request_(total|duration_seconds_bucket)"}'
            static_configs:
            - targets: ['prometheus-k8s.openshift-monitoring.svc:9091']
          - job_name: openshift-user-workload
            scrape_interval: 30s
            metrics_path: /federate
            honor_labels: true
            scheme: https
            tls_config:
              ca_file: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
              server_name: prometheus-user-workload.openshift-user-workload-monitoring.svc
            authorization:
              type: Bearer
              credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
            params:
              'match[]':
              - '{namespace="$APP_NAMESPACE"}'
            static_configs:
            - targets: ['prometheus-user-workload.openshift-user-workload-monitoring.svc:9091']
    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 50
        spike_limit_percentage: 30
      k8sattributes:
        auth_type: serviceAccount
        passthrough: false
        extract:
          metadata:
          - k8s.namespace.name
          - k8s.pod.name
          - k8s.pod.uid
          - k8s.node.name
          - k8s.deployment.name
      batch:
        send_batch_size: 8192
        send_batch_max_size: 16384
        timeout: 5s
    connectors:
      spanmetrics:
        metrics_flush_interval: 15s
        histogram:
          explicit:
            buckets: [10ms, 50ms, 100ms, 250ms, 500ms, 1s, 5s]
        dimensions:
        - name: http.method
        - name: http.status_code
    exporters:
      kafka/traces:
        brokers: ["$KAFKA_BOOTSTRAP"]
        traces:
          topic: $TOPIC_TRACES
          encoding: otlp_proto
        protocol_version: "3.5.0"
        sending_queue: { enabled: true, num_consumers: 4, queue_size: 1000 }
        retry_on_failure: { enabled: true, initial_interval: 5s, max_interval: 30s, max_elapsed_time: 300s }
        auth:
          tls:
            ca_file: /etc/kafka-ca/ca.crt
          sasl:
            mechanism: $KAFKA_SASL_MECHANISM
            username: \${env:KAFKA_USERNAME}
            password: \${env:KAFKA_PASSWORD}
      kafka/spanmetrics:
        brokers: ["$KAFKA_BOOTSTRAP"]
        metrics:
          topic: $TOPIC_SPANMETRICS
          encoding: otlp_proto
        protocol_version: "3.5.0"
        sending_queue: { enabled: true, num_consumers: 4, queue_size: 1000 }
        retry_on_failure: { enabled: true, initial_interval: 5s, max_interval: 30s, max_elapsed_time: 300s }
        auth:
          tls:
            ca_file: /etc/kafka-ca/ca.crt
          sasl:
            mechanism: $KAFKA_SASL_MECHANISM
            username: \${env:KAFKA_USERNAME}
            password: \${env:KAFKA_PASSWORD}
      kafka/metrics:
        brokers: ["$KAFKA_BOOTSTRAP"]
        metrics:
          topic: $TOPIC_METRICS
          encoding: otlp_proto
        protocol_version: "3.5.0"
        sending_queue: { enabled: true, num_consumers: 4, queue_size: 1000 }
        retry_on_failure: { enabled: true, initial_interval: 5s, max_interval: 30s, max_elapsed_time: 300s }
        auth:
          tls:
            ca_file: /etc/kafka-ca/ca.crt
          sasl:
            mechanism: $KAFKA_SASL_MECHANISM
            username: \${env:KAFKA_USERNAME}
            password: \${env:KAFKA_PASSWORD}
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [kafka/traces, spanmetrics]
        metrics/spanmetrics:
          receivers: [spanmetrics]
          processors: [memory_limiter, batch]
          exporters: [kafka/spanmetrics]
        metrics/federated:
          receivers: [prometheus/federate]
          processors: [memory_limiter, batch]
          exporters: [kafka/metrics]
EOF
```

- **Path B** — the plaintext lab broker. There are no credentials to hand the collector, so the
  `env`, `volumes` and `volumeMounts` blocks go with the `auth` block on each of the three
  exporters. Everything else — the receivers, the processors, the connector and all three
  pipelines — is unchanged.

```bash
cat <<EOF > otel-collector.yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel
  namespace: $OTEL_NAMESPACE
spec:
  mode: deployment
  replicas: 2
  serviceAccount: otel-collector
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
      prometheus/federate:
        config:
          scrape_configs:
          - job_name: openshift-platform
            scrape_interval: 30s
            metrics_path: /federate
            honor_labels: true
            scheme: https
            tls_config:
              ca_file: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
              server_name: prometheus-k8s.openshift-monitoring.svc
            authorization:
              type: Bearer
              credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
            params:
              'match[]':
              - '{__name__=~"cluster:.+"}'
              - '{job="node-exporter",__name__=~"node_(cpu|memory|filesystem|network)_.+"}'
              - '{job="kube-state-metrics",__name__=~"kube_(pod|deployment|node|namespace)_.+"}'
              - '{job="etcd"}'
              - '{__name__=~"apiserver_request_(total|duration_seconds_bucket)"}'
            static_configs:
            - targets: ['prometheus-k8s.openshift-monitoring.svc:9091']
          - job_name: openshift-user-workload
            scrape_interval: 30s
            metrics_path: /federate
            honor_labels: true
            scheme: https
            tls_config:
              ca_file: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
              server_name: prometheus-user-workload.openshift-user-workload-monitoring.svc
            authorization:
              type: Bearer
              credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
            params:
              'match[]':
              - '{namespace="$APP_NAMESPACE"}'
            static_configs:
            - targets: ['prometheus-user-workload.openshift-user-workload-monitoring.svc:9091']
    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 50
        spike_limit_percentage: 30
      k8sattributes:
        auth_type: serviceAccount
        passthrough: false
        extract:
          metadata:
          - k8s.namespace.name
          - k8s.pod.name
          - k8s.pod.uid
          - k8s.node.name
          - k8s.deployment.name
      batch:
        send_batch_size: 8192
        send_batch_max_size: 16384
        timeout: 5s
    connectors:
      spanmetrics:
        metrics_flush_interval: 15s
        histogram:
          explicit:
            buckets: [10ms, 50ms, 100ms, 250ms, 500ms, 1s, 5s]
        dimensions:
        - name: http.method
        - name: http.status_code
    exporters:
      kafka/traces:
        brokers: ["$KAFKA_BOOTSTRAP"]
        traces:
          topic: $TOPIC_TRACES
          encoding: otlp_proto
        protocol_version: "3.5.0"
        sending_queue: { enabled: true, num_consumers: 4, queue_size: 1000 }
        retry_on_failure: { enabled: true, initial_interval: 5s, max_interval: 30s, max_elapsed_time: 300s }
      kafka/spanmetrics:
        brokers: ["$KAFKA_BOOTSTRAP"]
        metrics:
          topic: $TOPIC_SPANMETRICS
          encoding: otlp_proto
        protocol_version: "3.5.0"
        sending_queue: { enabled: true, num_consumers: 4, queue_size: 1000 }
        retry_on_failure: { enabled: true, initial_interval: 5s, max_interval: 30s, max_elapsed_time: 300s }
      kafka/metrics:
        brokers: ["$KAFKA_BOOTSTRAP"]
        metrics:
          topic: $TOPIC_METRICS
          encoding: otlp_proto
        protocol_version: "3.5.0"
        sending_queue: { enabled: true, num_consumers: 4, queue_size: 1000 }
        retry_on_failure: { enabled: true, initial_interval: 5s, max_interval: 30s, max_elapsed_time: 300s }
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [kafka/traces, spanmetrics]
        metrics/spanmetrics:
          receivers: [spanmetrics]
          processors: [memory_limiter, batch]
          exporters: [kafka/spanmetrics]
        metrics/federated:
          receivers: [prometheus/federate]
          processors: [memory_limiter, batch]
          exporters: [kafka/metrics]
EOF
```

- Apply whichever you wrote.

```bash
oc apply -f otel-collector.yaml
```

Several things in there are worth knowing before you have to debug them:

- **`topic` and `encoding` are nested under the signal, not top-level.** The Kafka exporter moved
  them into per-signal sections — `traces:`, `metrics:`, `logs:` — so one exporter instance can
  serve several signals with a topic each. Each instance here still carries one signal, which is why
  `kafka/spanmetrics` and `kafka/metrics` both use `metrics:` and differ only by topic. A build that
  has not moved them yet rejects the nested form; put both keys back at the top level, alongside
  `brokers`, if you see `has invalid keys: traces, metrics`.

- **Where the TLS and SASL settings go has moved too, on a separate schedule.** The
  `auth: {tls:, sasl:}` layout above is what the Red Hat build currently ships. Upstream moved to
  top-level `tls:` and `sasl:` keys on the exporter, and newer builds will eventually require that
  instead. `brokers`, `protocol_version`, `sending_queue` and `retry_on_failure` stayed top-level
  through both changes.

> **Both are startup failures, and the message names the keys.** A config error is fatal rather than
> silent, and the collector says exactly what it rejected:
>
> ```
> 'kafkaexporter.Config' has invalid keys: encoding, topic
> ```
>
> means the build wants the **nested** form shown above. `invalid keys: traces, metrics` means it
> wants the flat one. `invalid keys: auth` means the TLS and SASL blocks belong at the top level;
> `invalid keys: tls, sasl` means they belong under `auth`. Read it with
> `oc logs -n $OTEL_NAMESPACE deploy/otel-collector` and change only what it named.

- **The traces pipeline forks.** The same spans go to `kafka/traces` for storage *and* into the
  `spanmetrics` connector, which is an exporter on one pipeline and a receiver on the next. That is
  what manufactures RED metrics for an application exposing no `/metrics` endpoint of its own — and
  here they go to their own topic rather than to a Prometheus.

- **Federation returns every series matching `match[]`, on every scrape.** The selectors above are
  deliberately curated. Widen them one at a time and watch the collector's memory; `{__name__=~".+"}`
  will melt both ends.

- **`honor_labels: true` is not optional.** Federated samples arrive already carrying `job` and
  `instance`. Without it, Prometheus scrape semantics overwrite them and every series claims to have
  come from `job="openshift-platform"`.

- **The credentials are read from the environment, not written into the config.** An
  `OpenTelemetryCollector` resource is readable by anyone with `get` on the namespace.

- **`sending_queue` is what stops a slow broker becoming backpressure** all the way to the
  application. Past the queue, records are dropped and counted rather than blocking the receiver.

- Verify.

```bash
oc rollout status deploy/otel-collector -n $OTEL_NAMESPACE --timeout=300s
```

```bash
oc logs -n $OTEL_NAMESPACE deploy/otel-collector --tail=40
```

Instrumented workloads should send OTLP to:

- gRPC: `otel-collector.$OTEL_NAMESPACE.svc.cluster.local:4317`
- HTTP: `otel-collector.$OTEL_NAMESPACE.svc.cluster.local:4318`

## Test workload

Without traffic every topic stays empty and there is nothing to verify. Online Boutique — 11
stateless microservices and a load generator that drives itself — is vendored at
[`../../test-workloads/online-boutique`](../../test-workloads/online-boutique).

```bash
oc apply -k ../../test-workloads/online-boutique/overlays/tracing
```

The `tracing` overlay points at the collector deployed by [`../README.md`](../README.md)
(`otel-collector.tracing-system`). Repoint the seven traced services at this one:

```bash
for d in frontend checkoutservice currencyservice emailservice paymentservice \
         productcatalogservice recommendationservice; do
  oc set env deploy/$d -n $APP_NAMESPACE \
    COLLECTOR_SERVICE_ADDR=otel-collector.$OTEL_NAMESPACE.svc.cluster.local:4317
done
```

```bash
oc get pods -n $APP_NAMESPACE
oc get route frontend -n $APP_NAMESPACE -o jsonpath='{.spec.host}{"\n"}'
```

## Verify

The shortest proof that data is arriving is the end offset on each topic — the offset that will be
written next. Non-zero means records have landed.

Take the block that matches the path you followed.

- **Path A** — an authenticated broker.

```bash
cat <<EOF | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kafka-verify-topics
  namespace: $KAFKA_NAMESPACE
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: kafka-offsets
        image: $KAFKA_IMAGE
        command:
        - /bin/bash
        - -c
        - |
          for t in $TOPIC_TRACES $TOPIC_SPANMETRICS $TOPIC_METRICS $TOPIC_LOGS $TOPIC_FLOWS; do
            echo "==> \$t"
            bin/kafka-get-offsets.sh --bootstrap-server $KAFKA_BOOTSTRAP \
              --command-config /etc/kafka-admin/client.properties --topic "\$t" | sed 's/^/    /'
          done
        volumeMounts:
        - { name: admin-config, mountPath: /etc/kafka-admin, readOnly: true }
        - { name: kafka-ca, mountPath: /etc/kafka-ca, readOnly: true }
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          capabilities: { drop: ["ALL"] }
          seccompProfile: { type: RuntimeDefault }
      volumes:
      - { name: admin-config, secret: { secretName: kafka-admin-config } }
      - { name: kafka-ca, secret: { secretName: kafka-ca } }
EOF
```

- **Path B** — the plaintext lab broker. There is no `kafka-ca` Secret to mount, so the volume and
  its mount go; `client.properties` is the one written at the end of
  [Path B](#path-b-a-lab-broker-on-the-cluster).

```bash
cat <<EOF | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kafka-verify-topics
  namespace: $KAFKA_NAMESPACE
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: kafka-offsets
        image: $KAFKA_IMAGE
        command:
        - /bin/bash
        - -c
        - |
          for t in $TOPIC_TRACES $TOPIC_SPANMETRICS $TOPIC_METRICS $TOPIC_LOGS $TOPIC_FLOWS; do
            echo "==> \$t"
            bin/kafka-get-offsets.sh --bootstrap-server $KAFKA_BOOTSTRAP \
              --command-config /etc/kafka-admin/client.properties --topic "\$t" | sed 's/^/    /'
          done
        volumeMounts:
        - { name: admin-config, mountPath: /etc/kafka-admin, readOnly: true }
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          capabilities: { drop: ["ALL"] }
          seccompProfile: { type: RuntimeDefault }
      volumes:
      - { name: admin-config, secret: { secretName: kafka-admin-config } }
EOF
```

- Read the offsets.

```bash
oc wait --for=condition=complete job/kafka-verify-topics -n $KAFKA_NAMESPACE --timeout=180s
oc logs -n $KAFKA_NAMESPACE job/kafka-verify-topics
```

Output is `<topic>:<partition>:<end offset>` — the offset the *next* record will get. Expect:

| Topic | First records after |
|---|---|
| `federated-metrics` | one scrape interval — 30s |
| `cluster-logs` | as soon as the collector DaemonSet is running |
| `network-flows` | as soon as the eBPF agents are running and there is traffic |
| `otlp-traces`, `otlp-spanmetrics` | traffic through an instrumented workload — a few minutes after the load generator starts |

A healthy first run looks like this. The counts are wildly different and that is expected — see
[what the numbers mean](#what-the-numbers-mean) below:

```
==> otlp-traces
    otlp-traces:0:47
    otlp-traces:1:46
    otlp-traces:2:48
==> otlp-spanmetrics
    otlp-spanmetrics:0:21
    otlp-spanmetrics:1:20
    otlp-spanmetrics:2:20
==> federated-metrics
    federated-metrics:0:13
    federated-metrics:1:19
    federated-metrics:2:18
==> cluster-logs
    cluster-logs:0:333721
    cluster-logs:1:338239
    cluster-logs:2:346566
    cluster-logs:3:348731
    cluster-logs:4:323250
    cluster-logs:5:313230
==> network-flows
    network-flows:0:22300
    network-flows:1:22298
    network-flows:2:22297
    network-flows:3:22293
    network-flows:4:22291
    network-flows:5:22289
```

### Is it still flowing?

An end offset is a **cumulative counter, not a rate**. A single snapshot cannot tell "producing
steadily" apart from "wrote 141 records and died an hour ago". Sample twice and subtract:

```bash
for i in 1 2; do
  oc delete job kafka-verify-topics -n $KAFKA_NAMESPACE --ignore-not-found --wait=true
  oc apply -f kafka-verify-topics.yaml
  oc wait --for=condition=complete job/kafka-verify-topics -n $KAFKA_NAMESPACE --timeout=180s
  oc logs -n $KAFKA_NAMESPACE job/kafka-verify-topics | grep -oE '\S+:[0-9]+:[0-9]+' > /tmp/off-$i
  [ $i = 1 ] && sleep 60
done
paste /tmp/off-1 /tmp/off-2 | awk -F'[:\t]' '{printf "%-20s p%s  +%d/min\n",$1,$2,$6-$3}'
```

```
otlp-traces          p0  +8/min          cluster-logs         p0  +2609/min
otlp-traces          p1  +9/min          cluster-logs         p1  +1992/min
otlp-traces          p2  +6/min          cluster-logs         p2  +2336/min
otlp-spanmetrics     p0  +3/min          cluster-logs         p3  +2416/min
otlp-spanmetrics     p1  +4/min          cluster-logs         p4  +1991/min
otlp-spanmetrics     p2  +3/min          cluster-logs         p5  +1640/min
federated-metrics    p0  +1/min          network-flows        p0  +2047/min
federated-metrics    p1  +2/min          network-flows        p1  +2047/min
federated-metrics    p2  +1/min          network-flows        p2  +2048/min
                                         network-flows        p3  +2048/min
                                         network-flows        p4  +2049/min
                                         network-flows        p5  +2046/min
```

Every partition advancing is the real pass condition. Two things in that output are worth reading:

- **`federated-metrics` at 4/min total** matches two scrape jobs at a 30s interval exactly. When a
  number can be predicted from configuration and then matches, it is a much stronger signal than a
  number that is merely non-zero.
- **`network-flows` is flat to within 3 across six partitions.** That is round-robin partitioning
  with no message key — every partition is live and no broker is being favoured. `cluster-logs`
  varies more (1640–2609) because Vector's batching lands unevenly, which is normal.

### What the numbers mean

**The five topics do not count the same thing**, so comparing 141 traces to two million logs is
meaningless:

| Topic | One Kafka record is | So the offset counts |
|---|---|---|
| `otlp-traces`, `otlp-spanmetrics`, `federated-metrics` | one OTLP **export batch** | batches, each holding many spans or data points |
| `cluster-logs` | one log **event** | log lines |
| `network-flows` | one **flow** record | flows, already sampled |

141 records on `otlp-traces` is thousands of spans. And every flow record carries
`"Sampling": 50`, so the traffic it represents is roughly fifty times what the record itself says.

## Reading a record

Offsets prove bytes landed. They do not prove the bytes are *usable* — right encoding, right
enrichment, the attributes a consumer needs. For that you have to decode one.

`cluster-logs` and `network-flows` are JSON and can be read directly. Use a Job rather than
`oc run`, which trips the `restricted` Pod Security warning:

```bash
cat <<EOF | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kafka-peek
  namespace: $KAFKA_NAMESPACE
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: kafka-peek
        image: $KAFKA_IMAGE
        command:
        - /bin/bash
        - -c
        - |
          bin/kafka-console-consumer.sh --bootstrap-server $KAFKA_BOOTSTRAP \
            --consumer.config /etc/kafka-admin/client.properties \
            --topic $TOPIC_FLOWS --max-messages 1 --from-beginning --timeout-ms 20000
        volumeMounts:
        - { name: admin-config, mountPath: /etc/kafka-admin, readOnly: true }
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          capabilities: { drop: ["ALL"] }
          seccompProfile: { type: RuntimeDefault }
      volumes:
      - { name: admin-config, secret: { secretName: kafka-admin-config } }
EOF
```

```bash
oc wait --for=condition=complete job/kafka-peek -n $KAFKA_NAMESPACE --timeout=120s
oc logs -n $KAFKA_NAMESPACE job/kafka-peek | grep -m1 '^{' | python3 -m json.tool
```

> **The `grep` is load-bearing.** `kafka-console-consumer.sh` writes the record to stdout but
> `Processed a total of 1 messages` to stderr, and `oc logs` merges the two. In a Job there is no
> TTY, so stdout is block-buffered while stderr is not — the summary line usually lands *first*.
> Piping the whole log straight into a JSON parser therefore fails on a record that arrived
> perfectly:
>
> ```
> Expecting value: line 1 column 1 (char 0)     # summary line first, or the log is empty
> Extra data: line 2 column 1 (char 37)         # record first, summary after
> ```
>
> Neither says anything about the record. Run `oc logs` on its own to see what is really there.

Swap `--topic` for `$TOPIC_LOGS` to read a log record instead. Delete the Job before re-running it —
the pod template is immutable.

### A network flow

One record, reformatted for reading. Node addresses are replaced with the documentation range
([RFC 5737](https://datatracker.ietf.org/doc/html/rfc5737)); the pod addresses are OpenShift's
default `10.128.0.0/14` and are left alone. Everything else is verbatim:

```json
{
  "SrcAddr": "10.129.2.19",         "DstAddr": "10.128.0.74",
  "SrcPort": 9092,                  "DstPort": 37506,
  "SrcK8S_Name": "observability-dual-role-1",
  "SrcK8S_Namespace": "kafka",
  "SrcK8S_OwnerName": "observability-dual-role",
  "SrcK8S_OwnerType": "StrimziPodSet",
  "SrcK8S_HostName": "worker2",     "SrcK8S_HostIP": "192.0.2.35",
  "DstK8S_Name": "instance-g89dt",
  "DstK8S_Namespace": "openshift-logging",
  "DstK8S_OwnerName": "instance",
  "DstK8S_OwnerType": "DaemonSet",
  "DstK8S_HostName": "master1",     "DstK8S_HostIP": "192.0.2.31",
  "Proto": 6, "Etype": 2048, "Flags": ["ACK"],
  "Bytes": 195, "Packets": 2, "Sampling": 50,
  "K8S_FlowLayer": "app",
  "Interfaces": ["dc015203f7a7950", "genev_sys_6081"],
  "IfDirections": [0, 1], "FlowDirection": 1,
  "AgentIP": "192.0.2.35",
  "TimeFlowStartMs": 1788255733306,
  "TimeFlowEndMs": 1788255741164,
  "TimeReceived": 1788255748
}
```

**What this particular record is.** Source port 9092 in namespace `kafka` is the broker. The
destination is a DaemonSet pod named `instance-…` in `openshift-logging` — that is Vector, the
collector the `ClusterLogForwarder` named `instance` creates. So this is the broker ACKing Vector's
own produce requests: **the flow pipeline captured the log pipeline shipping to the same broker.**
Two of the five signals confirming each other in a single record is a better end-to-end proof than
any offset count.

Reading the rest:

| Field | Meaning |
|---|---|
| `Proto: 6`, `Etype: 2048` | TCP over IPv4 (`0x0800`). Numeric, not symbolic — a consumer maps them. |
| `Flags: ["ACK"]`, `Bytes: 195`, `Packets: 2` | A pure acknowledgement, which is why it is tiny. |
| `Sampling: 50` | **This record stands for ~50 flows.** Multiply `Bytes` and `Packets` by it for a traffic estimate. Set `sampling: 1` on the `FlowCollector` to export every flow. |
| `Src/DstK8S_*` | The enrichment, and the whole point. FLP turned two pod IPs into names, namespaces, owners and nodes *before* the record left the cluster — so a consumer never needs to query this cluster's API to interpret it. |
| `SrcK8S_OwnerType: StrimziPodSet` | Owner resolution follows custom controllers, not just Deployments and DaemonSets. |
| `Interfaces`, `IfDirections` | `dc015203f7a7950` is the pod's veth; `genev_sys_6081` is the Geneve tunnel — this crossed nodes on the OVN-Kubernetes overlay. `0` = ingress, `1` = egress on the matching interface. |
| `FlowDirection: 1` | Egress as reported by `AgentIP`, the agent on the source node. |
| `TimeFlow*Ms` | Epoch milliseconds. Here `EndMs - StartMs` = 7858ms, a connection held open across the sampling window rather than a one-shot request. |
| `K8S_FlowLayer: app` | Application traffic, as opposed to `infra`. |

### A trace

`otlp-traces` is protobuf, so a console consumer prints binary. Two ways to make one readable:

- **Lab:** flip `encoding: otlp_json` on the `kafka/traces` exporter, re-apply, consume, flip back.
  Note the topic then holds two encodings across that window, which a consumer mid-stream will not
  enjoy.
- **Production:** add a second exporter with `encoding: otlp_json` writing to a throwaway topic and
  add it to the `traces` pipeline's `exporters` list. Nothing already on the topic changes.

OTLP is nested three levels deep, and knowing the shape is most of reading it:

```
resourceSpans[]           ← one per producing service; carries `resource.attributes`
  └── scopeSpans[]        ← one per instrumentation library
        └── spans[]       ← the actual spans
```

Trimmed to the fields that matter (illustrative — the trace and span IDs are made up):

```json
{"resourceSpans": [{
  "resource": {"attributes": [
    {"key": "service.name",       "value": {"stringValue": "frontend"}},
    {"key": "k8s.namespace.name", "value": {"stringValue": "online-boutique"}},
    {"key": "k8s.pod.name",       "value": {"stringValue": "frontend-7d9c8b6f5d-x2klm"}},
    {"key": "k8s.node.name",      "value": {"stringValue": "worker2"}}
  ]},
  "scopeSpans": [{
    "scope": {"name": "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"},
    "spans": [{
      "traceId":           "5b8efff798038103d269b633813fc60c",
      "spanId":            "eee19b7ec3c1b174",
      "parentSpanId":      "",
      "name":              "GET /product/{id}",
      "kind":              2,
      "startTimeUnixNano": "1788255733306000000",
      "endTimeUnixNano":   "1788255733412000000",
      "attributes": [
        {"key": "http.method",      "value": {"stringValue": "GET"}},
        {"key": "http.status_code", "value": {"intValue": "200"}}
      ],
      "status": {}
    }]
  }]
}]}
```

What to look at, in order:

| Field | Meaning |
|---|---|
| `traceId` | The join key. Every service touched by one user request emits spans carrying the **same** `traceId` — that is what lets a backend reassemble a distributed call from records that arrived independently. |
| `spanId` / `parentSpanId` | The tree. An empty `parentSpanId` is the **root span**, where the request entered the system. |
| `kind` | `2` = SERVER (received a request), `3` = CLIENT (made one). A client span in one service and a server span in the next, sharing a `traceId`, is one hop. |
| `startTimeUnixNano` / `endTimeUnixNano` | Duration is the difference, in nanoseconds — 106ms here. There is no duration field; it is always computed. |
| `resource.attributes` → `service.name` | Which service emitted it. Set by `OTEL_SERVICE_NAME` on the workload; without it the Go services all report `unknown_service:server` and collapse into one. |
| `resource.attributes` → `k8s.*` | **Added by the `k8sattributes` processor, not the application.** Their presence is proof that processor and its ClusterRole are working. Absent, the topic still gets valid traces with no idea which pod produced them. |
| one record | One *batch*: many `resourceSpans`, from several services, covering many traces. |

Cross-check against `otlp-spanmetrics`: the RED metrics on that topic are derived from exactly these
spans by the `spanmetrics` connector, so a service appearing in traces should appear there too.

## What verification does and does not establish

Worth being precise, because the checks above are easy to over-read:

| Established | Not established |
|---|---|
| All five topics exist and every partition is live | That **all** of a signal arrives — offsets cannot show you what was dropped or never collected |
| Every producer connects, authenticates and writes | That records are complete — a log record per line does not mean every namespace is represented |
| Data is still arriving now, at a measurable rate | That a consumer can do anything useful with them; only decoding shows that |
| Records carry their k8s enrichment | That ordering or exactly-once delivery holds — Kafka gives per-partition ordering only |

For completeness, check the dimension you actually care about. `log_type` on `cluster-logs` records
should show `application`, `infrastructure` **and** `audit` — if `audit` never appears, the
`collect-audit-logs` binding is missing and offsets would never have told you.

## What is on each topic

| Topic | Format | Notes |
|---|---|---|
| `otlp-traces` | OTLP `ExportTraceServiceRequest`, protobuf | Consumable by Tempo's Kafka receiver, Jaeger, or an OTel collector with a `kafka` receiver. |
| `otlp-spanmetrics` | OTLP `ExportMetricsServiceRequest`, protobuf | RED metrics. Names carry a `traces_span_metrics_` prefix by default — the connector applies a default namespace of `traces.span.metrics`. Set `namespace: ""` on the connector for the bare names. |
| `federated-metrics` | OTLP metrics, protobuf | Prometheus samples converted to OTLP by the receiver. `job` and `instance` become resource attributes. |
| `cluster-logs` | JSON, one record per message | The ViaQ data model — `kubernetes.namespace_name`, `log_type`, `message`, `@timestamp`. `log_type` is how a consumer splits application, infrastructure and audit back out. |
| `network-flows` | JSON, one record per flow | Enriched flows — `SrcK8S_Namespace`, `DstK8S_OwnerName`, `Bytes`, `Packets`, `TimeFlowStartMs`. |

The three OTLP topics are the ones a central backend (Mimir, Thanos, Tempo, Jaeger) consumes
directly. The two JSON topics are the ones a SIEM or an archival pipeline consumes.

## Troubleshooting

| Symptom | Cause |
|---|---|
| The topic-creation Job fails with `TimeoutException` | The broker address is wrong or unreachable from the cluster. This runs before every producer precisely so this is the failure you get first. |
| ...with `SSL handshake failed` | Wrong CA, or the broker presents a certificate for a different hostname. `ssl.endpoint.identification.algorithm=` (empty) in `client.properties` disables hostname checking — lab only. |
| ...with `Authentication failed` | Wrong SASL user, password, or mechanism. The mechanism must match what the broker's listener actually offers. |
| ...with `INVALID_REPLICATION_FACTOR` | `--replication-factor 3` against fewer than three brokers. |
| `ClusterLogForwarder` `Valid=False` | A referenced Secret is missing or has the wrong key. The condition message names it. |
| `Valid=True` but the `cluster-logs` topic stays at offset 0 | Vector cannot reach the broker. `oc logs -n $LOGGING_NAMESPACE -l app.kubernetes.io/component=collector`. |
| Collector `CrashLoopBackOff`, `error decoding 'exporters'` | The `auth: {tls:, sasl:}` versus top-level `tls:`/`sasl:` layout — your build wants the other one. |
| Collector running, `federated-metrics` at offset 0 | A `403` on `/federate`. The `cluster-monitoring-view` binding is missing, or user workload monitoring is not enabled and the second scrape target has no endpoints. Check `oc logs -n $OTEL_NAMESPACE deploy/otel-collector \| grep -i scrape`. |
| Collector memory climbing steadily | The `match[]` selectors are too broad. Federation returns every matching series on every scrape. |
| `otlp-traces` at offset 0 with the workload running | The services are still pointed at `otel-collector.tracing-system`. `oc set env deploy/frontend -n $APP_NAMESPACE --list \| grep COLLECTOR`. |
| `encodeKafka error: dial tcp <ip>:<port>: i/o timeout` in the flow processor | NetObserv's own NetworkPolicy has no egress rule for Kafka. See [Let the flow processor out to the broker](#let-the-flow-processor-out-to-the-broker). A timeout rather than a refusal is the tell: the packets are dropped, not rejected. Affects an external broker too. |
| ...but a probe pod in the same namespace connects fine | Expected, and it confirms the policy: the probe does not carry the `part-of=netobserv-operator` label the policy selects on, so it is not subject to it. |
| Flows missing but the agent is running | The `FlowCollector` has no `exporters` entry, or `deploymentModel: Kafka` was set instead — that is internal transport, not export. |
| `'kafkaexporter.Config' has invalid keys: encoding, topic` | The build wants `topic` and `encoding` nested under `traces:` / `metrics:`. `invalid keys: traces, metrics` means the opposite. |
| `kafka-peek`: `Expecting value: line 1 column 1` or `Extra data: line 2 column 1` | Not a data problem. The consumer's `Processed a total of N messages` summary is on stderr and `oc logs` merges it with the record. Filter first: `oc logs … \| grep -m1 '^{' \| python3 -m json.tool`. |
| Vector: `too old resource version ... reason: Expired, code: 410` | **Benign.** A Kubernetes watch fell behind and the reflector is re-listing; it retries and recovers on its own. It says nothing about whether logs are reaching the topic — check the `cluster-logs` offsets for that. |
| `Observe → Network Traffic` shows no "Traffic flows" table | Expected. That table reads from Loki, and there is none. Overview and Topology still work. |

## Clean up

Producers first, then topics — deleting a topic while Vector and the flow processor are still
producing to it either has the broker recreate it (if auto-creation is on) or has them retry forever
(if it is not).

```bash
oc delete namespace $APP_NAMESPACE --ignore-not-found
```

```bash
oc delete flowcollector cluster --ignore-not-found
oc delete clusterlogforwarder instance -n $LOGGING_NAMESPACE --ignore-not-found
oc delete opentelemetrycollector otel -n $OTEL_NAMESPACE --ignore-not-found
```

```bash
for ns in $LOGGING_NAMESPACE $NETOBSERV_NAMESPACE $OTEL_NAMESPACE; do
  oc delete secret kafka-ca kafka-sasl -n $ns --ignore-not-found
done
```

```bash
oc delete networkpolicy netobserv-egress-kafka -n $NETOBSERV_NAMESPACE --ignore-not-found
```

The topics are a separate decision, and on an external broker they are **not this cluster's to
remove** — they may be shared, and they may hold records nobody has consumed yet. If you are certain:

```bash
oc delete namespace $KAFKA_NAMESPACE --ignore-not-found     # Path B: removes the lab broker too
```

Operators, Subscriptions and CSVs are left in place: removing them is rarely what you want
mid-iteration and they cost nothing idle.
