# AZ Failure Resilience Testing on OpenShift (AWS)

Manifests and a runbook for proving that an application survives the loss of a
single AWS Availability Zone: nine replicas spread 3/3/3 across three AZs,
rescheduled onto the survivors when one zone dies, with worker nodes added
automatically if the survivors have no room, and rebalanced back to 3/3/3 once
the zone returns.

Three OpenShift mechanisms do the work, and all three are required — any one on
its own leaves a hole:

| Mechanism | Provides | Without it |
|---|---|---|
| `topologySpreadConstraints` on the Deployment | Even 3/3/3 placement, and Pending pods when a zone is lost | Pods pile into whichever zone has room; losing that zone takes the app down |
| Cluster Autoscaler + one MachineAutoscaler per AZ | New workers in the surviving zones when they are full | Displaced pods stay Pending; capacity never recovers |
| Kube Descheduler, `TopologySpreadConstraint` profile | Eviction of over-weighted zones so pods return to the recovered AZ | The app runs 5/4/0 forever; the next zone failure is far more damaging |

> **Status of the numbers in this document.** Timings and pod counts below are
> derived from the timeouts configured in these manifests and from how the
> scheduler, autoscaler and descheduler are specified to behave. They are
> *expected* results, not a transcript of a recorded run against a live cluster.
> The tables in [Recording your results](#recording-your-results) are laid out
> for you to fill in what you actually observe.

---

## Contents

| File | Purpose |
|---|---|
| `01-namespace.yaml` | `az-resilience-demo` namespace (the descheduler will not touch `openshift-*`) |
| `02-deployment.yaml` | The sample app — 9 replicas, zone + hostname spread constraints |
| `03-service-route.yaml` | Service and edge-terminated Route for observing which pod serves traffic |
| `04-pdb.yaml` | PodDisruptionBudget, `maxUnavailable: 1` — bounds descheduler evictions |
| `05-clusterautoscaler.yaml` | Cluster-wide autoscaler policy (`name: default`) |
| `06-machineautoscaler.yaml` | One MachineAutoscaler per AZ MachineSet, min 1 / max 4 |
| `07-machinehealthcheck.yaml` | Remediates the Machine stranded in the dead AZ |
| `08-descheduler-operator.yaml` | Namespace, OperatorGroup and Subscription for the Kube Descheduler Operator |
| `09-kubedescheduler.yaml` | `KubeDescheduler/cluster` with the `TopologySpreadConstraint` profile |
| `simulate/verify-spread.sh` | Prints live node/zone/pod distribution — run before, during and after |
| `simulate/descheduler-debug.sh` | Read-only diagnostic dump for when the descheduler is not rebalancing |
| `simulate/drain-az.sh` | Simulation method 1 — graceful node drain |
| `simulate/nacl-blackhole-az.sh` | Simulation method 2 — network ACL blackhole, with exact undo |
| `simulate/fis-experiment-template.json` | Simulation method 3 — AWS FIS experiment, whole AZ selected by cluster tag |
| `simulate/fis-experiment-template-subnet.json` | Same, but targeting one named subnet by ARN |

Placeholders (`<infra-id>`, `<vpc-id>`, `<account-id>`, `us-east-1a/b/c`) follow
this repository's convention — substitute real values before applying.

---

## The sample application

A single stateless container: `registry.access.redhat.com/ubi9/httpd-24`, with
its DocumentRoot on an `emptyDir` and an `index.html` written at start-up naming
the pod, node and pod IP.

**Why no PVC, deliberately.** An EBS-backed PVC is bound to one AZ. A pod that
mounts one can only ever be scheduled back into the zone its volume lives in, so
when that zone fails the pod does not move — it stays Pending until the zone
returns, and the test proves nothing about zone failover. Anything with a
per-pod EBS volume (a StatefulSet database, for instance) needs a different
resilience story: cross-AZ replication at the application layer, or a
zone-redundant storage class. This test is about the stateless tier, so the app
holds no state at all.

The node name in the HTTP response is what makes failover visible from outside
the cluster. Map nodes to zones with:

```bash
oc get nodes -L topology.kubernetes.io/zone
```

### Sizing the demo so it actually scales

Requirement 4 — "the remaining two AZs must auto scale worker nodes if no
capacity" — only gets exercised if the survivors genuinely run out of room. If
the pods are tiny, two nodes absorb all nine replicas, nothing goes Pending, and
the autoscaler correctly does nothing. The test then silently proves less than
you think it does.

The CPU request in `02-deployment.yaml` is the knob. It is set to `1` core
against an assumed `m5.xlarge` worker:

| | |
|---|---|
| `m5.xlarge` capacity | 4 vCPU |
| Allocatable after kube/system reserved | ~3500m |
| Pods per node at `cpu: 1` | 3 |
| Steady state | 3 nodes × 3 pods = 9 replicas, exactly full |
| One AZ lost | 2 nodes hold 6; **3 replicas go Pending** → autoscaler fires |

If your workers are a different size, recompute so that one node holds exactly
three replicas:

```bash
# allocatable CPU on a worker, in millicores
oc get node <worker> -o jsonpath='{.status.allocatable.cpu}{"\n"}'
```

Then set the request to roughly `allocatable / 3`, rounded down with headroom
for DaemonSets. Setting it too high is the more common mistake — a request the
autoscaler cannot satisfy on *any* instance in the MachineSet means the pod
stays Pending and no node is ever added.

---

## Prerequisites

- An OpenShift 4.14+ cluster installed across three AZs from
  [`aws/self-managed/connected`](../README.md). 4.14 is the floor because
  `nodeTaintsPolicy` reached GA there; `matchLabelKeys` in the spread
  constraints needs 4.16+ (drop that field on older clusters — it only affects
  rollouts, not failover).
- Exactly one worker MachineSet per AZ, one replica each — the installer's
  default layout. Verify:
  ```bash
  oc get machinesets -n openshift-machine-api
  oc get nodes -l node-role.kubernetes.io/worker -L topology.kubernetes.io/zone
  ```
- `cluster-admin`, and AWS credentials with EC2/NACL (or FIS) permissions for
  whichever simulation method you choose.
- On ROSA or another managed OpenShift, read [Running this on ROSA](#running-this-on-rosa)
  first — three of these manifests do not apply there.
- The cluster's `infrastructureName` and VPC ID:
  ```bash
  INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
  VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${INFRA_ID}-vpc" \
    --query 'Vpcs[0].VpcId' --output text)
  echo "$INFRA_ID / $VPC_ID"
  ```

### Control plane and ingress are a separate concern

This test targets the application tier. Two cluster-level facts make it
meaningful, and both are worth confirming before you start:

- **etcd quorum.** A three-AZ control plane keeps 2 of 3 members after a zone
  loss, so the API stays writable. A cluster with control plane nodes in fewer
  than three zones will lose quorum and the whole exercise stops being about
  your application.
  ```bash
  oc get nodes -l node-role.kubernetes.io/master -L topology.kubernetes.io/zone
  ```
- **Ingress.** The default IngressController runs 2 router replicas with
  anti-affinity, and the AWS NLB/CLB health-checks across zones. The Route stays
  reachable through the survivors, which is why `curl` in a loop is a valid
  probe. If you have pinned routers to specific nodes, re-check that first.

---

## Deploy

Apply in order. The descheduler CR needs its operator installed first.

```bash
cd aws/self-managed/connected/az-resilience

# 1. Application
oc apply -f 01-namespace.yaml
oc apply -f 02-deployment.yaml
oc apply -f 03-service-route.yaml
oc apply -f 04-pdb.yaml

# 2. Autoscaling — SKIP THIS STEP ENTIRELY ON ROSA, see "Running this on ROSA"
#    Substitute <infra-id> first
sed -i "s/<infra-id>/${INFRA_ID}/g" 06-machineautoscaler.yaml 07-machinehealthcheck.yaml
# ...and the AZ suffixes if you are not in us-east-1
oc apply -f 05-clusterautoscaler.yaml
oc apply -f 06-machineautoscaler.yaml
oc apply -f 07-machinehealthcheck.yaml

# 3. Descheduler operator, then wait for the CSV
oc apply -f 08-descheduler-operator.yaml
oc get csv -n openshift-kube-descheduler-operator -w   # wait for Succeeded
oc apply -f 09-kubedescheduler.yaml
```

Confirm the 3/3/3 baseline before breaking anything:

```bash
./simulate/verify-spread.sh
```

You should see three worker nodes, one per zone, and three Running pods in each
zone. If you see anything else — Pending pods, an uneven split — fix that first;
a test that starts from a broken baseline tells you nothing.

Start a traffic probe in a second terminal and leave it running for the whole
test. Its output is the clearest evidence of user-visible impact:

```bash
ROUTE=$(oc get route hello-az -n az-resilience-demo -o jsonpath='{.spec.host}')
while true; do
  printf '%s ' "$(date +%T)"
  curl -sk --max-time 3 "https://${ROUTE}/" | grep -o 'ip-[0-9-]*' | head -n1 || echo "FAIL"
  sleep 1
done
```

---

## Running this on ROSA

Self-managed OpenShift is what this directory targets, and on it the three
autoscaling manifests are the right interface. On **ROSA — and any other managed
OpenShift — skip `05-clusterautoscaler.yaml`, `06-machineautoscaler.yaml` and
`07-machinehealthcheck.yaml`.** Everything else applies unchanged.

The reason is ownership: on ROSA the machine-api is operated by Red Hat SRE.
There are no user-managed MachineSets for a `MachineAutoscaler` to reference,
and `ClusterAutoscaler` / `MachineAutoscaler` / `MachineHealthCheck` CRs are not
the supported interface — expect them to be rejected or reconciled away rather
than to quietly work. Autoscaling is a property of the **machine pool** (ROSA
Classic) or **node pool** (ROSA HCP) instead.

Set it in the Hybrid Cloud Console — [console.redhat.com/openshift](https://console.redhat.com/openshift)
→ your cluster → **Machine pools** → **Edit** → **Enable autoscaling**, with min
and max node counts — or with the `rosa` CLI:

```bash
rosa list machinepools --cluster <cluster>

rosa edit machinepool --cluster <cluster> \
  --enable-autoscaling --min-replicas 3 --max-replicas 12 <machinepool>
```

ROSA Classic also exposes the cluster-wide settings that
`05-clusterautoscaler.yaml` carries — scale-down timers, resource limits,
balancing similar node groups — as a separate managed object; check
`rosa create autoscaler --help` for your CLI version. On ROSA HCP, autoscaling
is configured per node pool only.

### What changes about the test itself

The per-AZ node group model maps across differently depending on the flavour,
and it changes what requirement 4 can actually demonstrate:

| | Self-managed (this directory) | ROSA Classic, multi-AZ | ROSA HCP |
|---|---|---|---|
| Node group | One MachineSet per AZ | One machine pool spanning all 3 AZs | One node pool per AZ |
| Replica granularity | Per zone | Multiples of 3, spread evenly | Per zone |
| Can one zone grow alone? | ✅ Yes | ❌ No — scaling adds a node in *every* zone | ✅ Yes |
| Autoscaling min/max set on | `MachineAutoscaler` | Machine pool | Node pool |

**On ROSA Classic multi-AZ this is the detail to plan around.** A pool
autoscaling 3 → 12 gives exactly the one-worker-per-AZ baseline this test
assumes, and it grows evenly, so the surviving zones do get their capacity. But
you cannot scale a single zone independently: absorbing 3 displaced pods costs
you 3 nodes, one of which lands in the zone that is down (and will fail to come
up until it recovers). The application-level result is the same — the pods do
get scheduled — but the "scale only the surviving AZs" part of requirement 4 is
not something ROSA Classic can express. If that specific behaviour is what you
need to prove, use ROSA HCP with one node pool per AZ, or a self-managed
cluster.

Node remediation is likewise handled by the service on ROSA, which is why
`07-machinehealthcheck.yaml` is skipped — the recovery leg still works, you just
do not own the timing of it.

The parts that carry the actual resilience argument — the topology spread
constraints, the PDB and the Descheduler operator — are ordinary
user-namespace and OLM objects, and behave identically on ROSA. See
[`aws/rosa`](../../../rosa) for the ROSA deployments in this repository.

---

## How the three mechanisms interlock

Three settings in these manifests are load-bearing in ways that are not obvious
from reading them. Each one, set the other way, produces a test that appears to
run but silently fails to demonstrate the requirement.

### 1. `whenUnsatisfiable: DoNotSchedule` is what triggers the autoscaler

The cluster autoscaler reacts to exactly one signal: pods it cannot schedule. A
`ScheduleAnyway` constraint is advisory — the scheduler will happily cram all
nine replicas onto two nodes if that is where the room is, no pod is ever
Pending, and no worker is ever added. Requirement 4 depends on the hard
constraint.

The cost is real and worth stating: `DoNotSchedule` means that if the autoscaler
cannot add capacity — an AWS capacity error, a MachineAutoscaler `maxReplicas`
cap, a quota limit — those replicas stay Pending rather than running somewhere
suboptimal. That is the correct trade for an app whose whole point is zonal
spread, but it is a trade.

### 2. `nodeTaintsPolicy: Honor` is what lets pods leave the dead zone

This is the setting that most often breaks an otherwise correct-looking test.

When an AZ fails, its node is not deleted — it goes `NotReady` and picks up
`node.kubernetes.io/unreachable:NoExecute`. The Node object still exists, so as
far as the scheduler is concerned `us-east-1a` is still a topology domain, now
holding 0 pods.

With the **default** `nodeTaintsPolicy: Ignore`, the skew calculation is over
three domains with a global minimum of 0. Placing a 4th pod in `us-east-1b`
gives `4 - 0 = 4`, which exceeds `maxSkew: 1`, so the scheduler rejects every
surviving node. All three displaced pods sit Pending indefinitely, the app runs
at 6/9, and no amount of autoscaling helps — new nodes in the surviving zones
are rejected for the same reason.

With `nodeTaintsPolicy: Honor`, nodes carrying taints the pod does not tolerate
are excluded from the domain calculation. The unreachable node drops out, two
domains remain, and a 5/4 split satisfies `maxSkew: 1`. The displaced pods
schedule — and go Pending only for the legitimate reason that the surviving
nodes are full, which is what the autoscaler is for.

> The Deployment tolerates `not-ready` and `unreachable` for 60 seconds via
> `tolerationSeconds`, purely so eviction happens inside a reasonable test
> window instead of at the 300s default. The toleration is short-lived and does
> not make the node eligible for the spread calculation.

### 3. Why recovery takes ~15 minutes, not 5

The descheduler evicts; it does not place. Each pass it finds the domains
holding too many pods and evicts from them, bounded by the PDB
(`maxUnavailable: 1`). The scheduler then decides where the replacement goes,
and `maxSkew: 1` forces it into the recovered zone, because that zone is the
global minimum.

Starting from 0/5/4 after the zone returns, with one eviction per pass:

| Descheduler pass | Before | Evicted from | After |
|---|---|---|---|
| 1 (t+5m) | 0 / 5 / 4 | `1b` | 1 / 4 / 4 |
| 2 (t+10m) | 1 / 4 / 4 | `1b` | 2 / 3 / 4 |
| 3 (t+15m) | 2 / 3 / 4 | `1c` | 3 / 3 / 3 ✅ |

Three passes at `deschedulingIntervalSeconds: 300` is roughly 15 minutes. This
is convergence, not a stall — do not conclude the descheduler is broken at the
5-minute mark. If you want it faster for a demo, lower the interval (300s is the
minimum the operator accepts) or temporarily relax the PDB to allow more
concurrent evictions; leave the PDB tight for anything resembling production.

The requirement as stated — "two replicas should move back" — describes the net
effect (one zone gains 3, two zones give up 2 and 1). It takes more than two
evictions to get there, because each eviction is followed by a rescheduling
decision that only moves one pod.

**The recovered zone must have a Ready node before any of this can work.** If
the MachineHealthCheck has not yet replaced the stranded Machine, there is
nowhere for the evicted pods to land and they will bounce back into the
over-weighted zones. Confirm the node is back first.

---

## Simulating the AZ failure

Three methods, in increasing order of fidelity. Run them in this order the first
time — the drain validates your manifests cheaply before you start blackholing
networks.

| | Node drain | NACL blackhole | AWS FIS |
|---|---|---|---|
| Fidelity | Low — planned evacuation | High | High, and repeatable |
| Node state | `Ready,SchedulingDisabled` | `NotReady` | `NotReady` |
| Taint applied | `unschedulable:NoSchedule` | `unreachable:NoExecute` | `unreachable:NoExecute` |
| Exercises `nodeTaintsPolicy` | ✅ Yes (`NoSchedule`) | ✅ Yes | ✅ Yes |
| Exercises MHC remediation | ❌ No | ✅ Yes | ✅ Yes |
| Exercises `NoExecute` eviction | ❌ No — drain evicts | ✅ Yes | ✅ Yes |
| Pod termination | Graceful | Ungraceful (node unreachable) | Ungraceful |
| Blast radius | Cluster only | Every subnet in the AZ | Tagged subnets in the AZ, or one subnet by ARN |
| Auto-revert | No | No (`--undo`) | ✅ Yes, on duration expiry |
| AWS permissions | none | `ec2:*NetworkAcl*` | FIS + service role |
| Descheduler recovery leg | ✅ Faithful | ✅ Faithful | ✅ Faithful |
| Best for | Iterating on spread + descheduler | A true one-off outage test | Scheduled/repeated game days |

### Method 1 — node drain

```bash
./simulate/drain-az.sh us-east-1a
# ... observe ...
./simulate/drain-az.sh us-east-1a --undo
```

**What it exercises.** The topology spread and autoscaler paths, quickly and
with no AWS access — and more than you might expect.

Cordoning adds `node.kubernetes.io/unschedulable:NoSchedule`, and
`nodeTaintsPolicy: Honor` excludes nodes carrying any `NoSchedule` or
`NoExecute` taint the pod does not tolerate. So the cordoned node drops out of
the domain calculation exactly as an unreachable one does, and the drain is a
real test of [mechanism 2](#2-nodetaintspolicy-honor-is-what-lets-pods-leave-the-dead-zone):
with the default `nodeTaintsPolicy: Ignore` the drained zone would still count
as a domain holding 0 pods, and the displaced pods would sit Pending rather than
forming a 5/4 split. If a drain redistributes cleanly, that setting is working.

**What it does not exercise.** The node stays `Ready` and the kubelet keeps
reporting. Pods leave because `oc adm drain` evicts them through the eviction
API, gracefully and one PDB slot at a time — nothing tests the
`unreachable:NoExecute` path, the `tolerationSeconds` you set for it, or how the
app behaves when connections are severed mid-request instead of drained. The
MachineHealthCheck never fires either, since nothing is unhealthy. A passing
drain says your scheduling configuration is correct; it says nothing about
whether the app survives an ungraceful zone loss.

**The uncordon is a faithful recovery test.** On the way back, an uncordoned
node and a freshly booted replacement node look identical to the descheduler:
the zone is a domain again, holding 0 pods, and 0/5/4 violates `maxSkew: 1`. The
rebalance proceeds exactly as after a real outage, which makes cordon → drain →
uncordon the fastest loop for iterating on the descheduler half of this test.
See [Does the descheduler act after a cordon → uncordon?](#does-the-descheduler-act-after-a-cordon--uncordon)

### Method 2 — network ACL blackhole

```bash
VPC_ID=$VPC_ID ./simulate/nacl-blackhole-az.sh us-east-1a
# ... observe for 20-30 minutes ...
VPC_ID=$VPC_ID ./simulate/nacl-blackhole-az.sh us-east-1a --undo
```

A newly created NACL denies all ingress and egress, and the script swaps every
subnet in the target AZ onto one, recording the original associations in
`/tmp/nacl-blackhole-<az>.json` so the undo is exact.

**What it exercises.** Essentially everything a real zone outage does from the
cluster's point of view: the kubelet cannot reach the API server, the node goes
`NotReady`, `unreachable:NoExecute` lands, pods are force-evicted, and the MHC
eventually deletes the Machine.

**Cautions.**
- It blackholes *every* subnet in that AZ in the VPC, not just worker subnets.
  Anything else you run there goes dark too. Check the VPC is dedicated to this
  cluster.
- There is no automatic revert. If your workstation loses the state file you
  will be reconstructing NACL associations by hand — copy
  `/tmp/nacl-blackhole-<az>.json` somewhere safe before you walk away.
- Run the undo from the same machine, and confirm afterwards with
  `aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC_ID"` that no
  `az-blackhole-*` NACL remains.

### Method 3 — AWS Fault Injection Service

The highest-fidelity option and the only one that reverts itself, which makes it
the right choice for anything repeated or scheduled.

One-time IAM setup:

```bash
cat > /tmp/fis-trust.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "fis.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
JSON

aws iam create-role --role-name FISAzFailureRole \
  --assume-role-policy-document file:///tmp/fis-trust.json

aws iam attach-role-policy --role-name FISAzFailureRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSFaultInjectionSimulatorNetworkAccess
```

Two templates ship here, differing only in how they pick their targets.

#### Targeting by tag (whole AZ) — `fis-experiment-template.json`

Selects every subnet carrying the cluster ownership tag, filtered to one AZ.
Substitute `<infra-id>`, `<vpc-id>`, `<account-id>` and the AZ, then:

```bash
aws fis create-experiment-template \
  --cli-input-json file://simulate/fis-experiment-template.json

aws fis start-experiment --experiment-template-id <id>
aws fis get-experiment --id <experiment-id>    # watch state
```

This is the closest analogue to losing the zone: both the private (worker) and
public (NAT/LB) subnets in that AZ go dark, and because selection is by tag it
still hits only this cluster's subnets — the main advantage over the NACL
script, which blackholes every subnet in the AZ regardless of owner.

#### Targeting one named subnet — `fis-experiment-template-subnet.json`

To blackhole exactly one subnet, replace the `resourceTags` + `filters` block
with an explicit `resourceArns` list. The two are mutually exclusive — FIS
rejects a target that sets both — and with `resourceArns` the `selectionMode`
must be `ALL`:

```json
"targets": {
  "worker-subnet": {
    "resourceType": "aws:ec2:subnet",
    "resourceArns": [
      "arn:aws:ec2:<region>:<account-id>:subnet/<subnet-id>"
    ],
    "selectionMode": "ALL"
  }
}
```

Find the private worker subnet for the AZ you want to break:

```bash
AZ=us-east-1a
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region)

# The subnet the worker MachineSet actually places nodes in
SUBNET_ID=$(oc get machineset -n openshift-machine-api "${INFRA_ID}-worker-${AZ}" \
  -o jsonpath='{.spec.template.spec.providerSpec.value.subnet.id}')

# Falls back to a tag lookup if the MachineSet references the subnet by filter
[ -n "$SUBNET_ID" ] || SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
            "Name=availability-zone,Values=${AZ}" \
            "Name=tag:Name,Values=*private*" \
  --query 'Subnets[0].SubnetId' --output text)

echo "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:subnet/${SUBNET_ID}"
```

Substitute that ARN (and `<account-id>` in the `roleArn`) into
`simulate/fis-experiment-template-subnet.json` and start it the same way.

Targeting the private worker subnet alone is arguably the *better* test for this
workload: it isolates the node without touching the NAT gateway, load balancer
ENIs or anything else sharing the zone, so any impact you observe is
unambiguously your application's, not collateral damage. What it stops being is
a full AZ-loss simulation — if you need to prove the cluster survives the whole
zone disappearing, including ingress in that zone, use the tag-targeted
template.

#### `scope` decides what "disrupted" means

The two templates also differ in `scope`, and this matters more than the
targeting does:

| `scope` | Denies | Use when |
|---|---|---|
| `all` | All traffic in and out of the subnet | You want the node simply gone — the closest match to the NACL script |
| `availability-zone` | Traffic between the target subnet and other AZs in the VPC | You want a zone *partition*: the node keeps its own-AZ and internet path but loses the control plane |

`availability-zone` is what AWS's own AZ-power-interruption scenario uses, and
it is the more realistic failure mode. Be aware of what it leaves alive, though:
the node can still reach its own AZ's NAT gateway, so it stays on the internet
while being cut off from the API server. If you want an unambiguous "the node
is unreachable, full stop", use `all` — the single-subnet template does.

One caveat that applies to every scope, and to the NACL script equally: FIS
implements this action by attaching a network ACL to the subnet, and traffic
*within* a single subnet never traverses its NACL. Two nodes in the same subnet
can still talk to each other no matter what scope you pick. Irrelevant for the
one-node-per-AZ layout this test assumes, but it will surprise you if you run
several workers per subnet.

An alternative worth knowing: `aws:ec2:stop-instances` targeting worker
instances in one AZ. It is a more brutal simulation (the instances are actually
stopped, so the MachineSet's replacement is a genuine new EC2 instance) but it
does not model a *network* partition, and stopped instances that later restart
can confuse the machine-api. Prefer `disrupt-connectivity` for this test.

**Stop conditions.** The template ships with `"source": "none"`. For any test
against something you care about, wire a CloudWatch alarm in instead so the
experiment halts on its own if impact exceeds what you expected.

---

## Expected timeline

From the moment connectivity to `us-east-1a` is cut (method 2 or 3):

| Time | Event | Check |
|---|---|---|
| t+0 | AZ blackholed | — |
| ~t+40s | Node marked `NotReady` (node monitor grace period) | `oc get nodes` |
| ~t+100s | `unreachable:NoExecute` evicts the 3 pods (60s toleration) | `oc get pods -n az-resilience-demo` |
| ~t+2m | 3 pods Pending: `Insufficient cpu` on the 2 surviving nodes | `oc get events -n az-resilience-demo` |
| ~t+2m | Autoscaler scales the two surviving MachineSets 1 → 2 | `oc get machinesets -n openshift-machine-api` |
| ~t+7m | New workers `Ready`; distribution reaches 5/4 across two zones | `./simulate/verify-spread.sh` |
| ~t+6m | MHC deletes the Machine in the dead AZ; its MachineSet retries and fails while the zone is down | `oc get machines -n openshift-machine-api` |
| **Throughout** | **Route stays up; the probe loop shows zero failed requests** | the `curl` loop |

After restoring the zone:

| Time | Event |
|---|---|
| r+0 | NACL restored / FIS duration expires |
| ~r+5m | MachineSet succeeds in creating the replacement Machine in `us-east-1a`; node joins `Ready` |
| ~r+5/10/15m | Three descheduler passes walk 0/5/4 → 1/4/4 → 2/3/4 → **3/3/3** |
| ~r+25m | Autoscaler scales the surviving MachineSets back to 1 (`unneededTime: 10m` + `delayAfterAdd: 10m`) |

The single most important line is the bold one: nine replicas becoming six and
then nine again is only resilience if the Route never stopped answering. A
handful of failed requests in the first ~100 seconds — before eviction
completes, while the Service still lists endpoints on the dead node — is
expected; sustained failures are a finding.

---

## Verification

```bash
# Live distribution, the workhorse
./simulate/verify-spread.sh

# Why a pod is Pending
oc describe pod -n az-resilience-demo -l app=hello-az | grep -A5 Events

# Autoscaler decisions
oc logs -n openshift-machine-api -l k8s-app=cluster-autoscaler --tail=100 | grep -i "scale"

# Descheduler evictions (see "Troubleshooting the descheduler" when this is empty)
oc logs deployment/descheduler -n openshift-kube-descheduler-operator --tail=100 \
  | grep -i "evict"

# Eviction events, cluster-wide
oc get events -A --field-selector reason=Evicted --sort-by=.lastTimestamp | tail -20
```

## Recording your results

Fill these in per method — the point of running all three is the comparison.

| Method | Date | Pods evicted by | Time to all-Running | Nodes added | Max Pending | Failed requests | 3/3/3 restored at |
|---|---|---|---|---|---|---|---|
| Node drain | | | | | | | |
| NACL blackhole | | | | | | | |
| AWS FIS | | | | | | | |

Worth capturing alongside: the exact `verify-spread.sh` output at baseline, at
peak disruption, and after convergence.

---

## Troubleshooting

**Displaced pods stay Pending with `node(s) didn't match pod topology spread constraints`.**
`nodeTaintsPolicy: Honor` is missing or the cluster is older than 4.14. The dead
zone is still counted as a domain holding 0 pods. See
[mechanism 2](#2-nodetaintspolicy-honor-is-what-lets-pods-leave-the-dead-zone).

**Pods are Pending and no nodes are added.**
Check, in order: is there a `ClusterAutoscaler` named exactly `default`; does
each AZ MachineSet have a `MachineAutoscaler`; has the MachineAutoscaler hit
`maxReplicas`; is the pod's CPU request larger than any node the MachineSet can
produce; has `resourceLimits.maxNodesTotal` been reached. The autoscaler logs
name the reason.

**Nodes are added but pods stay Pending.**
Usually a second constraint the new node does not satisfy — the `nodeSelector`,
or a hostname spread constraint left at `DoNotSchedule`. `oc describe pod` lists
every filter that rejected each node.

**The descheduler never evicts anything, or evicts without improving the
spread.** It has its own section — work down
[Troubleshooting the descheduler](#troubleshooting-the-descheduler), which
covers the operator install, the CR, the rendered policy, the operand logs and
the PDB in the order that rules each out.

**Extra workers are never removed after recovery.**
`skipNodesWithLocalStorage` defaults to `true` and these pods use `emptyDir`,
which counts as local storage. `05-clusterautoscaler.yaml` sets it to `false`
for exactly this reason. Also check `scaleDown.enabled` and give it
`unneededTime` plus `delayAfterAdd` before concluding it is stuck.

**MachineHealthCheck does not remediate the dead node.**
`maxUnhealthy` is likely too low. One unhealthy node out of three workers is
33%; a `maxUnhealthy` at or below that makes the MHC stand down. Recompute it if
you run more than one worker per zone.

---

## Troubleshooting the descheduler

The descheduler is the quietest of the three mechanisms — it has no CLI, emits
nothing when it decides to do nothing, and the only outward sign it worked is a
pod disappearing five minutes later. When 3/3/3 does not come back, work down
this ladder in order. Each step rules out everything above it, and the fast way
to run the whole thing is:

```bash
./simulate/descheduler-debug.sh
```

Object names below assume the defaults the operator creates. Confirm them once
on your cluster before trusting any command that hardcodes one:

```bash
oc get all,cm,kubedescheduler -n openshift-kube-descheduler-operator
```

### Step 1 — Is the operator actually installed?

```bash
oc get csv -n openshift-kube-descheduler-operator
oc get subscription -n openshift-kube-descheduler-operator -o yaml | grep -A10 'conditions:'
oc get installplan -n openshift-kube-descheduler-operator
```

The CSV must read `Succeeded`. Anything else — `Pending`, `InstallReady`,
`Failed` — and no operand exists yet, so nothing downstream can work. The usual
causes are a missing `redhat-operators` CatalogSource (common on disconnected
clusters, where it must be mirrored) or an OperatorGroup whose
`targetNamespaces` does not include the install namespace.

### Step 2 — Is the CR accepted, and is the operand running?

```bash
oc get kubedescheduler cluster -n openshift-kube-descheduler-operator
oc get kubedescheduler cluster -n openshift-kube-descheduler-operator \
  -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}'

oc get pods -n openshift-kube-descheduler-operator
```

You are looking for two pods: the operator (`descheduler-operator-*`) and the
operand (`descheduler-*`). If only the operator is there, the CR was not
accepted.

Three things silently produce exactly that:

- **The CR is not named `cluster`, or is not in
  `openshift-kube-descheduler-operator`.** The operator reconciles only that
  one name in that one namespace. A CR named anything else is accepted by the
  API server — it is valid YAML against a real CRD — and then ignored forever.
  No error, no status, no operand. Check with
  `oc get kubedescheduler -A`.
- **`managementState` is not `Managed`.** `Removed` scales the operand to zero;
  `Unmanaged` leaves whatever is there and stops reconciling your edits.
- **A `Degraded` condition.** Read the `message` from the jsonpath above —
  `TargetConfigControllerDegraded` usually means the profile or
  `profileCustomizations` you asked for is not valid for the operator version
  installed.

### Step 3 — Does the rendered policy contain the strategy you think it does?

This is the highest-value check, and the one most people skip. The operator
translates the `profiles` list in your CR into a descheduler policy file
delivered as a ConfigMap. Read the rendered result rather than assuming your CR
produced it:

```bash
oc get cm -n openshift-kube-descheduler-operator
oc get cm cluster -n openshift-kube-descheduler-operator \
  -o jsonpath='{.data.policy\.yaml}'
```

`RemovePodsViolatingTopologySpreadConstraint` must appear in that output. If it
does not, the `TopologySpreadConstraint` profile did not take effect regardless
of what the CR says — go back to the `Degraded` message in step 2.

While you are in there, check what the rendered policy says about namespaces and
about soft constraints. If you enabled `enableSoftTopologyConstraints` or a
namespace filter, they show up here; if your customization was silently dropped,
this is where you find out.

### Step 4 — Is there actually a violation to act on?

The descheduler is not broken when it has nothing to do. Before reading logs,
confirm a real violation exists:

```bash
./simulate/verify-spread.sh
oc get nodes -l node-role.kubernetes.io/worker -L topology.kubernetes.io/zone
```

The trap on the recovery leg: **the strategy computes topology domains from
Nodes, not from AWS.** If the recovered AZ has no `Ready`, schedulable node —
the stranded Machine was never remediated, or the replacement is still booting —
then that zone is not a domain at all, the surviving 5/4 split is perfectly
legal under `maxSkew: 1`, and the descheduler correctly evicts nothing. It looks
identical to a broken descheduler.

```bash
oc get machines -n openshift-machine-api
oc get nodes | grep -v Ready        # anything NotReady or SchedulingDisabled
```

Fix the node first, then give it one interval before concluding anything.

### Step 5 — Read the operand log

```bash
# One pass, in full
oc logs deployment/descheduler -n openshift-kube-descheduler-operator --tail=200

# Follow it across the next interval
oc logs deployment/descheduler -n openshift-kube-descheduler-operator -f

# Just the decisions
oc logs deployment/descheduler -n openshift-kube-descheduler-operator --tail=500 \
  | grep -iE 'evict|topolog|skew|violat|pdb|disruption'
```

A pass logs the policy it loaded, the strategies it ran, and a count of pods
evicted. What the interesting lines tell you:

| Log line contains | Means |
|---|---|
| `"Number of evicted pods: 0"` (or no eviction lines at all) | The strategy ran and found nothing to do — you are in step 4 territory, not a descheduler fault |
| `RemovePodsViolatingTopologySpreadConstraint` never appears | The strategy is not in the rendered policy — back to step 3 |
| `Cannot evict pod as it would violate the pod's disruption budget` / HTTP 429 | The PDB is blocking it — step 6 |
| `pod does not have an owner reference` / `no ReplicaSet owner` | Bare pods are skipped by design. Deployment pods are fine; if you see this, you are looking at something else |
| `pod has local storage and descheduler is not configured with evictLocalStoragePods` | An `emptyDir` pod being refused. Our app uses `emptyDir`, so if this appears the operator's defaults are stricter than expected — enable local-storage eviction in `profileCustomizations` |
| `pod is a DaemonSet pod` / `is a static pod` / `priority higher than threshold` | Correctly skipped, not your workload |
| `namespace is excluded` | Step 7 |

If the log is too terse to tell you anything, raise the level on the CR — it
takes `logLevel` from the standard OpenShift operator spec:

```bash
oc patch kubedescheduler cluster -n openshift-kube-descheduler-operator \
  --type=merge -p '{"spec":{"logLevel":"Debug"}}'
```

`Debug` is usually enough; `Trace` logs per-pod decisions. Put it back to
`Normal` afterwards — this is noisy.

### Step 6 — Is the PDB refusing every eviction?

```bash
oc get pdb -n az-resilience-demo
oc describe pdb hello-az -n az-resilience-demo
```

Read the **ALLOWED DISRUPTIONS** column. If it is `0`, the descheduler cannot
evict anything, and it will keep not evicting anything forever — this is the
single most common reason a correctly configured descheduler appears dead.

It reads `0` when `maxUnavailable: 0`, when `minAvailable` equals the replica
count, or — the easy one to miss — when the replicas are not all healthy yet. If
one of the nine pods is `Pending` or `CrashLoopBackOff`, the budget is already
spent on that pod and there is no headroom left for a voluntary eviction. Get
the app to nine `Running` first.

### Step 7 — Is the workload excluded?

The descheduler skips `openshift-*`, `kube-*` and `default` by default, which is
why `01-namespace.yaml` creates a plain user namespace. Also check, in the
rendered policy from step 3:

- a `namespaces.included` list from `profileCustomizations` that does not
  contain `az-resilience-demo` — an inclusion list excludes everything else
- a priority threshold above your pods' priority class
- `evictionLimits`, if your operator version supports it, capping evictions per
  pass low enough that convergence stalls

### Does the descheduler act after a cordon → uncordon?

Yes — a cordon/drain/uncordon cycle produces the same rebalance a real AZ
recovery does, and it is the quickest way to exercise that leg.

Why it works: while the node is cordoned it carries
`node.kubernetes.io/unschedulable:NoSchedule`, so `nodeTaintsPolicy: Honor`
drops it from the domain calculation and the surviving zones legally hold 5 and
4. The uncordon removes that taint, the zone becomes a domain again holding 0
pods, and 0/5/4 now violates `maxSkew: 1`. The descheduler's next pass sees that
violation and starts evicting from the over-weighted zones.

What it needs, in the order worth checking:

```bash
# 1. The taint is actually gone and the node is schedulable
oc get node <node> -o jsonpath='{.spec.unschedulable}{"\n"}{.spec.taints}{"\n"}'

# 2. PDB has headroom (ALLOWED DISRUPTIONS > 0)
oc get pdb -n az-resilience-demo

# 3. The recovered node has room for the returning pods
oc describe node <node> | grep -A5 'Allocated resources'
```

Timing is the part that trips people up. **The descheduler is a timer, not a
controller** — it does not watch for the uncordon and react. The first pass
lands up to `deschedulingIntervalSeconds` (300s) after you uncordon, and
convergence back to 3/3/3 still takes about three passes, so budget ~15 minutes
before concluding it is not working. See
[Why recovery takes ~15 minutes, not 5](#3-why-recovery-takes-15-minutes-not-5).
To skip the wait while iterating, restart the operand as described below.

Two cordon-specific things to be aware of:

- **Do not set `minReplicas: 0` on the MachineAutoscalers.** The recovered node
  sits empty for up to five minutes, which makes it a scale-down candidate. If
  the autoscaler is allowed to take the zone to zero nodes it may remove the
  node before the descheduler rebalances onto it, and the two will fight: the
  descheduler evicts, the pod cannot fit in the zone, it returns to where it
  came from. `06-machineautoscaler.yaml` uses `minReplicas: 1` partly for this
  reason.
- **A cordon alone does nothing.** Cordoning without draining leaves the pods
  running where they are, so the spread never changes and there is nothing to
  rebalance on uncordon. `drain-az.sh` does both; if you cordoned by hand,
  drain too.

You may also see the descheduler evicting *during* the cordoned window, with the
evicted pods simply landing back in the surviving zones. Whether it does depends
on whether your descheduler version applies `nodeTaintsPolicy` when it computes
domains — the scheduler always does, but the descheduler's implementation of
that has changed across releases. It is harmless churn bounded by the PDB, not a
fault, but it is worth recognising so you do not read it as the rebalance having
already happened.

### Forcing a pass instead of waiting

`deschedulingIntervalSeconds: 300` is the operator's minimum, so testing a
change means five minutes per iteration. The operand runs a pass on startup, so
restart it to get an immediate one:

```bash
oc rollout restart deployment/descheduler -n openshift-kube-descheduler-operator
oc rollout status  deployment/descheduler -n openshift-kube-descheduler-operator
oc logs -f deployment/descheduler -n openshift-kube-descheduler-operator
```

This is also how you confirm a CR edit is live at all: after any change to the
`KubeDescheduler`, the operator rolls the operand, so a pod whose `AGE` predates
your edit means your edit never took.

### It evicts, but nothing improves

Eviction is the only thing the descheduler does — the scheduler decides where
the replacement lands. If pods are being evicted and coming straight back to the
same over-weighted zone, the problem is on the scheduling side, not here:

```bash
oc get events -n az-resilience-demo --field-selector reason=Evicted \
  --sort-by=.lastTimestamp | tail -20
oc describe pod -n az-resilience-demo -l app=hello-az | grep -A10 'Events:'
```

`FailedScheduling` on the new pod names the filter that rejected the recovered
zone's node — most often a taint the node still carries, or a `nodeSelector` the
new node does not satisfy. Also remember that three passes are needed to walk
0/5/4 back to 3/3/3; one eviction that appears to change nothing is expected
progress, not a failure. See
[Why recovery takes ~15 minutes, not 5](#3-why-recovery-takes-15-minutes-not-5).

---

## Cleanup

```bash
# Application
oc delete -f 03-service-route.yaml -f 04-pdb.yaml -f 02-deployment.yaml -f 01-namespace.yaml

# Descheduler
oc delete -f 09-kubedescheduler.yaml
oc delete -f 08-descheduler-operator.yaml

# Autoscaling — leaving these in place is usually fine, but they will keep
# scaling MachineSets after the test workload is gone
oc delete -f 07-machinehealthcheck.yaml -f 06-machineautoscaler.yaml -f 05-clusterautoscaler.yaml
```

Then confirm no simulation artefacts survive:

```bash
# No blackhole NACL left behind
aws ec2 describe-network-acls --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'NetworkAcls[?Tags[?starts_with(Value, `az-blackhole`)]].NetworkAclId'

# No FIS experiment still running
aws fis list-experiments --query 'experiments[?state.status==`running`]'

# Workers back to one per zone
oc get machinesets -n openshift-machine-api
```

---

## References

- [Connected OpenShift environment on AWS](../README.md) — the cluster this test assumes
- [Kubernetes: Pod Topology Spread Constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/)
- [OpenShift: Applying autoscaling to a cluster](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/machine_management/applying-autoscaling)
- [OpenShift: Descheduler](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/nodes/controlling-pod-placement-onto-nodes-scheduling#nodes-descheduler)
- [AWS Fault Injection Service: `aws:network:disrupt-connectivity`](https://docs.aws.amazon.com/fis/latest/userguide/fis-actions-reference.html)
