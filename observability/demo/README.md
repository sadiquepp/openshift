# Demoing the OpenShift observability stack

A walkthrough of a cluster built by [`../ansible`](../ansible), driven by the
Online Boutique test workload. Five parts, roughly 35 minutes end to end, each
one usable on its own.

The through-line: **one application, four signals, and the question each signal
can answer that the others cannot.** The last part is the interesting one — it
shows the single thing OpenTelemetry gives you that the platform's own log
pipeline structurally cannot.

## Contents
- [Before you start](#before-you-start)
- [The workload](#the-workload)
- [Part 1 — Logs](#part-1--logs)
- [Part 2 — Network flows](#part-2--network-flows)
- [Part 3 — Traces](#part-3--traces)
- [Part 4 — Metrics](#part-4--metrics)
- [Part 5 — Logs through OpenTelemetry, and why they are different](#part-5--logs-through-opentelemetry-and-why-they-are-different)
- [Closing the loop](#closing-the-loop)
- [Reverting](#reverting)

## Before you start

**Let it warm up.** Ten minutes of load generator traffic before you demo
anything. Loki needs to have flushed a chunk, the spanmetrics connector only
emits after its 15s flush interval, and Prometheus scrapes every 30s. A demo of
empty dashboards is worse than no demo.

**Use the Administrator perspective.** In the Developer perspective
**Observe → Metrics** is scoped to the selected project, which quietly hides
`tracing-system`.

**Check the four pages load before your audience arrives.** Each part below
opens a different one, and the console plugin bundles are cached client-side —
if you registered a plugin recently, hard-refresh once now rather than in front
of people.

**The CLI snippets need a logged-in `oc`**, unlike the automation, which talks
to the API directly and only ever uses `oc` to render kustomize locally. So if
your `~/.kube/config` is not already pointing at this cluster:

```bash
export KUBECONFIG=~/clusters/lab/auth/kubeconfig
```

Set these too:

```bash
export APP_NAMESPACE=online-boutique
export TRACING_NAMESPACE=tracing-system
```

**If you are demoing to non-admins**, they need three cluster roles to see any
of this: `netobserv-reader` (or `netobserv-metrics-reader` on Path A),
`tempostack-traces-reader`, and the usual namespace view access. The automation
grants them for anyone listed in `grant_users`. Cluster admins already pass
every one of these checks, which is exactly why this is easy to miss until the
first non-admin tries.

## The workload

[Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) —
11 stateless microservices in Go, C#, Node, Python and Java, talking gRPC, plus
a load generator that keeps traffic flowing on its own.

Open it:

```bash
oc get route frontend -n $APP_NAMESPACE -o jsonpath='https://{.spec.host}{"\n"}'
```

Click a product, add it to the cart, place an order. Say out loud that you are
generating the trace you will look at in Part 3 — the load generator is doing
the same thing continuously, but a demo lands better when the audience watched
the request happen.

What matters about this application for a demo:

- **A dense east-west call graph.** Eleven services on gRPC makes the topology
  view worth looking at, unlike a two-tier app.
- **Deliberately uneven instrumentation.** Seven services ship the OpenTelemetry
  SDK compiled in. Four do not: `adservice` (Java), `cartservice` (.NET),
  `shippingservice` (Go) and `loadgenerator` (Python). Those gaps are visible in
  the traces, and closing one of them without touching the code is Part 3's
  payoff.
- **It exposes no `/metrics` endpoint at all.** Which makes it the honest case
  for Part 4: every metric you will see is manufactured either by the platform
  or from spans.

## Part 1 — Logs

*≈5 minutes. **Observe → Logs**.*

**The claim: every container's stdout is already in Loki, with no application
change and no per-namespace configuration.** A Vector DaemonSet tails
`/var/log/pods` on every node and adds the Kubernetes metadata.

Start broad:

```logql
{ kubernetes_namespace_name="online-boutique" }
```

Narrow to one service and grep:

```logql
{ kubernetes_namespace_name="online-boutique", kubernetes_pod_name=~"frontend-.*" } |= "error"
```

Rate of log lines per container — the shape you would actually alert on, since
a service that suddenly starts complaining shows up as a step change:

```logql
sum by (kubernetes_container_name) (
  rate({ kubernetes_namespace_name="online-boutique" }[5m])
)
```

**The one thing worth teaching here.** Loki indexes only a small fixed set of
stream labels — namespace, pod, container, log type — and those are the *only*
names valid inside `{}`. The record body carries far more, but putting a body
field in the selector matches nothing, **silently**. Parse first, then filter:

```logql
{ kubernetes_namespace_name="online-boutique" } | json | kubernetes_labels_app="adservice"
```

Show both. The silent-empty-result is the single most common way people conclude
Loki is broken.

> **If the namespace dropdown is empty**, the console plugin's `schema` disagrees
> with the data model the `ClusterLogForwarder` writes. The automation sets
> `viaq` on both sides for exactly this reason; if you changed one, change the
> other.

Keep this in mind for Part 5: **nothing you have just seen contains a trace ID.**

## Part 2 — Network flows

*≈5 minutes. **Observe → Network Traffic**.*

**The claim: you can see what is actually talking to what, measured
independently of the application, by an eBPF agent on every node.**

Set the time range to the last 15 minutes and filter `Namespace` =
`online-boutique`.

- **Topology** draws the service call graph. Switch **Scope** to `Owner` to
  collapse pods into Deployments — at pod scope with a load generator running it
  is unreadable, and that is worth showing once before you fix it.
- **Overview** gives you the dashboards: top talkers, byte rates, dropped
  packets.
- **Traffic flows** lists individual flow records. **This tab exists only on the
  Loki-backed deployment.** If your cluster was built with
  `netobserv_use_loki=false`, say so and skip it — Overview and Topology still
  work, from metrics alone.

The same data is queryable as Prometheus metrics, which works on **both**
deployments. Under **Observe → Metrics**:

```promql
sum by (DstK8S_OwnerName) (
  rate(netobserv_workload_ingress_bytes_total{DstK8S_Namespace="online-boutique"}[5m])
)
```

Traffic crossing the namespace boundary — everything entering the app from
outside it, which is the query people actually want and rarely think to write:

```promql
sum by (SrcK8S_Namespace) (
  rate(netobserv_workload_ingress_bytes_total{
    DstK8S_Namespace="online-boutique", SrcK8S_Namespace!="online-boutique"
  }[5m])
)
```

> The flow labels are **CamelCase**, unlike every other metric in the console.
> Confirm the spelling for your operator version rather than guessing:
> ```bash
> THANOS=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
> curl -sk -H "Authorization: Bearer $(oc whoami -t)" \
>   "https://$THANOS/api/v1/label/__name__/values" | tr ',' '\n' | grep netobserv | head -20
> ```

**The point to land:** this is measured at the kernel, not reported by the
application. It sees traffic from workloads that have no instrumentation, no
metrics endpoint, and no cooperation — including things that should not be
talking to each other at all.

## Part 3 — Traces

*≈10 minutes. **Observe → Traces**. This is the part people remember.*

Select the `tempo` TempoStack and the `dev` tenant.

### Read one trace

Filter by service `frontend` and open a trace. A list entry looks like:

```
frontend: GET
  1 adservice   2 currencyservice   12 frontend   7 productcatalogservice   2 recommendationservice
  24 spans      13ms
```

Four things to say while it is on screen:

1. **The badge counts sum to the total.** One HTTP request fanned out into 24
   spans.
2. **Each remote call produces two spans** — a client span on the caller, a
   server span on the callee — so the count roughly doubles per hop.
3. **A service can be called twice in one trace.** `productcatalogservice` shows
   7 because both `frontend` and `recommendationservice` call it.
4. **Root span names are generic.** Every page render is `frontend: GET`, because
   the Go HTTP instrumentation names spans by method and upstream adds no route
   templating. Identify the flow from the services involved, not the name.

### Then open an order

Filter the service to `checkoutservice`, or search for the span
`hipstershop.CheckoutService/PlaceOrder`. These traces are much larger and
slower. The waterfall reads like this:

```
frontend: POST                                              27.5ms
└─ frontend: CheckoutService/PlaceOrder                     19.11ms   (client)
   └─ checkoutservice: CheckoutService/PlaceOrder           17.78ms   (server)
      ├─ checkoutservice: CartService/GetCart                2.45ms   ← no child
      ├─ checkoutservice: ProductCatalogService/GetProduct   1.86ms
      │  └─ productcatalogservice: GetProduct                  45us
      ├─ checkoutservice: ProductCatalogService/GetProduct     329us
      ├─ checkoutservice: ProductCatalogService/GetProduct     275us
      ├─ checkoutservice: ShippingService/GetQuote           1.61ms   ← no child
      ├─ checkoutservice: PaymentService/Charge              2.33ms   ← no child
      ├─ checkoutservice: CartService/EmptyCart              1.41ms   ← no child
      └─ checkoutservice: EmailService/SendOrderConfirmation 2.65ms
         └─ emailservice: SendOrderConfirmation                240us
```

Four readings, each of which generalises to any application — this is the real
content of the demo:

1. **The work is serial, not parallel.** Every child starts after the previous
   one ends, so nine calls add up rather than overlap. Shipping quote, payment
   and email plausibly could run concurrently; the trace both reveals that and
   quantifies the prize — about 6.6ms of the 17.78ms. **No metric can show
   this.** It is purely a property of span timings.
2. **An N+1 pattern.** `GetProduct` is called once per cart item instead of being
   batched. The first costs 1.86ms and the next two 329µs and 275µs — that decay
   is connection setup being paid once, visible only because each call has its
   own span.
3. **Client spans dwarf server spans.** `GetProduct` is 1.86ms at the caller and
   45µs at the callee. The 40× gap is network, serialization and client
   overhead: the latency lives *between* the services. Optimising
   `productcatalogservice` here would achieve nothing.
4. **Childless spans are instrumentation gaps, and they are expensive.**
   `GetCart`, `GetQuote`, `ShipOrder` and `EmptyCart` total about 5.9ms — a third
   of `PlaceOrder` — and are completely opaque, because `cartservice` and
   `shippingservice` carry no instrumentation.

That fourth point sets up the payoff.

### The payoff: a service that was never instrumented

`adservice` is Java and ships no OpenTelemetry SDK. The automation applied an
`Instrumentation` CR and annotated its pod template; the operator injected an
init container carrying the Java agent and set `JAVA_TOOL_OPTIONS` on the
application container. **No code was changed, no image was rebuilt.**

Show that it happened:

```bash
oc get pod -n $APP_NAMESPACE -l app=adservice \
  -o jsonpath='{.items[0].spec.initContainers[*].name}{"\n"}'
```

```bash
oc get pod -n $APP_NAMESPACE -l app=adservice \
  -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="JAVA_TOOL_OPTIONS")].value}{"\n"}'
```

> **Worth saying out loud during the demo:** both commands read the **Pod**, and
> deliberately so. `oc set env deployment/adservice --list` shows nothing,
> because the operator injects through a mutating admission webhook that runs at
> Pod creation — the Deployment is never touched. That is not a caveat, it *is*
> the feature: the manifest and the image are unchanged, and the agent appears
> only in the running Pod. Showing the Deployment first and then the Pod makes
> the point better than either alone.

Then open a `frontend` trace and point at the `adservice` span — **nested under
the frontend client span, not a separate trace.** That nesting is the whole
point: `frontend` was already propagating W3C trace context on that gRPC call,
and the injected agent picked it up. A service with no code change became part
of a distributed trace.

Useful TraceQL to have ready:

```traceql
{ resource.service.name = "adservice" }
```

```traceql
{ trace:duration > 100ms }
```

```traceql
{ span:status = error }
```

> **Scope the attribute correctly.** `service.name` is a *resource* attribute, so
> it is `resource.service.name`. Querying `span.service.name` returns nothing at
> all rather than an error — the most common reason a TraceQL query looks broken.

> **A missing service usually means missing instrumentation, not a missing call.**
> But `paymentservice` is a different case worth mentioning if someone asks: it
> *is* instrumented and *does* appear in the service list, yet its span has no
> child. It emits spans that are not nesting — its SDK is not extracting the
> inbound `traceparent`, so each one starts a separate trace. Broken propagation
> and absent instrumentation look identical in the waterfall; you tell them apart
> by searching Tempo for the service and finding single-span parentless traces.

## Part 4 — Metrics

*≈5 minutes. **Observe → Metrics**, Administrator perspective.*

**The claim worth making up front: this application exposes no `/metrics`
endpoint whatsoever, and you still get both resource metrics and request
metrics.** They come from two completely different places.

### From the platform, for free

Platform monitoring already scrapes cAdvisor and kube-state-metrics for every
namespace. Nothing was configured for this.

```promql
sum by (pod) (
  rate(container_cpu_usage_seconds_total{namespace="online-boutique", container!=""}[5m])
)
```

```promql
kube_deployment_status_replicas_available{namespace="online-boutique"}
  / kube_deployment_spec_replicas{namespace="online-boutique"}
```

```promql
sum by (pod) (kube_pod_container_status_restarts_total{namespace="online-boutique"})
```

### From the spans, via the spanmetrics connector

The collector's trace pipeline forks: the same spans go to Tempo *and* into a
connector that counts them and records their durations, producing RED metrics —
Rate, Errors, Duration — for an application that publishes none.

Request rate per service:

```promql
sum by (service_name) (rate(traces_span_metrics_calls_total[5m]))
```

95th percentile latency per service:

```promql
histogram_quantile(0.95,
  sum by (le, service_name) (rate(traces_span_metrics_duration_milliseconds_bucket[5m]))
)
```

Slowest operations across the whole app, which is where the gRPC fan-out shows:

```promql
topk(10, histogram_quantile(0.95,
  sum by (le, service_name, span_name) (rate(traces_span_metrics_duration_milliseconds_bucket[5m]))
))
```

### The distinction to land

| Source | Layer | Can tell you | Cannot tell you |
|---|---|---|---|
| cAdvisor / kube-state-metrics | container and API object | `frontend` burned 300m of CPU and restarted twice | whether checkout requests are *failing* — a pod serving errors at 200 rps looks identical to one serving successes |
| spanmetrics | request behaviour | `checkoutservice` answers 12 rps at p95 400ms with a 3% error rate | which pod, or whether the node is under memory pressure |

**And this is the payoff of running spanmetrics next to Tempo: the metric tells
you *which* service slowed down, the trace tells you *why*, for the same
request.** Demonstrate it — find a service with a bad p95 above, then filter
Tempo to that service and open a slow trace.

> **If a metric returns nothing**, work down in this order: are the user workload
> monitoring pods running (`oc -n openshift-user-workload-monitoring get pods`);
> is the target up (`up{namespace="tracing-system"}` — two series with value 1);
> then the metric itself. No `up` series at all means the `ServiceMonitor`
> selector does not match the Service, which is silent and is the usual cause.

> **A missing failure counter is good news.** The collector's own metrics come
> from the OpenTelemetry SDK, which only exports a counter after it has been
> incremented once. On a healthy collector `otelcol_exporter_send_failed_spans_total`
> does not exist at all. For a dashboard panel, floor it:
> `sum(rate(otelcol_exporter_send_failed_spans_total[5m])) or vector(0)`.

## Part 5 — Logs through OpenTelemetry, and why they are different

*≈10 minutes. **This is the part the whole demo is building towards.***

Part 1 showed logs already working, completely, for every pod, with no
application change. So the obvious question — and you should ask it out loud —
is **why would anyone route logs through OpenTelemetry at all?**

There is exactly one answer, and it is worth the whole section.

### The two paths are different mechanisms

| | OpenShift Logging | OpenTelemetry |
|---|---|---|
| What it reads | container stdout/stderr from `/var/log/pods` on each node | log records emitted by the application's own logging framework, **in process** |
| How | a Vector DaemonSet tails files and adds Kubernetes metadata | the SDK or injected agent bridges log4j/logback/etc. and pushes OTLP |
| Application changes | none — works for every pod | requires the SDK or an injected agent |
| Coverage | everything, including crashed containers and infrastructure | only instrumented applications, only while running |
| **Trace correlation** | **only if the app printed trace IDs into the text itself** | **automatic — `TraceId` and `SpanId` are fields on the record** |

Every row but the last favours Vector. The last row is the entire reason the
other path exists.

**Vector cannot do it, and not because of an implementation gap.** By the time
Vector reads the line from disk, the trace context is gone — the span ended, the
process moved on, and all that survives is text. The agent reads the trace ID
from the live span context *at the moment the log statement executes*.

### Online Boutique illustrates the gap perfectly

`adservice` logs JSON via log4j2 and *tries* to include trace context:

```json
{"level":"INFO","message":"Ad Service started, listening on 9555",
 "logging.googleapis.com/trace":"${ctx:traceId}"}
```

That `${ctx:traceId}` placeholder is **never substituted** — it needs a context
provider the image does not wire up. Show it landing in Loki as a literal
string. Search for the placeholder itself; every match is a line where the
application tried to record a trace ID and failed:

```logql
{ kubernetes_namespace_name="online-boutique", kubernetes_pod_name=~"adservice-.*" } |= "ctx:traceId"
```

This is not a contrived example. It is what "we log the trace ID" looks like in
practice when nobody has verified it.

### Turn the OpenTelemetry path on

Three things have to line up, and all three are easy to get wrong
individually — which is why they are automated as one step:

1. The `Instrumentation` CR must stop setting `OTEL_LOGS_EXPORTER: none`.
2. The collector must have a `logs` pipeline, or `/v1/logs` returns 404 every
   couple of seconds.
3. `adservice` must be **restarted** — the CR is read only at pod admission, so a
   running pod ignores changes to it.

```bash
ansible-playbook demo-otel-logs.yml -e suffix=xipio
```

From [`../ansible`](../ansible). It adds the logs pipeline to the collector
first, then re-applies the CR, then rolls `adservice`, and waits.

### Read a record

`adservice` logs at INFO on **every** request, and the load generator calls it on
every page render, so there is a continuous supply without scripting anything.
The line is written *inside* the gRPC server span the injected agent created.

```bash
oc logs -n $TRACING_NAMESPACE deploy/otel-collector --tail=500 \
  | grep -B6 -A20 'received ad request' | head -40
```

For a live demo, follow the stream instead:

```bash
oc logs -n $TRACING_NAMESPACE deploy/otel-collector -f \
  | grep --line-buffered -E 'Body: Str\(received ad request|^Trace ID:|^Span ID:'
```

> `--line-buffered` matters. Without it `grep` buffers in blocks and the output
> appears to stall — which in front of an audience looks like a broken demo.

What comes out:

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

Point at two things:

- **`cluster: Str(lab)`** — inserted by a `resource` processor as the record
  passed through the pipeline. Proof that the collector is transforming, not just
  forwarding.
- **A non-zero `Trace ID` and `Span ID`** — the fields Loki's copy of this exact
  same line does not have.

Note what you are reading: this is the **collector's** stdout, not
`adservice`'s. The record travelled `adservice` → OTLP over the network → the
collector's `logs` pipeline → the `debug` exporter, which renders it. And only
`adservice` appears — the other six services configure trace providers but no log
provider, so the Java agent's log bridge is the sole source feeding this
pipeline.

### Prove the correlation

Copy that `Trace ID` and open it in **Observe → Traces** using the **Trace ID**
lookup field. Or in TraceQL, where `trace:id` is an intrinsic and the hex string
must be quoted:

```traceql
{ trace:id = "22b13f9e11b2c4d953241d477ad81470" }
```

**The trace that opens is the one whose `adservice` span produced that exact log
line.** You can see the request it belonged to, which service called it, and how
long it took.

Say the sentence plainly: *from one log line, to the distributed request it was
part of, without the application having printed anything about it.*

Then put the two side by side. Same line, both paths:

| | Vector → Loki | Agent → OTLP → collector |
|---|---|---|
| Gets the line | always, from stdout on disk | only while the app runs and is instrumented |
| Trace identity | whatever the app printed — here, a broken placeholder | read from the live span context |
| Best for | complete retention, searching all workloads | pivoting from a slow trace to its log lines |

**They coexist rather than compete.** That is the conclusion, and it is a more
useful one than "OpenTelemetry replaces your logging stack."

### The honest caveat

If someone asks where these logs are *stored*: **nowhere.** `debug` is a terminal
sink — it renders each record to the collector's stdout and that is the end of
the pipeline. There is nothing behind it to query.

Do not skip this. Three ways to fix it, in ascending order of realism:

1. **Read the collector's stdout** — what this demo does. No extra
   configuration, and the record block stays intact.
2. **Let Vector collect the debug output.** It does, automatically, since the
   collector's stdout is ordinary container output. But **this cannot show the
   correlation**, and the reason is instructive: the `debug` exporter renders each
   record as a multi-line block, and Vector is line-oriented, so the `Body:` line
   and the `Trace ID:` line become two unrelated Loki entries with nothing
   joining them. Use it to confirm records are arriving, not to demonstrate
   anything.
3. **Export to LokiStack over OTLP** (`otlphttp` to the distributor's `/otlp`
   endpoint). The only option that preserves the record as a single structured
   entry with the trace ID in structured metadata — which is what makes it
   queryable and joinable. This is what you would actually run.

And note that while `verbosity: detailed` is on, every `adservice` line reaches
Loki **twice** — once from `adservice`, once inside the collector's debug output.
Harmless for a demo, confusing on a shared cluster, and the reason to revert.

> **If the collector output is empty**, one of the three setup steps did not
> take. In order: the `Instrumentation` CR must no longer set
> `OTEL_LOGS_EXPORTER: none`; the collector must have a `logs` pipeline
> (`oc get opentelemetrycollector otel -n $TRACING_NAMESPACE -o jsonpath='{.spec.config.service.pipelines}'`);
> and `adservice` must have been restarted *after* both.

## Closing the loop

If you have time for one more thing, **Observe → Alerting** → open any alert →
**Troubleshooting Panel**. Korrel8r correlates across the stores you have just
been through separately — alerts, metrics, logs, netflows and cluster resources
— so you can pivot from an alert straight to the related network traffic or log
lines. It needs the Loki-backed network deployment to have flow data to
correlate with.

The summary slide, if you want one:

| Signal | Answers | Would not exist without |
|---|---|---|
| Logs | what did this service *say* | nothing — it is free, for every pod |
| Flows | what is actually talking to what | the eBPF agent, measuring at the kernel |
| Traces | *why* is this request slow | the application being instrumented |
| Metrics | is this getting worse, and how fast | either the platform, or spans via spanmetrics |
| OTel logs | which request wrote this line | the log record carrying live span context |

## Reverting

Put the collector and the `Instrumentation` CR back:

```bash
ansible-playbook demo-otel-logs.yml -e suffix=xipio -e demo_state=reverted
```

This removes the `logs` pipeline, the `debug` exporter and the `resource/demo`
processor, and sets `OTEL_LOGS_EXPORTER: none` again. The traces and metrics
pipelines are untouched throughout — the whole demo is additive.

Full teardown is in [`../ansible/README.md`](../ansible/README.md#teardown).
