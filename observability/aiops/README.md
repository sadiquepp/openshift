# Agentic AIOps on traces

An automated incident beat for the Online Boutique workload already deployed by
[`../ansible`](../ansible): a latency fault is injected, an alert fires off
**span** metrics, and an agent investigates in Slack and proposes a remediation
that a human confirms.

This directory is the demo-day layer on top of
[`../README.md`](../README.md) (the stack) and [`../demo/README.md`](../demo/README.md)
(the walkthrough). It adds nothing to the observability stack itself — it
consumes the Tempo, spanmetrics and Loki pipelines that are already there.

> **Status: phase 1 of 5.** Nothing here deploys an agent yet. What exists today
> is the design below and a read-only probe that pins down the facts the later
> phases are built on. See [Phases](#phases).

## Contents
- [The argument](#the-argument)
- [The two beats](#the-two-beats)
- [Why these two faults](#why-these-two-faults)
- [Phases](#phases)
- [Phase 1 — ground truth](#phase-1--ground-truth)
- [Design decisions already made](#design-decisions-already-made)
- [Known blockers](#known-blockers)
- [Upstream reference](#upstream-reference)

## The argument

`../demo/README.md` makes its case by showing four signals in sequence and
naming the question each one answers that the others cannot. This directory
makes the same case a different way: **two incidents, back to back, where each
signal cracks the one the other is blind to.** Not asserted from a summary
slide — demonstrated, with a fault injected live.

That framing matters because the usual version of this demo ("observability
tool finds problem") is unfalsifiable theatre. Two beats where one tool visibly
fails and the other visibly succeeds, then the reverse, is an argument.

## The two beats

### Beat A — flows win, traces are blind

Fault on the `cartservice → redis-cart:6379` link.

| | What it shows |
|---|---|
| Traces | `checkoutservice: CartService/GetCart` inflates to ~900ms and is **childless** — `cartservice` is .NET and ships no SDK. Completely opaque. |
| Flows | Elevated RTT and retransmits on one pod-to-pod link, localised exactly. |

`../demo/README.md` Part 3 already documents the childless span as an
instrumentation gap. Beat A is that gap, weaponised: the trace proves something
is wrong beneath `cartservice` and cannot say what. The eBPF agent, which needs
no cooperation from the application, can.

### Beat B — traces win, flows are blind

`EXTRA_LATENCY` on `productcatalogservice`.

| | What it shows |
|---|---|
| Flows | Nothing. RTT normal, no drops, no retransmits — the network is genuinely healthy. |
| Traces | The **server** span inflates in-process with no child accounting for the time; the N+1 multiplies it; and the charge is already committed while the customer waits. |

The customer-facing story is the one that makes people wince. From the verified
`checkoutservice` call order in v0.10.6:

```
GetCart → GetProduct+Convert (per item) → GetQuote+Convert
  → Charge                   ← the money moves here
  → ShipOrder                ← no instrumentation
  → EmptyCart                ← no instrumentation, error discarded
  → SendOrderConfirmation     ← failure only logged
```

…and then `PlaceOrder` returns and the frontend fetches recommendations for the
confirmation page *before rendering it*, inside the same request:

```go
log.WithField("order", order.GetOrder().GetOrderId()).Info("order placed")
recommendations, _ := fe.getRecommendations(r.Context(), sessionID(r), nil)
// → then ExecuteTemplate(w, "order", ...)
```

So the spinner keeps turning through four more steps after the card is charged,
two of which do not affect whether the order succeeded. **Only the trace can
establish that ordering**, and it is the whole reason this beat is about traces
rather than metrics.

## Why these two faults

| | Beat A: `cart → redis` netem | Beat B: `EXTRA_LATENCY` |
|---|---|---|
| Mechanism | tc/netem on the pod path | `time.Sleep()` inside the RPC handler |
| Injection | privileged chaos job | `oc set env`, one command |
| Reversal | clear the qdisc | unset the variable |
| Why it suits the beat | a real L3/L4 fault is what flows are *for* | an in-process stall is invisible at L4, so "it is not the network" is **true**, not hand-waved |

`EXTRA_LATENCY` is upstream, not a patch: `productcatalogservice`'s
`ListProducts`, `GetProduct` and `SearchProducts` each open with
`time.Sleep(extraLatency)`, and `main()` logs
`extra latency enabled (duration: …)` at startup.

> **On naming the flag in the diagnosis.** A debug or load-test flag left
> enabled in production is a real and common incident class, so the agent
> naming it is not a spoiler — it is the most plausible reading of the
> evidence. Frame it that way rather than as chaos tooling and the demo gets
> *more* credible, not less.

> **The cause is not in the trace.** The sleep emits no span. The trace can
> prove "unattributed in-process time inside `GetProduct`" and no more. Naming
> `EXTRA_LATENCY` needs a second signal — the Deployment env, or the startup log
> line, which `oc set env` conveniently re-emits with a timestamp that matches
> the latency onset. That logs-plus-traces step is a feature of the demo, not a
> workaround: it is the correlation `../demo/README.md` Part 5 argues for.

## Phases

| Phase | What | Exit gate |
|---|---|---|
| **1** | Ground truth and scaffold. No cluster changes. | Real numbers for the four unknowns below |
| 2 | Signal path, no agent: histogram buckets, `PrometheusRule`, Alertmanager → Slack, both fault scripts and their reverts | Inject → Slack within ~2 min; revert → resolves |
| 3 | `trace_analyze` as a plain script, then wrapped as an MCP server | Deterministic verdict against a real slow trace, repeatably |
| 4 | Agent layer: sandbox, hooks, Slack, the investigate skill | Agent posts the diagnosis in-thread |
| 5 | Remediation job behind a confirmation gate, then timed rehearsals | 10 consecutive runs inside the slot |

**Phase 2 is a complete, demoable segment on its own.** If phase 4 is blocked
(see [Known blockers](#known-blockers)), the automated beat still works — it
just posts to Slack without an agent narrating it. Build in this order so that
the thing most likely to fail is the thing you need least.

## Phase 1 — ground truth

Four facts drive the content of every later phase, and all four can only be
observed on a running cluster. Guessing them means a wrong alert expression and
a wrong analyzer:

1. **The exact `span_name` label values** that the spanmetrics connector emits
   for `checkoutservice` and `productcatalogservice`. The phase 2 alert
   expression is a string match against one of these.
2. **Current p50/p99 for `PlaceOrder` and `GetProduct`**, and the `le` bucket
   boundaries actually present — which is also how you confirm the
   coarse-bucket problem before changing the collector.
3. **Whether the post-checkout recommendation fan-out appears in the trace.**
   The frontend source says it should; the span count and shape on *this*
   cluster decides whether the post-charge wait is dramatic or marginal.
4. **The Tempo gateway query URL and whether a token gets through it** —
   protocol, port name and tenant path. Phase 3's MCP server is built directly
   on this.

### What the cluster needs

**One cluster.** If you build it with
[`sadiquepp/ocp-onpremise`](https://github.com/sadiquepp/ocp-onpremise) that is
its hub cluster, which is all you need — nothing here is hub-and-spoke, so no
second or managed cluster is involved.

The probe reads only the tracing pipeline and the workload, so the other two
layers can stay off:

```bash
ansible-playbook site.yml -e suffix=xipio \
  -e logging_enabled=false -e netobserv_enabled=false
```

That is enough for phases 1 to 3: TempoStack on S3, the collector with the
spanmetrics connector, user workload monitoring with both `ServiceMonitor`s,
and Online Boutique on the `tracing` overlay. With those layers off,
`observability_backends` enables only the tempo entry, so one S3 bucket is
created instead of three and both LokiStacks are skipped.

### An on-premise cluster with S3 on AWS

That combination needs no change to `../ansible`: the cluster layer never cares
where the cluster runs, and `aws-prereqs.yml` mints the buckets and keys exactly
as it does for a cluster on EC2. Four things are worth checking that do not come
up when both sides are in AWS.

**Egress to S3 must actually work from the cluster.** The Loki and Tempo
operators write straight to `https://s3.<region>.amazonaws.com`, so the
on-premise nodes need outbound HTTPS to it. If the lab reaches the internet
through a proxy, set the cluster-wide `Proxy` resource before deploying rather
than debugging a TempoStack that will not go Ready — the operators honour it,
but only if it is configured.

**Headroom is fixed, unlike on AWS.** A three-node compact cluster takes the
tracing layer and the workload comfortably; the squeeze is two more LokiStacks
on top. That is the same argument for leaving `logging` and `netobserv` off for
phases 1 to 3, except that on bare metal you cannot resize your way out of
getting it wrong. See
[`../ansible/README.md`](../ansible/README.md#prerequisites) for what the full
stack expects.

**A default StorageClass is still needed**, separately from S3 — the
TempoStack's own PVCs come from it. The LVM Storage Operator that
`ocp-onpremise` installs (`roles/setup-lvm-storage`,
`gitops-manifests/lvm-storage`) provides one, and `storage_class_name` in
`../ansible/group_vars/all.yml` is empty by default, meaning "use the cluster
default" — so there is nothing to set if LVM Storage is it.

**A disconnected build is a different exercise.** The Online Boutique images
come from `us-central1-docker.pkg.dev` and every operator from the
`redhat-operators` catalog, so an air-gapped cluster needs all of it mirrored
first — see [`../../disconnected`](../../disconnected). Reaching AWS S3 at all
implies a connected cluster, so this only matters if that changes.

| Layer | Needed by the probe | Needed for the demo |
|---|---|---|
| `tracing` | yes | yes — beat B |
| `workload` | yes | yes — both beats |
| `netobserv` | no | **yes — beat A is the flows beat** |
| `logging` | no | optional |

> **Decide `netobserv_use_loki` before you provision.** Per-flow RTT in the
> Traffic flows tab is Path B only. If beat A is a 45-second presenter walk over
> Topology and Overview, Path A (`-e netobserv_use_loki=false`) does it without
> a second LokiStack. Changing your mind later means re-running that layer.

> **Logging is optional even for beat B.** The log line that names the flag is
> emitted at startup, and `oc set env` restarts the pod, so `oc logs` has it.
> Loki reads better on screen — queryable over a window, with a timestamp that
> lines up with the latency onset — but it is not required.

### Run it

The probe needs a **bearer token**, and the kubeconfig written by
`openshift-install` is certificate-based — `oc whoami -t` returns nothing with
it, and both the Thanos and Tempo HTTP APIs need a token. So log in first:

```bash
oc login -u kubeadmin -p "$(cat ~/clusters/lab/auth/kubeadmin-password)" \
  --insecure-skip-tls-verify
```

This is the inverse of the automation's requirement and therefore easy to miss:
the playbooks never contact the cluster with `oc` at all, so `oc login` is not a
prerequisite *there*. The probe fails fast with this message rather than
returning empty results that look like a broken pipeline.

```bash
./scripts/verify-baseline.sh
```

It makes **no writes**: `oc get`, instant PromQL queries through
`thanos-querier`, and Tempo reads over a temporary port-forward. It prints a
`VALUES FOR PHASE 2` block at the end — that block is the input to the next
phase.

> Let the load generator run for at least ten minutes first, for the same
> reason `../demo/README.md` opens with that warning: the spanmetrics connector
> flushes every 15s and Prometheus scrapes every 30s, so a cold cluster reports
> empty and you will think something is broken.

## Design decisions already made

Recorded here so phase 2 does not relitigate them.

**Alert on `CheckoutService/PlaceOrder`, never on the frontend root span.**
Part 3 of the demo README documents that root spans are named by HTTP method
only, so `span_name="POST"` on `frontend` aggregates place-order with
add-to-cart and set-currency. The p99 would be polluted. `PlaceOrder` is
uniquely named. The frontend-POST-versus-`PlaceOrder` gap is still worth
showing — read it from the waterfall, where it is unambiguous, not from a
metric.

**Alert off spanmetrics in user workload monitoring, not Grafana.** The
upstream reference deploys Grafana and federates into a standalone Prometheus.
Not needed here: a `PrometheusRule` in `tracing-system` plus an
`AlertmanagerConfig` webhook receiver reaches the same place with no new
operator, because OpenShift's own Alertmanager posts the payload shape the
bridge already parses (`status`, `alerts[].fingerprint`, `commonLabels`,
`commonAnnotations.summary`).

**Widen the histogram buckets before trusting any p99.** The collector template
sets `[10ms, 50ms, 100ms, 250ms, 500ms, 1s, 5s]`. Against a 17.78ms `PlaceOrder`
baseline, `histogram_quantile` is quantisation noise — the alert still fires
under fault, but the number the agent quotes in Slack is meaningless. Phase 2
adds 1ms/2ms/5ms boundaries.

**Compute the verdict in code; let the model narrate it.** The analyzer decides
the baseline comparison, the in-process-versus-wire discriminator (server span
inflated → in-process; client/server gap inflated → wire) and the N+1 count.
The model sequences tool calls and writes prose. This is both faster and
rehearsable, and it is how the upstream reference achieves the same effect.

**One agent turn, not two.** Beat A is presenter-driven on the console —
Topology with Scope set to `Owner` is a better 45 seconds than waiting on a
model to describe a graph that is already on screen. Only beat B is agentic.
That halves the slowest and least predictable part of the demo.

## Known blockers

**The agent runtime is not a product.** Phase 4 depends on OpenShell and
OpenClaw, Red Hat Emerging Technologies lab components installed from a pinned
commit of an external lab repository. The upstream install notes state that the
pinned OpenClaw image digest was **removed from Quay**, and instruct you to
mirror it from a cluster where it is still running rather than chase newer tags.
If no such cluster is reachable, phase 4 does not start. This is the single
largest risk and the reason phases 2 and 3 are built to stand alone.

**Phase 5's remediation needs an AAP subscription** for the governed job-template
path. Without one, the fallback is a playbook run behind the same explicit
confirmation gate — weaker governance story, identical demo.

## Upstream reference

The event-driven pattern here — alert → webhook bridge → agent hook → Slack
thread, with remediation gated on human confirmation — follows
[lfedgeai/AIOps `demo-4-openshift-network-observability`](https://github.com/lfedgeai/AIOps/tree/main/demo/demo-4-openshift-network-observability),
which implements it against Network Observability flows and a two-tier Quarkus
workload.

Nothing in this directory is copied from it. That project publishes no LICENSE
file, so there is no grant to rely on, and in any case every component needed
reworking for traces: the alert expression, the investigation prompt, the
analyzer's verdict logic and the tool surface are all different. The patterns
are credited; the code is ours.
