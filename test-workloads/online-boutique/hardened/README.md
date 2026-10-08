# Online Boutique on Red Hat Hardened Images

Feasibility investigation and the build assets that come out of it.

**Verdict: yes, with one real caveat — it is a rebuild, not a retag.**

[Red Hat Hardened Images](https://images.redhat.com/) are *base* images: language
runtimes, servers and UBI bases. There is no hardened Online Boutique to point at. Upstream
publishes the 11 service images **prebuilt**, from Alpine, `gcr.io/distroless/static` and
Ubuntu-chiseled bases, so moving this workload onto hardened images means rebuilding every service
from upstream source against `registry.access.redhat.com/hi/*` and pushing the results to your
registry. All 11 build cleanly in principle — nothing in the app needs musl, root, a writable
filesystem or a package the hardened catalog lacks.

The friction is not the languages, it is that the hardened runtime variants are **distroless — no
shell, no package manager**. Three of upstream's containers assume a shell, and one image
(`busybox`) has no hardened equivalent at all. Those four are addressed below and in
[`../overlays/hardened`](../overlays/hardened).

> **What has and has not been run.** The analysis was written without a container engine, from
> upstream's own Dockerfiles, build files and dependency manifests at `v0.10.6` (all read directly)
> plus Red Hat's published documentation. A [`preflight.sh`](preflight.sh) run has since confirmed,
> against the live catalog, that every tag exists, that `hi/python` carries `libstdc++`, and that a
> static Go binary built on `hi/go:latest-builder` runs — see
> [What a real preflight run established](#what-a-real-preflight-run-established). The kustomize
> overlays are verified too: all five render, and the hardened output contains no
> `us-central1-docker.pkg.dev`, `docker.io` or `redis:alpine` reference.
>
> **The eleven service builds themselves have not been run.** Expect to hit something; the
> symptom table under [If a pod will not start](#if-a-pod-will-not-start) covers what is likely,
> and the first real preflight run already caught a wrong Python interpreter name that would
> otherwise have surfaced as a CrashLoopBackOff.

## Why a rebuild, and what it costs

| | upstream v0.10.6 | on hardened images |
|---|---|---|
| Images to obtain | 13, all pulled prebuilt | 11 built by you + 1 mirrored |
| Registries to reach | 3 (Google AR, Docker Hub ×2 images) | 1 (`registry.access.redhat.com`) + yours |
| Docker Hub rate limits | yes, `redis` and `busybox` | gone |
| Build-time network | none | yes — Go, npm, PyPI, NuGet, Maven Central |
| Rebuild on a CVE | wait for upstream | yours to run, whenever you like |

That last row is the actual trade. You take on a build pipeline; in exchange patching stops being
somebody else's release cadence, which is the point of the exercise.

## Catalog mapping

Hardened images live under `registry.access.redhat.com/hi/`. They are no-cost and need no
subscription, so **no pull secret** — which also means the build host needs nothing configured
beyond network access. Each image ships a runtime variant (`:<version>`, distroless) and a builder
variant (`:<version>-builder`, with `dnf` and `bash`), plus `-fips` variants of both if you need
them.

| upstream base | hardened replacement | notes |
|---|---|---|
| `golang:1.26-alpine` | `hi/go:latest-builder` | |
| `gcr.io/distroless/static` | `hi/static` | the direct counterpart; `hi/go:latest` works but ships the toolchain |
| `node:20-alpine` | `hi/nodejs:latest-builder` / `:latest` | |
| `python:3.14-alpine` | `hi/python:3.12-builder` / `:3.12` | 3.12 so the UBI comparison is on one interpreter |
| `eclipse-temurin:25-jre-alpine` | `hi/openjdk:21-builder` / `:21` | `build.gradle` sets `sourceCompatibility = VERSION_21` |
| `mcr.microsoft.com/dotnet/sdk:10.0` | `hi/dotnet-sdk:10.0` | |
| `mcr.microsoft.com/dotnet/runtime-deps:10.0` | `hi/dotnet-runtime:10.0` | |
| `redis:alpine` | `hi/valkey` | Valkey, not Redis — see below |
| `busybox:1.38.0` | **none** | dropped; see below |

## Per-service findings

| service | language | difficulty | why |
|---|---|---|---|
| `frontend` | Go | trivial | `CGO_ENABLED=0` already — the static binary does not care that the libc changed |
| `productcatalogservice` | Go | trivial | same; plus `products.json` |
| `checkoutservice` | Go | trivial | same |
| `shippingservice` | Go | trivial | same |
| `emailservice` | Python | **easier than upstream** | `grpcio`/`protobuf` publish manylinux wheels but no musl wheels; upstream compiles grpcio from source on Alpine, glibc just downloads it |
| `recommendationservice` | Python | **easier than upstream** | same |
| `loadgenerator` | Python | low + entrypoint fix | wheels as above; shell-form `ENTRYPOINT` has to go |
| `currencyservice` | Node | low | `npm install` must re-run — `@google-cloud/profiler` has native code and musl-built modules cannot be copied into glibc |
| `paymentservice` | Node | low | same |
| `cartservice` | .NET | medium | `net10.0`, `Microsoft.NET.Sdk.Web`; publish self-contained |
| `adservice` | Java | medium | Gradle launcher script has to be replaced with a direct JVM invocation |
| `redis-cart` | — | none | mirror `hi/valkey`, no build |

Nothing in the list is a blocker. The Go services are nearly free, the Python services get *better*
on glibc, and the two genuinely fiddly ones (`cartservice`, `adservice`) are fiddly for ordinary
packaging reasons, not security ones.

## Pin the runtime major, not `:latest`

The language runtime major is an **application compatibility decision**, so it
does not belong on a floating tag even though the whole point of these bases is
that patches arrive under one. The two are different things: a patched openssl
inside `hi/python:3.12` is what you want automatically; a jump from node 22 to
node 26 is not.

This was learned the hard way. `python` was pinned to 3.12, `openjdk` to 21 and
`dotnet` to 10.0, while `nodejs` was left on `:latest` — and the build broke the
moment `:latest` became node 26:

```
npm error node-pre-gyp ERR! install response status 404 Not Found on
  .../pprof-nodejs/release/v4.0.0/node-v147-linux-x64-glibc.tar.gz
npm error WARN Pre-built binaries not installable for pprof@4.0.0 and
  node@26.10.0 (node-v147 ABI, glibc) (falling back to source compile)
```

Upstream's node services depend on `@google-cloud/profiler`, whose `pprof`
dependency is a native addon shipping prebuilt binaries per node ABI. For an ABI
it has no prebuilt for, it compiles `nan`-based C++ against current V8 headers,
and fails. Nothing about the hardened base caused this; a floating major did.

So `bases.env` now takes `NODE_MAJOR` (default 22), and `preflight.sh` probes
which `hi/nodejs` majors the catalog ships and warns if the configured tag is
floating.

### …and drop the profiler while you are here

`@google-cloud/profiler` reports to Google Cloud Profiler. On OpenShift it has
nowhere to report, so it is dead weight — and it is the only reason the node
builder stage needs a C++ toolchain at all. Upstream requires it lazily, inside
an `if (!DISABLE_PROFILER)` branch, so [`Containerfile.node`](Containerfile.node)
removes the dependency with `npm pkg delete` and sets `DISABLE_PROFILER=1` in
the runtime stage, which keeps the application off the code path that would need
it. `WITH_PROFILER=1` keeps it, for an actual GCP deployment.

That removes the most ABI-fragile thing in the build rather than pinning around
it — pinning the major is still right, but on its own it only postpones this
until the next bump.

## The four things that are not an image swap

### 1. `loadgenerator` — shell-form entrypoint

Upstream ends its Dockerfile with:

```dockerfile
ENTRYPOINT locust --host="http://${FRONTEND_ADDR}" --headless -u "${USERS:-10}" -r "${RATE:-1}" 2>&1
```

Shell form, so the container needs `/bin/sh` to expand those variables. A distroless runtime has
none. Locust reads every one of those flags from `LOCUST_*` environment variables, so
[`Containerfile.loadgenerator`](Containerfile.loadgenerator) uses an exec-form
`python3 -m locust` entrypoint with `LOCUST_LOCUSTFILE` and `LOCUST_HEADLESS` baked in, and the
overlay sets `LOCUST_HOST`, `LOCUST_USERS` and `LOCUST_SPAWN_RATE`. Behaviour is identical.

### 2. `adservice` — the Gradle launcher is a shell script

Upstream's entrypoint is `/app/build/install/hipstershop/bin/AdService`, which is the `sh` launcher
`gradle installDist` generates. [`Containerfile.java`](Containerfile.java) invokes the JVM directly
instead, with the main class taken from `build.gradle`
(`mainClass.set('hipstershop.AdService')`). `java` expands the `/app/lib/*` classpath wildcard
itself, so no shell is involved.

### 3. `busybox` init container — no hardened equivalent

Upstream gates the load generator behind a busybox container running a `/bin/sh` retry loop around
`wget`, because Locust exits rather than retrying if the frontend is not up yet. busybox is a Docker
Hub image and has no counterpart in a catalog of language runtimes and servers.

Keeping it would leave one unhardened image — and one anonymous Docker Hub pull — in an otherwise
hardened deployment. The overlay instead expresses the same wait as an exec-form `python3 -c` command
**on the loadgenerator image you already build**: same 12 attempts, same 10-second interval, no
shell, no thirteenth image. If you would rather keep a busybox-shaped tool, `ubi9/ubi-minimal` is
the closest thing with a shell in it, at the cost of being UBI rather than hardened.

### 4. `redis-cart` — Valkey, not Redis

The hardened catalog ships **Valkey**, the fork the Linux Foundation took over at Redis 7.2.4, not
Redis. It is wire-compatible, which is all `cartservice`'s `StackExchange.Redis` client needs. The
cart is ephemeral anyway (`emptyDir`), so the overlay turns off RDB and AOF rather than let the
server try to persist.

**Wire-compatible is not the same as drop-in.** Started on its built-in defaults — protected mode
on, no password set — valkey accepts connections only from loopback and answers every other client
with `-DENIED Running in protected mode`. Upstream's `redis:alpine` did not need anything here;
valkey does. The overlay passes `--protected-mode no`.

That one is worth knowing for how badly it hides. Nothing looks wrong:

```
redis-cart-6c9fff49c9-2kxpp   1/1   Running   0   6m54s
```

Upstream's readiness probe for `redis-cart` is a **TCP socket check**, which passes the moment
something accepts on 6379 and never speaks the protocol, so a server rejecting every real client
reports healthy. The failure surfaces two hops away, as a `StackExchange.Redis` connection timeout
in `cartservice` and an HTTP 500 on the frontend's home page, against a dependency that looks fine.
`loadgenerator` then sits in `Init:0/1` forever, because its init container waits for HTTP 200 and
the home page is 500 — a third symptom, also not the cause.

Disabling protected mode is right for this workload and is not a general recommendation: the cart is
ephemeral, the Service is `ClusterIP` with no route, and nothing in it is sensitive. For anything
that outlives a demo, set a password instead — `--requirepass` on the server, plus the password
appended to `cartservice`'s `REDIS_ADDR`, which `StackExchange.Redis` parses as a configuration
string (`redis-cart:6379,password=...`). A password satisfies protected mode on its own, so the two
are alternatives rather than layers.

To check a cache this way without a client — the hardened image is distroless and has no
`valkey-cli` — speak RESP at it over bash's `/dev/tcp`:

```bash
oc run resp-probe --rm -i --restart=Never -n online-boutique \
  --image=registry.access.redhat.com/ubi9/ubi-minimal \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"resp-probe","image":"registry.access.redhat.com/ubi9/ubi-minimal","stdin":true,"tty":false,"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"command":["bash","-c","exec 3<>/dev/tcp/redis-cart/6379; printf \'PING\\r\\n\' >&3; timeout 3 head -c 200 <&3"]}]}}'
```

`+PONG` means the server is healthy and the problem is elsewhere. Anything beginning `-DENIED`,
`-NOAUTH` or `-ERR` names the real cause in one line. The `--overrides` block is there because a
plain `oc run` is rejected by the `restricted:latest` Pod Security admission policy.

## OpenShift-specific notes

- **Arbitrary UIDs still win.** Hardened images default to `USER 65532`, but under `restricted-v2`
  OpenShift assigns a UID from the namespace range regardless, so the container runs as neither
  `1000` nor `65532`. The existing [`../base/kustomization.yaml`](../base/kustomization.yaml) patch
  that strips `runAsUser`/`runAsGroup`/`fsGroup` is therefore still required and still correct — the
  hardened overlay builds on top of it, and the rendered pod `securityContext` is `runAsNonRoot:
  true` and nothing else on all 12 deployments. Every Containerfile here ends its builder stage with
  `chmod -R a+rX`, so an unknown UID can always read the app.
- **`readOnlyRootFilesystem: true` is kept everywhere**, as upstream sets it. Hence
  `PYTHONDONTWRITEBYTECODE=1` on the Python images, `-XX:-UsePerfData` on the JVM, and a
  self-contained — not single-file — .NET publish so nothing extracts at startup.
- **`oc rsh` and `oc debug` stop working.** No shell in the image is the point of distroless, but it
  does change how you troubleshoot: use `oc debug --image=registry.access.redhat.com/ubi9/ubi-minimal`
  against the pod's node, or `oc exec` a binary you know is in the image.
- **Resource requests are unchanged.** None of this moves the 1.57 CPU / 1368 Mi footprint.

## What a real preflight run established

The three unknowns this originally flagged have been resolved against the live
catalog, on OCP with `podman` and `skopeo`. Re-run [`preflight.sh`](preflight.sh)
yourself rather than trusting this list — the catalog moves — but as of the last
run:

1. **Every tag in [`bases.env`](bases.env) exists.** `hi/python:3.12`,
   `hi/openjdk:21`, `hi/dotnet-sdk:10.0`, `hi/dotnet-runtime:10.0`,
   `hi/nodejs:latest`, `hi/go:latest-builder`, `hi/valkey:latest` — all present,
   unauthenticated. No `TargetFramework` or Gradle toolchain change needed:
   .NET 10 and JDK 21 are both there.
2. **`hi/python:3.12` carries `libstdc++`**, so `grpcio`'s wheels import fine and
   nothing needs copying out of the builder stage.
3. **`hi/static` exists, and is what the Go services use.** It is the hardened
   counterpart of `gcr.io/distroless/static` — exactly what upstream's own
   Dockerfile uses for these four — so `GO_RUNTIME` defaults to it and the whole
   stack is hardened with no UBI fallback. `hi/ubi-micro`, `hi/ubi-minimal` and
   `hi/base` are **not** in the catalog; `ubi9/ubi-micro` is the fallback if
   `hi/static` ever disappears, and works (verified end to end), but it is UBI
   rather than hardened and carries a libc these binaries never call.
   `preflight.sh` probes all five and names the best fit it finds.
4. **`hi/go:latest` works as a runtime base but carries the Go toolchain.** A
   static binary built on `hi/go:latest-builder` does run on it — verified end to
   end — but using it would ship a compiler in four of eleven production images,
   so it is deliberately not the default.

And five things that are not catalog questions but bit during the first real
builds:

5. **The interpreter is `python3`, not `python`.** RHEL and Fedora ship
   `/usr/bin/python3` and only provide a bare `python` if
   `python-unversioned-command` is installed, which these images do not. Every
   Python entrypoint here — the two service images, the load generator, the
   `cve-demo` variants and the overlays' init container — calls `python3`, and
   `pip` is invoked as `python3 -m pip`. An `ENTRYPOINT ["python", ...]` fails
   with a crun `executable file not found`, which reads exactly like a missing
   interpreter and is why `preflight.sh` now identifies the name before it tests
   anything with it.
6. **The `-builder` images run as uid 65532, not root.** A directory created by
   `WORKDIR` is owned by root, so an unprivileged `RUN` cannot write into it:
   `pip --prefix=/install` downloads every wheel and then fails with
   `OSError: [Errno 13] Permission denied`, and `dnf`, `gradle` and
   `dotnet publish` fail the same way. Every build stage here declares `USER 0`,
   which costs nothing because build stages are discarded — the runtime stages
   keep their base image's non-root user, and OpenShift assigns a UID from the
   namespace range anyway. `preflight.sh` reports the builder's uid so an edited
   Containerfile that drops `USER 0` has an obvious explanation.
7. **`pip --prefix` splits packages across `lib/` and `lib64/` on RHEL.** Fedora
   and RHEL patch `sysconfig` so *purelib* goes to `lib/` and *platlib* to
   `lib64/`. `grpcio` is a compiled extension, so installing with `--prefix` and
   then moving `lib/python*/site-packages` moved the pure packages and left
   `grpc` behind — the build succeeded and `import grpc` then failed. All four
   Python Containerfiles now use `--target`, which puts everything in one flat
   directory and removes the `python3.X` path component too. The import smoke
   test in `cve-demo/Containerfile.hardened` is what caught it, at build time
   rather than in a CrashLoopBackOff.
8. **Scanners need an image archive, not the local image store.** `grype
   podman:<image>` asks podman's API socket for the image, and that socket is
   not running after a plain `podman build` — it fails with `podman: podman not
   available: no host address`. A bare `trivy image <image>` probes for the same
   thing. Both read a `podman save` docker-archive directly instead, with no
   daemon and no registry round trip, which is what `compare.sh` now does.
   `scan-stack.sh` names `registry:` explicitly for the same reason, since the
   images it scans live in your registry.
9. **grype's database can download and still be unusable.** A `failed to
   hydrate` followed by `database does not exist` means the download worked and
   the unpack did not — normally no disk space in
   `${GRYPE_DB_CACHE_DIR:-~/.cache/grype}` (it wants ~1GB) or a cache left by an
   older grype with a different format. `grype db delete && grype db update`
   fixes it, and `preflight.sh`, `compare.sh` and `scan-stack.sh` all check
   `grype db status` up front rather than after the builds.

## Getting started

Six steps, in this order. The first three take about five minutes and will tell
you whether the other three are going to work.

Set the registry once, in the shell you are going to work in. Every script here
reads it from the environment — see [`registry.env`](registry.env) — so it is
stated once rather than repeated on four command lines:

```bash
export REGISTRY=registry.example.com:8443
```

Optionally `export NAMESPACE=...` (defaults to `online-boutique`, so images
land at `$REGISTRY/online-boutique/<service>`) and `export VERSION=...`
(defaults to `v0.10.6`, which is what `base/kubernetes-manifests.yaml` is
vendored from — change both together or the manifests and images drift).

A positional argument still overrides the environment on any of these scripts,
for one-off runs against a different registry.

### 1. Preflight

```bash
./preflight.sh --build-check
```

Checks your tooling, then asks the registry whether every tag in
[`bases.env`](bases.env) actually exists, which name the Python interpreter goes
by, whether it carries `libstdc++`, and whether the Go runtime base is minimal
or secretly the whole toolchain — see [What a real preflight run
established](#what-a-real-preflight-run-established) for what these came back as
last time. It pushes nothing and exits non-zero if anything is wrong, with the
fix in the message. A wrong tag is the most likely reason a first run dies, and
this is how you find out in ten seconds instead of twenty minutes.

Without `REGISTRY` set it still runs every base-image check and just skips the
registry reachability and login one.

Needs `skopeo` and `podman`; `--build-check` additionally builds and runs a
five-line static Go binary across the builder/runtime pair.

### 2. Point the overlays at your registry

```bash
./set-registry.sh
./set-registry.sh --check
```

Rewrites all 13 image references in both overlays to
`$REGISTRY/$NAMESPACE/<service>`. Idempotent — change `REGISTRY` and run it
again any time, from whatever the overlays currently say rather than only from
the placeholder. `--check` prints what they point at now and changes nothing.

It insists on a namespace under the registry — the `NAMESPACE` default exists
because 13 repositories at a registry root is nobody's intent.

### 3. Build and scan one service

```bash
cd cve-demo && ./compare.sh && cd ..
```

Start here rather than with the full stack. It exercises the whole Python
toolchain end to end — hardened builder, wheel install, distroless runtime — on
the service most likely to expose a problem, and it is also the CVE comparison,
so step 3 is both the smoke test and the demo. Roughly ten minutes, mostly
pulling base images. Read `cve-demo/results/report.md` when it finishes.

If this works, the remaining ten services are variations on it.

### 4. Build the full stack

```bash
podman login "$REGISTRY"
BASE=hardened ./build-push.sh
```

Clones upstream `v0.10.6`, builds all 11 services, pushes each, mirrors the
cache image. Expect 20–40 minutes — `adservice` (Gradle) and `cartservice`
(.NET restore) dominate, and both need outbound access to Maven Central and
NuGet. Add `BASE=ubi` in a second run for the comparison stack.

### 5. Let the cluster reach your registry

**All of this goes before the deploy, and none of it depends on anything
existing yet.** Two things OpenShift needs, and the usual cause of
`ImagePullBackOff`.

#### A private CA

If the registry serves a self-signed or internal certificate, trust it
cluster-wide, or every pull fails certificate verification no matter what
credentials it has. Note the `..` in the key where the port's colon goes:

```bash
oc create configmap registry-cas -n openshift-config \
  --from-file="${REGISTRY/:/..}=/path/to/ca.crt"
```

```bash
oc patch image.config.openshift.io/cluster --type=merge \
  -p '{"spec":{"additionalTrustedCA":{"name":"registry-cas"}}}'
```

#### Credentials, if the registry needs a login

```bash
REGISTRY_USER=robot REGISTRY_PASSWORD=... ./pull-secret.sh --global
```

An earlier version of this document warned that this "rolls every node through
the Machine Config Operator", and that is **out of date**: as of OpenShift
4.7.4, changing the global pull secret no longer triggers a node drain or
reboot. What still does is a `registries.conf` change via
`ImageContentSourcePolicy` or `ImageDigestMirrorSet` — a different object, and
where that cost actually belongs. The pull secret change does still propagate to
every node, so give it a moment and watch `oc get machineconfigpool`.

With that objection gone, the global route is better on the merits:

- **no ordering constraint** — nothing needs to exist first, so it can run
  before any deploy, which is what makes the namespace-scoped route awkward
- **no ServiceAccount linking and no rollout restart** — the two steps that are
  easy to forget and look like wrong credentials when missed
- **covers both comparison namespaces** — the namespace-scoped route has to be
  repeated for `online-boutique-ubi`
- **may already be done** — for a mirror registry the cluster already pulls
  release images from, the credential is likely in there; `--global` says so
  instead of silently re-adding it

It merges rather than replaces, which is the part to get right by hand: that
secret holds every registry credential the cluster has, including the Red Hat
ones it needs for its own payload, so a clobbered merge breaks the cluster in a
way that looks unrelated to what you just did. The script asserts no registry
key disappeared before writing anything back, and refuses if the existing secret
is not valid JSON.

By hand:

```bash
oc get secret/pull-secret -n openshift-config \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > /tmp/ps.json

# merge, do not overwrite
REG="$REGISTRY" AUTH="$(printf '%s:%s' "$USER" "$PASS" | base64 -w0)" \
  jq '.auths[$ENV.REG] = {auth: $ENV.AUTH}' /tmp/ps.json > /tmp/ps.new.json

oc set data secret/pull-secret -n openshift-config \
  --from-file=.dockerconfigjson=/tmp/ps.new.json
rm -f /tmp/ps.json /tmp/ps.new.json
```

Note `$ENV.AUTH` rather than `jq --arg`: `/proc/<pid>/cmdline` is world-readable
and `/proc/<pid>/environ` is not, so passing the credential as an argument
publishes it to every user on the box for the life of the process. And delete
those temp files — the first one contains the cluster's entire set of registry
credentials.

If you would rather keep the credential out of the cluster-wide secret, there is
a namespace-scoped route — but it has to wait until the namespace exists, so it
is [step 7](#7-optional-a-namespace-scoped-pull-secret-instead).

### 6. Deploy and diff

```bash
oc apply -k ../overlays/hardened
oc get pods -n online-boutique -w
```

```bash
oc get route frontend -n online-boutique -o jsonpath='https://{.spec.host}{"\n"}'
```

For the UBI comparison, **build it before applying it.** The two overlays point
at different tags — `v0.10.6` for hardened, `v0.10.6-ubi` for UBI, from
`TAG_SUFFIX` in [`bases.env`](bases.env) — so applying the UBI overlay without
having run the UBI build gives every pod

```
Failed to pull image ".../frontend:v0.10.6-ubi": manifest unknown
```

which is the registry correctly reporting a tag nobody pushed. Both steps:

```bash
BASE=ubi ./build-push.sh
oc apply -k ../overlays/ubi
oc get pods -n online-boutique-ubi -w
```

Then, with both namespaces up:

```bash
./scan-stack.sh online-boutique online-boutique-ubi
```

Then set up the rebuild loop — see [Rebuilding when a base image gets a CVE
fix](#rebuilding-when-a-base-image-gets-a-cve-fix). The first build is the
bootstrap; the loop is the point.

### 7. Optional: a namespace-scoped pull secret instead

Skip this if you used `--global` in step 5. This route keeps the credential out
of the cluster-wide secret, at the cost of an ordering constraint: the namespace
and all twelve ServiceAccounts are created by the manifests, so it **must run
after step 6** or it fails with `namespaces "online-boutique" not found`. Pods
sitting in `ImagePullBackOff` until then is expected, not a failed deploy. It
also has to be repeated for `online-boutique-ubi`.

```bash
REGISTRY_USER=robot REGISTRY_PASSWORD=... ./pull-secret.sh
```

[`pull-secret.sh`](pull-secret.sh) creates the secret, links it to every
ServiceAccount it finds, and restarts the deployments. That last part is the
step people miss: a pull secret resolves when a pod is **created**, so pods
that already failed keep failing — the kubelet retries the pull, not the
ServiceAccount lookup — and the credentials look wrong when they are merely
late. It is idempotent, so re-run it after rotating a credential or any apply
that adds a ServiceAccount, since linking only reaches the accounts that exist
at the time.

It takes the credentials from the environment or prompts for them, never as
command-line arguments, which are visible in the process list and persist in
shell history.

By hand, the same thing:

```bash
oc create secret docker-registry mirror-creds -n online-boutique \
  --docker-server="$REGISTRY" \
  --docker-username='<user>' --docker-password='<pass>'

for sa in $(oc get sa -n online-boutique -o name); do
  oc secrets link "${sa#*/}" mirror-creds --for=pull -n online-boutique
done

oc rollout restart deployment -n online-boutique
```

### If a pod will not start

| symptom | cause |
|---|---|
| `manifest unknown` on a `-ubi` tag | the UBI stack was applied without `BASE=ubi ./build-push.sh` — `BASE=hardened` pushes plain tags only |
| frontend HTTP 500 "Can't access cart storage" | `redis-cart` rejecting clients — protected mode, see [4](#4-redis-cart--valkey-not-redis). The pod reads 1/1 Running regardless |
| `loadgenerator` stuck `Init:0/1` | its init container waits for HTTP 200; something upstream of the home page is failing. Not itself the fault |
| `ImagePullBackOff` | step 5 — CA not trusted, or no credentials for the registry. If you took the step 7 route instead: no pull secret on that ServiceAccount, or pods not restarted since it was linked |
| `CrashLoopBackOff` on a Python service, `ImportError` on `grpc._cython` | `libstdc++` missing from the runtime image; see the fix `preflight.sh` prints |
| `CreateContainerError`, `exec: "/bin/sh"` | something still has a shell-form entrypoint or a shell `command:` — the runtime images are distroless |
| `unable to validate against any security context constraint` | the base `runAsUser`/`runAsGroup`/`fsGroup` patch did not apply; `kustomize build` and check the pod `securityContext` is `runAsNonRoot` only |
| permission denied reading `/app` | an image built without the `chmod -R a+rX` the Containerfiles end with |

`oc rsh` will not work on these pods — there is no shell. Use
`oc debug --image=registry.access.redhat.com/ubi9/ubi-minimal -n online-boutique`
or read `oc logs`.

## Rebuilding when a base image gets a CVE fix

**This is not a one-time build.** The reason to take on the rebuild is that
patching stops being somebody else's release cadence — which only pays off if
you rerun it. A build you cannot repeat has traded waiting on upstream for
waiting on nobody, which is strictly worse than where you started.

Red Hat ships a fixed base image under the *same tag* with a new digest. Your
image still contains the old one, and nothing about it looks different.

Note what moves and what does not. The fix arrives as a new *RPM* inside the
image — `openssl-3.5.8-0.1.hum1` replacing an earlier release — and the image
tag stays `hi/python:3.12`. There is no `hum1` tag to pull: the suffix is an RPM
release, visible with a scanner or an SBOM, not a thing you can reference in a
`FROM` line. So "am I current?" cannot be answered by looking at the tag you
build from, which is exactly why the digest labels and `check-bases.sh` exist.

Because the tag floats, the container engine's pull policy decides whether a
rebuild picks the fix up at all. Both build paths here therefore pull
explicitly: `build-push.sh` pulls each base and *fails* if it cannot, and both
it and `compare.sh` pass `--pull=newer` rather than relying on a default that
has differed between podman versions and is unstated in the `podman build` man
page. Without that, a cached base makes the rebuild a no-op that looks like a
success — and worse, the digest labels are read from the registry, so the image
would be stamped with the digest of a base it was not built on, and
`check-bases.sh` would call it current. `PULL=never` pins to local bases and
`ALLOW_STALE_BASE=1` downgrades an unreachable registry to a warning; both make
the digest label read `unverified`, which `check-bases.sh` reports as stale
rather than current, because an unprovable base must not pass a staleness gate.

### Finding out what went stale

`build-push.sh` stamps the builder and runtime digests onto every image it
builds, as OCI labels. That state lives in the registry, with the image, rather
than on whoever's laptop ran the build:

| label | |
|---|---|
| `org.opencontainers.image.base.name` / `.base.digest` | the runtime base, standard OCI annotations |
| `online-boutique.build.builder-base.name` / `.digest` | the builder base |
| `org.opencontainers.image.revision` | the build id |
| `online-boutique.build.base-set` | `hardened` or `ubi` |

```bash
./check-bases.sh
```

Compares what each image was built *from* against what that tag resolves to
*now*, and names the services whose rebuild is overdue. Registry-only — no
cluster, nothing pulled beyond manifests. Exits non-zero when anything is stale,
so it works as a cron job or a CI gate.

### Rebuilding just that service

```bash
BASE=hardened ./build-push.sh --only emailservice
```

`check-bases.sh` prints this line for you with the right service list.

A `hi/python` fix rebuilds three services; a `hi/go` fix rebuilds four; a
`glibc`-level fix in every base rebuilds all eleven. That spread is the argument
for the shared Containerfiles — a base image bump is a build-arg change, not
eleven files to edit.

### Tags, and why the app version is not enough

Each image is pushed twice:

```
v0.10.6-b20261007   immutable -- deploy this
v0.10.6             floating convenience pointer
```

A CVE fix changes the image without changing the app, so `v0.10.6` alone cannot
identify a build. Worse, these manifests set **no `imagePullPolicy`**, which for
a non-`:latest` tag defaults to `IfNotPresent` — move the `v0.10.6` tag and a
node that already has that tag cached will happily keep running the vulnerable
image, and `oc rollout restart` will not change its mind. Deploying the
immutable tag makes the rollout a real change to the pod spec, which is what
makes it happen at all.

### Rolling it out

```bash
cd ../overlays/hardened
kustomize edit set image \
  us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/emailservice="$REGISTRY/online-boutique/emailservice:v0.10.6-b20261007"
oc apply -k .
```

Note the left-hand side: `kustomize edit set image` keys on the **original**
image name, the one the vendored manifests actually reference. Keying on the
rewritten name looks right, succeeds, and silently appends a second `images:`
entry that matches nothing — the rendered output keeps the old tag and the
rollout never happens. `build-push.sh` prints the correct command for the
services it just built; for `redis-cart` the key is the bare `redis`.

The edit rewrites the `images:` entry in place, so the new tag is committed to
git rather than typed at a cluster — which also means the next `oc apply -k`
from anywhere agrees with what is running.

The Deployment's pod template changes, so OpenShift performs a normal rolling
update: new pod, readiness gate, old pod terminated. Every service here is
stateless (`redis-cart` uses `emptyDir`), so there is nothing to drain and no
ordering to respect.

Pin by digest instead of tag if you want certainty that content cannot change
under a tag you have already deployed — `build-push.sh` prints each digest after
pushing, and `newTag:` becomes `digest:` in the overlay.

### Automating it

Three places this can live, in increasing order of how much you have to build:

1. **Cron plus the two scripts.** `check-bases.sh` nightly; on a non-zero exit,
   rebuild the named services and open a PR that bumps the tag. Smallest thing
   that works, and it is auditable because the tag bump is a commit.
2. **A pipeline** (Tekton, GitHub Actions, Jenkins) on the same logic, with the
   scan from `cve-demo/` as a gate so a rebuild that does not actually reduce
   findings does not get promoted.
3. **In-cluster builds.** OpenShift `BuildConfig` with the **docker** strategy
   plus an `ImageStream` on each base image with `scheduled: true`, an
   `ImageChangeTrigger` on the BuildConfig, and a Deployment image trigger. Red
   Hat moving a base tag then drives a rebuild and a rollout with nothing
   watching. This is the most hands-off option and the most OpenShift-native;
   note that `ImageChangeTrigger` substitution against a *multi-stage*
   Containerfile is fiddly — the trigger fires on the stream, but which `FROM`
   gets substituted needs checking against your OCP version, so pass the bases
   as `dockerStrategy.buildArgs` and treat the trigger as a trigger only. Not
   shipped here because it is untested.

## Does this use S2I?

No, and it should not.

S2I needs `assemble` and `run` scripts in the builder image, and it produces a
**single-stage** result by default: the image you build with is the image you
ship. That is precisely variant C in [`cve-demo/`](cve-demo) — the one that
carries `pip`, `setuptools` and `gcc` into production because there is no second
stage to leave them behind in.

More concretely, it cannot work against this catalog. The hardened runtime
variants are distroless, with no shell and no S2I scripts, so there is nothing
for `oc new-build --strategy=source` to invoke. The UBI s2i images
(`ubi9/python-312`, `ubi9/nodejs-22`) *do* carry those scripts, so S2I would work
on the UBI side — which would make the comparison measure S2I versus
multi-stage rather than UBI versus hardened, and that is a different question.

If you want builds to run in the cluster, the mechanism is a `BuildConfig` with
the **docker** strategy, which consumes the Containerfiles here unchanged. S2I
chained builds get you something multi-stage-shaped, but at that point you have
reimplemented a multi-stage Containerfile in two BuildConfigs.

## Knobs

`REGISTRY`, `NAMESPACE` and `VERSION` come from [`registry.env`](registry.env);
the engine is `ENGINE=docker`; the base-image pull policy is `PULL=newer`
(`always`, `missing` and `never` also work, and `ALLOW_STALE_BASE=1` tolerates a
registry it cannot reach); and every base image comes from
[`bases.env`](bases.env), which holds both base sets. All of it is overridable
from the environment, and the registry and version can still be passed
positionally for a one-off. `BASE=ubi` builds the same 11
services on UBI 9 and tags them `-ubi`, from the same Containerfiles; only the
base images change, which is what makes the comparison in
[`cve-demo/`](cve-demo) mean anything.

Both overlays build on `overlays/default`, so the namespace, labels and the SCC
patches come from where they always did.

### Disconnected clusters

This gets *simpler*, not harder. Instead of 13 images across three registries including two
anonymous Docker Hub pulls, everything already lives in one registry you control — the images you
built are there by construction. Only `hi/valkey` crosses the air gap, and `build-push.sh` copies it
with `skopeo` rather than going through `oc mirror`. See [`../../../disconnected`](../../../disconnected)
for the surrounding mirror setup.

## Files

```
Containerfile.go              frontend, productcatalogservice, checkoutservice, shippingservice
Containerfile.node            currencyservice, paymentservice      (ENTRY build arg)
Containerfile.python          emailservice, recommendationservice  (ENTRY build arg)
Containerfile.loadgenerator   loadgenerator — separate because of the Locust entrypoint
Containerfile.java            adservice
Containerfile.dotnet          cartservice
registry.env                  REGISTRY / NAMESPACE / VERSION, read by all four scripts
bases.env                     the hardened and UBI base-image sets  (BASE=hardened|ubi)
preflight.sh                  check tags, runtimes and your registry before building
set-registry.sh               point both overlays at your registry
pull-secret.sh                give the deployed namespace registry credentials
build-push.sh                 build all 11, or --only one; push immutable + floating tags
check-bases.sh                which services a new base image release made stale
scan-stack.sh                 scan a running namespace; diff two of them
cve-demo/                     emailservice built 3 ways, scanned and diffed
  compare.sh                  ... as one command
  breakdown.sh                resolve a scan's counts to individual CVEs
  manual-steps.md             ... as individual commands you run yourself
```

Deploy-time changes are in [`../overlays/hardened`](../overlays/hardened), and the UBI counterpart
in [`../overlays/ubi`](../overlays/ubi).

## Scanning it with ACS

[`../../../acs/`](../../../acs) has the operator, Central and SecuredCluster
manifests plus a script that scans both namespaces and writes a per-image table.
Read [the ACS section of
`cve-demo/README.md`](cve-demo/README.md#what-about-scanning-with-acs-instead)
first: RHACS 4.11 is documented as not reporting vulnerabilities for Red Hat
hardened images, so the hardened side is expected to come back thin, and that is
a tooling-readiness finding rather than a clean result.

## Measuring it

Whether this is worth doing is an empirical question, so there are two ways to answer it:

| | scope | what it answers |
|---|---|---|
| [`cve-demo/`](cve-demo) | one service, three variants | separates what *multi-stage* buys from what the *hardened base* buys — and is the worked example of the multi-stage pattern |
| [`scan-stack.sh`](scan-stack.sh) | two whole namespaces | the as-deployed number, per service and per stack |

```bash
cd cve-demo && ./compare.sh
```

```bash
./scan-stack.sh online-boutique online-boutique-ubi
```

Both need **one** scanner — `grype` or `trivy`, whichever you have; grype is
preferred when both are installed, and the report names which one ran. Neither
is required by the build, only by these two. Installing the second one is a
cross-check, not a requirement:

```bash
curl -sSfL https://get.anchore.io/grype | sh -s -- -b /usr/local/bin
```

The two use overlapping but different vulnerability databases, so a sharp
disagreement between them on the same image is itself the finding — usually a
distroless image whose packages one of them cannot enumerate. `compare.sh` runs
both when both are present and keeps both JSON files for exactly that reason.

Neither commits its output: CVE
counts are true for the day they were scanned, and a stale table in git reads as
a current claim. See [`cve-demo/README.md`](cve-demo/README.md) for how to read
the diff, including the two ways a scan can mislead you.
