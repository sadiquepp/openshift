# OpenShift Observability

## Contents
- [OpenShift Logging](#openshift-logging)
  - [Pre-requisites](#pre-requisites)
  - [Install and Configure the Loki Operator](#install-and-configure-the-loki-operator)
  - [Install openshift-logging Operator](#install-openshift-logging-operator)
- [Network Observability](#network-observability)
  - [Choose a deployment mode](#choose-a-deployment-mode)
  - [Install the operator](#install-the-operator)
  - [Path A: FlowCollector without Loki](#path-a-flowcollector-without-loki)
  - [Path B: FlowCollector with Loki](#path-b-flowcollector-with-loki)
    - [Install the Loki Operator](#install-the-loki-operator)
    - [Create the S3 bucket for the flows LokiStack](#create-the-s3-bucket-for-the-flows-lokistack)
    - [Create the LokiStack](#create-the-lokistack)
    - [Grant the operator access to the LokiStack CA](#grant-the-operator-access-to-the-lokistack-ca)
    - [Create the FlowCollector](#create-the-flowcollector)
    - [Verify the deployment](#verify-the-deployment)
    - [Install the console plugin](#install-the-console-plugin)
    - [Optional: enable the Troubleshooting Panel UIPlugin](#optional-enable-the-troubleshooting-panel-uiplugin)
- [Distributed Tracing](#distributed-tracing)
  - [Create the tracing namespace](#create-the-tracing-namespace)
  - [Create the S3 bucket for Tempo](#create-the-s3-bucket-for-tempo)
  - [Install Tempo Operator](#install-tempo-operator)
  - [Create the TempoStack](#create-the-tempostack)
  - [Configure the UIPlugin for distributed tracing](#configure-the-uiplugin-for-distributed-tracing)
  - [Install OpenTelemetry Collector Operator](#install-opentelemetry-collector-operator)
  - [Create the collector service account and RBAC](#create-the-collector-service-account-and-rbac)
  - [Create the OpenTelemetryCollector](#create-the-opentelemetrycollector)
- [Test workload: Online Boutique](#test-workload-online-boutique)
  - [Deploy the application](#deploy-the-application)
    - [Deploying as a non-admin user](#deploying-as-a-non-admin-user)
  - [Enable tracing for the workload](#enable-tracing-for-the-workload)
    - [Reading a trace](#reading-a-trace)
    - [Worked example: an order placement](#worked-example-an-order-placement)
  - [Auto-instrument a service with the Instrumentation CR](#auto-instrument-a-service-with-the-instrumentation-cr)
    - [Notes and limits](#notes-and-limits)
  - [Analyze the application logs](#analyze-the-application-logs)
  - [How OpenTelemetry handles logs, and how that differs](#how-opentelemetry-handles-logs-and-how-that-differs)
    - [Demo: collecting and correlating `adservice` logs](#demo-collecting-and-correlating-adservice-logs)
    - [What the demo actually proves](#what-the-demo-actually-proves)
    - [Where these logs actually go](#where-these-logs-actually-go)
  - [Observe the network flows](#observe-the-network-flows)
  - [Metrics from native Prometheus](#metrics-from-native-prometheus)
  - [What metrics OpenTelemetry collects](#what-metrics-opentelemetry-collects)
    - [How this differs from what the platform already collects](#how-this-differs-from-what-the-platform-already-collects)
    - [How the pieces fit together](#how-the-pieces-fit-together)
    - [Add the spanmetrics connector](#add-the-spanmetrics-connector)
    - [Scrape the collector](#scrape-the-collector)
    - [Finding them in the console](#finding-them-in-the-console)
    - [The metrics you get](#the-metrics-you-get)
  - [Tear down the workload](#tear-down-the-workload)
- [Clean up](#clean-up)

> **Automated version.** Everything in this document is automated in
> [`ansible/`](ansible/) — an AWS phase an AWS admin can run alone, a cluster
> phase, and the Network Observability Loki/no-Loki choice as a single variable.
> [`demo/README.md`](demo/README.md) is the walkthrough for showing the result.
> This document remains the source of truth for *why* each resource looks the
> way it does.

## OpenShift Logging

This Document describes the pre-requisites for installing and configuring the OpenShift Logging using AWS S3 as the storage backend.

It then extends that into a full observability stack — Network Observability, distributed tracing
with Tempo and OpenTelemetry — and drives the whole thing with a test workload so each signal can be
followed end to end.

### Pre-requisites

- Define the following variables: Configure SUFFIX to make the resources unique.

```bash
export SUFFIX=xipio
export BUCKET_NAME=logging-loki-s3-$SUFFIX   # Bucket name should be unique and should not contain spaces.
export REGION=ap-south-1
export AWS_ACCOUNT_NUMBER=$(aws sts get-caller-identity --query "Account" --output text)
export LOKI_USERNAME=logging-loki-s3-$SUFFIX
export LOKI_SECRET_NAME=logging-loki-s3-$SUFFIX
export STORAGE_CLASS_NAME=lvms-vg1
export LOKI_VERSION=6.6
export OPENSHIFT_LOGGING_VERSION=6.6
```

- Create S3 bucket.

```bash
aws s3 mb s3://$BUCKET_NAME --region $REGION
```

- Create an AWS IAM Policy for the S3 bucket.

```bash
cat <<EOF > iam-policy-$SUFFIX.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::$BUCKET_NAME"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:GetObjectTagging",
        "s3:PutObjectTagging"
      ],
      "Resource": "arn:aws:s3:::$BUCKET_NAME/*"
    }
  ]
}
EOF
```

```bash
aws iam create-policy --policy-name $LOKI_USERNAME --policy-document file://iam-policy-$SUFFIX.json
```

- Create an AWS IAM User for the S3 bucket.

```bash
aws iam create-user --user-name $LOKI_USERNAME
```

- Attach the IAM Policy to the IAM User.

```bash
aws iam attach-user-policy --user-name $LOKI_USERNAME --policy-arn arn:aws:iam::$AWS_ACCOUNT_NUMBER:policy/$LOKI_USERNAME
```

- Get the IAM User Access Key.

```bash
read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY <<< $(aws iam create-access-key --user-name $LOKI_USERNAME --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text) && export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
echo "AWS_ACCESS_KEY_ID: $AWS_ACCESS_KEY_ID"
echo "AWS_SECRET_ACCESS_KEY: $AWS_SECRET_ACCESS_KEY"
```



### Install and Configure the Loki Operator

- Create the Namespace.

```bash
cat <<EOF > namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-operators-redhat
  labels:
    openshift.io/cluster-monitoring: "true"
EOF
```

- Apply the Namespace.

```bash
oc apply -f namespace.yaml
```

- Create the Operator Group.

```bash
cat <<EOF > operator-group.yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  upgradeStrategy: Default
EOF
```

- Apply the Operator Group.

```bash
oc apply -f operator-group.yaml
```

- Create the Subscription.

```bash
cat <<EOF > subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  channel: stable-$LOKI_VERSION
  installPlanApproval: Automatic
  name: loki-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

- Apply the Subscription.

```bash
oc apply -f subscription.yaml
```

- Create the `openshift-logging` Namespace.

```bash
cat <<EOF > openshift-logging-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-logging
  labels:
    openshift.io/cluster-monitoring: "true"
EOF
```

- Apply the Namespace.

```bash
oc apply -f openshift-logging-namespace.yaml
```

- Create the secret for the S3 bucket without STS.

```bash
oc create secret generic $LOKI_SECRET_NAME \
  -n openshift-logging \
  --from-literal=bucketnames="$BUCKET_NAME" \
  --from-literal=endpoint="https://s3.$REGION.amazonaws.com" \
  --from-literal=access_key_id="$AWS_ACCESS_KEY_ID" \
  --from-literal=access_key_secret="$AWS_SECRET_ACCESS_KEY" \
  --from-literal=region="$REGION"
```

- Verify the secret is created.

```bash
oc get secret $LOKI_SECRET_NAME -n openshift-logging -o yaml
```

- Create the Loki Stack custom resource.

```bash
cat <<EOF > loki-stack.yaml
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: logging-loki 
  namespace: openshift-logging
spec:
  size: 1x.pico
  storage:
    schemas:
      - effectiveDate: '2023-10-15'
        version: v13
    secret:
      name: $LOKI_SECRET_NAME 
      type: s3 
      credentialMode: static
  storageClassName: $STORAGE_CLASS_NAME 
  tenants:
    mode: openshift-logging
EOF
```

- Apply the Loki Stack custom resource.

```bash
oc apply -f loki-stack.yaml
```



### Install openshift-logging Operator

```bash
cat <<EOF > openshift-logging-operator-group.yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-logging
  namespace: openshift-logging
spec:
  upgradeStrategy: Default
EOF
```

- Apply the Operator Group.

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
  namespace: openshift-logging
spec:
  channel: stable-$OPENSHIFT_LOGGING_VERSION
  installPlanApproval: Automatic
  name: cluster-logging
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

- Apply the Subscription.

```bash
oc apply -f openshift-logging-subscription.yaml
```

- Verify the CSV is created.

```bash
oc get csv -n openshift-logging
```

- Creating the collector service account and RBAC

```bash
cat <<EOF > serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: logging-collector
  namespace: openshift-logging
EOF
```

- Apply the ServiceAccount.

```bash
oc apply -f serviceaccount.yaml
```

- Create the RBAC.

```bash
cat <<EOF > rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: logging-collector:write-logs
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: logging-collector-logs-writer
subjects:
- kind: ServiceAccount
  name: logging-collector
  namespace: openshift-logging
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
  namespace: openshift-logging
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
  namespace: openshift-logging
EOF
```

- Apply the RBAC.

```bash
oc apply -f rbac.yaml
```

- Create the ClusterLogForwarder custom resource.

```bash
cat <<EOF > clusterlogforwarder.yaml
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: instance
  namespace: openshift-logging
spec:
  serviceAccount:
    name: logging-collector
  outputs:
  - name: lokistack-out
    type: lokiStack
    lokiStack:
      target:
        name: logging-loki
        namespace: openshift-logging
      authentication:
        token:
          from: serviceAccount
    tls:
      ca:
        key: service-ca.crt
        configMapName: openshift-service-ca.crt
  pipelines:
  - name: infra-app-logs
    inputRefs:
    - application
    - infrastructure
    outputRefs:
    - lokistack-out
EOF
```

- Apply the ClusterLogForwarder custom resource.

```bash
oc apply -f clusterlogforwarder.yaml
```

- Create the LogFileMetricExporter custom resource.

```bash
cat <<EOF > logfilemetricexporter.yaml
apiVersion: logging.openshift.io/v1alpha1
kind: LogFileMetricExporter
metadata:
  name: instance
  namespace: openshift-logging
spec:
  nodeSelector: {}
  resources:
    limits:
      cpu: 500m
      memory: 256Mi
    requests:
      cpu: 200m
      memory: 128Mi
  tolerations: []
EOF
```

- Apply the LogFileMetricExporter custom resource.

```bash
oc apply -f logfilemetricexporter.yaml
```

- Verify the LogFileMetricExporter pod is running.

```bash
oc get pods -l app.kubernetes.io/component=logfilesmetricexporter \
  -n openshift-logging
```

- Verify the Collector pod is running.

```bash
oc get pods -n openshift-logging -l app.kubernetes.io/component=collector
```

- Verify the Collector logs.

```bash
oc logs -n openshift-logging -l app.kubernetes.io/component=collector --tail=20
```



### Install the Cluster Observability Operator

- Create the Subscription for the Cluster Observability Operator.

```bash
cat <<EOF > cluster-observability-operator-subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: cluster-observability-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

- Apply the Subscription.

```bash
oc apply -f cluster-observability-operator-subscription.yaml
```

- Verify the Cluster Observability Operator csv is created.

```bash
oc get csv -n openshift-operators | grep cluster-observability
```



### Configure the UIPlugin for logging

- Create the UIPlugin custom resource.

```bash
cat <<EOF > uiplugin.yaml
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: logging
spec:
  type: Logging
  logging:
    lokiStack:
      name: logging-loki
    logsLimit: 50
    timeout: 30s
    schema: otel 
EOF
```

- Apply the UIPlugin custom resource.

```bash
oc apply -f uiplugin.yaml
```

- Verify the UIPlugin pod is running.

```bash
oc get pods -l app.kubernetes.io/component=logging \
  -n openshift-logging
```



## Network Observability

Network Observability can be deployed in two shapes. **Decide which one you want before you start** —
the operator install is identical, but the `FlowCollector` differs and only one of them needs
storage.

### Choose a deployment mode


|                                           | **Without Loki** (metrics only)                 | **With Loki** (full flow records)         |
| ----------------------------------------- | ----------------------------------------------- | ----------------------------------------- |
| Extra storage                             | None                                            | S3 bucket + a dedicated LokiStack         |
| Console → Overview dashboards             | Yes                                             | Yes                                       |
| Console → Topology                        | Yes, at node / namespace / owner-workload level | Yes, down to pod and IP                   |
| Console → Traffic flows table (raw flows) | No                                              | Yes                                       |
| Where flow data lives                     | Prometheus, via existing cluster monitoring     | Loki, on S3                               |
| Relative cost                             | Baseline                                        | ~45–65% more memory, ~10–20% more CPU     |
| Follow                                    | [Path A](#path-a-flowcollector-without-loki)    | [Path B](#path-b-flowcollector-with-loki) |


> **Why Network Observability cannot reuse the** `logging-loki` **stack.** A LokiStack has exactly one
> `spec.tenants.mode`. `openshift-logging` serves the `application`, `infrastructure` and `audit`
> tenants; Network Observability writes flows to a `network` tenant, which is served only by
> `openshift-network` mode. So if you want Loki-backed flows you need a LokiStack of your own —
> either as the only LokiStack on the cluster (if you are not deploying OpenShift Logging), or as a
> second one alongside `logging-loki`. Path B covers both.

If you are running Path B without having done the OpenShift Logging sections above, you still need
the `SUFFIX`, `REGION`, `AWS_ACCOUNT_NUMBER` and `STORAGE_CLASS_NAME` variables from
[Pre-requisites](#pre-requisites).

- Define the variables used throughout this section.

```bash
export NETOBSERV_NAMESPACE=netobserv
```



### Install the operator

These steps are the same for both paths.

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

- Apply the Namespace.

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

- Apply the Operator Group.

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

- Apply the Subscription.

```bash
oc apply -f netobserv-subscription.yaml
```

- Verify the CSV is created.

```bash
oc get csv -n openshift-netobserv-operator
```

- If you did not tick *Enable console plugin* on the install form, the operator's console plugin is
left **Disabled** — see [Install the console plugin](#install-the-console-plugin).
- Create the namespace the flow collector components will run in.

```bash
oc create namespace $NETOBSERV_NAMESPACE --dry-run=client -o yaml | oc apply -f -
```

Now follow **either** Path A **or** Path B below, then continue at
[Verify the deployment](#verify-the-deployment).

### Path A: FlowCollector without Loki

No storage is required. The pipeline keeps only the Prometheus exporter, and the metrics are
scraped by the existing cluster monitoring stack.

The `FlowCollector` is cluster-scoped and must be named `cluster`. Only one can exist per cluster.

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
EOF
```

- Apply the FlowCollector custom resource.

```bash
oc apply -f flowcollector.yaml
```

- Confirm the flow metrics are reaching cluster monitoring. The query returns a non-empty result
once traffic has been observed.

```bash
THANOS=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
curl -sk -H "Authorization: Bearer $(oc whoami -t)" \
  --data-urlencode 'query=netobserv_namespace_flows_total' \
  "https://$THANOS/api/v1/query" | head -c 400; echo
```

  The Thanos querier route is the supported way to query cluster monitoring from outside the
  cluster; `oc exec … -- curl` into the Prometheus pod does not work, as that image ships no `curl`.

- Grant a non-admin user permission to read the flow metrics in the console. Cluster admins already
have this.

```bash
oc adm policy add-cluster-role-to-user netobserv-metrics-reader <user>
```

> `<user>` is a placeholder for an OpenShift identity you choose — there is no account created for
> you. Cluster admins already pass these checks, so this is only for non-admins. Use
> `add-cluster-role-to-group <group>` for a team, or `-z <sa> -n <namespace>` for a service account.
> `oc get users` and `oc get groups` list the real names (a `User` object only exists once that
> person has logged in at least once).

You can switch to Path B later without reinstalling: create the LokiStack, then patch the
FlowCollector as shown at the end of Path B.

### Path B: FlowCollector with Loki

- Decide where the flows LokiStack will live. If you are **not** deploying OpenShift Logging, put it
in the same namespace as the flow collector components — this is the simplest layout and needs no
extra RBAC:

```bash
export NETOBSERV_LOKI_NAMESPACE=$NETOBSERV_NAMESPACE
```

  If you **are** also running OpenShift Logging, keep the two LokiStacks together in the logging
  namespace instead. This layout additionally requires the two rolebindings further down:

```bash
export NETOBSERV_LOKI_NAMESPACE=openshift-logging
```

- Define the remaining variables.

```bash
export NETOBSERV_BUCKET_NAME=netobserv-loki-s3-$SUFFIX
export NETOBSERV_LOKI_USERNAME=netobserv-loki-s3-$SUFFIX
export NETOBSERV_LOKI_SECRET_NAME=netobserv-loki-s3-$SUFFIX
```



### Install the Loki Operator

Skip this if you already installed the Loki Operator during the OpenShift Logging sections above —
a single Loki Operator manages every LokiStack on the cluster.

```bash
cat <<EOF > loki-operator-standalone.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-operators-redhat
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  channel: stable-$LOKI_VERSION
  installPlanApproval: Automatic
  name: loki-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

- Apply the Loki Operator manifests.

```bash
oc apply -f loki-operator-standalone.yaml
```

- Verify the CSV is created.

```bash
oc get csv -n openshift-operators-redhat | grep loki
```



### Create the S3 bucket for the flows LokiStack

- Create the S3 bucket.

```bash
aws s3 mb s3://$NETOBSERV_BUCKET_NAME --region $REGION
```

- Create an AWS IAM Policy for the S3 bucket.

```bash
cat <<EOF > netobserv-iam-policy-$SUFFIX.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::$NETOBSERV_BUCKET_NAME"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:GetObjectTagging",
        "s3:PutObjectTagging"
      ],
      "Resource": "arn:aws:s3:::$NETOBSERV_BUCKET_NAME/*"
    }
  ]
}
EOF
```

```bash
aws iam create-policy --policy-name $NETOBSERV_LOKI_USERNAME --policy-document file://netobserv-iam-policy-$SUFFIX.json
```

- Create an AWS IAM User and attach the policy.

```bash
aws iam create-user --user-name $NETOBSERV_LOKI_USERNAME
aws iam attach-user-policy --user-name $NETOBSERV_LOKI_USERNAME --policy-arn arn:aws:iam::$AWS_ACCOUNT_NUMBER:policy/$NETOBSERV_LOKI_USERNAME
```

- Get the IAM User Access Key.

```bash
read -r NETOBSERV_AWS_ACCESS_KEY_ID NETOBSERV_AWS_SECRET_ACCESS_KEY <<< $(aws iam create-access-key --user-name $NETOBSERV_LOKI_USERNAME --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text) && export NETOBSERV_AWS_ACCESS_KEY_ID NETOBSERV_AWS_SECRET_ACCESS_KEY
echo "NETOBSERV_AWS_ACCESS_KEY_ID: $NETOBSERV_AWS_ACCESS_KEY_ID"
echo "NETOBSERV_AWS_SECRET_ACCESS_KEY: $NETOBSERV_AWS_SECRET_ACCESS_KEY"
```



### Create the LokiStack

- Create the secret for the S3 bucket.

```bash
oc create secret generic $NETOBSERV_LOKI_SECRET_NAME \
  -n $NETOBSERV_LOKI_NAMESPACE \
  --from-literal=bucketnames="$NETOBSERV_BUCKET_NAME" \
  --from-literal=endpoint="https://s3.$REGION.amazonaws.com" \
  --from-literal=access_key_id="$NETOBSERV_AWS_ACCESS_KEY_ID" \
  --from-literal=access_key_secret="$NETOBSERV_AWS_SECRET_ACCESS_KEY" \
  --from-literal=region="$REGION"
```

- Create the LokiStack custom resource. Note the `openshift-network` tenant mode — this is what
makes it a flows store rather than a logs store.

```bash
cat <<EOF > netobserv-loki-stack.yaml
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: netobserv-loki
  namespace: $NETOBSERV_LOKI_NAMESPACE
spec:
  size: 1x.pico
  storage:
    schemas:
      - effectiveDate: '2023-10-15'
        version: v13
    secret:
      name: $NETOBSERV_LOKI_SECRET_NAME
      type: s3
      credentialMode: static
  storageClassName: $STORAGE_CLASS_NAME
  tenants:
    mode: openshift-network
EOF
```

- Apply the LokiStack custom resource and wait for it to become ready.

```bash
oc apply -f netobserv-loki-stack.yaml
```

```bash
oc get lokistack netobserv-loki -n $NETOBSERV_LOKI_NAMESPACE \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```



### Grant the operator access to the LokiStack CA

**Only needed when** `NETOBSERV_LOKI_NAMESPACE` **is different from** `NETOBSERV_NAMESPACE` — that is,
the OpenShift Logging layout. The operator reads the LokiStack CA secret in the namespace where the
LokiStack runs (`netobserv-secret-watcher`, `get/list/watch` on secrets) and writes a copy of it
into the namespace where the flow collector components run (`netobserv-secret-creator`, write on
secrets), so that flowlogs-pipeline can verify the Loki gateway certificate. Neither ClusterRole is
bound by default.

```bash
[ "$NETOBSERV_LOKI_NAMESPACE" != "$NETOBSERV_NAMESPACE" ] && oc create rolebinding secret-watcher \
  -n $NETOBSERV_LOKI_NAMESPACE \
  --clusterrole=netobserv-secret-watcher \
  --serviceaccount=openshift-netobserv-operator:netobserv-controller-manager
```

```bash
[ "$NETOBSERV_LOKI_NAMESPACE" != "$NETOBSERV_NAMESPACE" ] && oc create rolebinding secret-creator \
  -n $NETOBSERV_NAMESPACE \
  --clusterrole=netobserv-secret-creator \
  --serviceaccount=openshift-netobserv-operator:netobserv-controller-manager
```

If flowlogs-pipeline later logs certificate or `x509` errors against the Loki gateway, these two
bindings are the first thing to check.

### Create the FlowCollector

The `FlowCollector` is cluster-scoped and must be named `cluster`. Only one can exist per cluster.

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
    enable: true
    mode: LokiStack
    lokiStack:
      name: netobserv-loki
      namespace: $NETOBSERV_LOKI_NAMESPACE
EOF
```

- Apply the FlowCollector custom resource.

```bash
oc apply -f flowcollector.yaml
```

- Grant a non-admin user permission to read the flows. Cluster admins already have this.

```bash
oc adm policy add-cluster-role-to-user netobserv-reader <user>
```

> `<user>` is a placeholder for an OpenShift identity you choose — there is no account created for
> you. Cluster admins already pass these checks, so this is only for non-admins. Use
> `add-cluster-role-to-group <group>` for a team, or `-z <sa> -n <namespace>` for a service account.
> `oc get users` and `oc get groups` list the real names (a `User` object only exists once that
> person has logged in at least once).

- If you started on Path A and are switching to Loki now, patch the existing FlowCollector instead
of re-applying it.

```bash
oc patch flowcollector cluster --type=merge -p '{
  "spec": {
    "loki": {
      "enable": true,
      "mode": "LokiStack",
      "lokiStack": {
        "name": "netobserv-loki",
        "namespace": "'"$NETOBSERV_LOKI_NAMESPACE"'"
      }
    }
  }
}'
```



### Verify the deployment

- Verify the FlowCollector is ready.

```bash
oc get flowcollector cluster \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```

- Verify the flowlogs-pipeline and console plugin pods are running.

```bash
oc get pods -n $NETOBSERV_NAMESPACE
```

- The eBPF agent runs as a DaemonSet in a dedicated privileged namespace. Verify it is scheduled on
every node.

```bash
oc get daemonset netobserv-ebpf-agent -n $NETOBSERV_NAMESPACE-privileged
```

- Check the pipeline logs for export errors.

```bash
oc logs -n $NETOBSERV_NAMESPACE -l app=flowlogs-pipeline --tail=20
```

- Confirm the exact reader role names available for your operator version — they differ between the
upstream and Red Hat builds.

```bash
oc get clusterrole | grep netobserv
```



### Install the console plugin

Network Observability does **not** use a Cluster Observability Operator `UIPlugin`. The `UIPlugin`
API only accepts the types `TroubleshootingPanel`, `DistributedTracing`, `Logging` and `Monitoring`
(`Dashboards` is deprecated) — there is no `NetworkObservability` type. The
**Observe → Network Traffic** page is served by the console plugin shipped with the operator, which
has to be registered with the console operator.

The FlowCollector needs no configuration for this: `spec.consolePlugin.enable` and
`spec.consolePlugin.register` both default to `true`, so the operator creates the
`netobserv-plugin` Deployment and attempts registration on its own. If the plugin was left disabled
at install time, the operator page under **Operators → Installed Operators → Network Observability**
shows:

> Console plugin — netobserv-plugin: **Disabled**

Click **Disabled** and switch it to **Enabled**, or use the CLI below.

- Verify the console plugin pod is running.

```bash
oc get pods -n $NETOBSERV_NAMESPACE -l app=netobserv-plugin
```

- Check whether the plugin is registered with the console operator.

```bash
oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}{"\n"}'
```

- If `netobserv-plugin` is not in that list, append it. Appending with `/spec/plugins/-` preserves
any other registered plugins, such as `logging-view-plugin` or `monitoring-plugin`.

```bash
oc patch console.operator.openshift.io cluster \
  --type=json -p '[{"op":"add","path":"/spec/plugins/-","value":"netobserv-plugin"}]'
```

  If that fails with `path /spec/plugins does not exist`, no plugin has ever been registered on this
  cluster — create the list instead.

```bash
oc patch console.operator.openshift.io cluster \
  --type=json -p '[{"op":"add","path":"/spec/plugins","value":["netobserv-plugin"]}]'
```

- Wait for the console operator to finish rolling out, then hard-refresh the browser — the plugin
bundle is cached client-side.

```bash
oc rollout status deployment/console -n openshift-console --timeout=5m
```



### Optional: enable the Troubleshooting Panel UIPlugin

This is the Cluster Observability Operator plugin that *does* consume network flows. Korrel8r
correlates signals across data stores — alerts, metrics, logs, netflows and cluster resources — so
you can pivot from an alert straight to the related network traffic. It is available from
OpenShift 4.16 and GA from 4.19.

Prerequisites: the Cluster Observability Operator (installed in
[Install the Cluster Observability Operator](#install-the-cluster-observability-operator)) and, for
the netflow correlation specifically, the Loki-backed deployment from Path B — Korrel8r reads flow
records from Loki, so a metrics-only Path A install has no per-flow data to correlate.

- Create the UIPlugin custom resource.

```bash
cat <<EOF > uiplugin-troubleshooting.yaml
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: troubleshooting-panel
spec:
  type: TroubleshootingPanel
EOF
```

- Apply the UIPlugin custom resource.

```bash
oc apply -f uiplugin-troubleshooting.yaml
```

- Verify the plugin pod is running.

```bash
oc get pods -n openshift-cluster-observability-operator
```

The panel is reached from **Observe → Alerting**: open an alert and select **Troubleshooting Panel**.

## Distributed Tracing

Distributed tracing is made up of two operators: **Tempo** stores and queries the traces, and the
**Red Hat build of OpenTelemetry** provides the collector that receives spans from instrumented
workloads and forwards them to Tempo.

- Define the additional variables.

```bash
export TRACING_NAMESPACE=tracing-system
export TEMPO_BUCKET_NAME=tempo-s3-$SUFFIX
export TEMPO_USERNAME=tempo-s3-$SUFFIX
export TEMPO_SECRET_NAME=tempo-s3-$SUFFIX
export TEMPO_TENANT_NAME=dev
export TEMPO_TENANT_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
```

> **Do not put the TempoStack and collector in an `openshift-*` namespace.** Monitoring for
> user-defined projects deliberately excludes `openshift-` prefixed namespaces, on the grounds that
> platform monitoring already covers them. A `ServiceMonitor` created in, say, `openshift-tracing`
> is silently ignored by the user workload Prometheus — which would break the collector metrics in
> [What metrics OpenTelemetry collects](#what-metrics-opentelemetry-collects). The operators
> themselves live in `openshift-tempo-operator` and `openshift-opentelemetry-operator`, which is
> correct; it is the *workload* namespace that must not carry the prefix.

### Create the tracing namespace

Both the TempoStack and the OpenTelemetry collector live here, and the S3 secret below is created
in it — so this has to exist first.

```bash
oc create namespace $TRACING_NAMESPACE --dry-run=client -o yaml | oc apply -f -
```

- Verify it exists before continuing.

```bash
oc get namespace $TRACING_NAMESPACE
```

### Create the S3 bucket for Tempo

- Create the S3 bucket.

```bash
aws s3 mb s3://$TEMPO_BUCKET_NAME --region $REGION
```

- Create an AWS IAM Policy for the S3 bucket.

```bash
cat <<EOF > tempo-iam-policy-$SUFFIX.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::$TEMPO_BUCKET_NAME"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:GetObjectTagging",
        "s3:PutObjectTagging"
      ],
      "Resource": "arn:aws:s3:::$TEMPO_BUCKET_NAME/*"
    }
  ]
}
EOF
```

```bash
aws iam create-policy --policy-name $TEMPO_USERNAME --policy-document file://tempo-iam-policy-$SUFFIX.json
```

- Create an AWS IAM User and attach the policy.

```bash
aws iam create-user --user-name $TEMPO_USERNAME
aws iam attach-user-policy --user-name $TEMPO_USERNAME --policy-arn arn:aws:iam::$AWS_ACCOUNT_NUMBER:policy/$TEMPO_USERNAME
```

- Get the IAM User Access Key.

```bash
read -r TEMPO_AWS_ACCESS_KEY_ID TEMPO_AWS_SECRET_ACCESS_KEY <<< $(aws iam create-access-key --user-name $TEMPO_USERNAME --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text) && export TEMPO_AWS_ACCESS_KEY_ID TEMPO_AWS_SECRET_ACCESS_KEY
echo "TEMPO_AWS_ACCESS_KEY_ID: $TEMPO_AWS_ACCESS_KEY_ID"
echo "TEMPO_AWS_SECRET_ACCESS_KEY: $TEMPO_AWS_SECRET_ACCESS_KEY"
```

- Create the secret for the S3 bucket. Two differences from the Loki secrets above: Tempo expects
  the key `bucket`, not `bucketnames`, and it must **not** carry `region`.

```bash
oc create secret generic $TEMPO_SECRET_NAME \
  -n $TRACING_NAMESPACE \
  --from-literal=bucket="$TEMPO_BUCKET_NAME" \
  --from-literal=endpoint="https://s3.$REGION.amazonaws.com" \
  --from-literal=access_key_id="$TEMPO_AWS_ACCESS_KEY_ID" \
  --from-literal=access_key_secret="$TEMPO_AWS_SECRET_ACCESS_KEY"
```

> **Why no `region`.** The Tempo operator infers the credential type from which keys are present.
> `endpoint` + `access_key_id` + `access_key_secret` mean long-lived static credentials; `region` +
> `role_arn` mean short-lived STS credentials. Supplying `region` together with the static keys puts
> the secret in both sets at once and the TempoStack is rejected at admission:
>
> ```
> The TempoStack "tempo" is invalid: spec.storage.secret.name: Invalid value: "tempo-s3-xxxxx":
> storage secret contains fields for long lived and short lived configuration
> ```
>
> The region is already implicit in the `endpoint` hostname. Note this differs from the LokiStack
> secrets earlier in this document, where `region` is a valid part of the static configuration — do
> not copy the Tempo secret's key set onto a Loki secret or vice versa.

- If you already created the secret with `region`, drop that key and re-apply the TempoStack.

```bash
oc patch secret $TEMPO_SECRET_NAME -n $TRACING_NAMESPACE \
  --type=json -p '[{"op":"remove","path":"/data/region"}]'
```



### Install Tempo Operator

- Create the Namespace.

```bash
cat <<EOF > tempo-operator-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-tempo-operator
  labels:
    openshift.io/cluster-monitoring: "true"
EOF
```

- Apply the Namespace.

```bash
oc apply -f tempo-operator-namespace.yaml
```

- Create the Operator Group.

```bash
cat <<EOF > tempo-operator-group.yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-tempo-operator
  namespace: openshift-tempo-operator
spec:
  upgradeStrategy: Default
EOF
```

- Apply the Operator Group.

```bash
oc apply -f tempo-operator-group.yaml
```

- Create the Subscription.

```bash
cat <<EOF > tempo-subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: tempo-product
  namespace: openshift-tempo-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: tempo-product
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

- Apply the Subscription.

```bash
oc apply -f tempo-subscription.yaml
```

- Verify the CSV is created.

```bash
oc get csv -n openshift-tempo-operator
```



### Create the TempoStack

The `openshift` tenant mode puts the Tempo gateway in front of the query and ingest paths, so that
OpenShift authentication and authorization are enforced per tenant.

```bash
cat <<EOF > tempostack.yaml
apiVersion: tempo.grafana.com/v1alpha1
kind: TempoStack
metadata:
  name: tempo
  namespace: $TRACING_NAMESPACE
spec:
  storage:
    secret:
      name: $TEMPO_SECRET_NAME
      type: s3
  storageSize: 10Gi
  storageClassName: $STORAGE_CLASS_NAME
  resources:
    total:
      limits:
        cpu: 2000m
        memory: 4Gi
  tenants:
    mode: openshift
    authentication:
      - tenantName: $TEMPO_TENANT_NAME
        tenantId: "$TEMPO_TENANT_ID"
  template:
    gateway:
      enabled: true
    queryFrontend:
      jaegerQuery:
        enabled: true
EOF
```

- Apply the TempoStack custom resource.

```bash
oc apply -f tempostack.yaml
```

- Verify the TempoStack pods are running.

```bash
oc get pods -n $TRACING_NAMESPACE
```

```bash
oc get tempostack tempo -n $TRACING_NAMESPACE \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```



### Configure the UIPlugin for distributed tracing

The Cluster Observability Operator installed earlier also provides the tracing console plugin.

```bash
cat <<EOF > uiplugin-tracing.yaml
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: distributed-tracing
spec:
  type: DistributedTracing
EOF
```

- Apply the UIPlugin custom resource.

```bash
oc apply -f uiplugin-tracing.yaml
```

- Verify the UIPlugin pod is running.

```bash
oc get pods -n openshift-cluster-observability-operator
```

The **Observe → Traces** page appears in the web console once the plugin pod is running.

### Install OpenTelemetry Collector Operator

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

- Apply the Namespace.

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

- Apply the Operator Group.

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

- Apply the Subscription.

```bash
oc apply -f opentelemetry-subscription.yaml
```

- Verify the CSV is created.

```bash
oc get csv -n openshift-opentelemetry-operator
```



### Create the collector service account and RBAC

The collector authenticates to the Tempo gateway with its own service account token, so it needs
write permission on the Tempo tenant.

```bash
cat <<EOF > otel-collector-rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-collector
  namespace: $TRACING_NAMESPACE
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tempostack-traces-write
rules:
- apiGroups:
  - 'tempo.grafana.com'
  resources:
  - $TEMPO_TENANT_NAME
  resourceNames:
  - traces
  verbs:
  - 'create'
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tempostack-traces-write
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tempostack-traces-write
subjects:
- kind: ServiceAccount
  name: otel-collector
  namespace: $TRACING_NAMESPACE
EOF
```

- Apply the ServiceAccount and RBAC.

```bash
oc apply -f otel-collector-rbac.yaml
```



### Create the OpenTelemetryCollector

The collector exposes OTLP receivers for the workloads and exports to the Tempo gateway. The
`X-Scope-OrgID` header selects the Tempo tenant.

```bash
cat <<EOF > otel-collector.yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel
  namespace: $TRACING_NAMESPACE
spec:
  mode: deployment
  serviceAccount: otel-collector
  config:
    extensions:
      bearertokenauth:
        filename: "/var/run/secrets/kubernetes.io/serviceaccount/token"
    receivers:
      otlp:
        protocols:
          grpc: {}
          http: {}
    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 50
        spike_limit_percentage: 30
      batch: {}
    exporters:
      otlp:
        endpoint: tempo-tempo-gateway.$TRACING_NAMESPACE.svc.cluster.local:8090
        tls:
          insecure: false
          ca_file: "/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt"
        auth:
          authenticator: bearertokenauth
        headers:
          X-Scope-OrgID: "$TEMPO_TENANT_NAME"
    service:
      extensions: [bearertokenauth]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [otlp]
EOF
```

- Apply the OpenTelemetryCollector custom resource.

```bash
oc apply -f otel-collector.yaml
```

- Verify the collector pod is running.

```bash
oc get pods -n $TRACING_NAMESPACE -l app.kubernetes.io/component=opentelemetry-collector
```

- Verify the collector logs for export errors.

```bash
oc logs -n $TRACING_NAMESPACE -l app.kubernetes.io/component=opentelemetry-collector --tail=20
```

Instrumented workloads should send OTLP traffic to the collector service:

- gRPC: `http://otel-collector.$TRACING_NAMESPACE.svc.cluster.local:4317`
- HTTP: `http://otel-collector.$TRACING_NAMESPACE.svc.cluster.local:4318`
- Grant a user permission to read traces in the console.

```bash
cat <<EOF > tempostack-traces-reader.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tempostack-traces-reader
rules:
- apiGroups:
  - 'tempo.grafana.com'
  resources:
  - $TEMPO_TENANT_NAME
  resourceNames:
  - traces
  verbs:
  - 'get'
EOF
```

```bash
oc apply -f tempostack-traces-reader.yaml
oc adm policy add-cluster-role-to-user tempostack-traces-reader <user>
```

> `<user>` is a placeholder for an OpenShift identity you choose — there is no account created for
> you. Cluster admins already pass these checks, so this is only for non-admins. Use
> `add-cluster-role-to-group <group>` for a team, or `-z <sa> -n <namespace>` for a service account.
> `oc get users` and `oc get groups` list the real names (a `User` object only exists once that
> person has logged in at least once).



## Test workload: Online Boutique

Everything above is plumbing. This section deploys a real workload through it and shows where each
signal lands: logs in Loki, flows in Network Observability, metrics in Prometheus, traces in Tempo.

[Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) is an 11-service
stateless microservices demo — Go, C#, Node, Python and Java, talking gRPC — with a load generator
that keeps traffic flowing on its own, so the dashboards are never empty. An OpenShift-patched copy
is vendored in this repo at [`../test-workloads/online-boutique`](../test-workloads/online-boutique);
it strips the upstream `runAsUser`/`runAsGroup`/`fsGroup: 1000` settings that `restricted-v2`
rejects, and swaps the GKE `LoadBalancer` Service for a Route. See that directory's README for the
details.

- Define the variables for this section.

```bash
export APP_NAMESPACE=online-boutique
export APP_DIR=test-workloads/online-boutique
```

### Deploy the application

Deploy with tracing already switched on — the `tracing` overlay is `default` plus the two
OpenTelemetry environment variables, covered in the next subsection.

```bash
oc apply -k $APP_DIR/overlays/tracing
```

  Use `$APP_DIR/overlays/default` instead if you want the application without tracing.

### Deploying as a non-admin user

Everything before this section needs cluster-admin — Subscriptions, the cluster-scoped
`FlowCollector`, the `UIPlugin` resources, console plugin registration and user workload monitoring
all require it. The **workload itself does not**: the base patch strips upstream's
`runAsUser`/`runAsGroup`/`fsGroup`, so every container runs with `runAsNonRoot: true`,
`readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false` and `capabilities: drop: [ALL]` —
which is what `restricted-v2` admits, and that SCC is granted to `system:authenticated` by default.

The only privileged step is the `Namespace` object in the overlay. Even with `self-provisioner` a
normal user cannot create one directly — that role grants `create` on `projectrequests`, not
`namespaces` — so the command above fails with:

```
Error from server (Forbidden): namespaces is forbidden: User "alice" cannot create resource
"namespaces" in API group "" at the cluster scope
```

- Create the project the normal way, then render `base/`, which contains no `Namespace` and pins no
  namespace on its objects. `oc` has kustomize built in, so no separate `kustomize` CLI is needed.

```bash
oc new-project $APP_NAMESPACE
```

```bash
oc kustomize $APP_DIR/base | oc apply -n $APP_NAMESPACE -f -
```

- The `tracing` overlay inherits that same `Namespace`, so set the two variables directly on the
  seven instrumented Deployments instead. The result is identical to applying the overlay.

```bash
for SVC in frontend checkoutservice currencyservice emailservice \
           paymentservice productcatalogservice recommendationservice; do
  oc set env deployment/$SVC -n $APP_NAMESPACE \
    ENABLE_TRACING=1 \
    OTEL_SERVICE_NAME=$SVC \
    COLLECTOR_SERVICE_ADDR=otel-collector.$TRACING_NAMESPACE.svc.cluster.local:4317
done
```

If an admin creates the namespace once up front, `oc apply -k` works normally from then on and none
of the above is needed. See
[the fixture README](../test-workloads/online-boutique/README.md#deploying-as-a-non-admin-user) for
the full reasoning.

- Wait for all deployments to roll out.

```bash
oc wait --for=condition=Available deployment --all -n $APP_NAMESPACE --timeout=5m
```

- Get the route and open it in a browser. The load generator also drives traffic on its own.

```bash
oc get route frontend -n $APP_NAMESPACE -o jsonpath='https://{.spec.host}{"\n"}'
```

Use `overlays/no-loadgenerator` instead if you want a quiet cluster for baseline measurements —
but note that with no traffic there is nothing to trace, flow or graph.

### Enable tracing for the workload

The vendored `v0.10.6` release manifest ships **no** tracing configuration — upstream keeps it in a
separate kustomize component. The services read two environment variables, and instrumentation
stays dormant until both are set:

| variable | value |
|---|---|
| `ENABLE_TRACING` | `1` — switches instrumentation on |
| `COLLECTOR_SERVICE_ADDR` | host:port of an OTLP/gRPC endpoint |
| `OTEL_SERVICE_NAME` | the name the service reports itself as |

> **Why `OTEL_SERVICE_NAME` is required.** The Go services (`frontend`, `checkoutservice`,
> `productcatalogservice`) build their tracer provider without `WithResource()`, so the SDK falls
> back to `resource.Default()`, whose default detector reports `unknown_service:<executable>`.
> `frontend` and `productcatalogservice` both ship a binary named `server`, so without this variable
> they **collapse into a single `unknown_service:server` entry** in the Tempo service list and
> `frontend` appears to be missing entirely. The Python services (`emailservice`,
> `recommendationservice`) report a bare `unknown_service`. Only the Node services
> (`currencyservice`, `paymentservice`) hardcode a fallback name, which is why those two look
> correct without it.

The `tracing` overlay applied above sets both, on the seven services that carry OpenTelemetry
instrumentation in this release: `frontend`, `checkoutservice`, `currencyservice`, `emailservice`,
`paymentservice`, `productcatalogservice` and `recommendationservice`. The remaining workloads —
`adservice`, `cartservice`, `shippingservice`, `redis-cart` and `loadgenerator` — are not
instrumented upstream and are deliberately left alone.

The overlay points at `otel-collector.tracing-system.svc.cluster.local:4317`, the collector built
in [Create the OpenTelemetryCollector](#create-the-opentelemetrycollector). If your collector has a
different name or namespace, edit
[`overlays/tracing/kustomization.yaml`](../test-workloads/online-boutique/overlays/tracing/kustomization.yaml)
before applying.

- Confirm the variables landed on a service.

```bash
oc set env deployment/frontend -n $APP_NAMESPACE --list | grep -E 'ENABLE_TRACING|COLLECTOR|OTEL_SERVICE_NAME'
```

- If the application was already running without tracing, re-apply the overlay and the Deployments
  roll out with the new environment.

```bash
oc apply -k $APP_DIR/overlays/tracing
```

- Wait for the rollouts, then confirm the collector is receiving spans.

```bash
oc rollout status deployment/frontend -n $APP_NAMESPACE --timeout=5m
```

```bash
oc logs -n $TRACING_NAMESPACE -l app.kubernetes.io/component=opentelemetry-collector --tail=30
```

- View the traces in the web console under **Observe → Traces**: select the `tempo` TempoStack, the
  `dev` tenant, and filter by service name. All seven should appear under their own names; any
  `unknown_service` entry means `OTEL_SERVICE_NAME` did not reach that pod. `frontend` is the entry
  point, and a checkout will show
  a span tree fanning out to `checkoutservice`, `productcatalogservice`, `currencyservice`,
  `paymentservice` and `emailservice`. `shippingservice`, `cartservice` and `adservice` are called
  too but produce no spans — they carry no instrumentation, which the next subsection fixes for
  `adservice`.

The instrumentation emits **traces only**. It exposes no Prometheus endpoint of its own, which is
why the metrics sections below come from either the platform (cAdvisor / kube-state-metrics) or
from spans (the spanmetrics connector).

### Reading a trace

A trace list entry looks like this — a root span, one badge per service with its span count, the
total, and the wall-clock duration:

```
frontend: GET
  1 adservice   2 currencyservice   12 frontend   7 productcatalogservice   2 recommendationservice
  24 spans      13ms
```

- **The badge counts sum to the total** (1+2+12+7+2 = 24). One HTTP request to `frontend` fanned out
  into 24 spans.
- **Each remote call produces two spans** — a client span on the caller and a server span on the
  callee — so the count roughly doubles per hop. `frontend`'s 12 is one server span for the inbound
  request plus one client span per outbound gRPC call.
- **A service can be called twice in one trace.** `productcatalogservice` shows 7 because both
  `frontend` and `recommendationservice` call it; resolving recommendations triggers a second wave.
- **Root span names are generic.** The Go HTTP instrumentation names spans by method, and upstream
  adds no route templating, so every page render appears as `frontend: GET`. Identify the flow from
  the services involved, not the name.

Which flow you are looking at follows from the badges:

| Services present | Flow |
|---|---|
| `productcatalogservice`, `currencyservice`, `adservice`, `recommendationservice` | Home or product page render |
| `checkoutservice`, `paymentservice`, `emailservice`, `shippingservice`, `cartservice` | Order placement |

To find an order rather than a page view, filter the service to `checkoutservice` or search for the
span named `hipstershop.CheckoutService/PlaceOrder`. Those traces are much larger and slower, since
checkout calls cart, shipping, payment and email in sequence.

TraceQL queries that are useful against this workload:

```traceql
{ resource.service.name = "checkoutservice" && span:name = "hipstershop.CheckoutService/PlaceOrder" }
```

```traceql
{ resource.service.name = "adservice" }
```

```traceql
{ trace:duration > 100ms }
```

```traceql
{ span:status = error }
```

> **Scope the attribute correctly.** `service.name` is a *resource* attribute, so it is
> `resource.service.name`; span-level attributes use the `span.` prefix. Querying `span.service.name`
> returns nothing at all rather than an error, which is the most common reason a TraceQL query looks
> broken.

> **A missing service usually means missing instrumentation, not a missing call.** `cartservice` and
> `shippingservice` are called on these paths but never appear as badges: only the caller's client
> span exists, with nothing on the other end. Conversely, once `adservice` has been auto-instrumented
> it starts appearing — a single server span from the injected agent, nested under the `frontend`
> client span that was already there.

### Worked example: an order placement

Open a `checkoutservice` trace and the waterfall looks like this — a `frontend: POST` root of 27.5ms
containing a serial chain inside `checkoutservice`:

```
frontend: POST                                              27.5ms
└─ frontend: CheckoutService/PlaceOrder                     19.11ms   (client)
   └─ checkoutservice: CheckoutService/PlaceOrder           17.78ms   (server)
      ├─ checkoutservice: CartService/GetCart                2.45ms   ← no child
      ├─ checkoutservice: ProductCatalogService/GetProduct   1.86ms
      │  └─ productcatalogservice: GetProduct                  45us
      ├─ checkoutservice: ProductCatalogService/GetProduct     329us
      │  └─ productcatalogservice: GetProduct                   28us
      ├─ checkoutservice: ProductCatalogService/GetProduct     275us
      │  └─ productcatalogservice: GetProduct                   45us
      ├─ checkoutservice: ShippingService/GetQuote           1.61ms   ← no child
      ├─ checkoutservice: PaymentService/Charge              2.33ms   ← no child
      ├─ checkoutservice: ShippingService/ShipOrder            417us   ← no child
      ├─ checkoutservice: CartService/EmptyCart              1.41ms   ← no child
      └─ checkoutservice: EmailService/SendOrderConfirmation 2.65ms
         └─ emailservice: SendOrderConfirmation                240us
└─ frontend: RecommendationService/ListRecommendations       4.02ms
   └─ recommendationservice: ListRecommendations             2.42ms
      └─ recommendationservice: ProductCatalogService/ListProducts  1.99ms
         └─ productcatalogservice: ListProducts                 97us
└─ frontend: ProductCatalogService/GetProduct  (x3)      583/363/269us
```

Four readings that generalise to any application:

1. **The work is serial, not parallel.** Every child starts after the previous one ends, so the
   nine calls add up rather than overlap. Shipping quote, payment and email plausibly could run
   concurrently — the trace both reveals that and quantifies the prize (~6.6ms of the 17.78ms).
   No metric can show this; it is purely a property of the span timings.
2. **An N+1 pattern.** `GetProduct` is called once per cart item instead of being batched. The first
   costs 1.86ms and the next two 329µs and 275µs — that decay is connection setup being paid once,
   visible only because each call has its own span.
3. **Client spans dwarf server spans.** `GetProduct` is 1.86ms at the caller and 45µs at the callee.
   The 40× gap is network, serialization and client-side overhead: the latency lives *between* the
   services, not inside `productcatalogservice`. Optimising the callee here would achieve nothing.
4. **Childless spans are instrumentation gaps, and they are expensive.** `GetCart`, `GetQuote`,
   `ShipOrder` and `EmptyCart` total about 5.9ms — a third of `PlaceOrder` — and are completely
   opaque, because `cartservice` and `shippingservice` carry no instrumentation. This is the
   strongest argument for the `Instrumentation` CR: `cartservice` is .NET, so
   `instrumentation.opentelemetry.io/inject-dotnet` would light up the largest remaining blind spot.

> **A childless span for a service you *did* instrument means broken context propagation.**
> `PaymentService/Charge` has no child even though `paymentservice` is one of the seven and does
> appear in the Tempo service list. It is emitting spans, but they are not nesting — most likely its
> SDK is not extracting the inbound `traceparent`, so each one starts a separate trace. Distinguish
> the two cases by searching Tempo for that service: single-span traces with no parent mean
> propagation, not instrumentation, is the problem.

```bash
oc set env deployment/paymentservice -n $APP_NAMESPACE --list | grep -E 'ENABLE_TRACING|OTEL|COLLECTOR'
```

### Auto-instrument a service with the Instrumentation CR

Nothing so far has used an `Instrumentation` custom resource, and that is correct: the seven
services above ship the OpenTelemetry SDK compiled in, so they only needed configuring. The
`Instrumentation` CR solves the opposite problem — adding telemetry to an application whose code you
cannot or do not want to change. The operator injects an init container that copies a language agent
into a shared volume, then sets the runtime's agent hook (`JAVA_TOOL_OPTIONS`, `PYTHONPATH`,
`DOTNET_STARTUP_HOOKS`, …) on the application container.

Do **not** apply it to the seven already-instrumented services — they would be instrumented twice.

Online Boutique is a good place to demonstrate it precisely because four of its services carry no
instrumentation at all: `adservice` (Java), `cartservice` (.NET), `shippingservice` (Go) and
`loadgenerator` (Python). They are the blind spots in the traces you just looked at — `frontend`
records an outgoing call to `adservice`, but nothing records the server side of it.

`adservice` is the best demonstration: it is Java, so the most mature agent applies; it is called by
`frontend` on every home and product page, so traffic is continuous; and because `frontend` already
propagates W3C trace context on that gRPC call, the injected agent's spans **join the existing
trace** rather than starting a new one. That is the point worth showing — a service with no code
change becoming part of a distributed trace.

- Create the `Instrumentation` CR in the application namespace. An annotation value of `"true"`
  makes the operator look for a CR in the pod's own namespace.

```bash
cat <<EOF > instrumentation.yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: online-boutique
  namespace: $APP_NAMESPACE
spec:
  exporter:
    # The injected agents default to OTLP over HTTP, which is port 4318 on the
    # collector, not the 4317 the compiled-in SDKs use.
    endpoint: http://otel-collector.$TRACING_NAMESPACE.svc.cluster.local:4318
  propagators:
    - tracecontext
    - baggage
  sampler:
    type: parentbased_traceidratio
    argument: "1"
  env:
    # The agent exports traces, metrics AND logs by default. The collector built
    # earlier only serves traces on its OTLP HTTP receiver, so the other two
    # signals would POST to /v1/metrics and /v1/logs and get a 404 every few
    # seconds. Turn off what nothing is listening for.
    - name: OTEL_LOGS_EXPORTER
      value: none
    - name: OTEL_METRICS_EXPORTER
      value: none
EOF
```

```bash
oc apply -f instrumentation.yaml
```

> **What the 404s look like** if you leave them on — harmless `WARN`s, but they repeat every couple
> of seconds and drown the container log:
>
> ```
> WARN io.opentelemetry.exporter.internal.http.HttpExporter - Failed to export logs.
> Server responded with HTTP status code 404. HTTP status message: Not Found
> ```
>
> Container stdout is already collected into Loki by the `ClusterLogForwarder`, so OTLP logs would
> be a duplicate path. Metrics are the more interesting of the two — see below if you want the JVM
> metrics the agent produces.

- *Optional:* to keep the agent's metrics instead of discarding them — JVM heap, GC, thread counts
  and gRPC server metrics — drop `OTEL_METRICS_EXPORTER` from the CR above and add the OTLP receiver
  to the collector's metrics pipeline, so they reach the same Prometheus exporter as the spanmetrics
  output.

```yaml
        metrics:
          receivers: [spanmetrics, otlp]
          processors: [memory_limiter, batch]
          exporters: [prometheus]
```

- Give `adservice` room to start first. Its probes are tuned for a plain JVM: `timeoutSeconds` is
  unset, so it defaults to **1 second**, and the CPU limit is `300m`. Adding the agent makes startup
  much slower — it rewrites bytecode as classes load, which is CPU-bound — and the container is then
  killed by the liveness probe before it can serve gRPC, restarting forever:

```
Liveness probe failed: timeout: failed to connect service "10.129.2.78:9555" within 1s: context deadline exceeded
Container server failed liveness probe, will be restarted
```

  A `startupProbe` is the right fix: liveness and readiness are suspended until it first succeeds,
  so slow startup no longer counts as failure, while the steady-state probes stay strict. Raising
  the CPU limit matters as much — most of the extra startup time is class transformation.

```bash
oc patch deployment adservice -n $APP_NAMESPACE --type=strategic -p '{
  "spec": {"template": {"spec": {"containers": [{
    "name": "server",
    "resources": {
      "requests": {"cpu": "300m", "memory": "300Mi"},
      "limits":   {"cpu": "1",    "memory": "512Mi"}
    },
    "startupProbe":   {"grpc": {"port": 9555}, "periodSeconds": 10, "failureThreshold": 30},
    "readinessProbe": {"grpc": {"port": 9555}, "periodSeconds": 15, "timeoutSeconds": 5},
    "livenessProbe":  {"grpc": {"port": 9555}, "periodSeconds": 15, "timeoutSeconds": 5}
  }]}}}
}'
```

  `failureThreshold: 30` at `periodSeconds: 10` allows up to five minutes to start — generous, but
  it costs nothing once the container is up.

- Annotate the `adservice` pod template. The annotation goes on the **pod template**, not the
  Deployment's own metadata, and applying it triggers a rollout.

```bash
oc patch deployment adservice -n $APP_NAMESPACE --type=merge -p '{
  "spec": {"template": {"metadata": {"annotations": {
    "instrumentation.opentelemetry.io/inject-java": "true"
  }}}}
}'
```

- Confirm the operator injected the agent. A successful injection adds an init container and sets
  `JAVA_TOOL_OPTIONS` on the application container.

```bash
oc get pod -n $APP_NAMESPACE -l app=adservice \
  -o jsonpath='{.items[0].spec.initContainers[*].name}{"\n"}'
```

```bash
oc set env deployment/adservice -n $APP_NAMESPACE --list | grep JAVA_TOOL_OPTIONS
```

- Give it a minute of traffic, then look at **Observe → Traces** again. `adservice` now appears in
  the service list, and opening a `frontend` trace shows an `adservice` span nested under the
  frontend call rather than as a separate trace — that nesting is the trace context propagating from
  an SDK-instrumented service into an auto-instrumented one.

### Notes and limits

- **Go is impractical here.** Go auto-instrumentation is an eBPF sidecar, not an init container, and
  the pod must run with `privileged: true` and `runAsUser: 0`. That conflicts with `restricted-v2`,
  so instrumenting `shippingservice` would mean granting the workload a privileged SCC — the
  opposite of what the base patch achieves. It also does not support multi-container pods.
- **`cartservice` (.NET)** is the natural second demo, using
  `instrumentation.opentelemetry.io/inject-dotnet: "true"` against the same CR.
- **Multi-container pods** need the container named explicitly:
  `instrumentation.opentelemetry.io/java-container-names: "server"`.
- **Probe budgets are the usual failure, not permissions.** If the new pod sits at `0/1 Running`
  with climbing restarts, read the events before anything else — a liveness timeout means the
  container started and was too slow, which the `startupProbe` above fixes. Every container in this
  fixture also sets `readOnlyRootFilesystem: true`; the agent itself is mounted on a writable
  `emptyDir` so that is normally fine, but if the logs show a write or permission error rather than
  a probe timeout, mount an `emptyDir` at `/tmp`.

```bash
oc describe pod -n $APP_NAMESPACE -l app=adservice | tail -20
```

```bash
oc logs -n $APP_NAMESPACE -l app=adservice --tail=40
```

- **Budget for the overhead.** The agent costs startup time and memory in every language. Any
  workload you auto-instrument may need its probes and limits revisited, exactly as `adservice` did
  — this is a property of auto-instrumentation, not of this fixture.

- **To undo the injection**, remove the annotation; the next rollout drops the init container.

```bash
oc patch deployment adservice -n $APP_NAMESPACE --type=json \
  -p '[{"op":"remove","path":"/spec/template/metadata/annotations/instrumentation.opentelemetry.io~1inject-java"}]'
```

### Analyze the application logs

Container stdout/stderr is already being collected — the `ClusterLogForwarder` created earlier
forwards the `application` input for every namespace to `logging-loki`.

- In the console, go to **Observe → Logs**, then query by namespace.

```logql
{ kubernetes_namespace_name="online-boutique" }
```

- Narrow to one service and grep for errors.

> **Stream labels are not the same as record fields.** Loki indexes only a small fixed set as stream
> labels — namespace, pod, container, log type — and those are the only names valid inside `{}`. The
> record *body* carries far more, including `kubernetes.labels.app`, but putting
> `kubernetes_labels_app="adservice"` in the selector matches nothing, silently. Either select on
> `kubernetes_pod_name`, or parse the body first and filter on the result, which flattens nested keys
> with underscores:
>
> ```logql
> { kubernetes_namespace_name="online-boutique" } | json | kubernetes_labels_app="adservice"
> ```

```logql
{ kubernetes_namespace_name="online-boutique", kubernetes_pod_name=~"frontend-.*" } |= "error"
```

- If a selector returns nothing, list what is actually indexed before guessing at names. In the
  console the Logs page offers the available labels in its dropdowns; from the CLI, see the
  port-forward command in the data-model note below.

- Rate of log lines per container, to spot a service that has started complaining.

```logql
sum by (kubernetes_container_name) (
  rate({ kubernetes_namespace_name="online-boutique" }[5m])
)
```

> **Label names depend on the data model.** The `ClusterLogForwarder` above writes the default ViaQ
> model, whose stream labels are `kubernetes_namespace_name`, `kubernetes_container_name` and so on.
> The `UIPlugin` created in [Configure the UIPlugin for logging](#configure-the-uiplugin-for-logging)
> sets `schema: otel`, which tells the console to expect the OpenTelemetry names
> (`k8s_namespace_name`, `k8s_container_name`). If the console's namespace dropdown comes up empty,
> that mismatch is why — either set the UIPlugin to `schema: viaq`, or switch the forwarder output to
> the OTel data model. Check what is actually in Loki with:

```bash
oc port-forward -n openshift-logging svc/logging-loki-query-frontend-http 3100:3100 &
```

```bash
curl -sG -H 'X-Scope-OrgID: application' http://localhost:3100/loki/api/v1/labels | head -c 500; echo
```

  Stop the tunnel with `kill %1` when done. The `X-Scope-OrgID` header is required because you are
  bypassing the gateway that normally supplies the tenant.

- The same query from the CLI, without the console.

```bash
oc -n $APP_NAMESPACE logs -l app=frontend --tail=20
```

### How OpenTelemetry handles logs, and how that differs

Nothing in this document collects logs through OpenTelemetry — the `Instrumentation` CR explicitly
sets `OTEL_LOGS_EXPORTER: none`, because the collector has no logs pipeline and the agent's log
exports were returning 404. That is a deliberate choice, not an omission, and it is worth
understanding what is being given up.

**The two paths are genuinely different mechanisms:**

| | OpenShift Logging | OpenTelemetry |
|---|---|---|
| What it reads | Container stdout/stderr from `/var/log/pods` on each node | Log records emitted by the application's own logging framework, in process |
| How | A Vector DaemonSet tails files, adds Kubernetes metadata | The SDK or agent bridges log4j/logback/etc. and pushes OTLP |
| Application changes | None — works for every pod, instrumented or not | Requires the SDK or an injected agent |
| Coverage | Everything, including crashed containers and infrastructure | Only instrumented applications, only while running |
| Trace correlation | Only if the app prints trace IDs into the text itself | Automatic — `TraceId` and `SpanId` are fields on the record |

The one thing OpenTelemetry adds is the last row, and it is the whole point. A log record emitted
inside an active span carries that span's identity as **structured fields**, so you can pivot from a
slow trace directly to the log lines written during it. Vector cannot do this, because by the time it
reads the line from disk the trace context is gone — it only sees text.

Online Boutique illustrates the gap neatly. `adservice` logs JSON via log4j2 and *tries* to include
trace context:

```json
{"level":"INFO","message":"Ad Service started, listening on 9555",
 "logging.googleapis.com/trace":"${ctx:traceId}"}
```

That `${ctx:traceId}` placeholder is never substituted — it needs a context provider the image does
not wire up — so the field arrives in Loki as the literal string. The OpenTelemetry log bridge
attaches the real trace ID to the record instead of relying on the app's log pattern.

**Four architectures, in increasing order of change:**

1. **What this document does.** Vector tails stdout into LokiStack; OTLP logs disabled. Complete
   coverage, no trace correlation. For most clusters this is the right default.
2. **Application logs over OTLP** — the agent bridges the logging framework and pushes records to
   the collector, which routes them onward. Adds trace correlation for instrumented services only.
   Demonstrated below.
3. **The collector as the log agent** — run a collector DaemonSet with the `filelog` receiver
   tailing `/var/log/pods`. This does the same job as Vector, in the same way, and is the path for
   consolidating on a single collection agent. It replaces OpenShift Logging rather than adding to
   it.
4. **`ClusterLogForwarder` with an `otlp` output** — keep Vector doing the collecting, but forward
   in OTLP to a collector or any OTLP backend. This is the convergence path, and note that the OTLP
   output type is a **Technology Preview** feature.

> **Beware double-counting.** In option 2 the application still writes to stdout, so Vector keeps
> collecting the same lines. The same message lands in Loki twice by two routes, with different
> metadata. Either accept the duplication for the correlation benefit, or stop the app writing to
> stdout — do not silently ship both and then trust log-volume metrics.

### Demo: collecting and correlating `adservice` logs

`adservice` is the ideal subject. It logs at INFO on **every** request:

```java
logger.info("received ad request (context_words=" + req.getContextKeysList() + ")");
```

That line is written *inside* the gRPC server span the injected Java agent created, so the emitted
record carries that span's identity. The load generator calls `adservice` on every page render, so
there is a continuous supply without scripting anything.

This demo routes those records to the collector's `debug` exporter and reads them from the
collector's own output — no log store is reconfigured, so nothing downstream can break.

- **1. Let the agent export logs again.** The `Instrumentation` CR disables them by default; keep
  metrics off and drop only the logs override.

```bash
oc patch instrumentation online-boutique -n $APP_NAMESPACE --type=merge -p '{
  "spec": {"env": [{"name": "OTEL_METRICS_EXPORTER", "value": "none"}]}
}'
```

- **2. Give the collector a logs pipeline**, so `/v1/logs` stops returning 404. This is what is being
  added — the `resource` processor exists to make the processing step visible, since every record
  gains a `cluster` attribute on its way through:

```yaml
    processors:
      resource/demo:
        attributes:
          - key: cluster
            value: lab
            action: insert
    exporters:
      debug:
        verbosity: detailed
    service:
      pipelines:
        logs:
          receivers: [otlp]
          processors: [memory_limiter, resource/demo, batch]
          exporters: [debug]
```

  A merge patch adds those keys without disturbing the existing traces and metrics pipelines —
  RFC 7386 merges maps recursively, and none of the arrays already in the config are touched.

```bash
oc patch opentelemetrycollector otel -n $TRACING_NAMESPACE --type=merge -p '{
  "spec": {
    "config": {
      "processors": {
        "resource/demo": {
          "attributes": [{"key": "cluster", "value": "lab", "action": "insert"}]
        }
      },
      "exporters": {
        "debug": {"verbosity": "detailed"}
      },
      "service": {
        "pipelines": {
          "logs": {
            "receivers": ["otlp"],
            "processors": ["memory_limiter", "resource/demo", "batch"],
            "exporters": ["debug"]
          }
        }
      }
    }
  }
}'
```

- Confirm all three pipelines survived the patch, then wait for the operator to roll the collector.

```bash
oc get opentelemetrycollector otel -n $TRACING_NAMESPACE \
  -o jsonpath='{.spec.config.service.pipelines}{"\n"}'
```

```bash
oc rollout status deployment/otel-collector -n $TRACING_NAMESPACE --timeout=3m
```

- **3. Restart `adservice`.** The `Instrumentation` CR is read only at pod admission, so a running
  pod will not pick up the change.

```bash
oc rollout restart deployment/adservice -n $APP_NAMESPACE
```

```bash
oc rollout status deployment/adservice -n $APP_NAMESPACE --timeout=6m
```

- **4. Read a record.** Each `LogRecord` shows the body, the attributes the pipeline added, and the
  trace identity.

```bash
oc logs -n $TRACING_NAMESPACE deploy/otel-collector --tail=500 \
  | grep -B6 -A20 'received ad request' | head -40
```

  This reads the **collector's** stdout, not `adservice`'s. The records travel `adservice` → OTLP
  over the network → the collector's `logs` pipeline → the `debug` exporter, which prints them to
  the collector's own output. Only `adservice` appears: the other six services configure trace
  providers but no log provider, so the Java agent's log bridge is the sole source feeding this
  pipeline.

  For a live demo, follow the stream and print just the body and its trace identity. The
  `--line-buffered` matters — without it `grep` buffers in blocks and the output appears to stall:

```bash
oc logs -n $TRACING_NAMESPACE deploy/otel-collector -f \
  | grep --line-buffered -E 'Body: Str\(received ad request|^Trace ID:|^Span ID:'
```

> **The debug output is itself collected.** The collector's stdout is ordinary container output, so
> Vector ships it to Loki like anything else. While `verbosity: detailed` is on, every `adservice`
> line reaches Loki twice — once from `adservice`, once inside the collector's debug output. Harmless
> for a demo, confusing on a shared cluster, and the main reason to revert it afterwards.

  The output looks like this — note `cluster: Str(lab)` inserted by the processor, and the non-zero
  `Trace ID` / `Span ID`:

```
LogRecord #0
Body: Str(received ad request (context_words=[binoculars]))
SeverityText: INFO
Attributes:
     -> cluster: Str(lab)
     -> thread.name: Str(grpc-default-executor-1)
Trace ID: 22b13f9e11b2c4d953241d477ad81470
Span ID: 4d953241d477ad81
```

- **5. Prove the correlation.** Copy that `Trace ID` and open it in **Observe → Traces**. The trace
  that opens is the one whose `adservice` span produced this exact log line — you can see the request
  it belonged to, which service called it, and how long it took.

  Two ways to get there. The **Trace ID** lookup field in the trace search is not TraceQL; it calls
  `GET /api/traces/<id>` and works on every Tempo version. Or query for it in TraceQL, where
  `trace:id` is an intrinsic and the hex string must be quoted:

```traceql
{ trace:id = "22b13f9e11b2c4d953241d477ad81470" }
```

  The `trace:`- and `span:`-scoped intrinsics are a relatively recent addition, so use the ID lookup
  field instead if your TempoStack rejects that syntax.

```bash
oc logs -n $TRACING_NAMESPACE deploy/otel-collector --tail=500 \
  | grep -A12 'received ad request' | grep 'Trace ID' | tail -1
```

> **If the output is empty**, one of the three setup steps did not take. In order: the
> `Instrumentation` CR must no longer set `OTEL_LOGS_EXPORTER: none`; the collector must have a
> `logs` pipeline, or `/v1/logs` still returns 404; and `adservice` must have been restarted, since
> the CR is read only at pod admission and a running pod ignores changes to it.

### What the demo actually proves

Compare the same log line arriving by the two paths. Query it in Loki, as collected by Vector:

```logql
{ kubernetes_namespace_name="online-boutique", kubernetes_pod_name=~"adservice-.*" } |= "received ad request"
```

The Loki copy contains this, because `adservice`'s log4j2 layout declares trace fields that its
image never wires up a context provider for:

```json
"logging.googleapis.com/trace":"${ctx:traceId}"
```

Search for the placeholder itself — every match is a line where the application tried to record a
trace ID and failed:

```logql
{ kubernetes_namespace_name="online-boutique", kubernetes_pod_name=~"adservice-.*" } |= "ctx:traceId"
```

Note also that the message arrives double-encoded: the collected record's `message` field is a JSON
string containing log4j2's own JSON. Unwrap it to read just the application's text:

```logql
{ kubernetes_namespace_name="online-boutique", kubernetes_pod_name=~"adservice-.*" } |= "received ad request" | json | line_format "{{ .message }}"
```

An unsubstituted placeholder. The same line through OpenTelemetry carries
`Trace ID: 22b13f9e...` as a first-class field on the record — because the agent read it from the
active span in-process, rather than hoping the application had printed it into the text.

That is the entire difference, and it is why the two paths coexist rather than compete:

| | Vector → Loki | Agent → OTLP → collector |
|---|---|---|
| Gets the line | Always, from stdout on disk | Only while the app runs and is instrumented |
| Trace identity | Whatever the app printed — here, a broken placeholder | Read from the live span context |
| Best for | Complete retention, searching all workloads | Pivoting from a slow trace to its log lines |

### Where these logs actually go

Nowhere, in the demo as written. `debug` is a terminal sink: it renders each record to the
collector's stdout and that is the end of the pipeline. There is no store behind it and nothing to
query. That is fine for showing *what a record contains*, but not for using it.

Three ways to put them somewhere visible, in ascending order of realism.

**1. Read the collector's stdout** — what the demo does. `oc logs`, no extra configuration.

**2. Let Vector collect the debug output — but it will not show correlation.** The collector's
stdout is ordinary container output, so Vector ships it to Loki with no extra configuration, and the
rendered lines are queryable:

```logql
{ kubernetes_namespace_name="tracing-system", kubernetes_container_name="otc-container" } |= "received ad request"
```

**This cannot demonstrate the correlation, and it is worth understanding why.** The `debug` exporter
renders each record as a multi-line block — `LogRecord`, `Body`, `Attributes`, `Trace ID`, `Span ID`
on separate lines. Vector is line-oriented and collects each line as its own Loki entry, so the block
is shredded: the `Body:` line and the `Trace ID:` line become two unrelated records with nothing
joining them. A query for the message text returns a record containing no trace ID, because that
line genuinely has none:

```json
"message":"Body: Str(received ad request (context_words=[hair, beauty]))"
```

The trace ID is in Loki, but as a separate entry that can only be tied back by timestamp adjacency:

```logql
{ kubernetes_namespace_name="tracing-system", kubernetes_container_name="otc-container" } |= "Trace ID:"
```

So use this only to confirm records are arriving. To *show* the correlation, read the collector's
stdout directly with `oc logs`, where the block stays intact — or use option 3, which is the only
one that makes the correlation queryable.

**3. Export to LokiStack over OTLP.** The only option that preserves the record. Ingested over OTLP
the log stays a single structured entry, with the trace ID in structured metadata rather than smeared
across lines of rendered text — which is what makes it queryable and joinable. Loki 3.0 added an OTLP
ingestion endpoint at `/otlp`, and the `openshift-logging` tenant mode applies a default attribute
mapping that turns OTel attributes into stream labels and structured metadata. LokiStack already meets the
prerequisite, which is storage schema `v13`.

Swap the `debug` exporter for `otlphttp`. Confirm the service name first — it varies with the
LokiStack resource name:

```bash
oc get svc -n openshift-logging | grep -E 'distributor|gateway'
```

```yaml
    exporters:
      otlphttp/loki:
        endpoint: http://logging-loki-distributor-http.openshift-logging.svc.cluster.local:3100/otlp
        headers:
          X-Scope-OrgID: application
    service:
      pipelines:
        logs:
          receivers: [otlp]
          processors: [memory_limiter, resource/demo, batch]
          exporters: [otlphttp/loki]
```

> **What about Kafka?** A `kafka` exporter preserves the correlation — with `otlp_proto` (the
> default) or `otlp_json` it serializes the whole `ExportLogsServiceRequest`, in which `trace_id` and
> `span_id` are fields on each `LogRecord`, so nothing is flattened to text or split by line. Avoid
> the `raw` encoding, which discards resource and record attributes. But Kafka is transport, not
> storage or a UI: you still need a consumer — usually a second collector with a `kafka` receiver
> exporting onward — so it moves the visualization question one hop downstream rather than answering
> it. Both the Kafka exporter and receiver are Technology Preview in the Red Hat build. Reach for it
> when you need buffering against a slow backend, fan-out to several consumers, or cross-cluster
> shipping — not to demonstrate correlation.

> **Two caveats.** Addressing the distributor directly bypasses the LokiStack gateway and therefore
> its authentication and tenant enforcement — acceptable in a lab, not in production, where you would
> send through the gateway with a bearer token and let it supply the tenant. I have not verified the
> gateway's OTLP path on this LokiStack version, so check it before relying on it. Second, this
> writes OTel-model records into the same `application` tenant that Vector fills with ViaQ-model
> records: one tenant, two label shapes, and the console's `UIPlugin` `schema` setting decides which
> it can filter on. Consider a separate tenant or LokiStack if that matters.

- **Revert when finished.** `verbosity: detailed` prints every record and will dominate the
  collector's own log volume.

```bash
oc patch instrumentation online-boutique -n $APP_NAMESPACE --type=merge -p '{
  "spec": {"env": [
    {"name": "OTEL_METRICS_EXPORTER", "value": "none"},
    {"name": "OTEL_LOGS_EXPORTER", "value": "none"}
  ]}
}'
```

- Remove the demo pipeline too, if you do not want to keep it. Note the `~1` — in a JSON *Patch*
  path, `/` inside a key must be escaped, unlike the merge patch above where `resource/demo` is just
  an ordinary map key.

```bash
oc patch opentelemetrycollector otel -n $TRACING_NAMESPACE --type=json -p '[
  {"op": "remove", "path": "/spec/config/service/pipelines/logs"},
  {"op": "remove", "path": "/spec/config/processors/resource~1demo"},
  {"op": "remove", "path": "/spec/config/exporters/debug"}
]'
```

  In a real deployment you would keep the logs pipeline and swap `debug` for an exporter pointing at
  a log store, so the correlation is queryable rather than only visible in the collector's output.
  In the console, the [Troubleshooting Panel](#optional-enable-the-troubleshooting-panel-uiplugin) is
  what consumes this correlation, pivoting between logs, traces, metrics and alerts.

### Observe the network flows

Online Boutique is an unusually good netobserv subject: 11 services on gRPC means a dense,
constantly-changing east-west call graph.

- In the console, go to **Observe → Network Traffic**. Set the time range to the last 15 minutes,
  then filter with `Namespace` = `online-boutique`. The **Topology** tab draws the service call
  graph; switch **Scope** to `Owner` to collapse pods into their Deployments.
- The **Traffic flows** tab lists individual flows — available only on the Loki-backed
  [Path B](#path-b-flowcollector-with-loki). On [Path A](#path-a-flowcollector-without-loki) the
  Overview and Topology tabs still work, from metrics alone.

The same data is queryable as Prometheus metrics, which works on both paths. Confirm the exact
label spelling for your operator version first — the flow labels are CamelCase.

```bash
THANOS=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
curl -sk -H "Authorization: Bearer $(oc whoami -t)" \
  "https://$THANOS/api/v1/label/__name__/values" | tr ',' '\n' | grep netobserv | head -20
```

- Ingress bytes per workload in the namespace.

```promql
sum by (DstK8S_OwnerName) (
  rate(netobserv_workload_ingress_bytes_total{DstK8S_Namespace="online-boutique"}[5m])
)
```

- Traffic crossing the namespace boundary — everything entering the app from outside it.

```promql
sum by (SrcK8S_Namespace) (
  rate(netobserv_workload_ingress_bytes_total{
    DstK8S_Namespace="online-boutique", SrcK8S_Namespace!="online-boutique"
  }[5m])
)
```

- Flow count, useful as a liveness check that the eBPF agent is still reporting.

```promql
sum(rate(netobserv_namespace_flows_total{DstK8S_Namespace="online-boutique"}[5m]))
```

### Metrics from native Prometheus

The application exposes no `/metrics` endpoint, but the platform monitoring stack already scrapes
cAdvisor and kube-state-metrics for every namespace, so per-container resource and health metrics
need no extra configuration. Query them under **Observe → Metrics**.

- CPU per pod.

```promql
sum by (pod) (
  rate(container_cpu_usage_seconds_total{namespace="online-boutique", container!=""}[5m])
)
```

- Working-set memory per pod, against the 1368 Mi the fixture requests in total.

```promql
sum by (pod) (
  container_memory_working_set_bytes{namespace="online-boutique", container!=""}
)
```

- Deployment health — any row below its desired count is a service that failed to roll out.

```promql
kube_deployment_status_replicas_available{namespace="online-boutique"}
  / kube_deployment_spec_replicas{namespace="online-boutique"}
```

- Container restarts, the fastest way to spot a crash-looping service.

```promql
sum by (pod) (kube_pod_container_status_restarts_total{namespace="online-boutique"})
```

- Network throughput per pod, straight from cAdvisor — a useful cross-check against the netobserv
  numbers above, which are measured independently by the eBPF agent.

```promql
sum by (pod) (
  rate(container_network_receive_bytes_total{namespace="online-boutique"}[5m])
)
```

### What metrics OpenTelemetry collects

Two distinct sets, and neither comes from the application itself:

| Source | Port | What it tells you |
|---|---|---|
| Collector internal telemetry | 8888 | Health of the pipeline — spans in, spans out, spans dropped |
| `spanmetrics` connector | 8889 | RED metrics (Rate, Errors, Duration) derived from the spans |

##### How this differs from what the platform already collects

These do not duplicate anything. The metric names are disjoint, and more importantly they describe
different layers.

It is worth being precise about one thing first: **user workload monitoring collects nothing on its
own.** It is a Prometheus instance that scrapes exactly what `ServiceMonitor` and `PodMonitor`
resources point it at. The metrics that appear for any namespace without you configuring anything —
`container_*`, `kube_*` — come from **platform** monitoring, which scrapes cAdvisor on each kubelet
and kube-state-metrics. The console shows both through the Thanos querier, which is why they look
like one dataset.

| Source | Collected by | Layer | Example |
|---|---|---|---|
| cAdvisor (kubelet) | platform monitoring | Resource consumption of a container | `container_cpu_usage_seconds_total` |
| kube-state-metrics | platform monitoring | State of an API object | `kube_deployment_status_replicas_available` |
| `spanmetrics` | UWM, via your ServiceMonitor | Request behaviour of a service | `traces_span_metrics_calls_total`, `traces_span_metrics_duration_milliseconds_bucket` |
| collector internal | UWM, via your ServiceMonitor | Health of the telemetry pipeline | `otelcol_exporter_send_failed_spans` |

The practical difference is what question each can answer:

- **cAdvisor / kube-state-metrics know nothing about what the application does.** They can tell you
  `frontend` burned 300m of CPU and restarted twice. They cannot tell you that checkout requests are
  failing, because a pod serving errors at 200 requests per second looks identical to one serving
  successes.
- **spanmetrics knows nothing about pods.** It can tell you `checkoutservice` is answering 12
  requests per second with a p95 of 400ms and a 3% error rate. It cannot tell you which pod, or
  whether the node is under memory pressure.

If Online Boutique exposed its own `/metrics` endpoint, you would point a `ServiceMonitor` at it and
UWM would scrape that directly — those would be genuine application metrics with no OpenTelemetry
involved. It does not, and that is exactly the gap spanmetrics fills: it manufactures
request-level metrics from trace data for an application that publishes none.

> **Joining the two.** By default the spanmetrics series carry `service_name`, `span_name`,
> `span_kind` and `status_code`, with no `pod` or `namespace` label, so they cannot be joined to
> `container_*` series in PromQL. The `resource_to_telemetry_conversion` setting on the Prometheus
> exporter promotes OTel resource attributes to labels — so if you also give each pod its Kubernetes
> identity, the labels appear and correlation becomes possible:
>
> ```yaml
> - name: OTEL_RESOURCE_ATTRIBUTES
>   value: "k8s.namespace.name=$(K8S_NAMESPACE),k8s.pod.name=$(K8S_POD)"
> ```
>
> with `K8S_NAMESPACE` and `K8S_POD` supplied from the downward API.

### How the pieces fit together

The most common misreading is that the collector *scrapes* Prometheus. It does not — the collector
**exposes** metrics and Prometheus **pulls** them. Data flows one way through the collector and is
then pulled out of it:

```
  online-boutique                  otel-collector (tracing-system)
  ┌──────────────┐                 ┌──────────────────────────────────────────┐
  │ frontend     │  OTLP/gRPC      │  receivers: otlp  :4317                  │
  │ checkoutsvc  │ ──── push ────► │        │                                 │
  │ … 7 services │   (traces)      │        ▼                                 │
  └──────────────┘                 │  traces pipeline ──► otlp exporter ──────┼──► Tempo
                                   │        │                                 │
                                   │        └──► spanmetrics connector        │
                                   │                    │                     │
                                   │                    ▼                     │
                                   │            metrics pipeline              │
                                   │                    │                     │
                                   │                    ▼                     │
                                   │        prometheus exporter  :8889 ◄──────┼── pull
                                   │        internal telemetry   :8888 ◄──────┼── pull
                                   └──────────────────────────────────────────┘
                                                                                   │
                                                     user workload monitoring ─────┘
                                                     (Prometheus, guided by ServiceMonitors)
```

Step by step:

1. **The seven instrumented services push traces** to the collector over OTLP/gRPC on port 4317.
   Nothing about metrics has happened yet.
2. **The traces pipeline forks.** Its exporters are `[otlp, spanmetrics]` — the same spans go to
   Tempo for storage *and* into the `spanmetrics` connector.
3. **The connector turns spans into metrics.** A connector is an exporter on one pipeline and a
   receiver on the next: it counts spans and records their durations, emitting `traces_span_metrics_calls_total` and
   `traces_span_metrics_duration_milliseconds_*`. This is why you get request-rate and latency metrics for an
   application that exposes no metrics of its own.
4. **The metrics pipeline ends at the `prometheus` exporter.** Despite the name this pushes nothing.
   It opens an HTTP listener on `0.0.0.0:8889` and serves `/metrics` in Prometheus text format, then
   waits. The collector's own health metrics are served separately on `:8888`.
5. **`spec.ports` publishes 8889** on the generated `otel-collector` Service, with the name
   `promexporter`. Without this the listener is reachable only inside the pod.
6. **Something has to pull.** Platform monitoring only scrapes `openshift-*` namespaces, so for a
   collector in `tracing-system` the scraper must be **user workload monitoring** — which is why it
   is enabled below. Enabling it starts a second Prometheus that is permitted to scrape user
   namespaces. On its own it still scrapes nothing.
7. **The `ServiceMonitor` is the instruction.** It tells that Prometheus *what* to scrape: match
   this Service by label, hit the port named `promexporter`, on this interval. Prometheus resolves
   the Service to its pod endpoints and scrapes `http://<pod-ip>:8889/metrics`. A second
   ServiceMonitor does the same for `:8888` via the `otel-collector-monitoring` Service the operator
   creates automatically.
8. **The series land in user workload Prometheus**, queryable from **Observe → Metrics** or the
   Thanos querier, which is where the PromQL further down runs.

So the three moving parts have distinct jobs, and all three are required:

| Piece | Job |
|---|---|
| `prometheus` **exporter** in the collector config | Opens the `/metrics` listener — the target |
| `spec.ports` on the collector CR | Publishes that port on the Service under a name |
| `ServiceMonitor` | Tells Prometheus to scrape that named port |
| User workload monitoring | Provides a Prometheus allowed to scrape user namespaces |

> **Exporter vs receiver.** The collector also has a `prometheus` *receiver*, which does the
> opposite — scrapes other `/metrics` endpoints and pulls them into a pipeline. That is not what is
> configured here. Same name, opposite direction; it is the usual source of confusion.

- Enable user workload monitoring.

```bash
cat <<EOF > cluster-monitoring-config.yaml
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
oc apply -f cluster-monitoring-config.yaml
```

```bash
oc -n openshift-user-workload-monitoring rollout status deployment/prometheus-operator --timeout=5m
```

### Add the spanmetrics connector

A connector sits between two pipelines: it consumes the trace pipeline as an exporter and feeds a
metrics pipeline as a receiver, turning spans into RED metrics without touching the application.
This replaces the collector created earlier — the trace pipeline is unchanged, with a metrics
pipeline added alongside it.

Note that the Prometheus **exporter** is a Technology Preview feature in the Red Hat build of
OpenTelemetry, while the `spanmetrics` connector is fully supported.

```bash
cat <<EOF > otel-collector-spanmetrics.yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel
  namespace: $TRACING_NAMESPACE
spec:
  mode: deployment
  serviceAccount: otel-collector
  ports:
  - name: promexporter
    port: 8889
    protocol: TCP
  config:
    extensions:
      bearertokenauth:
        filename: "/var/run/secrets/kubernetes.io/serviceaccount/token"
    receivers:
      otlp:
        protocols:
          grpc: {}
          http: {}
    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 50
        spike_limit_percentage: 30
      batch: {}
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
      otlp:
        endpoint: tempo-tempo-gateway.$TRACING_NAMESPACE.svc.cluster.local:8090
        tls:
          insecure: false
          ca_file: "/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt"
        auth:
          authenticator: bearertokenauth
        headers:
          X-Scope-OrgID: "$TEMPO_TENANT_NAME"
      prometheus:
        endpoint: "0.0.0.0:8889"
        resource_to_telemetry_conversion:
          enabled: true
    service:
      extensions: [bearertokenauth]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [otlp, spanmetrics]
        metrics:
          receivers: [spanmetrics]
          processors: [memory_limiter, batch]
          exporters: [prometheus]
EOF
```

```bash
oc apply -f otel-collector-spanmetrics.yaml
```

### Scrape the collector

The operator creates two Services: `otel-collector` for the receiver and exporter ports, and
`otel-collector-monitoring` for the collector's own telemetry on 8888.

```bash
cat <<EOF > otel-servicemonitors.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: otel-collector-internal
  namespace: $TRACING_NAMESPACE
spec:
  selector:
    matchLabels:
      operator.opentelemetry.io/collector-monitoring-service: "Exists"
  endpoints:
  - port: monitoring
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: otel-collector-spanmetrics
  namespace: $TRACING_NAMESPACE
spec:
  selector:
    matchLabels:
      operator.opentelemetry.io/collector-service-type: base
  endpoints:
  - port: promexporter
EOF
```

```bash
oc apply -f otel-servicemonitors.yaml
```

- The selector labels the operator puts on those Services vary between versions. Check what is
  actually there and adjust the ServiceMonitors to match.

```bash
oc get svc -n $TRACING_NAMESPACE --show-labels
```

- Confirm the exporter is producing metrics before relying on the names below — the spanmetrics
  metric names and units differ between collector versions.

  The easiest way is to ask Prometheus what it actually scraped from that job. Run this in
  **Observe → Metrics** — it lists every metric name on the endpoint, so there is no guessing:

```promql
group by (__name__) ({job="otel-collector"})
```

> **The names carry a `traces_span_metrics_` prefix.** The connector applies a default `namespace`
> of `traces.span.metrics`, so the series are `traces_span_metrics_calls_total` and
> `traces_span_metrics_duration_milliseconds_{bucket,count,sum}` — not the bare `calls_total` the
> upstream connector documentation shows. This default has changed between collector versions, so
> run the query above and use whatever it returns. To pin the short names instead, set an empty
> namespace on the connector:
>
> ```yaml
>     connectors:
>       spanmetrics:
>         namespace: ""
> ```

  If you would rather read the raw endpoint, the collector image is distroless and has no `curl`, so
  forward the port and query it from your workstation. The same works for port 8888.

```bash
oc port-forward -n $TRACING_NAMESPACE deploy/otel-collector 8889:8889 &
```

```bash
curl -s http://localhost:8889/metrics | grep -vE '^#' | cut -d'{' -f1 | sort -u
```

  Stop the tunnel with `kill %1` when done.

### Finding them in the console

Work down this list — each step tells you which of the four moving parts has failed, and stops you
hunting for a metric that was never scraped.

1. **Is the second Prometheus running?** Enabling user workload monitoring starts a separate stack.
   If these pods are absent, the ConfigMap edit did not take effect.

```bash
oc -n openshift-user-workload-monitoring get pods
```

2. **Is the target up?** In the console go to **Observe → Metrics** (Administrator perspective) and
   run:

```promql
up{namespace="tracing-system"}
```

   Two series with value `1` is what you want — one for `otel-collector` (the spanmetrics port) and
   one for `otel-collector-monitoring` (internal telemetry). The `job` label carries the Service
   name.

   - **No series at all** means Prometheus never discovered the target: the `ServiceMonitor`'s label
     selector does not match the Service. This is the most common failure, and it is silent. Compare
     them with `oc get svc -n tracing-system --show-labels` and adjust the selector.
   - **A series with value `0`** means it was discovered but the scrape failed — usually the port
     name in the `ServiceMonitor` does not match the name in `spec.ports`, or the exporter is not
     listening.

   **Observe → Targets** shows the same thing visually; filter it to the `tracing-system` namespace
   and look for a target ending in `/otel-collector-spanmetrics/0`.

3. **Are the series there?** Still under **Observe → Metrics**, start typing a metric name — the
   query field autocompletes from what Prometheus actually holds, which is itself a good check:

```promql
traces_span_metrics_calls_total
```

```promql
otelcol_exporter_sent_spans_total
```

   Nothing returned here while `up` is `1` means the scrape works but the collector is producing no
   data — for `traces_span_metrics_calls_total` that means no spans are reaching the spanmetrics connector, so go back
   and confirm traces are arriving in Tempo first.

4. **Then use the PromQL below.** Remember `traces_span_metrics_calls_total` is a counter, so a raw graph of it only
   ever climbs; wrap it in `rate()` to see request rate.

Two things that make metrics look missing when they are not:

- **Nothing appears for the first minute.** The default scrape interval is 30s, and spanmetrics only
  emits after its `metrics_flush_interval` (15s here) has passed with traffic flowing.
- **In the Developer perspective**, **Observe → Metrics** is scoped to the selected project. Select
  `tracing-system` there, or use the Administrator perspective, which queries across namespaces.

### The metrics you get

**Collector internal telemetry** (port 8888) — pipeline health, not application behaviour:

| Metric | Meaning |
|---|---|
| `otelcol_receiver_accepted_spans_total` | Spans accepted by the OTLP receiver |
| `otelcol_receiver_refused_spans_total` | Spans rejected — usually back-pressure from `memory_limiter`. Absent until the first rejection |
| `otelcol_exporter_sent_spans_total` | Spans successfully written to Tempo — increments only on success |
| `otelcol_exporter_sent_metric_points_total` | Metric points served by the `prometheus` exporter — proof the spanmetrics pipeline is flowing |
| `otelcol_exporter_send_failed_spans_total` | Failed exports. **Absent until the first failure** — see below |
| `otelcol_exporter_queue_size` | Depth of the export queue (a gauge, so no `_total`) |
| `otelcol_exporter_in_flight_requests` | Exports currently in flight (gauge) |
| `otelcol_processor_batch_batch_send_size_count` | Batches leaving the batch processor (a histogram: `_count`, `_sum`, `_bucket`) |

> **A missing failure counter is good news, not a broken query.** The collector's own metrics come
> from the OpenTelemetry SDK, which only exports a counter after it has been incremented at least
> once — unlike most Prometheus client libraries, which register counters at zero up front. So on a
> healthy collector `otelcol_exporter_send_failed_spans_total` does not exist at all, and the console
> autocomplete will not offer it. It appears the moment an export first fails.
>
> That makes `rate(otelcol_exporter_send_failed_spans_total[5m])` return "no datapoints" on a healthy
> system, which is indistinguishable from a typo. For a dashboard panel or an alert, give it a
> floor so the query is always defined:
>
> ```promql
> sum(rate(otelcol_exporter_send_failed_spans_total[5m])) or vector(0)
> ```
>
> The same applies to `otelcol_receiver_refused_spans_total`. To check export health positively
> instead, watch that `otelcol_exporter_sent_spans_total` keeps climbing and that
> `otelcol_exporter_queue_size` is not growing without bound.

> **Counters carry a `_total` suffix.** Prometheus appends it when converting OTLP counters, so the
> series is `otelcol_exporter_sent_spans_total`, not `otelcol_exporter_sent_spans`. Gauges such as
> `otelcol_exporter_queue_size` do not get one, and histograms expand into `_count` / `_sum` /
> `_bucket`. If a name returns nothing, type the stem into the console query field and let it
> autocomplete rather than guessing the suffix.

Useful labels on these series: `exporter` / `receiver` names which component, `server.address` and
`server.port` show where the exporter is sending (the Tempo gateway on 8090), and `pod` identifies
the collector replica.

**spanmetrics** (port 8889) — RED metrics derived from the spans, dimensioned by `service_name`,
`span_name`, `span_kind` and `status_code`, plus the `http.method` and `http.status_code`
dimensions added in the config above:

| Metric | Meaning |
|---|---|
| `traces_span_metrics_calls_total` | Counter of spans, i.e. request rate per service and operation |
| `traces_span_metrics_duration_milliseconds_bucket` | Latency histogram — feeds percentile queries |
| `traces_span_metrics_duration_milliseconds_count` / `_sum` | Histogram count and total, for computing averages |

- Request rate per service.

```promql
sum by (service_name) (rate(traces_span_metrics_calls_total[5m]))
```

- Error rate — the share of spans reporting a failed status.

```promql
sum by (service_name) (rate(traces_span_metrics_calls_total{status_code="STATUS_CODE_ERROR"}[5m]))
  / sum by (service_name) (rate(traces_span_metrics_calls_total[5m]))
```

- 95th percentile latency per service.

```promql
histogram_quantile(0.95,
  sum by (le, service_name) (rate(traces_span_metrics_duration_milliseconds_bucket[5m]))
)
```

- Slowest operations across the whole app, which is where Online Boutique's gRPC fan-out shows up.

```promql
topk(10, histogram_quantile(0.95,
  sum by (le, service_name, span_name) (rate(traces_span_metrics_duration_milliseconds_bucket[5m]))
))
```

This is the payoff of running spanmetrics next to Tempo: the metrics tell you *which* service
slowed down, and the trace view tells you *why*, for the same request.

### Tear down the workload

```bash
oc delete -k $APP_DIR/overlays/tracing
```

## Clean up

Delete the OpenShift resources before removing the AWS resources, otherwise the operators keep
writing to buckets that are being deleted.

```bash
oc delete -k test-workloads/online-boutique/overlays/default --ignore-not-found
oc delete flowcollector cluster --ignore-not-found
oc delete opentelemetrycollector otel -n $TRACING_NAMESPACE --ignore-not-found
oc delete tempostack tempo -n $TRACING_NAMESPACE --ignore-not-found
oc delete clusterlogforwarder instance -n openshift-logging --ignore-not-found
oc delete lokistack logging-loki -n openshift-logging --ignore-not-found
oc delete lokistack netobserv-loki -n ${NETOBSERV_LOKI_NAMESPACE:-$NETOBSERV_NAMESPACE} --ignore-not-found
```

Then remove the S3 buckets and the IAM users and policies created above. The `NETOBSERV_*` entries
only apply if you took Path B for network flows; unset variables are skipped.

```bash
for NAME in $LOKI_USERNAME $NETOBSERV_LOKI_USERNAME $TEMPO_USERNAME; do
  for KEY in $(aws iam list-access-keys --user-name $NAME --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    aws iam delete-access-key --user-name $NAME --access-key-id $KEY
  done
  aws iam detach-user-policy --user-name $NAME --policy-arn arn:aws:iam::$AWS_ACCOUNT_NUMBER:policy/$NAME
  aws iam delete-policy --policy-arn arn:aws:iam::$AWS_ACCOUNT_NUMBER:policy/$NAME
  aws iam delete-user --user-name $NAME
done
```

```bash
for BUCKET in $BUCKET_NAME $NETOBSERV_BUCKET_NAME $TEMPO_BUCKET_NAME; do
  aws s3 rb s3://$BUCKET --force
done
```

