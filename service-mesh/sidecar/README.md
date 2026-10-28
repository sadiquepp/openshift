# OpenShift Service Mesh — sidecar mode, with Online Boutique

This is the traditional Istio data plane: an Envoy container **injected into every pod**.
It is the counterpart of [`../ambient`](../ambient). The directory contains the same
workload and the same policy goals, built the other way, so you can compare the two
directly.

You can use it in two ways:

- **On its own.** Install a sidecar-only mesh with `01` to `04` below. You don't need
  OVN local gateway mode, and FIPS-mode clusters are supported.
- **Side by side with ambient.** If you have already installed [`../ambient`](../ambient),
  **skip the install**. An ambient-profile istiod injects sidecars as well, so the
  sidecar overlay deploys into its own namespace, `online-boutique-sidecar`, next to the
  ambient `online-boutique-ambient`. Then follow [Compare the two](#6-compare-the-two).

## Contents

- [Requirements](#requirements)
- [Layout](#layout)
- [1. Install the mesh](#1-install-the-mesh)
- [2. Deploy Online Boutique with sidecars](#2-deploy-online-boutique-with-sidecars)
- [3. Prove the sidecars are there](#3-prove-the-sidecars-are-there)
- [4. Lock it down](#4-lock-it-down)
  - [4.1 STRICT mTLS](#41-strict-mtls)
  - [4.2 Identity policy on Redis](#42-identity-policy-on-redis)
  - [4.3 L7 policy on paymentservice](#43-l7-policy-on-paymentservice)
- [5. Upgrades restart your workloads](#5-upgrades-restart-your-workloads)
- [6. Compare the two](#6-compare-the-two)
- [How the sidecar works](#how-the-sidecar-works)
- [Moving between sidecar and ambient](#moving-between-sidecar-and-ambient)
- [Troubleshooting](#troubleshooting)
- [Tear down](#tear-down)

## Requirements

| | |
|---|---|
| OpenShift | 4.19 or later as written, because the ingress uses the Gateway API CRDs that ship with 4.19. Service Mesh 3 sidecar mode also runs on 4.18, but there you must install the Gateway API CRDs first, as described in the Service Mesh docs. |
| Service Mesh | 3.0 or later. |
| Network | No changes. Sidecar mode does **not** need the `routingViaHost` change that ambient needs. |
| FIPS | Supported. |
| Existing mesh | None, or the ambient mesh from [`../ambient`](../ambient). Not Service Mesh 2.x. |
| `istioctl` | Optional. Its version must match the mesh's Istio version. Every step also has an `oc`-only check. |

## Layout

```
service-mesh/sidecar/
  01-operator.yaml                 Service Mesh 3 operator (same as ../ambient/01)
  02-namespaces.yaml               istio-system, istio-cni
  03-istio.yaml                    istiod, default (sidecar) profile
  04-istiocni.yaml                 istio-cni: required on OpenShift for sidecars too
  online-boutique/
    mesh-client.yaml               a curl pod with its own identity, for testing
    10-peerauthentication-strict.yaml
    20-authz-l4-redis.yaml         only cartservice -> redis (redis's sidecar)
    30-authz-l7-payment.yaml       only checkout may Charge (payment's sidecar)

test-workloads/online-boutique/overlays/sidecar/
  kustomization.yaml               base + injection label + Route -> gateway + loadgenerator fix
  namespace.yaml                   online-boutique-sidecar, labelled for injection
  gateway.yaml                     Gateway API ingress (class istio) + HTTPRoute
```

There are three policy files here and five in the ambient variant. That difference is
explained in step 4.3.

## 1. Install the mesh

**Skip this step if the ambient mesh is already installed.** `03-istio.yaml` defines the
same resource, `Istio/default`, and applying it would switch the existing mesh out of
ambient mode.

All commands run from the repository root.

```bash
M=service-mesh/sidecar
oc apply -f $M/01-operator.yaml
```

```bash
until oc get csv -n openshift-operators -o name | grep -q servicemeshoperator3; do sleep 5; done
oc wait -n openshift-operators --for=jsonpath='{.status.phase}'=Succeeded \
  $(oc get csv -n openshift-operators -o name | grep servicemeshoperator3) --timeout=5m
```

```bash
oc apply -f $M/02-namespaces.yaml
oc apply -f $M/03-istio.yaml
oc wait --for=condition=Ready istio/default --timeout=5m
oc apply -f $M/04-istiocni.yaml
oc wait --for=condition=Ready istiocni/default --timeout=5m
```

```bash
oc get istio,istiocni
oc get pods -n istio-system      # istiod
oc get ds -n istio-cni           # istio-cni-node, one per node
oc get gatewayclass              # istio (and istio-waypoint, unused here)
```

Compared with ambient, there is no `ztunnel` namespace and no `ZTunnel` resource. The
data plane will be inside the application pods.

## 2. Deploy Online Boutique with sidecars

```bash
oc apply -k test-workloads/online-boutique/overlays/sidecar
```

```bash
oc -n online-boutique-sidecar rollout status deploy --timeout=5m
oc -n online-boutique-sidecar wait --for=condition=Programmed gateway/boutique-gateway --timeout=2m
oc get route frontend -n online-boutique-sidecar -o jsonpath='https://{.spec.host}{"\n"}'
```

The namespace is created with `istio-injection=enabled` **before** any pod exists, which
is why every pod gets a sidecar. The overlay's comments explain all three of its
changes. The one that is specific to sidecar mode is the **loadgenerator patch**:

loadgenerator has an init container that waits for `frontend` to respond. istio-cni sets
up the pod's traffic redirection before any container starts. A classic sidecar is an
ordinary container, so it starts only after the init containers finish. The init
container's requests are therefore redirected to an Envoy that isn't running yet, and the
pod never starts. The patch makes the proxy a **native sidecar**: an init container with
`restartPolicy: Always`, which Kubernetes starts first. istiod does this by default only
on nodes running kubelet 1.33 or later, which means OpenShift 4.20 and later. This
start-order problem doesn't exist in ambient mode, because there is no proxy inside the
pod.

## 3. Prove the sidecars are there

**Two containers in every pod:**

```bash
oc get pods -n online-boutique-sidecar
```

Every application pod shows `2/2`. `boutique-gateway-istio-…` shows `1/1`, because it is
an Envoy already and is not injected.

```bash
oc get pod -n online-boutique-sidecar -l app=frontend \
  -o jsonpath='containers: {.items[0].spec.containers[*].name}{"\n"}init: {.items[0].spec.initContainers[*].name}{"\n"}'
oc get pod -n online-boutique-sidecar -l app=loadgenerator \
  -o jsonpath='containers: {.items[0].spec.containers[*].name}{"\n"}init: {.items[0].spec.initContainers[*].name}{"\n"}'
```

Before OpenShift 4.20, frontend has `istio-proxy` under **containers** (a classic sidecar),
and loadgenerator has it under **init** before `frontend-check` (a native sidecar, from
the patch). On 4.20 and later, both have it under init.

**The webhook rewrote the pod.** Compare the Deployment with the pod that was created
from it:

```bash
oc get deploy frontend -n online-boutique-sidecar -o jsonpath='{.spec.template.spec.containers[*].name}{"\n"}'
oc get pod -n online-boutique-sidecar -l app=frontend -o jsonpath='{.items[0].metadata.annotations.sidecar\.istio\.io/status}{"\n"}'
```

The Deployment lists only `server`. The pod carries a `sidecar.istio.io/status`
annotation that records what was injected. Also notice that the frontend pod's HTTP
probes now point at port **15020**. The injector rewrote them so that kubelet's probes
go through `pilot-agent` in the sidecar instead of hitting STRICT mTLS:

```bash
oc get pod -n online-boutique-sidecar -l app=frontend \
  -o jsonpath='{.items[0].spec.containers[?(@.name=="server")].readinessProbe.httpGet}{"\n"}'
```

**The traffic is mTLS, with identities.** paymentservice's sidecar labels every request
it receives with the caller's identity and the security of the connection:

```bash
oc exec -n online-boutique-sidecar deploy/paymentservice -c istio-proxy -- \
  pilot-agent request GET stats/prometheus | grep '^istio_requests_total' | grep 'reporter="destination"' \
  | grep -o 'source_principal="[^"]*"\|connection_security_policy="[^"]*"' | sort | uniq -c
```

The output shows `connection_security_policy="mutual_tls"` and
`source_principal="spiffe://cluster.local/ns/online-boutique-sidecar/sa/checkoutservice"`.
checkoutservice dials plain `paymentservice:50051`, and its sidecar adds TLS. This
metric is an **L7** metric. Every sidecar emits it for every service. In ambient mode
you get it only from a waypoint (ztunnel's access log carried the identities there).

**Each sidecar holds its own pod's certificate, and config for every service in the
mesh:**

```bash
istioctl proxy-config secret deploy/frontend -n online-boutique-sidecar          # one identity: sa/frontend
istioctl proxy-config cluster deploy/frontend -n online-boutique-sidecar | wc -l # every Service istiod discovered
istioctl proxy-status                                                            # one row per pod
```

## 4. Lock it down

```bash
D=service-mesh/sidecar/online-boutique
oc apply -f $D/mesh-client.yaml
oc -n online-boutique-sidecar wait --for=condition=Ready pod/mesh-client
mc() { oc -n online-boutique-sidecar exec mesh-client -c curl -- "$@"; }
```

mesh-client is `2/2` as well, because it was created in an injected namespace. Its curl
sends plaintext to its own sidecar, and the sidecar handles mTLS.

### 4.1 STRICT mTLS

Sidecars already use mTLS with each other. What STRICT changes is whether a pod still
accepts **plaintext from outside the mesh**. To see that, you need a client outside the
mesh: a curl pod in a namespace without injection.

**1. Create the outside client.** It stays running, so you can repeat the same request
before and after the change:

```bash
oc new-project not-in-mesh
oc run probe -n not-in-mesh --image=quay.io/curl/curl:latest --command -- sleep infinity
oc -n not-in-mesh wait --for=condition=Ready pod/probe
out() { oc -n not-in-mesh exec probe -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' http://frontend.online-boutique-sidecar:80/; }
```

**2. Before: plaintext is accepted.** The namespace is still PERMISSIVE, so the frontend
pod's sidecar accepts the request even though it is plaintext:

```bash
out
# 200
```

**3. Apply STRICT:**

```bash
oc apply -f $D/10-peerauthentication-strict.yaml
```

**4. After: plaintext is refused.** Give istiod a few seconds to push the change, then
repeat the exact same request:

```bash
out
# 000
# curl: (56) Recv failure: Connection reset by peer
```

The frontend sidecar now requires mTLS, and the outside pod can't provide it. If you
still get `200`, wait a few seconds and run it again.

**5. Inside the mesh it still works.** The same request from `mesh-client` succeeds,
because mesh-client's own sidecar wraps it in mTLS:

```bash
mc curl -sS -m 5 -o /dev/null -w '%{http_code}\n' http://frontend:80/
# 200
```

The shop also still loads through its Route, because the router sends traffic to the
gateway and the gateway forwards it with mTLS. The behaviour is the same as in ambient;
only the component that enforces it is different.

```bash
oc delete project not-in-mesh
```

### 4.2 Identity policy on Redis

```bash
mc sh -c 'printf "PING\r\n" | nc -w 2 redis-cart 6379'     # +PONG
oc apply -f $D/20-authz-l4-redis.yaml
mc sh -c 'printf "PING\r\n" | nc -w 2 redis-cart 6379'     # nothing: the connection is closed
```

The cart keeps working. The **sidecar inside the redis-cart pod** enforces this policy.
The policy text is the same as in ambient, but two problems from the ambient walkthrough
don't arise here:

- **No waypoint changes the caller's identity.** Nothing sits between cartservice's
  sidecar and redis-cart's sidecar, so redis-cart always sees `sa/cartservice`.
  Ambient step 5.3 had to opt Redis out of the waypoint for this reason.
- **The policy can't be bypassed.** Every connection into the pod passes through the
  pod's own sidecar.

### 4.3 L7 policy on paymentservice

```bash
pay() { mc curl -sS -m 5 --http2-prior-knowledge -o /dev/null -D - \
          -X POST -H 'content-type: application/grpc' --data-binary '' \
          http://${1:-paymentservice}:50051/hipstershop.PaymentService/Charge | grep -i '^grpc-'; }
pay          # a grpc-status from paymentservice (not 7)
oc apply -f $D/30-authz-l7-payment.yaml
pay          # grpc-status: 7 / grpc-message: RBAC: access denied
```

The checkout still works in the browser. The policy is a plain `selector` policy that
matches on HTTP method and path. No waypoint was deployed, and no `targetRefs` were used.
The paymentservice pod's own Envoy is already an L7 proxy, so it evaluates the rule.

Now try to go around it by calling the pod IP directly, as in ambient step 5.5:

```bash
pay $(oc get pod -n online-boutique-sidecar -l app=paymentservice -o jsonpath='{.items[0].status.podIP}')
```

You don't get a successful response from paymentservice, because the request still has
to pass the sidecar in front of it. **Here, one policy does the job that took three
files in ambient** (waypoint, attached policy, and bypass guard). The trade-off is in
the next section: every pod pays for that L7 proxy, including the pods that never need
it.

## 5. Upgrades restart your workloads

The proxy version is fixed when the pod is created. After you upgrade the mesh (change
`spec.version` on `Istio` and `IstioCNI`, or let the operator move to a new release),
the running sidecars keep the old version until their pods are recreated:

```bash
istioctl proxy-status     # VERSION column: old proxies next to the new istiod
oc rollout restart deploy -n online-boutique-sidecar
```

In ambient mode, the same upgrade rolls the ztunnel and istio-cni DaemonSets, istiod
redeploys the waypoints, and no application pod restarts. For a cluster with hundreds
of Deployments, this difference often decides between the two modes.

## 6. Compare the two

This needs both variants running: the ambient mesh, plus `overlays/ambient` and
`overlays/sidecar`. Both namespaces run the same 12 workloads under the same load.

**Containers:**

```bash
oc get pods -n online-boutique-ambient  # 1/1 everywhere
oc get pods -n online-boutique-sidecar  # 2/2 everywhere
```

**What the data plane costs.** In sidecar mode it is the sum of the `istio-proxy`
containers. In ambient mode it is ztunnel (shared by everything on each node) plus the
waypoint, if you deployed one.

```bash
oc adm top pods -n online-boutique-sidecar --containers | awk 'NR==1 || $2=="istio-proxy"'
oc adm top pods -n ztunnel
oc adm top pods -n online-boutique-ambient -l gateway.networking.k8s.io/gateway-name=waypoint
```

**What the data plane reserves.** Requests are what the scheduler holds back, whether
or not they are used:

```bash
oc get pods -n online-boutique-sidecar -o jsonpath='{range .items[*]}{range .spec.containers[?(@.name=="istio-proxy")]}{.resources.requests.cpu}{" "}{.resources.requests.memory}{"\n"}{end}{range .spec.initContainers[?(@.name=="istio-proxy")]}{.resources.requests.cpu}{" "}{.resources.requests.memory}{"\n"}{end}{end}' | sort | uniq -c
```

That shows one reservation per pod. Multiply it by the replica count of every meshed
Deployment in a real cluster. ztunnel's reservation is per node, and it does not grow
when you add replicas.

How to read the numbers fairly: ztunnel is shared by every ambient pod on its node, so
its cost depends on the number of nodes. The sidecar cost depends on the number of pods.
The waypoint is the part of ambient that grows with the number of namespaces that need
L7. With one small app the totals can look similar. The difference shows when you scale
replicas, and it shows best in the **memory** column, because each sidecar holds config
for every Service in the mesh.

| | `online-boutique-sidecar` | `online-boutique` (ambient) |
|---|---|---|
| Containers per pod | 2 | 1 |
| L4 policy enforced by | Destination pod's sidecar | Destination node's ztunnel |
| L7 policy enforced by | Destination pod's sidecar | Waypoint (opt-in) |
| Files to get "only checkout may Charge" | 1 | 3 |
| Pod-IP bypass of L7 policy | Not possible | Possible until you add the L4 guard (ambient 45-*) |
| Enrol or remove a running app | Label, then restart every pod | Label only |
| Mesh upgrade | Restart every meshed pod | Roll two DaemonSets |
| Init containers that need the network | Need native sidecars (patched here) | Work as-is |

The full comparison, including identity, wire protocol and feature gaps, is in
[How ambient differs from sidecar mode](../ambient/README.md#how-ambient-differs-from-sidecar-mode).

## How the sidecar works

### 1. Injection: a webhook rewrites the pod as it is created

```
 oc apply Deployment ──► ReplicaSet creates Pod ──► API server ──► istiod mutating webhook
                                                                      │ namespace has
                                                                      │ istio-injection=enabled
                                                                      ▼
                                       Pod spec + istio-proxy container
                                                + Multus annotation: default/istio-cni
                                                + probes rewritten to :15020
                                                + sidecar.istio.io/status annotation
```

The Deployment is never changed. Only the pods created from it are. That is why
labelling a namespace has no effect on pods that already run, and why removing
injection also needs a restart.

### 2. Redirection: istio-cni, once, at pod creation

On OpenShift, the injected pod lists `default/istio-cni` as an extra Multus network. When
the pod's network is set up, the istio-cni plugin runs **inside the new pod's network
namespace** and writes iptables rules:

- all outbound TCP goes to Envoy on `15001`
- all inbound TCP goes to Envoy on `15006`
- traffic from the proxy's own user ID is exempt, so Envoy's own connections don't loop
  back into itself

On other platforms a privileged `istio-init` container does this. OpenShift's
`restricted-v2` SCC does not allow the `NET_ADMIN` capability that `istio-init` needs,
so on OpenShift the CNI plugin is required. These rules are written before any container
starts, which causes the loadgenerator init-container problem from step 2.

Ambient also uses istio-cni and in-pod iptables, but there the rules point at
**ztunnel's** sockets, and ztunnel can add them to pods that are already running.

### 3. Identity: each sidecar fetches its own certificate

Inside the `istio-proxy` container, `pilot-agent` starts Envoy and acts as its local
secret (SDS) server. It sends istiod a certificate signing request, authenticated with
**the pod's own** service account token, and passes the issued certificate to Envoy. It
renews the certificate before it expires.

Each pod holds only its own private key, so compromising one sidecar exposes one
identity. In ambient, compromising a ztunnel exposes every identity on its node.

### 4. A request, hop by hop

```
 ┌ checkout pod ─────────────────────────┐          ┌ payment pod ──────────────────────────┐
 │ app ─► paymentservice:50051           │          │                                       │
 │   │ iptables → 15001                  │  mTLS    │  iptables → 15006                     │
 │   ▼                                   │  (TLS,   │   ▼                                   │
 │ Envoy (sidecar)                       │  ALPN    │ Envoy (sidecar)                       │
 │   ├ HTTP/2 parsed: route, retries,    │  istio)  │   ├ mTLS: peer = sa/checkoutservice ✔ │
 │   │ L7 metrics, trace span            │─────────►│   ├ AuthorizationPolicy (L4 + L7) ✔   │
 │   ├ endpoint picked: payment pod IP   │ podIP:   │   ├ L7 metrics, trace span            │
 │   └ cert = sa/checkoutservice         │ 50051    │   └ ─► 127.0.0.1:50051 ─► app         │
 └───────────────────────────────────────┘          └───────────────────────────────────────┘
```

Compare this with ambient's [request walk](../ambient/README.md#3-a-request-hop-by-hop):

- **Two full L7 proxies on every hop.** Both sidecars parse HTTP/2, so you get
  `istio_requests_total`, retries, routing and spans for every service without deploying
  anything else. You also pay that parsing cost on every hop, including plain Redis TCP.
- **The connection goes to the app's real port** (`podIP:50051`), wrapped in TLS.
  Ambient tunnels everything to port `15008` (HBONE) and carries the real port inside the
  tunnel. This matters if you write NetworkPolicies.
- **Policy is enforced at the destination pod.** No connection to the app can avoid that
  pod's own Envoy.

### 5. Configuration: every sidecar gets the whole mesh

istiod pushes the full Envoy configuration (listeners, routes, clusters, endpoints) for
every Service it can see to **every** sidecar. Each sidecar's memory therefore grows
with the size of the mesh, and every change to an endpoint is pushed to every pod. Two
things limit that cost:

- `discoverySelectors` in `03-istio.yaml` keeps istiod from watching namespaces outside
  the mesh.
- The Istio `Sidecar` resource limits which services a given workload's proxy is told
  about.

ztunnel receives a much smaller, workload-level view, and only the waypoints get full
Envoy configuration.

## Moving between sidecar and ambient

One ambient-profile control plane serves both modes, and sidecar and ambient workloads
in the same mesh can call each other. That lets you migrate one namespace at a time:

```bash
oc label namespace <ns> istio-injection- istio.io/dataplane-mode=ambient
oc rollout restart deploy -n <ns>      # recreate the pods without sidecars
```

Before you migrate a namespace, check each policy that uses L7 fields with a `selector`.
In ambient, such a policy must move to a waypoint and use `targetRefs`, or ztunnel will
turn it into a DENY (see ambient steps 5.3 to 5.5). The upstream
[sidecar-to-ambient migration guide](https://github.com/istio-ecosystem/sail-operator/tree/main/docs/migrate-from-sidecar-to-ambient)
walks through this on Bookinfo with the same operator.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Pods are `1/1` | The pod was created before the namespace had `istio-injection=enabled`. Run `oc rollout restart deploy -n online-boutique-sidecar`. Or the namespace lacks `istio-discovery=enabled`. Or the Istio resource is not named `default` / uses RevisionBased, in which case use `istio.io/rev=<revision>` instead. |
| Pod stuck in `ContainerCreating` with an error about network `default/istio-cni` | IstioCNI is not installed or not ready: `oc get istiocni`, `oc get network-attachment-definitions -n default`. |
| loadgenerator stuck in `Init`, with `frontend-check` logs saying it can't reach frontend | The native-sidecar annotation is missing. You applied `overlays/default` into an injected namespace instead of `overlays/sidecar`. |
| The shop breaks after step 4.1 | The Route points at `frontend` instead of `boutique-gateway-istio`. |
| Probes fail after injection | Probe rewriting is turned off. Check that the pod's probes point at `:15020`. |
| Proxies on mixed versions after an upgrade | This is expected. Restart the workloads (step 5). |

## Tear down

```bash
oc delete -f service-mesh/sidecar/online-boutique/ --ignore-not-found
oc delete -k test-workloads/online-boutique/overlays/sidecar
```

If the ambient mesh is also installed, stop here and tear it down with
[`../ambient`](../ambient/README.md#tear-down). Otherwise:

```bash
M=service-mesh/sidecar
oc delete -f $M/04-istiocni.yaml -f $M/03-istio.yaml
oc delete -f $M/02-namespaces.yaml
oc delete -f $M/01-operator.yaml
oc delete csv -n openshift-operators $(oc get csv -n openshift-operators -o name | grep servicemeshoperator3 | cut -d/ -f2)
```
