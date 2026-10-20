# Agentic AIOps on traces

An automated incident beat for the Online Boutique workload already deployed by
[`../ansible`](../ansible): a latency fault is injected, an alert fires off
**span** metrics, and an agent investigates in Slack and proposes a remediation
that a human confirms.

This directory is the demo-day layer on top of
[`../README.md`](../README.md) (the stack) and [`../demo/README.md`](../demo/README.md)
(the walkthrough). It adds nothing to the observability stack itself — it
consumes the Tempo, spanmetrics and Loki pipelines that are already there.

> **Status: phase 2 of 5.** No agent yet. What works today is the full signal
> path without one — inject the fault, and Slack gets the alert. See
> [Phases](#phases).

## Contents
- [The argument](#the-argument)
- [The two beats](#the-two-beats)
- [Why these two faults](#why-these-two-faults)
- [Phases](#phases)
- [Phase 1 — ground truth](#phase-1--ground-truth)
- [Measured baseline](#measured-baseline)
- [Phase 2 — the signal path, without an agent](#phase-2--the-signal-path-without-an-agent)
- [Phase 4a — Ansible Automation Platform](#phase-4a--ansible-automation-platform)
- [The analyzer](#the-analyzer)
- [Design decisions already made](#design-decisions-already-made)
- [What phase 4a reuses, and the one thing that collides](#what-phase-4a-reuses-and-the-one-thing-that-collides)
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
| ~~1~~ | ~~Ground truth and scaffold~~ | **done** — see [Measured baseline](#measured-baseline) |
| **2** | Signal path, no agent: histogram buckets, `PrometheusRule`, Alertmanager → Slack, beat B's fault and its revert | Inject → Slack in ~3-5 min; revert → resolves |
| 2b | Beat A's `cartservice → redis-cart` network fault (presenter-driven, no alert path) | Flows localise it; traces cannot |
| ~~3a~~ | `trace-analyze.py` as a plain script | **done** — verified against the cluster, see [The analyzer](#the-analyzer) |
| 3b | the same analyzer wrapped as an MCP server | the agent can call it |
| 4a | Platform: RHOAI and ZTWI/SPIRE reused from `ocp-onpremise` (see below), AAP and TrustyAI new. `scripts/preflight-platform.sh` reports the catalog facts first | each operator Succeeded and its CR Ready |
| 4b | Agent runtime: Slack **app** over Socket Mode (replacing phase 2's one-way webhook), the investigate skill | agent posts the diagnosis in-thread, and reads the human's confirmation |
| 5 | AAP job template behind a confirmation gate, then timed rehearsals | 10 consecutive runs inside the slot |

The split in phase 4 is deliberate and load-bearing: **the one unavailable
image blocks 4b only.** Everything in 4a installs from operator catalogs, so
the product stack is not waiting on it.

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
# Which cluster. ocp-onpremise writes the hub's kubeconfig under its
# download_dir — hub_install for a connected build, hubd_install disconnected.
export KUBECONFIG=/var/lib/libvirt/images/hub_install/auth/kubeconfig

cd observability/ansible
ansible-playbook site.yml -e suffix=xipio \
  -e logging_enabled=false -e netobserv_enabled=false
```

`KUBECONFIG` is the loose way in: `cluster.yml` passes `kubeconfig` and
`context` to every `kubernetes.core` module but `omit`s them when unset, so the
modules fall back to the environment and then `~/.kube/config`. Pass
`-e kubeconfig=…` or `-e kube_context=…` instead if you juggle several clusters
and would rather not rely on an export — see
[`../ansible/README.md`](../ansible/README.md#pointing-at-the-right-cluster).

> **Copy it somewhere writable first if you are on the lab host.** That path is
> under `/var/lib/libvirt/images` and root-owned, and the `oc login` in
> [Run it](#run-it) *writes* a new context into whatever `KUBECONFIG` names. The
> playbook only reads it, so it is fine as-is for this step, but the probe's
> login is not — `cp` it to `~/.kube/config` and export that instead, and both
> steps work without sudo.

That is enough for phases 1 to 3: TempoStack on S3, the collector with the
spanmetrics connector, user workload monitoring with both `ServiceMonitor`s,
and Online Boutique on the `tracing` overlay. With those layers off,
`observability_backends` enables only the tempo entry, so one S3 bucket is
created instead of three and both LokiStacks are skipped.

### An on-premise cluster with S3 on AWS

That combination needs no change to `../ansible`: the cluster layer never cares
where the cluster runs, and `aws-prereqs.yml` mints the buckets and keys exactly
as it does for a cluster on EC2.

**This is a day-2 playbook.** It runs after the cluster is up — `ocp-onpremise`
`setup_hub_cluster.yaml` first, then `site.yml` here, then the probe. On the LVM
path nothing else is needed in between: preflight hard-fails without a default
StorageClass, and `roles/setup-lvm-storage` runs inside the hub build itself
(tag `lvm`) and makes `lvms-vg1` the default. On the Ceph path
(`use_lvm_storage: false`) the default class comes from `setup_ceph_odf.yaml`
instead, so run that first. `aws-prereqs.yml` is the exception — it talks only
to AWS and can run before the cluster exists.

`ocp-onpremise` deploys no observability components of its own, so there is
nothing here to collide with.

Four more things are worth checking that do not come up when both sides are in
AWS.

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

> **The demo is recorded, not presented live**, which retires several
> constraints: a slow model turn, the three-to-five minute wait from fault to
> alert, and the pacing worry about how long six seconds looks on screen are
> all edit-time problems. It also means **no GPU is needed anywhere** — nothing
> in this stack requires one, and only *fast* inference did. Bare metal with an
> 8B model on CPU is enough, because the analyzer computes the verdict and the
> model only phrases it. A model that cannot be trusted to derive a diagnosis
> can be trusted to read one out.

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
export KUBECONFIG=~/.kube/config     # a writable copy — see the note above
oc login -u kubeadmin \
  -p "$(sudo cat /var/lib/libvirt/images/hub_install/auth/kubeadmin-password)" \
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

## Measured baseline

Phase 1's probe, run against the cluster. These replace the inferences the
design was first written from.

| | Measured |
|---|---|
| metric base | `traces_span_metrics_duration_milliseconds` (ms) |
| PlaceOrder span | `hipstershop.CheckoutService/PlaceOrder` |
| GetProduct span | `hipstershop.ProductCatalogService/GetProduct` |
| PlaceOrder p50 / p99 | 29.1ms / 49.6ms |
| PlaceOrder rate | 0.089 rps |
| GetProduct p50 (server) | 5ms |
| Tempo query base | `https://tempo-tempo-gateway.tracing-system.svc.cluster.local:8080/api/traces/v1/dev/tempo` |

Four things came out differently from the design's assumptions, and all four
changed something.

**The N+1 is in the confirmation page, not inside `PlaceOrder`.** The trace
shows one `GetProduct` inside `PlaceOrder` on a single-item cart, then after
`PlaceOrder` returns the frontend fires **five** more plus a `ListProducts`
through `recommendationservice`. `EXTRA_LATENCY` sleeps in `ListProducts` too,
so at 400ms the delay lands roughly 0.4s inside checkout, 0.4s in
recommendations and 2.0s in the confirmation page. The charge completes 13.5ms
into a 25.4ms request, so **about 2.4 of the 2.9 added seconds fall after the
customer's card was charged.** The post-charge beat is real and larger than the
design projected.

**The alert understates the incident, and that is the point — but by less than
first estimated.** Measured under a 400ms fault:

| | clean | faulted |
|---|---|---|
| `PlaceOrder` p50 / p99 | 29.1 / 49.6ms | 538 / **2424ms** |
| `GetProduct` p50 (server) | 5ms | **365ms** |

The first estimate of a sevenfold gap came from the single-item cart in the
baseline trace, where `PlaceOrder` pays the 400ms once. It does not: `GetProduct`
runs **once per cart item**, so a six-item cart pays it six times and
`PlaceOrder` alone reaches ~2.4s. The alert therefore captures far more of the
fault than projected, and the post-charge remainder is proportionally smaller.

The gap is still real — the confirmation page's lookups genuinely happen after
the charge, and no metric reaches them — but its size scales with cart size and
has to be read off a faulted trace rather than asserted. `verify-baseline.sh`
now computes it; see `post-charge share` in its summary.

### The measured faulted trace

One captured request, `EXTRA_LATENCY=400ms`, nine-item cart:

| | |
|---|---|
| request total | 6050.4ms (45 spans) |
| inside `PlaceOrder` | 9 × 401ms serial = 3614ms, 60% of the request |
| charge completed | 3631.3ms |
| after the charge | 2419.1ms — 40% |
| confirmation page | 5 × 401ms serial = 2008ms, 33% |
| client vs server span | 401.9 vs 401.1ms — 99.8% inside the callee |

**Say the absolute, not a ratio.** The alert reports ~3.6s of checkout; the
customer waited 6.1s; the missing 2.4s all followed the charge. That is
measured, and it survives contact with an audience better than a multiplier
that moves with cart size.

> **The 40% post-charge share is structural, not a symptom.** The clean trace
> is 39% (12.2ms of 31.5ms) and the faulted one 40% (2419ms of 6050ms) — the
> fault scales the request without shifting the ratio. So the claim to make is
> that *40% of every checkout happens after the card is charged, and under this
> fault that is 2.4 seconds instead of 12 milliseconds.* Attributing the share
> itself to the fault would be wrong, and someone in the audience may well
> check.

**Nine identical 401ms blocks in a staircase** is the clearest N+1 a waterfall
will ever show you. It comes from the load generator's carts accumulating items
once scaled to 5 replicas.

### Tuning the fault, and the ceiling you must not cross

Six seconds is a severe checkout regression, not a normal one — past about
three seconds abandonment climbs steeply, and at six a customer assumes
failure and retries, which on a checkout risks a double submission. The
temptation is to make it far bigger anyway so an audience *feels* it. Resist
going to 30s, for three reasons.

> **An OpenShift Route times out at 30s by default, and the trace will not show
> it.** HAProxy closes the *client* connection and returns 504, while the
> frontend handler runs on and its span completes normally. So the customer sees
> an error, the waterfall shows a merely slow request, and nothing in the
> telemetry disagrees. On stage that is the worst available failure: the agent
> narrates latency while the audience watched a 504. It is only visible
> router-side, which is why `demo-fault.sh status` now checks
> `haproxy_server_http_responses_total` and reports the headroom.

The ceiling is a **cart size**, not a latency, because post-charge work is a
fixed six sleeps regardless of cart (one `ListProducts` for the
recommendations, five `GetProduct` for the confirmation page) while everything
before the charge scales with the items:

| `LATENCY` | post-charge | 504 above a cart of |
|---|---|---|
| 400ms | ~2.4s | ~69 items |
| 800ms | ~4.8s | ~31 items |
| 2000ms | ~12.0s | ~9 items |

`./scripts/demo-fault.sh route-timeout 120s` buys headroom if you want to go
high. The other two reasons to stay low: throughput falls roughly in
proportion, thinning the p99 samples the alert's rate guard depends on; and a
30-second checkout reads as a dead service, which nobody needs an agent to
diagnose. The two-to-six second insidious case is exactly where traces earn
their keep.

**The better lever is the post-charge share, not the total.** Post-charge work
is fixed, so a smaller cart raises its share without touching the ceiling:

| cart | pre-charge | post-charge | share after the charge |
|---|---|---|---|
| 9 items | ~3.6s | ~2.4s | 40% |
| 1 item | ~0.4s | ~2.4s | **~85%** |

So *"charged four tenths of a second in, then waited another two and a half
seconds"* is available at no risk at all. The nine-item trace is still the
better hero, though, because it carries both stories at once: the staircase and
the tail.

**`p99 = 49.58ms` against a `50ms` bucket edge** is the coarse-histogram problem
caught in the act. The alert fires either way, but every number it quotes is a
boundary. Hence the finer boundaries in
[`../ansible/group_vars/all.yml`](../ansible/group_vars/all.yml).

**Span names follow three conventions, by language.** Go emits
`hipstershop.X/Y`, Python `/hipstershop.X/Y`, Node `grpc.hipstershop.X/Y`.
Phase 3's analyzer must match with `=~`, never `=`.

> **One correction belongs upstream of here.**
> [`../demo/README.md`](../demo/README.md) Part 3 says `paymentservice` "is not
> extracting the inbound `traceparent`, so each one starts a separate trace".
> The measured trace shows `paymentservice`'s span nested under the
> `checkoutservice` client span, so propagation works and that caveat is stale —
> what actually differs is the `grpc.` prefix on its span name. Worth fixing
> before saying it out loud on stage.

## Phase 2 — the signal path, without an agent

Fault → spanmetrics → `PrometheusRule` → the user-workload Alertmanager →
Slack. No agent and no custom code, which is the point: the path is provable on
its own, and phase 4 swaps the receiver for the webhook bridge without touching
the rule, the thresholds or the fault.

```bash
export KUBECONFIG=~/.kube/config
export SLACK_WEBHOOK_URL='https://hooks.slack.com/services/...'

./scripts/setup-alerting.sh all      # buckets, Alertmanager, Secret, rule, route
./scripts/demo-fault.sh loadgen      # raise the request rate
./scripts/demo-fault.sh inject       # EXTRA_LATENCY=400ms
./scripts/demo-fault.sh watch        # poll p99 until it crosses 250ms
./scripts/demo-fault.sh revert       # unset, and loadgen back to 1
```

`setup-alerting.sh` also takes `status` and `revert`, and each stage
(`buckets`, `alertmanager`, `slack`, `rules`) runs alone.

### What it sets up, and why each part is there

**Finer histogram boundaries**, patched onto the live collector *and* set in
`../ansible/group_vars/all.yml` so the next ansible run does not quietly revert
them. Fourteen boundaries from 1ms to 10s, bracketing the 29ms baseline and the
multi-second faulted request. Confirmed on the cluster: a clean p99 of 49.58ms
against a 50ms boundary became a real distribution once the boundaries landed
either side of it.

> **Wait about five minutes after changing buckets before reading a p99.**
> Series carrying the old `le` values stay in Prometheus until they age out of
> the 5m rate window, and a query spanning both is averaging two different
> histograms. It reads as nonsense rather than as an error, so it is easy to
> mistake for a broken rule.

**The dedicated user-workload Alertmanager**, with `enableAlertmanagerConfig`.
`../ansible` only sets `enableUserWorkload`, which routes user alerts to the
*platform* Alertmanager and leaves `AlertmanagerConfig` objects unhonoured. The
script does a read-modify-write on `user-workload-monitoring-config`, so
existing retention or placement settings there survive.

> **This is the failure worth knowing in advance.** Without
> `enableAlertmanagerConfig: true` the `AlertmanagerConfig` is **accepted and
> silently ignored** — the rule fires, the alert is visible in the console, and
> Slack stays quiet with nothing anywhere reporting an error.
> `setup-alerting.sh status` checks for the StatefulSet precisely because
> nothing else will tell you.

**An alert on `PlaceOrder` with a sample-count guard.** At 0.089 rps a 5m window
holds ~11 samples, and `histogram_quantile` over a nearly empty histogram can
fire on one outlier. The expression requires a floor on the observed rate before
it will speak, and `demo-fault.sh loadgen` raises the rate so the percentile
sits still on stage.

**A Slack message that does not name a cause.** It reports what was measured,
says plainly that it only covers the work inside checkout, and hands over the
TraceQL that finds the offending requests. That is deliberately the same
handover phase 4's agent receives.

The webhook URL is read from `$SLACK_WEBHOOK_URL` into a Secret and never
written to this repository. Create it at
[api.slack.com/apps](https://api.slack.com/apps): new app → **Incoming
Webhooks** → **Add New Webhook to Workspace** → choose the channel. Treat it as
a credential; anyone holding it can post to that channel.

> **The channel is fixed by the webhook, not by this manifest.** Slack does not
> allow a request to override the channel an Incoming Webhook was installed
> against, so the `channel:` field only satisfies Alertmanager's schema. A
> second channel needs a second webhook.

### This webhook is scaffolding, and phase 4 throws it away

Worth being explicit, because it diverges from the upstream reference: that
project uses **no incoming webhook at all**. Slack is reached by a Slack *app* —
`xoxb-` bot token plus `xapp-` app token over **Socket Mode** — and the agent
posts through it. The only webhook in their chain is Grafana to their own
in-cluster bridge, which is plain HTTP and nothing to do with Slack.

The divergence is not cosmetic. **An incoming webhook cannot receive anything.**
The governance beat of this demo is a human typing confirmation in the thread
and the agent reading it, which needs inbound events (`app_mention` plus channel
history) over Socket Mode. A webhook physically cannot carry them. So phase 2
posts one-way to prove the signal path, and phase 4 *replaces* this receiver
rather than extending it.

Socket Mode also suits an on-premise cluster better than anything else on
offer: it is an outbound WebSocket, so Slack reaches the agent with no inbound
ingress to the lab at all.

Which changes what to request now — the tokens are the real ask, and the
webhook is a convenience for this phase only. One app covers both if you set it
up in full while you are there:

| Setting | Value |
|---|---|
| Socket Mode | on |
| App-level token | scope `connections:write` → `xapp-…` |
| Event Subscriptions | on, subscribed to `app_mention` |
| Bot token scopes | `app_mentions:read`, `chat:write`, `channels:read`, `channels:history`, `groups:read`, `groups:history`, `im:read`, `im:history`, `mpim:read`, `mpim:history` |
| Channel | bot invited; note the **ID** (`C…`), not the name |

`chat:write` and not `calls:write` — the upstream runbook calls that out
specifically, which reads like someone lost an afternoon to it. Reinstall the
app to the workspace after changing scopes or the new ones do not take effect.

**Start any approval request now** if the workspace restricts app creation,
which many do. It is the kind of lead time that becomes the blocker days before
a slot.

### Finishing phase 2 without Slack

The webhook is only the last hop, so a delay there does not block the phase.
Skip the `slack` stage and read the alert state directly:

```bash
./scripts/setup-alerting.sh buckets
./scripts/setup-alerting.sh alertmanager
./scripts/setup-alerting.sh rules
./scripts/demo-fault.sh loadgen && ./scripts/demo-fault.sh inject
./scripts/setup-alerting.sh status      # alertstate=pending, then firing
```

That proves the buckets, the rule, the threshold and the fault. Adding the
Secret later turns delivery on with nothing else to change.

### Timing

Roughly 3-5 minutes from inject to Slack: the 5m rate window has to fill with
slow samples, then the rule's `for: 2m` has to elapse. Resolution takes
about as long, for the same reason, and `sendResolved` is on so the all-clear
arrives rather than silence. Rehearse with that in mind — it is too slow to
inject live in an 8-minute slot, so inject before you start talking.

## Phase 4a — Ansible Automation Platform

AAP is the governed remediation path: the agent never runs a command, it
launches a job template someone else wrote. It is the one 4a component with no
prior work in `ocp-onpremise`, so it lives here, in
[`ansible/`](ansible), reusing
[`../ansible/roles/olm_operator`](../ansible/roles/olm_operator) through a
`roles_path` rather than reimplementing the Subscription-resolves,
CSV-Succeeded, CRDs-Established waiting that every other operator in this repo
already goes through.

```bash
cd ansible
export KUBECONFIG=~/.kube/config
ansible-playbook setup_aap.yml --tags preflight     # reads only
ansible-playbook setup_aap.yml
ansible-playbook setup_aap.yml --tags instance,verify
```

Measured on this cluster: package `ansible-automation-platform-operator` in
`redhat-operators`, default channel `stable-2.7` → 2.7.0, CRD
`ansibleautomationplatforms.aap.ansible.com`. The namespace-scoped channel is
used deliberately over `stable-2.7-cluster-scoped`, which watches every
namespace this demo has no use for.

Only the controller is enabled. Hub is a container registry and Event-Driven
Ansible a second controller, and neither sits on the path from "the agent asks"
to "a job template runs".

> **The CR's shape is read from the cluster, not assumed.** AAP moved from
> separate `AutomationController`, `AutomationHub` and EDA kinds in 2.4 to one
> `AnsibleAutomationPlatform` in 2.5, and which component keys its spec accepts
> is a property of the installed operator. So the role reads the storage
> version and the spec's property names out of the CRD, then writes only the
> keys that version has — a key the schema lacks is dropped rather than sent
> and rejected at admission. `openshift-ai/` settled on the same approach for
> `DataScienceCluster`, for the same reason, and this project has now been
> caught out by four assumed-API mistakes.

## The analyzer

`scripts/trace-analyze.py` computes the diagnosis; the model narrates what it
returns. Everything it reports is arithmetic over span timings, so the same
trace gives the same verdict every run — which is what makes a demo rehearsable
and stops a mid-size model inventing a fluent, wrong cause.

```bash
# against the cluster — opens and waits for its own port-forward, and reads
# the token from `oc whoami -t`, so this is the whole command
./scripts/trace-analyze.py --slowest --min-ms 2000 --baseline-ms 31.5

# offline, from a saved trace — this is how you rehearse
./scripts/trace-analyze.py --file trace.json --baseline-ms 31.5

# in-cluster (the MCP wrapper): TEMPO_BASE set, no forwarding
export TEMPO_BASE=https://tempo-tempo-gateway.tracing-system.svc.cluster.local:8080/api/traces/v1/dev/tempo
./scripts/trace-analyze.py --json --trace-id <id>
```

> **Do not background `oc port-forward` and run straight into it.** The shell
> reports the job started before the forward is listening, and the first
> request dies on `ECONNREFUSED` — which reads like a broken gateway rather
> than a race. The script waits for the socket itself, so pass
> `--port-forward` (or simply leave `TEMPO_BASE` unset) instead of setting one
> up by hand.

It reports the request total and slowdown, each repeated-call site, where the
time physically is, opaque spans, the payment ordering and the suspect — then
states plainly that the root cause is *not in the trace* and names the second
signal to check.

### Verified against the cluster

One live run, `EXTRA_LATENCY=800ms`, seven-item cart:

```
REQUEST   frontend POST  10461.9ms  (41 spans)
BASELINE  31.5ms  ->  332.1x slower
REPEATED  checkoutservice called ProductCatalogService/GetProduct 7x
          5609.8ms total, 54% of the request (801.4ms each), serial
REPEATED  frontend called ProductCatalogService/GetProduct 5x
          4005.7ms total, 38% of the request (801.1ms each), serial
LOCATION  in-process: productcatalogservice
          client 802.1ms vs server 801.2ms, a 0.9ms gap (99.9% inside the callee)
ORDERING  charge completed at 5626.8ms; the request continued 4835.1ms - 46%
SUSPECT   productcatalogservice - 10407.2ms of self time, 99% of the request
```

That run also **confirms the fixed-post-charge model** the cart-size ceiling
depends on: six sleeps after the charge predicts 6 × 800ms = 4800ms, and the
trace measured 4835.1ms. So the ceiling table above can be trusted, and the
post-charge share is arithmetic rather than luck — 4.8s fixed over a total that
grows with the cart.

### Three bugs worth recording, because each would have been said on stage

Tested against the real faulted trace, the first version got its three
headline findings wrong — all three fluently, which is the dangerous kind:

- **it blamed `checkoutservice`**, by ranking client/server pairs on client
  duration. The outermost pair always wins: `PlaceOrder`'s server span fills
  `PlaceOrder`'s client span by construction, at a meaningless "100% in
  callee".
- **it blamed `frontend` as the suspect**, by summing server-span time per
  service. The root `POST` span contains the whole request, so that metric
  elects whoever holds it.
- **it called nine strictly serial calls "overlapping"**, because two spans
  overlapped by 0.03ms.

The first two are fixed by **self time** — a span's duration minus the union of
what is nested inside it — which finds where a request actually terminates
rather than who contains it. The third by a tolerance: spans are
nanosecond-stamped across processes, so sequential calls routinely overlap by
microseconds, and "serial" is a claim the narrative rests on.

A fourth only appeared against the real cluster: **`kind` arrives as
`"SPAN_KIND_SERVER"`**, because protobuf's JSON mapping serialises enums by
name. The fixtures were hand-built with integers, so the parser had only ever
been tested against an encoding Tempo does not use — the one place synthetic
data was certain to mislead. It raised rather than misreading, which was luck:
had it decoded to zero, every finding would have been confident noise. Hence
the guard that refuses a trace with no client or server spans instead of
reporting on one.

The lesson generalises past this script. The analysis was covered thoroughly
and the plumbing not at all, because the plumbing needs a cluster — so three
separate integration failures (a raced port-forward, the enum encoding, and a
stale `TEMPO_BASE` suppressing the forward) were all found by running it for
real rather than by testing. Every network failure now prints one actionable
line instead of a traceback, with the hint picked from what actually broke.

A clean trace is the regression test that matters: the analyzer must not invent
findings when nothing is wrong. On the baseline trace it reports no location
verdict at all, and a suspect holding 4.6ms — 15% — rather than an alarming
one.

## Design decisions already made

Recorded here so later phases do not relitigate them.

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

**The agent runtime's image is gone, and only that.** Phase 4b depends on
OpenShell and OpenClaw — the only two components in the upstream reference's own
table filed under *Emerging Technologies lab* rather than Red Hat products. The
pinned image, `quay.io/ryan_nix/openclaw-openshift:openclaw-v2026.6.11`, is a
personal namespace, and the tag now answers:

```
Tag openclaw-v2026.6.11 was deleted or has expired. To pull, revive via time machine
```

Quay's time machine is owner-only, so that image is unrecoverable from outside.
The repository is very much alive — 60 active tags, built daily — but a current
image brings three known breakages, and the kit only solves two:

| on a newer image | handled by the kit? |
|---|---|
| `curl: command not found` in the seed init | yes — v6 hardening, node `fetch()` |
| `tar: command not found` in the seed init | yes — v7 hardening, a node ustar parser |
| **SQLite WAL error on init** | **no** — the only listed remedy is the June image |

And one the docs do not mention: the seed installs
`@openclaw/openshell-sandbox@2026.6.11` and `@openclaw/slack@2026.6.11`, so a
current gateway would run four-month-old plugins, across whatever changed in the
`/hooks/agent` contract the bridge depends on.

Three routes, in descending order of certainty: ask Red Hat Emerging
Technologies for the image; host the agent on RHOAI instead, which keeps every
product in the story and drops the only non-product dependency; or timebox an
attempt on a current tag and find out whether SQLite yields. What makes the
third unattractive is not the odds but the unbounded estimate — "make an
undocumented four-month-newer build work against a kit pinned to June" is the
wrong shape of task to have in front of a demo date.

**Phase 4a and phase 5 are unaffected.** The products install from catalogs.

**AAP needs a subscription** for the governed job-template path, and a manifest
to entitle it.

## What phase 4a reuses, and the one thing that collides

[`sadiquepp/ocp-onpremise`](https://github.com/sadiquepp/ocp-onpremise) already
carries two of 4a's four components, as Ansible in the same idiom as the cluster
build. The cluster is built from that repo anyway, so this is a sequencing
question rather than a porting one: `ocp-onpremise` for the cluster, RHOAI and
SPIRE; this repo for observability and the aiops layer.

**`openshift-ai/` solves the model problem**, which was 4a's only genuinely
uncertain piece. It serves a GGUF model on CPU through a custom KServe
`ServingRuntime` speaking the OpenAI API — necessary because Red Hat's own CPU
vLLM runtime is supported on Power, Z and ARM rather than x86-64, so a custom
runtime is the documented route out. It declares its own probes, since KServe
only generates probes for its v1/v2 protocols and an OpenAI-API server serves
neither, with a startup probe generous enough to survive a model loading off a
lab PVC. It runs `RawDeployment`, so no Knative. And it discovers the CRD shape
rather than assuming it, for the same reason `preflight-platform.sh` exists.

**`spiffe-spire/` covers ZTWI**, and already puts Online Boutique's
checkoutservice → paymentservice call under mTLS with SVIDs from the Workload
API.

That second one is the collision. Its overlay **patches `checkoutservice`** —
`PAYMENT_SERVICE_ADDR=localhost:50051` plus a ghostunnel sidecar — and so does
the `tracing` overlay, which sets this workload's OTel environment. Applied to
one namespace, the later apply wins and one of them is silently lost. Worse for
the demo: ghostunnel changes the span being measured. `PaymentService/Charge`
would then time a localhost proxy and an mTLS handshake, so the client/server
delta grows and the analyzer would read "between the services" where it reads
5.06ms against 0.15ms today.

> **SPIRE is the only part of 4a that modifies the application under
> observation.** RHOAI, AAP and TrustyAI sit beside it. So add it **last**, with
> a combined overlay rather than two competing ones, and re-run
> `trace-analyze.py` afterwards to see what the sidecar did to the waterfall.
> Building the demo on top of it and discovering this while recording is the
> expensive order.

AAP has no prior work. TrustyAI is deliberately off in `openshift-ai/`'s
component list — excluded with pipelines, Ray, Kueue, CodeFlare and ModelMesh
on the grounds that each is more pods than a lab hub has room for — so enabling
it is a decision about the pod budget, not a default to inherit.

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
