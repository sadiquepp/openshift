# ztunnel: CPU stalls on every new mTLS connection (OpenSSL builds, FIPS)

A write-up and a test kit for a ztunnel performance regression in OpenShift Service
Mesh 3 ambient mode, and for the patch that fixes it. It explains the problem, then
uses the Online Boutique deployment from the [ambient walkthrough](../README.md) to
reproduce it on one cluster, build a patched ztunnel image, and show that the patch
removes the cost.

You do not need a multi-network mesh, an east-west gateway, or a FIPS cluster to
follow it. Each of those is explained where it matters.

## Contents

- [Summary](#summary)
- [The problem](#the-problem)
  - [Symptom](#symptom)
  - [Root cause](#root-cause)
  - [Which builds are affected](#which-builds-are-affected)
  - [The fix](#the-fix)
- [Test strategy](#test-strategy)
- [Requirements](#requirements)
- [Layout](#layout)
- [1. Build the patched image](#1-build-the-patched-image)
- [2. Prepare the test](#2-prepare-the-test)
- [3. Run A: stock image, FIPS off](#3-run-a-stock-image-fips-off)
- [4. Run B: stock image, FIPS forced on](#4-run-b-stock-image-fips-forced-on)
- [5. Run C: patched image, FIPS forced on](#5-run-c-patched-image-fips-forced-on)
- [6. Read the results](#6-read-the-results)
- [7. Record the results](#7-record-the-results)
- [Results of a test run](#results-of-a-test-run)
- [Clean up](#clean-up)
- [Troubleshooting](#troubleshooting)
- [References](#references)

## Summary

- ztunnel builds a rustls `CryptoProvider` from scratch **every time** it needs one,
  which is several times for every new mTLS connection. With the OpenSSL backend,
  building one generates and throws away a real EC key pair for each key-exchange
  group it supports.
- `rustls-openssl` 0.4.2 moved that key generation onto OpenSSL's provider API
  (`EVP_PKEY_generate`). On a host in FIPS mode it now runs inside the FIPS provider,
  where it is many times more expensive. The repeated, wasted key generation that used
  to cost about 2% of ztunnel's CPU became the largest single cost.
- Each rebuild runs on a tokio worker thread. While a worker is busy generating keys,
  every other connection that worker serves waits, so latency rises for traffic that
  opens no new connections at all.
- The fix is a one-function patch that builds the provider once per process. Every
  input to it is already fixed for the life of the process.
- In a [test run](#results-of-a-test-run) with FIPS on, the patch cut ztunnel's CPU per
  new connection about 8 times and request latency about 5 times. Without FIPS it still
  cut CPU per connection by almost half.

## The problem

### Symptom

After a ztunnel upgrade on FIPS-mode nodes:

- ztunnel stalls a worker thread for several milliseconds of CPU on each new
  connection that needs an mTLS handshake.
- A CPU profile of ztunnel shows a large share in `EVP_PKEY_generate`, reached from
  `ztunnel::tls::lib::provider` →
  `<rustls_openssl::kx_group::ec::EcKxGroup as rustls::crypto::SupportedKxGroup>::start`.
  On the previous build, the same caller lands in `EC_KEY_generate_key` and costs very
  little.
- Request latency rises on every path, including reused connections, because of the
  worker stalls.

In the multi-network mesh where this was first found, ztunnel spent 42% of its CPU in
`EVP_PKEY_generate` (2% before the upgrade). Each new double-HBONE connection (through
an east-west gateway) stalled a worker for about 10 ms, and p95 latency rose about 2.5x
on east-west traffic and 3x on single-HBONE traffic through a waypoint.

Double HBONE shows it first because its inner mTLS connection is set up per proxied
connection, outside ztunnel's connection pool. Ordinary single-HBONE traffic pays the
same cost whenever the pool opens a new connection, which is less often.

### Root cause

Two changes combine. Neither is a problem alone.

**1. ztunnel rebuilds the provider on every call.** `provider()` in
`src/tls/lib.rs` (OpenSSL backend) returns a new `CryptoProvider` each time, built as
`CryptoProvider { cipher_suites, kx_groups, ..rustls_openssl::default_provider() }`.
Rust evaluates the whole `default_provider()` call even though two fields are then
replaced. `default_provider()` works out which key-exchange groups are available by
calling `start()` on each one, and `start()` generates a key pair. So each call to
`provider()` generates and discards a P-256 and a P-384 key, plus X25519 when not in
FIPS mode.

`provider()` is on the connection path several times:

| Caller | When |
|---|---|
| `ClientConfig::builder_with_provider(provider())` in `src/tls/certificate.rs` | ztunnel opens an outbound mTLS (HBONE) connection |
| `ServerConfig::builder_with_provider(provider())` in `src/tls/certificate.rs` | ztunnel accepts an inbound mTLS connection |
| certificate chain verification in `src/tls/certificate.rs` | each handshake |
| `IdentityVerifier` in `src/tls/workload.rs` (`verify_tls13_signature`, `supported_verify_schemes`) | each handshake |

This has been in ztunnel's OpenSSL backend for a long time, including upstream
`istio/ztunnel`.

**2. `rustls-openssl` 0.4.2 made each key generation expensive in FIPS mode.**
Up to 0.4.1, `EcKxGroup::start` generated keys with `EcKey::generate`, that is
`EC_KEY_generate_key`. That is OpenSSL's legacy EC code, which bypasses the provider
layer and so never runs in the FIPS provider. 0.4.2 routes all crypto through the
provider API so that FIPS status is reported correctly, so key generation is now
`EVP_PKEY_generate`. On a FIPS host this runs in the FIPS provider, which adds the
FIPS key-generation checks (including a pairwise consistency test) and provider
dispatch to every key.

The 0.4.2 change is a deliberate compliance fix. The waste is in calling it over and
over.

**Why other connections slow down.** Key generation is synchronous CPU work on a
tokio worker. ztunnel runs few workers (two by default with a 200m CPU request, or
fewer when a CPU limit is set). A worker that is busy generating keys does not read
other connections' sockets. Their data waits in the kernel until the worker is free.

### Which builds are affected

All three must be true:

| Condition | How to check |
|---|---|
| ztunnel is built with the OpenSSL backend (`tls-openssl`) | OSSM builds it this way. The binary links `libcrypto.so.3`. |
| It includes `rustls-openssl` 0.4.2 or later | `grep -a -o 'rustls-openssl-0\.[0-9]*\.[0-9]*' ztunnel \| head -1` |
| It is not patched | `grep -a -c 22build_openssl_provider ztunnel` prints `0` |

The regression is large only on **nodes in FIPS mode**
(`/proc/sys/crypto/fips_enabled` is `1`). Without FIPS the repeated key generation
still happens at a lower cost per key. It has been there in every version, and on
traffic that opens many connections it is still a large share of ztunnel's CPU: about
half of it in this test with FIPS off.

To check the image a cluster runs, copy the binary out of it:

```bash
IMG=$(oc -n ztunnel get ds ztunnel -o jsonpath='{.spec.template.spec.containers[0].image}')
podman pull -q "$IMG" >/dev/null
c=$(podman create "$IMG"); podman cp "$c:/usr/local/bin/ztunnel" ./ztunnel-running; podman rm "$c" >/dev/null
grep -a -o 'rustls-openssl-0\.[0-9]*\.[0-9]*' ztunnel-running | head -1
grep -a -c 22build_openssl_provider ztunnel-running
```

`22build_openssl_provider` is part of the patched function's symbol name under both of
Rust's symbol-mangling schemes, so a plain `grep` finds it. Do not rely on `nm -C`:
older binutils (RHEL 9 ships 2.35) cannot demangle the newer `_R…` scheme that current
Rust toolchains use, so a `nm -C | grep ztunnel::…` check can report nothing on a
binary that has the symbols.

For OSSM, the dependency bump is in the downstream source,
[`openshift-service-mesh/ztunnel`](https://github.com/openshift-service-mesh/ztunnel),
not in upstream `istio/ztunnel`: for example commit
[`dbd5932`](https://github.com/openshift-service-mesh/ztunnel/commit/dbd5932) on
`release-1.31.1`, and similar commits on later 1.30 branches. Diffing upstream tags
does not show it. Check the binary instead of the version number.

### The fix

[`0001-tls-cache-openssl-cryptoprovider.patch`](0001-tls-cache-openssl-cryptoprovider.patch)
changes only the OpenSSL backend in `src/tls/lib.rs`. The provider is built once, on
first use, and every caller gets the same `Arc`. The old body moves unchanged into
`build_openssl_provider()`:

```rust
#[cfg(feature = "tls-openssl")]
static OPENSSL_PROVIDER: Lazy<Arc<CryptoProvider>> = Lazy::new(build_openssl_provider);

#[cfg(feature = "tls-openssl")]
pub(super) fn provider() -> Arc<CryptoProvider> {
    OPENSSL_PROVIDER.clone()
}

#[cfg(feature = "tls-openssl")]
fn build_openssl_provider() -> Arc<CryptoProvider> {
    // ... unchanged ...
}
```

Caching is safe because every input is fixed for the life of the process:
`MESH_CIPHER_SUITES`, `TLS12_ENABLED` and `PQC_ENABLED` are already lazy statics, and
the FIPS state cannot change at runtime. The patch adds a unit test that `provider()`
returns the same instance twice.

The patch applies cleanly to the `release-1.30`, `release-1.30.5-2`, `release-1.31`
and `release-1.31.1` branches of `openshift-service-mesh/ztunnel`. The same change for
upstream `istio/ztunnel` `master` is proposed in
[istio/ztunnel#2246](https://github.com/istio/ztunnel/pull/2246).

After the patch, a new connection does one key generation, for the handshake's own key
share, instead of roughly nine.

## Test strategy

The test reproduces the cost on a single cluster with Online Boutique, then shows the
patch removes it. It changes four things from a normal deployment.

1. **No connection reuse.** `POOL_MAX_STREAMS_PER_CONNECTION=1` makes ztunnel open a
   new HBONE connection for every request instead of reusing pooled ones. Every
   request then pays for a client-side and a server-side mTLS handshake, the way every
   proxied connection does on a double-HBONE path. This replaces the east-west
   gateway.
2. **Client and server on different nodes.** `load-client` is never scheduled on
   frontend's node, so two ztunnels handle each request: one opens the connection, the
   other accepts it.
3. **FIPS mode inside ztunnel only.** RHEL's OpenSSL honours
   `OPENSSL_FORCE_FIPS_MODE=1`, which turns on FIPS mode for that one process on a
   non-FIPS host. It is a test hook: the steps check that the FIPS provider really is
   loaded before trusting any numbers. On a cluster installed in FIPS mode, skip it.
4. **Two worker threads.** `ZTUNNEL_WORKER_THREADS=2` keeps the worker count the same
   in every run, whatever the CPU request or limit.

Three runs, changing one thing at a time:

| Run | ztunnel image | FIPS in ztunnel | Shows |
|---|---|---|---|
| A | stock | off | the baseline: rebuilds happen at non-FIPS cost |
| B | stock | forced on | the regression |
| C | patched | forced on | the fix, under the same conditions as B |

Each run measures, in the same way:

- **Latency.** `churn.sh` sends sequential requests from `load-client` to
  `frontend/_healthz`, each on a new connection, and reports p50, p90, p95, p99 and
  max. A second pass adds concurrent background requests to the same service. ztunnel
  opens new connections to one destination one at a time (it holds a per-destination
  lock in its connection pool while the handshake runs, so that waiting requests can
  share the result). With one request per connection, concurrent requests therefore
  queue behind each other's handshakes, which multiplies the handshake cost. This pass
  shows that queueing, not worker threads stalling unrelated connections.
- **ztunnel CPU per request** on both nodes, read from `/proc` on each node before
  and after the sequential pass.
- **Where the CPU goes.** A 30-second CPU profile of the client-side ztunnel, from its
  admin endpoint (`/debug/pprof/profile`).

B against A shows how much FIPS-provider key generation costs. C against B shows how
much of that the patch removes.

## Requirements

| | |
|---|---|
| Mesh and app | The [ambient walkthrough](../README.md) done to step 4: mesh installed, Online Boutique running in `online-boutique-ambient`. |
| Waypoint | Run without one for the main test. If you did step 5.3, remove it from the namespace for now: `oc label ns online-boutique-ambient istio.io/use-waypoint-` (put it back afterwards). A waypoint adds hops and Envoy's own TLS, which blurs the comparison. |
| Nodes | At least two schedulable worker nodes. |
| Access | `cluster-admin`: the steps edit the `ZTunnel` CR and use `oc debug node`. |
| Disruption | Every ztunnel change restarts the ztunnel DaemonSet on all nodes. Meshed traffic on the cluster blips during each restart. Use a lab cluster. |
| Build host | Linux, same CPU architecture as the nodes, with `podman` and `git`. `podman login registry.redhat.io`, and to a registry the cluster can pull from. The build downloads Rust crates, `rustup` and `protoc`, so it needs internet access. |
| Workstation | `oc`, `curl`, and `go tool pprof` (Go installed) or the standalone [`pprof`](https://github.com/google/pprof) to read profiles. |

## Layout

```
service-mesh/ambient/ztunnel-openssl-provider/
  README.md                                    this file
  0001-tls-cache-openssl-cryptoprovider.patch  the fix (openshift-service-mesh/ztunnel)
  build-test-image.sh                          builds the patched test image
  Containerfile                                used by build-test-image.sh
  load-client.yaml                             curl pod, kept off frontend's node
  churn.sh                                     runs in load-client: latency percentiles
  test-lib.sh                                  helpers for the runs (source it)
  results/                                     created by the runs (git-ignored)
```

All commands below run from the repository root.

```bash
D=service-mesh/ambient/ztunnel-openssl-provider
```

## 1. Build the patched image

Find the image the cluster runs. Use its digest, so the test image is built on exactly
that image.

```bash
BASE=$(oc -n ztunnel get ds ztunnel -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "$BASE"
```

If it prints a tag rather than a digest, get the digest with
`oc -n ztunnel get pods -l app=ztunnel -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'`
and use that.

On the build host, from a checkout of this repository, pass that value as the first
argument:

```bash
./service-mesh/ambient/ztunnel-openssl-provider/build-test-image.sh "$BASE" <registry>/<namespace>/ztunnel:patched
```

The script:

1. Copies the ztunnel binary out of the base image, prints its `rustls-openssl`
   version, and stops if the base already has the patch.
2. Reads the source repository and commit from the base image's build history
   (`ZTUNNEL_GIT_URL` and `ZTUNNEL_GIT_SHA`, which OSSM images record). If an image
   does not record them, set `SOURCE_URL` and `SOURCE_COMMIT` yourself.
3. Checks out that commit and applies the patch. It stops if the patch does not apply.
4. Builds ztunnel on UBI 9 against RHEL's OpenSSL, with the same `cargo` command as
   the downstream CI, then copies only the binary over the base image. libcrypto, the
   FIPS provider and its configuration stay exactly as shipped.
5. Checks the new image contains the patch, pushes it, and prints the reference to use.

Note the reference it prints:

```bash
PATCHED=<registry>/<namespace>/ztunnel@sha256:<digest printed by the script>
```

The first build takes a while: it compiles about 500 crates.

If the cluster cannot pull from that registry without credentials, create a pull
secret in the `ztunnel` namespace and add it to the CR when you switch images (step 5).

## 2. Prepare the test

Run everything from the repository root. If this is a new shell, set `D` again:

```bash
D=service-mesh/ambient/ztunnel-openssl-provider
```

**Save the current ZTunnel configuration**, so you can compare against it when you
clean up:

```bash
oc get ztunnel default -o yaml > ztunnel-before.yaml
oc get ztunnel default -o jsonpath='{.spec.values.ztunnel}{"\n"}'
```

If the CR already sets `env`, `image` or `resources`, note them: the clean-up step
removes only the keys this test adds.

**Check for a CPU limit** on ztunnel. CFS throttling would distort every number:

```bash
oc -n ztunnel get ds ztunnel -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
```

If it has a `limits.cpu`, remove it for the test, or record it and keep it the same in
all three runs.

**Stop the load generator.** Online Boutique's `loadgenerator` sends traffic through
the same two ztunnels all the time. With connection reuse off it also opens new
connections in the background, which adds to the measured CPU per request and competes
with the timed requests. Keep it at zero for all runs:

```bash
oc -n online-boutique-ambient scale deploy/loadgenerator --replicas=0
```

**Deploy the load client** and load the helpers:

```bash
oc apply -f $D/load-client.yaml
oc -n online-boutique-ambient wait --for=condition=Ready pod/load-client --timeout=2m
source $D/test-lib.sh
nodes
```

`nodes` prints the two nodes and fails if they are the same. If frontend moves later
(for example it is rescheduled), run `nodes` again.

**Check the client works through the mesh:**

```bash
churn 20 0
```

Expect `errors=0 ok=20`.

**Set the settings used by every run:**

```bash
zt_patch '{"spec":{"values":{"ztunnel":{"env":{
  "POOL_MAX_STREAMS_PER_CONNECTION":"1","ZTUNNEL_WORKER_THREADS":"2"}}}}}'
```

`zt_patch` (from `test-lib.sh`) patches the `ZTunnel` CR, waits for the operator to
update the DaemonSet, then waits for the rollout. Use it for every ztunnel change in
this test: a plain `oc patch` followed straight away by `oc rollout status` can return
before the operator has acted, and report the old DaemonSet as rolled out.

The helpers in `test-lib.sh`, for reference:

| Helper | Does |
|---|---|
| `nodes` | sets `CLIENT_NODE` and `SERVER_NODE` |
| `zt_patch '<json>'` | merge-patches the `ZTunnel` CR and waits until the DaemonSet has changed and rolled out |
| `zt_status` | per node: ztunnel pod, image digest, number of `fips.so` mappings; plus the test env vars |
| `fips_maps <node>` | how many times the FIPS provider (`ossl-modules/fips.so`) is mapped into that node's ztunnel process; above 0 means FIPS mode is on in that process |
| `zt_cpu <node>` | CPU seconds used so far by that node's ztunnel |
| `churn <requests> <workers>` | runs `churn.sh` in `load-client` |
| `run_test <label>` | a full run: status, warm-up, sequential pass with CPU per request, concurrent pass with a CPU profile. Results go to `$D/results/<label>/` |

`REQUESTS` (default 1000) and `WORKERS` (default 4) set the size of each pass.

## 3. Run A: stock image, FIPS off

```bash
run_test A-stock-nofips
```

In `zt_status`, check the image is the stock digest and `fips.so` shows `0` mappings
on both nodes. A run takes a few minutes.

## 4. Run B: stock image, FIPS forced on

```bash
zt_patch '{"spec":{"values":{"ztunnel":{"env":{"OPENSSL_FORCE_FIPS_MODE":"1"}}}}}'
zt_status
```

**Check that FIPS mode took effect before going on.** Each node must show at least one
`fips.so` mapping.

- **It shows mappings:** run the test.

  ```bash
  run_test B-stock-fips
  ```

- **It shows 0:** this OpenSSL build ignores the variable, so a non-FIPS cluster cannot
  reproduce the regression. Use a cluster installed with `fips: true`, where the nodes
  already run in FIPS mode. On such a cluster, skip run A and do not set
  `OPENSSL_FORCE_FIPS_MODE`. Run B is then the stock image as it is.

## 5. Run C: patched image, FIPS forced on

Switch to the patched image. `values.ztunnel.image` takes a full image reference.

```bash
zt_patch "{\"spec\":{\"values\":{\"ztunnel\":{\"image\":\"$PATCHED\"}}}}"
zt_status
```

If the registry needs credentials, add `"imagePullSecrets":["<secret-name>"]` next to
`"image"` in the same patch.

Check that both nodes now show the patched digest and still show `fips.so` mappings.
Then:

```bash
run_test C-patched-fips
```

## 6. Read the results

**Latency and CPU per request:**

```bash
for r in A-stock-nofips B-stock-fips C-patched-fips D-patched-nofips; do
  [ -d $D/results/$r ] || continue
  echo "== $r"
  cat $D/results/$r/latency-sequential.txt $D/results/$r/latency-concurrent.txt $D/results/$r/cpu-per-request.txt
done
```

**Where the client-side ztunnel's CPU goes:**

```bash
for r in A-stock-nofips B-stock-fips C-patched-fips D-patched-nofips; do
  [ -d $D/results/$r ] || continue
  echo "== $r"
  go tool pprof -top -focus='tls::lib::provider' $D/results/$r/cpu-client-ztunnel.pb 2>/dev/null |
    grep -E '^Duration|^Showing nodes'
done
```

The line `Showing nodes accounting for …, X% of Y total` gives the share of ztunnel's
CPU spent under `provider()`. To see what is inside it:

```bash
go tool pprof -top -nodecount=20 $D/results/B-stock-fips/cpu-client-ztunnel.pb
go tool pprof -peek 'EVP_PKEY_generate' $D/results/B-stock-fips/cpu-client-ztunnel.pb
```

**What to expect:**

| | A: stock, no FIPS | B: stock, FIPS | C: patched, FIPS | D: patched, no FIPS |
|---|---|---|---|---|
| CPU share under `provider()` | large, around half: every request is a new connection | larger still; `EVP_PKEY_generate` dominates | near zero | near zero |
| ztunnel CPU per request | baseline | much higher than A | about A, or lower | well below A |
| Latency, sequential | baseline | several ms higher than A | about A, or lower | below A |
| Latency, concurrent | baseline | several times sequential: requests queue behind each other's handshakes | about A, or lower | below A |

The share under `provider()` is high even in run A because the test makes connection
setup most of what ztunnel does, and the rebuilds are most of connection setup. The
effect of FIPS shows in the absolute numbers: B's CPU per request and latency against
A's. Under `provider()` expect four call sites of about equal cost
(`outbound_connector`, `verify_cert_chain`, `verify_tls13_signature`,
`supported_verify_schemes`), and inside them EC key generation for P-256 and P-384
(`EcKxGroup::start`) and, without FIPS, the hybrid post-quantum group
(`X25519HybridKxGroup::start`). In FIPS mode X25519 is not allowed, so only P-256 and
P-384 are probed, and nearly all the time shows as "flat" in `EVP_PKEY_generate`: the
work runs inside the FIPS provider (`fips.so`), whose internal functions have no
exported symbols for the profiler to name.

**How to read it:**

| Result | Meaning |
|---|---|
| B much worse than A, C back near A | Reproduced, and the patch fixes it. |
| B much worse than A, C still worse than A | The patch removes the repeated rebuilds. Whatever remains is the cost of the one real key generation per handshake in the FIPS provider. Look at the profile of C to see what it is. |
| B about the same as A | FIPS mode did not take effect (check `fips.so` mappings), or something else limits throughput (CPU limit, node load). |
| `errors` above 0 in any run | Requests failed. Check `oc -n ztunnel logs` on both nodes before comparing numbers. |

Run each case two or three times if the numbers are close. Node load from other
workloads moves them.

**Optional extra runs:**

- **Patched image, FIPS off (run D).** Shows how much the patch saves without FIPS.
  It matters if run A already spends a large share of CPU under `provider()`. After
  run C:

  ```bash
  zt_patch '{"spec":{"values":{"ztunnel":{"env":{"OPENSSL_FORCE_FIPS_MODE":null}}}}}'
  run_test D-patched-nofips
  ```

  Check `zt_status` shows the patched digest and `0` `fips.so` mappings.
- **The waypoint path.** Put the waypoint back
  (`oc label ns online-boutique-ambient istio.io/use-waypoint=waypoint`, as in step
  5.3) and repeat B and C with new labels, for example `run_test B-stock-fips-waypoint`.
- **The previous release.** If your operator still supports an earlier ztunnel built
  with `rustls-openssl` older than 0.4.2, set `spec.version` on both the `Istio` and
  `ZTunnel` CRs to it, and repeat run B against it. It should be close to C.

## 7. Record the results

Fill this in from `$D/results/`:

| Run | p50 seq | p95 seq | p99 seq | p95 conc | p99 conc | CPU/req client | CPU/req server | `provider()` share |
|---|---|---|---|---|---|---|---|---|
| A stock, no FIPS | | | | | | | | |
| B stock, FIPS | | | | | | | | |
| C patched, FIPS | | | | | | | | |
| D patched, no FIPS (optional) | | | | | | | | |

Environment:

| | |
|---|---|
| OpenShift version | |
| Service Mesh operator version | |
| ztunnel stock image | |
| ztunnel patched image | |
| `rustls-openssl` in stock binary | |
| Node instance type | |
| FIPS: installed or forced | |
| `REQUESTS` / `WORKERS` | |

To share the raw data, pack the results directory. It holds only latency numbers,
image digests, node names and profiles.

```bash
tar czf ztunnel-openssl-provider-results.tgz -C $D results
```

## Results of a test run

The procedure above, run once on a lab cluster. Use it as a reference for what the
four runs look like.

### Environment

| | |
|---|---|
| Service Mesh | OSSM 3, `ZTunnel` `spec.version: v1.31.1` |
| Stock image | `registry.redhat.io/openshift-service-mesh/istio-ztunnel-rhel9@sha256:432a1070feec34efea46560dfd48b97234f740eef07fa6c24ab216f48f1a4ae8` (RHEL 9.8, OpenSSL 3.5.8) |
| Stock binary | built from `openshift-service-mesh/ztunnel` `864cf7d` (`release-1.31.1`), `rustls-openssl` 0.4.2 |
| Patched image | the stock image with the binary rebuilt from `864cf7d` plus the patch, by `build-test-image.sh` |
| Nodes | FIPS not enabled; FIPS forced inside ztunnel with `OPENSSL_FORCE_FIPS_MODE=1` for runs B and C (5 `fips.so` mappings per process) |
| ztunnel resources | CPU request 200m, no CPU limit, `ZTUNNEL_WORKER_THREADS=2` |
| Test settings | `POOL_MAX_STREAMS_PER_CONNECTION=1`, `REQUESTS=1000`, `WORKERS=4`, `loadgenerator` scaled to 0, `load-client` and frontend on different workers, no waypoint |

### Numbers

| | A: stock, no FIPS | B: stock, FIPS | C: patched, FIPS | D: patched, no FIPS |
|---|---|---|---|---|
| Sequential p50 / p95 / p99 (ms) | 9.26 / 11.14 / 12.29 | 42.43 / 50.63 / 56.06 | 8.27 / 9.79 / 10.91 | 6.11 / 7.31 / 8.02 |
| Sequential max (ms) | 54.00 | 68.21 | 13.50 | 17.41 |
| Concurrent p50 / p95 / p99 (ms) | 21.59 / 26.08 / 29.20 | 185.14 / 206.85 / 226.80 | 14.89 / 18.67 / 20.91 | 7.58 / 11.09 / 14.13 |
| ztunnel CPU per request, client (ms) | 5.21 | 31.01 | 3.97 | 2.78 |
| ztunnel CPU per request, server (ms) | 3.92 | 17.78 | 3.80 | 2.61 |
| Client ztunnel CPU under `provider()` | 51% | 87% | 0% | 0% |
| Errors | 0 | 0 | 0 | 0 |

Run A was done three times (the first with `loadgenerator` still running). Sequential
p50 was 9.26 to 9.62 ms and client CPU per request 5.21 to 5.64 ms, so differences of a
few percent between runs are noise.

Compared with the stock image:

| | With FIPS: B → C | Without FIPS: A → D |
|---|---|---|
| Sequential p50 | 5.1x lower | 34% lower |
| Concurrent p50 | 12x lower | 65% lower |
| Client ztunnel CPU per request | 7.8x lower | 47% lower |
| Server ztunnel CPU per request | 4.7x lower | 33% lower |

### What the profiles showed

**Run A (stock, no FIPS):** 51% of the client ztunnel's CPU under `provider()`, spread
evenly over the four call sites: `outbound_connector` 11%, `verify_cert_chain` 14%,
`verify_tls13_signature` 13%, `supported_verify_schemes` 13%. Inside, P-256 and P-384
key generation (`EcKxGroup::start` → `EVP_PKEY_generate` → `EC_KEY_generate_key` →
`EC_POINT_mul`) took 33% and the hybrid X25519MLKEM768 group
(`X25519HybridKxGroup::start` → `EVP_PKEY_Q_keygen`) 13%.

**Run B (stock, FIPS):** 87% under `provider()`, again evenly over the same four call
sites (21 to 23% each). Nearly all of it was `EcKxGroup::start` → `EVP_PKEY_generate`,
83% of it flat in `EVP_PKEY_generate`: the work runs inside the FIPS provider, which has
no symbols the profiler can name. The hybrid group was not probed, since X25519 is not
allowed in FIPS mode. This is the same stack as in the environment where the problem
was first found.

**Runs C and D (patched):** `provider()` at 0%.

From CPU per request × the share under `provider()` ÷ four rebuilds per connection, one
rebuild costs about 0.7 ms of CPU without FIPS and about 6.7 ms with it.

### Findings

- **The patch removes the regression.** With FIPS on, the patched ztunnel used 7.8
  times less client CPU per request than the stock image, and its latency was 5 times
  lower at p50 and 5 times lower at p99.
- **Nearly all of the FIPS cost was the thrown-away probe keys.** With the patch, FIPS
  mode (C) was only about 2 ms slower at p50 than no FIPS (D), and it was faster than
  the stock image without FIPS (A).
- **The waste matters without FIPS too.** The stock image spent half of the client
  ztunnel's CPU on rebuilds even without FIPS, because the test makes every request a
  new connection. The patch cut client CPU per request by 47% and latency by about a
  third. This applies to any ztunnel built with the OpenSSL backend, including
  upstream.
- **The expensive key is probably P-384.** In run C, the client's whole handshake cost
  about 4 ms of CPU, including the one real key generation, so the real key (P-256,
  the first group allowed in FIPS mode) is cheap. The several milliseconds per rebuild
  in run B therefore most likely come from P-384, which the probe generates and the
  handshake never uses. The FIPS provider has no symbols, so the profile cannot
  confirm this. Why P-384 key generation is that slow in the FIPS provider is a
  question for the OpenSSL package owners.
- **Queueing multiplies the cost.** In the concurrent pass, requests to the same
  destination wait for each other's handshakes, so B's concurrent p50 was 4.4 times
  its sequential p50. The cheaper the handshake, the shorter the queue, which is why
  the concurrent numbers improved most.

## Clean up

Put ztunnel back. Setting a key to `null` in a merge patch removes it.

```bash
zt_patch '{"spec":{"values":{"ztunnel":{"image":null,"env":{
  "POOL_MAX_STREAMS_PER_CONNECTION":null,"ZTUNNEL_WORKER_THREADS":null,"OPENSSL_FORCE_FIPS_MODE":null}}}}}'
oc get ztunnel default -o jsonpath='{.spec.values.ztunnel}{"\n"}'
```

If you started a new shell, `source $D/test-lib.sh` first.

Compare with `ztunnel-before.yaml`, and put back anything the CR had before (for
example its own `ZTUNNEL_WORKER_THREADS`, or a CPU limit you removed).

```bash
oc delete -f $D/load-client.yaml
oc -n online-boutique-ambient scale deploy/loadgenerator --replicas=1
```

If you removed the waypoint for the test, put it back:
`oc label ns online-boutique-ambient istio.io/use-waypoint=waypoint`.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `nodes` says both pods are on the same node | `load-client` was created before frontend moved. Delete and re-apply `load-client.yaml`. |
| `load-client` stays `Pending` | Only one schedulable node, or frontend's node is the only one with room. |
| `churn` reports `errors` | ztunnel restarting (wait for the rollout), or a policy denying `load-client`. The policies in `../online-boutique` do not cover frontend. |
| `fips.so` shows `0` after setting `OPENSSL_FORCE_FIPS_MODE` | This OpenSSL build ignores it. See run B. |
| `fips.so` already above 0 in run A | This image loads the FIPS provider even outside FIPS mode, so the mapping count cannot tell the runs apart. Rely on the difference between A and B in CPU per request and in the profile. |
| `fips_maps` prints `no-ztunnel-process` | ztunnel was restarting. Run `zt_status` again. |
| `cpu-client-ztunnel.pb` is empty or tiny | The port-forward failed, or the port is in use. Set `PPROF_PORT` to a free port and run again. |
| `pprof` shows addresses, not function names | The binary is stripped. The stock and patched images built here are not. |
| Build: `The patch does not apply` | The base image is from a ztunnel version whose `src/tls/lib.rs` differs. The patch needs rebasing onto that commit. |
| Build: `cargo` fails on OpenSSL | UBI's `openssl-devel` must be 3.x. The builder prints `openssl version`. |
| `zt_status` shows the old image or env right after a change | The operator had not updated the DaemonSet yet. Use `zt_patch`, which waits for it, or run `zt_status` again. |
| Pods `ImagePullBackOff` after switching image | The cluster cannot pull from your registry. Add a pull secret to the `ztunnel` namespace and `imagePullSecrets` to the CR. |

## References

- [`rustls-openssl`](https://github.com/tofay/rustls-openssl): the 0.4.2 changes that
  route crypto through the OpenSSL 3 provider layer.
- [`openshift-service-mesh/ztunnel`](https://github.com/openshift-service-mesh/ztunnel):
  the downstream source OSSM builds ztunnel from, and its CI build
  (`ossm/ci/pre-submit.sh`).
- [`istio/ztunnel`](https://github.com/istio/ztunnel): upstream. `provider()` is in
  `src/tls/lib.rs`.
- [istio/ztunnel#2246](https://github.com/istio/ztunnel/pull/2246): the upstream pull
  request for this fix.
- [Handling FIPS mode in upstream projects for RHEL](https://developers.redhat.com/articles/2024/02/27/handling-fips-mode-upstream-projects-rhel)
- [OpenSSL FIPS on Fedora](https://hackmd.io/@jaruga/SJXFQ0PNh): describes
  `OPENSSL_FORCE_FIPS_MODE`.
- Upstream ambient docs: [troubleshooting ztunnel](https://istio.io/latest/docs/ambient/usage/troubleshoot-ztunnel/).
