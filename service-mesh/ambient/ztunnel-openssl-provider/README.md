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
(`/proc/sys/crypto/fips_enabled` is `1`). Without FIPS, the repeated key generation
still happens, but each one is cheap.

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
and `release-1.31.1` branches of `openshift-service-mesh/ztunnel`. A variant for
upstream `istio/ztunnel` `master` is on
[`sadiquepp/ztunnel`, branch `fix/cache-openssl-provider`](https://github.com/sadiquepp/ztunnel/tree/fix/cache-openssl-provider).

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
| A | stock | off | the baseline: rebuilds happen, but are cheap |
| B | stock | forced on | the regression |
| C | patched | forced on | the fix, under the same conditions as B |

Each run measures, in the same way:

- **Latency.** `churn.sh` sends sequential requests from `load-client` to
  `frontend/_healthz`, each on a new connection, and reports p50, p90, p95, p99 and
  max. A second pass adds concurrent background requests, which shows the worker
  stalls hurting other connections.
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
oc patch ztunnel default --type merge -p '
spec:
  values:
    ztunnel:
      env:
        POOL_MAX_STREAMS_PER_CONNECTION: "1"
        ZTUNNEL_WORKER_THREADS: "2"
'
oc -n ztunnel rollout status ds/ztunnel --timeout=5m
```

The helpers in `test-lib.sh`, for reference:

| Helper | Does |
|---|---|
| `nodes` | sets `CLIENT_NODE` and `SERVER_NODE` |
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
oc patch ztunnel default --type merge -p '
spec:
  values:
    ztunnel:
      env:
        OPENSSL_FORCE_FIPS_MODE: "1"
'
oc -n ztunnel rollout status ds/ztunnel --timeout=5m
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
oc patch ztunnel default --type merge -p "
spec:
  values:
    ztunnel:
      image: $PATCHED
"
oc -n ztunnel rollout status ds/ztunnel --timeout=5m
zt_status
```

If the registry needs credentials, add `imagePullSecrets: [<secret-name>]` next to
`image` in the same patch.

Check that both nodes now show the patched digest and still show `fips.so` mappings.
Then:

```bash
run_test C-patched-fips
```

## 6. Read the results

**Latency and CPU per request:**

```bash
for r in A-stock-nofips B-stock-fips C-patched-fips; do
  echo "== $r"
  cat $D/results/$r/latency-sequential.txt $D/results/$r/latency-concurrent.txt $D/results/$r/cpu-per-request.txt
done
```

**Where the client-side ztunnel's CPU goes:**

```bash
for r in A-stock-nofips B-stock-fips C-patched-fips; do
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

| | A: stock, no FIPS | B: stock, FIPS | C: patched, FIPS |
|---|---|---|---|
| CPU share under `provider()` | small | large; `EVP_PKEY_generate` dominates | near zero |
| ztunnel CPU per request | baseline | much higher than A | about A, or lower |
| Latency, sequential | baseline | several ms higher than A | about A |
| Latency, concurrent | baseline | higher still, with a long tail | about A |

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

## Clean up

Put ztunnel back. Setting a key to `null` in a merge patch removes it.

```bash
oc patch ztunnel default --type merge -p '
spec:
  values:
    ztunnel:
      image: null
      env:
        POOL_MAX_STREAMS_PER_CONNECTION: null
        ZTUNNEL_WORKER_THREADS: null
        OPENSSL_FORCE_FIPS_MODE: null
'
oc -n ztunnel rollout status ds/ztunnel --timeout=5m
oc get ztunnel default -o jsonpath='{.spec.values.ztunnel}{"\n"}'
```

Compare with `ztunnel-before.yaml`, and put back anything the CR had before (for
example its own `ZTUNNEL_WORKER_THREADS`, or a CPU limit you removed).

```bash
oc delete -f $D/load-client.yaml
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
| Pods `ImagePullBackOff` after switching image | The cluster cannot pull from your registry. Add a pull secret to the `ztunnel` namespace and `imagePullSecrets` to the CR. |

## References

- [`rustls-openssl`](https://github.com/tofay/rustls-openssl): the 0.4.2 changes that
  route crypto through the OpenSSL 3 provider layer.
- [`openshift-service-mesh/ztunnel`](https://github.com/openshift-service-mesh/ztunnel):
  the downstream source OSSM builds ztunnel from, and its CI build
  (`ossm/ci/pre-submit.sh`).
- [`istio/ztunnel`](https://github.com/istio/ztunnel): upstream. `provider()` is in
  `src/tls/lib.rs`.
- [Handling FIPS mode in upstream projects for RHEL](https://developers.redhat.com/articles/2024/02/27/handling-fips-mode-upstream-projects-rhel)
- [OpenSSL FIPS on Fedora](https://hackmd.io/@jaruga/SJXFQ0PNh): describes
  `OPENSSL_FORCE_FIPS_MODE`.
- Upstream ambient docs: [troubleshooting ztunnel](https://istio.io/latest/docs/ambient/usage/troubleshoot-ztunnel/).
