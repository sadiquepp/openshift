# OpenShift Service Mesh — ambient mode, with Online Boutique

Artefacts to stand up Red Hat OpenShift Service Mesh 3 in **ambient mode**, then put
[`test-workloads/online-boutique`](../../test-workloads/online-boutique) into it and
work through what ambient actually does: mTLS with no sidecars, L4 policy in ztunnel,
L7 policy in a waypoint.

The first half is the runbook. The second half
([How ambient differs from sidecar mode](#how-ambient-differs-from-sidecar-mode) and
[How ztunnel works](#how-ztunnel-works)) explains what you just built. Read it in either
order; every step in the runbook points at the part of the explanation it shows.

## Contents

- [Requirements](#requirements)
- [Layout](#layout)
- [1. Switch OVN-Kubernetes to local gateway mode](#1-switch-ovn-kubernetes-to-local-gateway-mode)
- [2. Install the mesh](#2-install-the-mesh)
- [3. Deploy Online Boutique into the mesh](#3-deploy-online-boutique-into-the-mesh)
- [4. Prove it is in the mesh](#4-prove-it-is-in-the-mesh)
- [5. Lock it down, one layer at a time](#5-lock-it-down-one-layer-at-a-time)
  - [5.1 STRICT mTLS](#51-strict-mtls)
  - [5.2 L4 policy in ztunnel](#52-l4-policy-in-ztunnel)
  - [5.3 Add a waypoint](#53-add-a-waypoint)
  - [5.4 L7 policy in the waypoint](#54-l7-policy-in-the-waypoint)
  - [5.5 Close the waypoint bypass](#55-close-the-waypoint-bypass)
- [How ambient differs from sidecar mode](#how-ambient-differs-from-sidecar-mode)
- [How ztunnel works](#how-ztunnel-works)
- [Troubleshooting](#troubleshooting)
- [Tear down](#tear-down)

## Requirements

| | |
|---|---|
| OpenShift | 4.19 or later. The Gateway API CRDs ship with the cluster from 4.19, and ambient needs them for ingress and waypoints. |
| Service Mesh | 3.2 or later. Ambient (ztunnel and waypoints) is GA from 3.2. It was Technology Preview in 3.0 and 3.1. |
| Network | OVN-Kubernetes in **local gateway mode** (step 1). |
| Access | `cluster-admin` for steps 1 and 2. A project admin can do steps 3 to 5 if someone has already labelled the namespace. |
| FIPS | **Not supported.** On a FIPS-mode cluster, stay on sidecar mode. Check the release notes for your version, because ztunnel's FIPS support was being backported. |
| Existing mesh | Use a cluster with no Service Mesh installed. Ambient is not supported next to a 2.6-or-earlier control plane. |
| `istioctl` | Optional, but recommended. It must match the mesh's Istio version (`oc get istio default -o jsonpath='{.status.state} {.spec.version}{"\n"}'`). Every step also has an `oc`-only way to check. |

## Layout

```
service-mesh/ambient/
  01-operator.yaml                 Service Mesh 3 operator Subscription
  02-namespaces.yaml               istio-system, istio-cni, ztunnel
  03-istio.yaml                    istiod, profile: ambient
  04-istiocni.yaml                 istio-cni node agent (puts pods in the mesh)
  05-ztunnel.yaml                  ztunnel DaemonSet (the L4 data plane)
  online-boutique/
    mesh-client.yaml               a curl pod with its own identity, for testing
    10-peerauthentication-strict.yaml
    20-authz-l4-redis.yaml         ztunnel-enforced: only cartservice -> redis
    30-waypoint.yaml               the L7 proxy for the namespace
    40-authz-l7-payment.yaml       waypoint-enforced: only checkout may Charge
    45-authz-paymentservice-via-waypoint.yaml   no path around the waypoint

test-workloads/online-boutique/overlays/ambient/
  kustomization.yaml               default overlay + namespace labels + Route -> gateway
  gateway.yaml                     Gateway API ingress (class istio) + HTTPRoute
```

Every YAML file starts with a comment that explains what it does and why. The comments
are part of the documentation.

## 1. Switch OVN-Kubernetes to local gateway mode

```bash
oc get network.operator cluster \
  -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.routingViaHost}{"\n"}'
```

If that prints `true`, skip to step 2. Otherwise:

```bash
oc patch network.operator cluster --type=merge -p \
  '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true}}}}}'
```

```bash
oc -n openshift-ovn-kubernetes rollout status ds/ovnkube-node
```

**Why.** Red Hat's release notes make this a requirement for liveness and readiness
probes to keep working on ambient pods. Probes are the one kind of traffic that must
*not* reach ztunnel: kubelet is not in the mesh, so under STRICT mTLS ztunnel would
reject it. istio-cni keeps probes out of the mesh by rewriting kubelet's source address
on the node to a fixed link-local IP (`169.254.7.127`), and the redirect rules in each
pod exempt that IP (see [How ztunnel works](#how-ztunnel-works)). The rewrite happens
in the node's own iptables. Local gateway mode is the OVN-Kubernetes configuration in
which that works. If you skip this step, the symptom is ambient pods failing their
probes and going `NotReady`.

**What it costs.** Egress traffic from pods leaves through the host's network stack
instead of OVS's fast path. This is a cluster-wide setting, so get it agreed before you
change it on a shared cluster. The patch restarts `ovnkube-node` on each node in turn.

## 2. Install the mesh

Apply in order. Each `oc wait` must succeed before you apply the next file. All
commands in this README run from the repository root.

```bash
M=service-mesh/ambient
```

**Operator**

```bash
oc apply -f $M/01-operator.yaml
```

```bash
until oc get csv -n openshift-operators -o name | grep -q servicemeshoperator3; do sleep 5; done
oc wait -n openshift-operators --for=jsonpath='{.status.phase}'=Succeeded \
  $(oc get csv -n openshift-operators -o name | grep servicemeshoperator3) --timeout=5m
```

**Namespaces, then the control plane**

```bash
oc apply -f $M/02-namespaces.yaml
oc apply -f $M/03-istio.yaml
oc wait --for=condition=Ready istio/default --timeout=5m
```

**The node agents**

```bash
oc apply -f $M/04-istiocni.yaml
oc wait --for=condition=Ready istiocni/default --timeout=5m
oc apply -f $M/05-ztunnel.yaml
oc wait --for=condition=Ready ztunnel/default --timeout=5m
```

**Check**

```bash
oc get istio,istiocni,ztunnel
oc get pods -n istio-system      # istiod: 1 pod
oc get ds -n istio-cni           # istio-cni-node: one per node
oc get ds -n ztunnel             # ztunnel: one per node
oc get gatewayclass              # istio, istio-waypoint (plus openshift-default if used)
```

There is no Envoy anywhere yet. Ambient adds no proxy to application pods. The only
data plane is the ztunnel DaemonSet, plus a waypoint Envoy for each namespace that you
explicitly ask for one (step 5.3).

## 3. Deploy Online Boutique into the mesh

```bash
oc apply -k test-workloads/online-boutique/overlays/ambient
```

```bash
oc -n online-boutique rollout status deploy --timeout=5m
oc -n online-boutique wait --for=condition=Programmed gateway/boutique-gateway --timeout=2m
oc get route frontend -n online-boutique -o jsonpath='https://{.spec.host}{"\n"}'
```

What the overlay adds to `overlays/default` (the reasons are in the overlay's
`kustomization.yaml`):

1. **Two labels on the namespace.** `istio.io/dataplane-mode=ambient` puts every pod in
   the namespace into the mesh. `istio-discovery=enabled` makes istiod watch the
   namespace (see `discoverySelectors` in `03-istio.yaml`). Nothing in the Deployments
   changes.
2. **A Gateway API `Gateway` with class `istio`.** istiod deploys an Envoy for it
   (`boutique-gateway-istio`) into the namespace.
3. **The `frontend` Route now points at that gateway** instead of the frontend
   Service. The browser path becomes:
   router → gateway Envoy → (HBONE) → frontend.

> **You can enrol an app that is already running.** Deploy `overlays/default`, then
> run `oc label ns online-boutique istio.io/dataplane-mode=ambient istio-discovery=enabled`.
> No pod restarts. The next connection from each pod goes through ztunnel. In sidecar
> mode, the same change needs a rollout of every Deployment, because the proxy is
> added to the pod at creation time.

## 4. Prove it is in the mesh

**No sidecars.** Every pod is `1/1`. In sidecar mode it would be `2/2`.

```bash
oc get pods -n online-boutique
```

**Each pod has been captured.** istio-cni annotates every pod it has redirected:

```bash
oc get pods -n online-boutique -o \
  jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.ambient\.istio\.io/redirection}{"\n"}{end}'
```

Every application pod shows `enabled`. `boutique-gateway-istio-…` shows nothing, because
istiod labelled it `istio.io/dataplane-mode=none`. A gateway is already a mesh proxy,
so it is not captured a second time.

**ztunnel's sockets are inside the application pod.** This shows the core idea of
[how ztunnel works](#how-ztunnel-works). Attach an ephemeral container to frontend
(the frontend image itself has no shell) and list the listening sockets in its network
namespace:

```bash
FE=$(oc get pod -n online-boutique -l app=frontend -o name)
kubectl debug -n online-boutique -it $FE --image=quay.io/curl/curl:latest \
  --profile=restricted -- netstat -tln
```

Output similar to:

```
Proto Recv-Q Send-Q Local Address           Foreign Address         State
tcp        0      0 127.0.0.1:15053         0.0.0.0:*               LISTEN
tcp        0      0 :::15001                :::*                    LISTEN
tcp        0      0 :::15006                :::*                    LISTEN
tcp        0      0 :::15008                :::*                    LISTEN
tcp        0      0 :::8080                 :::*                    LISTEN
```

`8080` is frontend. No process in this pod owns `15001`, `15006`, `15008` or `15053`.
They belong to the ztunnel pod on the node, which opened them inside this pod's network
namespace.

**The traffic is mTLS, with identities.** The load generator is already sending
traffic:

```bash
oc logs -n ztunnel -l app=ztunnel --tail=500 | grep 'access' | grep online-boutique | head -5
```

One line, abridged and wrapped:

```
info  access  connection complete  src.addr=10.128.2.31:48266 src.workload="checkoutservice-…"
  src.namespace="online-boutique" src.identity="spiffe://cluster.local/ns/online-boutique/sa/checkoutservice"
  dst.addr=10.131.0.22:15008 dst.hbone_addr=10.131.0.22:50051 dst.service="paymentservice.online-boutique.svc.cluster.local"
  dst.workload="paymentservice-…" dst.identity="spiffe://cluster.local/ns/online-boutique/sa/paymentservice"
  direction="outbound" bytes_sent=… bytes_recv=… duration="3ms"
```

Read that line from left to right. `dst.addr` is port **15008**, the HBONE port, not
paymentservice's `50051`. The real destination port is carried inside the tunnel
(`dst.hbone_addr`). Both ends have a SPIFFE identity, and each identity is just the
pod's Kubernetes service account.

**With `istioctl`**

```bash
istioctl -n ztunnel ztunnel-config workloads | grep online-boutique
```

`PROTOCOL` is `HBONE` for every pod. Remove the namespace label and the same command
shows `TCP`.

## 5. Lock it down, one layer at a time

Create the test client first. It runs curl inside the mesh under its own service
account, `mesh-client`, which none of the policies below allow.

```bash
D=service-mesh/ambient/online-boutique
oc apply -f $D/mesh-client.yaml
oc -n online-boutique wait --for=condition=Ready pod/mesh-client
```

```bash
mc() { oc -n online-boutique exec mesh-client -- "$@"; }
```

### 5.1 STRICT mTLS

```bash
oc apply -f $D/10-peerauthentication-strict.yaml
```

Ambient pods already used mTLS with each other before this step. What STRICT removes
is **plaintext from outside the mesh**. To see it, make a request from a pod in a
namespace that is not in the mesh:

```bash
oc new-project not-in-mesh
oc run -n not-in-mesh probe --rm -it --restart=Never --image=quay.io/curl/curl:latest -- \
  curl -sS -m 5 -o /dev/null -w '%{http_code}\n' http://frontend.online-boutique:80/
```

Before step 5.1 this prints `200`. Now it fails with a connection reset: the frontend
pod's ztunnel refuses plaintext. The shop still loads through its Route, because the
OpenShift router sends traffic to the gateway, the gateway is not captured, and the
gateway forwards it as HBONE. This is why the overlay routes ingress through a gateway.
If the Route still pointed straight at `frontend`, this step would take the shop down.

```bash
oc delete project not-in-mesh
```

### 5.2 L4 policy in ztunnel

Before the policy is applied, any meshed pod can reach Redis:

```bash
mc sh -c 'printf "PING\r\n" | nc -w 2 redis-cart 6379'
# +PONG
```

```bash
oc apply -f $D/20-authz-l4-redis.yaml
```

```bash
mc sh -c 'printf "PING\r\n" | nc -w 2 redis-cart 6379'
# (nothing: the connection is reset before Redis sees it)
```

The TCP handshake itself still succeeds, because it is answered by the *local*
ztunnel inside mesh-client's own network namespace. The refusal comes a moment later,
from the destination ztunnel, after it has checked who is calling. Clients see a reset,
not a refused connection.

The cart still works in the browser, because the `cartservice` service account is
allowed. The policy uses `selector`, so the **destination pod's ztunnel** enforces it.
ztunnel only knows L4 facts: the peer's identity, which was proven by the mTLS
handshake, and the IP and port. That is enough for "only cartservice talks to Redis",
and you need no proxy to get it.

The redis-cart probes are not blocked either. Kubelet probe traffic is never redirected
to ztunnel (see [step 1](#1-switch-ovn-kubernetes-to-local-gateway-mode)).

### 5.3 Add a waypoint

ztunnel cannot see HTTP or gRPC, so anything that depends on a method, path, header or
gRPC method needs an L7 proxy. In ambient, that proxy is a **waypoint**: one Envoy per
namespace (or per service account) that traffic is routed through, and only when the
destination opts in.

```bash
oc apply -f $D/30-waypoint.yaml
oc -n online-boutique wait --for=condition=Programmed gateway/waypoint --timeout=2m
```

**Before you enrol the namespace, opt redis-cart out:**

```bash
oc -n online-boutique label service redis-cart istio.io/use-waypoint=none
```

```bash
oc label namespace online-boutique istio.io/use-waypoint=waypoint
```

Why redis-cart is opted out: with a waypoint in the path, a connection becomes
cartservice → waypoint → redis-cart. The destination ztunnel then sees the
**waypoint's** identity (`sa/waypoint`), not `sa/cartservice`, and the step 5.2 policy
rejects it. The cart stops working. Redis traffic is not HTTP anyway, so the waypoint
has nothing to add for it. The general rule: **once a waypoint is in the path,
destination-side L4 policies see the waypoint's identity, so put caller-specific rules
on the waypoint** (step 5.4).

Confirm the traffic now passes through the waypoint:

```bash
oc logs -n ztunnel -l app=ztunnel --tail=500 | grep access | grep 'dst.workload="waypoint' | head -2
istioctl -n ztunnel ztunnel-config services | grep online-boutique   # WAYPOINT column
```

### 5.4 L7 policy in the waypoint

Online Boutique uses gRPC, and every RPC is an HTTP/2 POST to
`/<package>.<Service>/<Method>`. Call `PaymentService/Charge` from `mesh-client` and
print only the gRPC status headers:

```bash
pay() { mc curl -sS -m 5 --http2-prior-knowledge -o /dev/null -D - \
          -X POST -H 'content-type: application/grpc' --data-binary '' \
          http://paymentservice:50051/hipstershop.PaymentService/Charge | grep -i '^grpc-'; }
pay
```

Before the policy, the response comes from paymentservice: some `grpc-status` other
than 7, because the empty request is not a valid charge. Now apply the policy:

```bash
oc apply -f $D/40-authz-l7-payment.yaml
pay
# grpc-status: 7
# grpc-message: RBAC: access denied
```

Status 7 is `PERMISSION_DENIED`. The waypoint's Envoy rejected the call before it
reached paymentservice. Checkout still works in the browser, because `checkoutservice`
calling `Charge` matches the rule. The policy uses `targetRefs` to name the **Service**,
and that is what attaches it to the waypoint instead of to ztunnel.

### 5.5 Close the waypoint bypass

The waypoint handles traffic that is addressed to the paymentservice **Service**. If a
client connects directly to a pod IP, the connection goes ztunnel → ztunnel and the
waypoint never sees it:

```bash
PAY_IP=$(oc get pod -n online-boutique -l app=paymentservice -o jsonpath='{.items[0].status.podIP}')
mc curl -sS -m 5 --http2-prior-knowledge -o /dev/null -D - -X POST \
  -H 'content-type: application/grpc' --data-binary '' \
  http://$PAY_IP:50051/hipstershop.PaymentService/Charge | grep -i '^grpc-'
# a status from paymentservice, not 7: the L7 policy was skipped
```

```bash
oc apply -f $D/45-authz-paymentservice-via-waypoint.yaml
```

Run the same pod-IP command again. The connection is now reset by the destination
ztunnel, which accepts connections to paymentservice pods only from the waypoint's
identity. The two policies work as a pair: **ztunnel decides who may reach the pod
(only the waypoint), and the waypoint decides which callers and RPCs are allowed.**

---

## How ambient differs from sidecar mode

Both modes give you the same mesh: the same istiod, the same SPIFFE identities, the same
`AuthorizationPolicy` and `PeerAuthentication` APIs, and mTLS between workloads. What
changes is **where the proxy runs**, and that one change causes almost every other
difference.

```
 SIDECAR                                     AMBIENT

 ┌─ pod ──────────────────────┐              ┌─ pod ───────┐   ┌─ pod ───────┐
 │ app ──► Envoy (L4 + L7)    │              │ app         │   │ app         │
 └────────────┬───────────────┘              └──────┬──────┘   └──────┬──────┘
              │ mTLS (TLS, per pod)                 │ redirected in the pod's netns
              ▼                                     ▼                 ▼
 ┌─ pod ──────────────────────┐              ┌──────── ztunnel (one per node, L4) ────────┐
 │ Envoy (L4 + L7) ──► app    │              └──────────────────┬─────────────────────────┘
 └────────────────────────────┘                                 │ HBONE (mTLS, port 15008)
                                                                ▼
 every pod: +1 container, full L7,                ┌─ waypoint (Envoy, L7) ─┐  only if the
 config, its own cert                             └────────────────────────┘  destination opts in
                                                                │
                                                                ▼
                                                     ztunnel on the destination node ──► app
```

| | Sidecar | Ambient |
|---|---|---|
| Where the proxy runs | An Envoy container in **every** pod | **ztunnel**, one per node (L4). **Waypoint** Envoys, one per namespace or service account, only where you need L7 |
| Joining the mesh | Label the namespace, then **restart every pod** so the webhook injects the proxy | Label the namespace. **No restart**: istio-cni redirects running pods |
| Leaving the mesh | Remove the label, restart again | Remove the label. Takes effect immediately |
| Pod spec | Changed: injected container, init container or CNI, annotations | Unchanged |
| L7 processing | Always on. Every hop parses HTTP, whether or not you use it | Opt-in, per namespace, service or workload. Most traffic stays L4 |
| Resource cost | Proxy CPU and memory **per pod**. Each sidecar holds config for every service it can reach | Per **node** (ztunnel) plus per **namespace** (waypoint). Does not grow with the replica count |
| Hops for L7 traffic | 2 proxies (source sidecar, destination sidecar) | Source ztunnel → waypoint → destination ztunnel |
| Wire protocol between pods | mTLS around the original connection | **HBONE**: HTTP/2 `CONNECT` tunnels over mTLS on port 15008, multiplexed |
| Identity and keys | Each sidecar holds only its own pod's key | ztunnel holds the keys of **every meshed pod on its node**. A compromised ztunnel affects the whole node |
| Upgrades | Restart every workload to pick up the new proxy | Roll the ztunnel and istio-cni DaemonSets. Waypoints are redeployed by istiod. Apps are untouched. A ztunnel restart on a node interrupts that node's meshed connections |
| App lifecycle problems | Start order (app before proxy), Jobs that never finish because the sidecar keeps running, `holdApplicationUntilProxyStarts` | None. The pod contains only your containers |
| `PeerAuthentication: DISABLE` | Sends plaintext | Ignored. Pod-to-pod traffic is always HBONE |
| Telemetry | L7 metrics (`istio_requests_total`) from every pod | ztunnel gives TCP metrics only (`istio_tcp_*`). L7 metrics and traces come only from waypoints |
| Feature parity | Full Istio feature set | Missing or not yet GA in ambient: `EnvoyFilter` on ztunnel, `VirtualService` with waypoints (prefer Gateway API `HTTPRoute`), some multi-cluster topologies, FIPS on OpenShift. See Red Hat's *Service Mesh feature support tables* for your version |

**Policy placement is the main new idea.** In sidecar mode every policy is enforced by
the destination's sidecar, which sees everything. In ambient mode there are two
enforcement points, chosen by how the policy is attached:

| Policy | Attached with | Enforced by | Can match on |
|---|---|---|---|
| L4 | `selector:` (pods) | Destination ztunnel | identity, namespace, IP, port |
| L7 | `targetRefs:` (Service or Gateway) | Waypoint | all of the above, plus method, path, headers, JWT claims |

If you put L7 fields in a `selector` policy, ztunnel cannot evaluate them. Instead of
ignoring the rule, it fails safe: an ALLOW policy turns into a DENY. Steps 5.2 to 5.5
put one policy of each kind on Online Boutique and show the trap that sits between
them.

**When to choose sidecar anyway:** you need a feature ambient does not support yet
(see the table), the cluster runs in FIPS mode, or you need per-pod L7 control on
nearly every workload. In that last case ambient's main saving, L7 only where you need
it, is gone.

## How ztunnel works

ztunnel ("zero-trust tunnel") is a small Rust proxy, not Envoy. It runs as a DaemonSet
with one pod per node, and it does three jobs for every meshed pod on its node:
**mTLS, L4 authorization, and TCP telemetry**. How it gets the traffic in the first
place is the part most diagrams get wrong.

### 1. Enrolment: istio-cni opens sockets for ztunnel inside the pod

```
  node ────────────────────────────────────────────────────────────────────────────
   ┌ istio-cni node agent ┐         ┌ ztunnel ┐
   │ sees: ns labelled    │  netns  │         │  opens 15001 / 15006 / 15008 / 15053
   │ ambient, pod started ├────────►│         ├───────────────┐  INSIDE the pod's netns
   └─────────┬────────────┘  (fd)   └─────────┘               │
             │ iptables rules in the pod's netns              ▼
             └──────────────────────────────────────►┌ pod netns ──────────────┐
                                                     │ app :8080               │
                                                     │ ztunnel's sockets :150xx│
                                                     └─────────────────────────┘
```

1. When a pod starts in an ambient namespace, or a running pod's namespace is labelled,
   the **istio-cni node agent** on that node sees it. It is called as a CNI plugin for
   new pods and watches the API for existing ones.
2. The agent enters the pod's network namespace and adds iptables rules that **apply
   only inside that namespace**. Outbound TCP goes to `15001`, inbound plaintext to
   `15006`, and inbound HBONE to `15008`. Traffic from `169.254.7.127`, kubelet's
   probes, is exempted.
3. The agent sends ztunnel a **file descriptor for the pod's network namespace** over
   a Unix socket. ztunnel uses it to open listening sockets *inside the pod*. That is
   what the `netstat` in [step 4](#4-prove-it-is-in-the-mesh) shows.
4. The agent annotates the pod `ambient.istio.io/redirection: enabled`.

This design is called **in-pod redirection**, and it is why ambient works on OVN-Kubernetes
without node-level tricks. Traffic never leaves the pod's network namespace before it is
encrypted. Nothing is routed on the node, and so ambient does not need to know how the CNI
moves packets between nodes. One ztunnel process serves many pods, each through
sockets inside that pod.

### 2. Identity: ztunnel fetches certificates for its node's pods

ztunnel subscribes to istiod for **workload** configuration: which pods exist, their
IPs, service accounts, Services, waypoints and L4 policies. It does not need Envoy's
full listener, route and cluster config, which is part of why it stays small.

For each meshed pod on its node, ztunnel asks istiod for a certificate **for that pod's
service account**. It authenticates as itself, `ztunnel/ztunnel`. istiod issues the
certificate only if two things hold:

- the request comes from the service account named by `trustedZtunnelNamespace` in
  `03-istio.yaml`, and
- the pod really runs on the requesting ztunnel's node.

This is what lets one process "be" many workloads. It is also why a compromised
ztunnel exposes every identity on its node, and no other node's.

### 3. A request, hop by hop

`checkoutservice` calls `paymentservice:50051`, with no waypoint:

```
 node A                                          node B
 ┌ checkout pod netns ─────────────┐             ┌ payment pod netns ───────────────┐
 │ app ─► 10.x(svc VIP):50051      │             │                                  │
 │   │ iptables: outbound → 15001  │             │  :15008 ztunnel(B) socket        │
 │   ▼                             │   HBONE     │   ├ mTLS: peer = sa/checkout ✔   │
 │ :15001 ztunnel(A) socket        │────────────►│   ├ L4 authz ✔                   │
 │   ├ resolve VIP → pod B IP      │  mTLS h2    │   └ connect → app :50051         │
 │   ├ cert = sa/checkoutservice   │  CONNECT    │                 │                │
 │   └ dial podB:15008             │  :50051     │  app :50051  ◄──┘                │
 └─────────────────────────────────┘             └──────────────────────────────────┘
```

1. The app connects to the Service VIP. iptables **in its own network namespace** sends
   the connection to ztunnel's `15001` socket.
2. ztunnel A looks up the VIP, picks a paymentservice endpoint, and checks whether the
   destination uses a waypoint.
3. It opens, or reuses, an **mTLS HTTP/2 connection to the destination pod's IP on
   port 15008**, presenting *checkoutservice's* certificate. Inside that connection it
   sends `CONNECT <podIP>:50051`. This is **HBONE** (HTTP-Based Overlay Network
   Environment). Many app connections become streams on one tunnel.
4. ztunnel B's `15008` socket is inside the paymentservice pod's network namespace. It
   terminates mTLS, checks the peer identity and the L4 `AuthorizationPolicy`, then
   connects to the app on `:50051`. The app sees an ordinary TCP connection. It has no
   way to tell that the connection crossed the network encrypted.
5. Both ztunnels log the connection (the `access` lines in step 4) and count
   `istio_tcp_*` metrics.

**With a waypoint**, ztunnel A dials the waypoint's `15008` instead. The waypoint
terminates HBONE, parses HTTP/2, applies L7 policy and routing, and opens a **new**
HBONE connection to the destination with **its own** identity. That is why the
destination ztunnel sees `sa/waypoint` (steps 5.3 and 5.5).

**Inbound plaintext** (from a pod outside the mesh, or the router) arrives on `15006`.
In PERMISSIVE mode ztunnel passes it through. In STRICT mode it refuses it (step 5.1).

### 4. What ztunnel deliberately does not do

ztunnel never parses HTTP. It does no retries, no header-based routing, no L7 metrics
and no tracing spans. Each of these needs a waypoint. The split is the point of the
design: the per-node component stays small and safe to run everywhere, and you pay for
Envoy only where you use what Envoy does.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Pods `NotReady` after labelling the namespace, probes time out | Step 1 not done: `routingViaHost` is not `true`. |
| ztunnel logs certificate or authorization errors from istiod | `trustedZtunnelNamespace` in `03-istio.yaml` does not match ZTunnel's `spec.namespace`, or the `ztunnel` namespace lacks `istio-discovery=enabled`. |
| Pods never get the `ambient.istio.io/redirection` annotation | The app namespace lacks `istio-discovery=enabled`, so istiod ignores it. Or istio-cni is not running on that node: `oc get pods -n istio-cni -o wide`. |
| The shop breaks after step 5.1 | The Route points at `frontend` instead of `boutique-gateway-istio`. You applied `overlays/default`, not `overlays/ambient`. |
| The cart breaks after step 5.3 | redis-cart was not opted out of the waypoint (see 5.3). |
| Every request denied after adding a policy | An L7 rule in a `selector` policy. ztunnel turned the ALLOW into a DENY. Use `targetRefs`. |
| NetworkPolicies in the namespace and cross-node traffic fails | Allow TCP **15008** between pods. All meshed traffic arrives on that port, not on the app's port. |

`istioctl ztunnel-config workloads | services | policies | certificates -n ztunnel` shows
what ztunnel knows, and that is the fastest way to check it matches what you expect.
Upstream's [ztunnel troubleshooting guide](https://istio.io/latest/docs/ambient/usage/troubleshoot-ztunnel/)
and [waypoint guide](https://istio.io/latest/docs/ambient/usage/troubleshoot-waypoint/)
apply as written.

## Tear down

Remove the app from the mesh **before** you remove the mesh. Pods still enrolled in a
mesh that has no ztunnel lose connectivity.

```bash
M=service-mesh/ambient
oc delete -f $M/online-boutique/ --ignore-not-found
oc label namespace online-boutique istio.io/use-waypoint- istio.io/dataplane-mode-
oc delete -k test-workloads/online-boutique/overlays/ambient
```

```bash
oc delete -f $M/05-ztunnel.yaml -f $M/04-istiocni.yaml -f $M/03-istio.yaml
oc delete -f $M/02-namespaces.yaml
oc delete -f $M/01-operator.yaml
oc delete csv -n openshift-operators $(oc get csv -n openshift-operators -o name | grep servicemeshoperator3 | cut -d/ -f2)
```

The operator's CRDs (`istios.sailoperator.io` and the others) stay installed. Delete
them only if no other mesh on the cluster uses them. To revert step 1, patch
`routingViaHost` back to `false`, but only after checking that nothing else on the
cluster now depends on local gateway mode.
