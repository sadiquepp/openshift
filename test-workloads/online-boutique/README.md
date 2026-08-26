# Online Boutique — telemetry test workload

[GoogleCloudPlatform/microservices-demo](https://github.com/GoogleCloudPlatform/microservices-demo)
`v0.10.6`, vendored and patched to run on OpenShift.

This is the workload used by [`../../observability`](../../observability) to put real traffic
through a logging, network observability and distributed tracing stack. It is a **large, genuinely
distributed, stateless** application: no PersistentVolumeClaims anywhere, 11 services across 5
languages talking gRPC, plus a load generator that keeps traffic flowing on its own — so the
dashboards are never empty and you do not have to script traffic by hand.

| | |
|---|---|
| Services | 11 (+ load generator) |
| State | none — `redis-cart` uses `emptyDir` |
| Protocol | gRPC |
| Languages | Go, C#, Node, Python, Java |
| Images to mirror | 13 |
| Requests | 1.57 CPU / 1368 Mi |
| Instrumented for tracing | 7 of the 11 services |

## Deploy

Without tracing:

```bash
oc apply -k test-workloads/online-boutique/overlays/default
```

With OpenTelemetry tracing enabled:

```bash
oc apply -k test-workloads/online-boutique/overlays/tracing
```

```bash
oc get route frontend -n online-boutique -o jsonpath='https://{.spec.host}{"\n"}'
```

Tear down with `oc delete -k test-workloads/online-boutique/overlays/default`.

`oc` has kustomize built in — `oc apply -k` and `oc kustomize` both work with no extra binary
installed, so nothing here needs the standalone `kustomize` CLI.

## Deploying as a non-admin user

The workload itself needs **no** elevated privileges. The base patch strips upstream's
`runAsUser` / `runAsGroup` / `fsGroup`, so all 13 containers run with `runAsNonRoot: true`,
`readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false` and `capabilities: drop: [ALL]` —
exactly what `restricted-v2` admits, and `restricted-v2` is granted to `system:authenticated` by
default. There is no `hostNetwork`, no `hostPath`, and no privileged container anywhere.

The one thing that does need cluster-level rights is the `Namespace` object in `overlays/default`.
Even with `self-provisioner` a normal user cannot create a `Namespace` directly — that role grants
`create` on `projectrequests`, not `namespaces` — so `oc apply -k overlays/default` fails with:

```
Error from server (Forbidden): namespaces is forbidden: User "alice" cannot create resource
"namespaces" in API group "" at the cluster scope
```

Create the project the normal way instead, and render `base/`, which contains no `Namespace` and
pins no namespace on its objects:

```bash
oc new-project online-boutique
```

```bash
oc kustomize test-workloads/online-boutique/base | oc apply -n online-boutique -f -
```

The `tracing` overlay builds on `default`, so it carries the same `Namespace`. Rather than filter it
out of the rendered stream, set the two variables directly on the seven instrumented Deployments —
this is exactly what the overlay does, and the result is identical:

```bash
for SVC in frontend checkoutservice currencyservice emailservice \
           paymentservice productcatalogservice recommendationservice; do
  oc set env deployment/$SVC -n online-boutique \
    ENABLE_TRACING=1 \
    OTEL_SERVICE_NAME=$SVC \
    COLLECTOR_SERVICE_ADDR=otel-collector.tracing-system.svc.cluster.local:4317
done
```

If an admin creates the namespace for you once, up front, you can use `oc apply -k` normally from
then on and skip all of the above.

Everything else — Deployments, Services, ServiceAccounts and the Route — is namespace-scoped and
within a project `admin`'s or `edit`'s rights.

Note that this applies only to the workload. The observability stack it feeds
([`../../observability`](../../observability)) does need cluster-admin: Subscriptions, the
cluster-scoped `FlowCollector`, `UIPlugin`, console plugin registration and user workload monitoring
all require it.

## Layout

```
base/
  kubernetes-manifests.yaml   vendored verbatim from upstream v0.10.6
  kustomization.yaml          the OpenShift compatibility layer
  route.yaml                  replaces upstream's LoadBalancer Service
overlays/
  default/                    namespace + labels           <- start here
  tracing/                    default + OTLP tracing env vars
  no-loadgenerator/           default minus the traffic generator
```

## Why the base needs patching

**It does not deploy on OpenShift as shipped.** Upstream pins `runAsUser: 1000`,
`runAsGroup: 1000` and `fsGroup: 1000` on all 12 deployments. Under the default `restricted-v2` SCC
each namespace gets its own allocated UID range (e.g. `1000750000/10000`), so a hardcoded `1000`
falls outside it and admission rejects the pod:

```
unable to validate against any security context constraint
```

There is no upstream OpenShift kustomize component (checked against `kustomize/components` at
`v0.10.6`), so `base/kustomization.yaml` supplies that missing piece. It strips the three fields and
keeps `runAsNonRoot: true`. Dropping `runAsGroup` matters as much as `runAsUser`: OpenShift runs
containers with GID 0 and expects images to be group-writable, so forcing GID 1000 breaks that
assumption.

**The `frontend-external` LoadBalancer Service is deleted.** Upstream ships it for GKE; on a cluster
with no LB provider it sits in `<pending>` forever. `base/route.yaml` exposes the ClusterIP
`frontend` Service via an OpenShift Route instead, with no `host:` so the cluster's apps domain
supplies one. If you do have MetalLB and would rather use a real LoadBalancer, delete that patch
from `base/kustomization.yaml`.

Both patches are written as JSON 6902 `remove`/`delete`, so if a future upstream release drops these
fields the build **fails loudly** rather than silently no-opping.

## Tracing

The vendored release manifest ships **no** tracing configuration — upstream keeps it in a separate
`google-cloud-operations` kustomize component. Two environment variables switch it on, and the
instrumentation stays dormant until both are set:

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

`overlays/tracing` sets both on the seven services that carry OpenTelemetry instrumentation in this
release: `frontend`, `checkoutservice`, `currencyservice`, `emailservice`, `paymentservice`,
`productcatalogservice` and `recommendationservice`. The other workloads — `adservice`,
`cartservice`, `shippingservice`, `redis-cart` and `loadgenerator` — are not instrumented upstream
and are deliberately left alone.

The collector address defaults to `otel-collector.tracing-system.svc.cluster.local:4317`, which
is the `OpenTelemetryCollector` built in [`../../observability`](../../observability). Edit
`overlays/tracing/kustomization.yaml` if yours differs.

The instrumentation emits **traces only** — no service exposes a Prometheus endpoint. Metrics for
this workload come either from the platform (cAdvisor / kube-state-metrics) or are derived from
spans by the collector's `spanmetrics` connector; both are covered in the observability README.

## Load generator

`overlays/default` and `overlays/tracing` include it: continuous synthetic traffic through the whole
call graph, so traces, flows, metrics and autoscaling behaviour appear without you scripting
anything. It also burns CPU continuously and means the app is never idle — use
`overlays/no-loadgenerator` when measuring baseline usage or when you want a quiet cluster.

## Disconnected clusters

13 images, two of which come from Docker Hub (`redis:alpine`, `busybox:1.38.0@sha256:…`) — that
means anonymous pull-rate limits in CI and two extra registries to mirror.

Add them to the `additionalImages` list in your `ImageSetConfiguration` (see
[`../../disconnected`](../../disconnected)), then repoint them with an `images:` block in
`overlays/default/kustomization.yaml` — there is a commented stub there. Upstream also ships a
`container-images-registry` component that does the same job if you prefer.

## Refreshing to a newer upstream release

```bash
V=v0.10.7
curl -sfL "https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/$V/release/kubernetes-manifests.yaml" \
  -o test-workloads/online-boutique/base/kubernetes-manifests.yaml
```

```bash
oc kustomize test-workloads/online-boutique/overlays/tracing > /dev/null && echo ok
```

The manifest is vendored rather than referenced by URL so that `oc kustomize` works air-gapped
and the version cannot drift underneath you. If the build fails after a refresh, upstream changed
something the patches depend on — read the error before working around it.
