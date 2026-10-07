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

> **None of this was executed.** The session this was written in has no container engine and its
> egress policy blocks `images.redhat.com`, `registry.access.redhat.com` and `docs.redhat.com`, so
> no image was pulled, built or inspected. The analysis is from upstream's own Dockerfiles, build
> files and dependency manifests at `v0.10.6` (all read directly) plus Red Hat's published
> documentation. Image **tags in particular are unverified** — see
> [Before the first build](#before-the-first-build). The kustomize overlay, by contrast, *is*
> verified: `kustomize build overlays/hardened` renders, and the rendered output contains no
> `us-central1-docker.pkg.dev`, `docker.io` or `redis:alpine` reference.

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
| `gcr.io/distroless/static` | `hi/go:latest` | runtime stage only holds a static binary |
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

## The four things that are not an image swap

### 1. `loadgenerator` — shell-form entrypoint

Upstream ends its Dockerfile with:

```dockerfile
ENTRYPOINT locust --host="http://${FRONTEND_ADDR}" --headless -u "${USERS:-10}" -r "${RATE:-1}" 2>&1
```

Shell form, so the container needs `/bin/sh` to expand those variables. A distroless runtime has
none. Locust reads every one of those flags from `LOCUST_*` environment variables, so
[`Containerfile.loadgenerator`](Containerfile.loadgenerator) uses an exec-form
`python -m locust` entrypoint with `LOCUST_LOCUSTFILE` and `LOCUST_HEADLESS` baked in, and the
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
hardened deployment. The overlay instead expresses the same wait as an exec-form `python -c` command
**on the loadgenerator image you already build**: same 12 attempts, same 10-second interval, no
shell, no thirteenth image. If you would rather keep a busybox-shaped tool, `ubi9/ubi-minimal` is
the closest thing with a shell in it, at the cost of being UBI rather than hardened.

### 4. `redis-cart` — Valkey, not Redis

The hardened catalog ships **Valkey**, the fork the Linux Foundation took over at Redis 7.2.4, not
Redis. It is wire-compatible, which is all `cartservice`'s `StackExchange.Redis` client needs. The
cart is ephemeral anyway (`emptyDir`), so the overlay turns off RDB and AOF rather than let the
server try to persist.

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

## Before the first build

Three things to confirm against [images.redhat.com](https://images.redhat.com/), because they could
not be checked from here and they are the most likely cause of a first-run failure:

1. **Tags.** Everything here assumes `hi/python:3.12`, `hi/openjdk:21`, `hi/dotnet-sdk:10.0`,
   `hi/go:latest`, `hi/nodejs:latest`. They all live in [`bases.env`](bases.env), so a wrong guess
   is a one-line fix in one file. `cartservice` targets `net10.0`, which is the one hard floor here
   — if the catalog has no .NET 10, that service needs its `TargetFramework` changed. `adservice`
   needs only JDK 21 despite upstream building it on 24.
2. **Whether `hi/go:latest` is usable as a runtime base** for a static binary, or whether the `go`
   image is builder-only. If it is builder-only, set `GO_RUNTIME` to `ubi9/ubi-micro` or `scratch` —
   these four services speak plaintext gRPC in-cluster and need neither a CA bundle nor tzdata.
3. **Whether `hi/python` carries `libstdc++`.** `grpcio`'s manylinux wheels link against it;
   upstream installs it explicitly on Alpine. If the runtime variant omits it, copy it out of the
   builder stage. This is the single most likely runtime failure in the whole set, and it shows up
   as an `ImportError` on `grpc._cython`, not at build time.

## Getting started

Six steps, in this order. The first three take about five minutes and will tell
you whether the other three are going to work.

### 1. Preflight

```bash
./preflight.sh registry.example.com:8443 --build-check
```

Checks your tooling, then asks the registry whether every tag in
[`bases.env`](bases.env) actually exists, whether `hi/go` works as a runtime base
for a static binary, and whether `hi/python` carries `libstdc++` — the three
things flagged under [Before the first build](#before-the-first-build). It
pushes nothing and exits non-zero if anything is wrong, with the fix in the
message. A wrong tag is the most likely reason a first run dies, and this is how
you find out in ten seconds instead of twenty minutes.

Needs `skopeo` and `podman`; `--build-check` additionally builds and runs a
five-line static Go binary across the builder/runtime pair.

### 2. Point the overlays at your registry

```bash
./set-registry.sh registry.example.com:8443/online-boutique
./set-registry.sh --check
```

Rewrites all 13 image references in both overlays. Idempotent — run it again
with a different value any time. Takes `<registry>/<namespace>`, not a bare
registry, because 13 repositories at a registry root is nobody's intent.

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
podman login registry.example.com:8443
BASE=hardened ./build-push.sh registry.example.com:8443/online-boutique
```

Clones upstream `v0.10.6`, builds all 11 services, pushes each, mirrors the
cache image. Expect 20–40 minutes — `adservice` (Gradle) and `cartservice`
(.NET restore) dominate, and both need outbound access to Maven Central and
NuGet. Add `BASE=ubi` in a second run for the comparison stack.

### 5. Let the cluster pull from your registry

Two things OpenShift needs, and the usual cause of `ImagePullBackOff` here.

**A private CA.** If the registry serves a self-signed or internal certificate,
trust it cluster-wide. Note the `..` in the key where the port's colon goes:

```bash
oc create configmap registry-cas -n openshift-config \
  --from-file=registry.example.com..8443=/path/to/ca.crt
```

```bash
oc patch image.config.openshift.io/cluster --type=merge \
  -p '{"spec":{"additionalTrustedCA":{"name":"registry-cas"}}}'
```

**Credentials**, if the registry needs a login. Namespace-scoped is the lighter
option, but this workload has 12 ServiceAccounts, so link the secret to all of
them — and run it *after* `oc apply`, since the manifests create those accounts:

```bash
oc create secret docker-registry mirror-creds -n online-boutique \
  --docker-server=registry.example.com:8443 \
  --docker-username='<user>' --docker-password='<pass>'
```

```bash
for sa in $(oc get sa -n online-boutique -o name); do
  oc secrets link "${sa#*/}" mirror-creds --for=pull -n online-boutique
done
```

Adding the credentials to the cluster-wide pull secret instead covers every
namespace in one step, but it rolls every node through the Machine Config
Operator — correct, and not what you want mid-demo.

### 6. Deploy and diff

```bash
oc apply -k ../overlays/hardened
oc get pods -n online-boutique -w
```

```bash
oc get route frontend -n online-boutique -o jsonpath='https://{.spec.host}{"\n"}'
```

Then, once the UBI stack is built and deployed too:

```bash
oc apply -k ../overlays/ubi
./scan-stack.sh online-boutique online-boutique-ubi
```

Then set up the rebuild loop — see [Rebuilding when a base image gets a CVE
fix](#rebuilding-when-a-base-image-gets-a-cve-fix). The first build is the
bootstrap; the loop is the point.

### If a pod will not start

| symptom | cause |
|---|---|
| `ImagePullBackOff` | step 5 — CA not trusted, or no pull secret on that ServiceAccount |
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
./check-bases.sh registry.example.com:8443/online-boutique
```

Compares what each image was built *from* against what that tag resolves to
*now*, and names the services whose rebuild is overdue. Registry-only — no
cluster, nothing pulled beyond manifests. Exits non-zero when anything is stale,
so it works as a cron job or a CI gate.

### Rebuilding just that service

```bash
BASE=hardened ./build-push.sh registry.example.com:8443/online-boutique \
  --only emailservice
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
  us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/emailservice=registry.example.com:8443/online-boutique/emailservice:v0.10.6-b20261007
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

`build-push.sh` takes the upstream version as a second argument, the engine as
`ENGINE=docker`, and every base image from the environment — the full list, for
both base sets, is in [`bases.env`](bases.env). `BASE=ubi` builds the same 11
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
bases.env                     the hardened and UBI base-image sets  (BASE=hardened|ubi)
preflight.sh                  check tags, runtimes and your registry before building
set-registry.sh               point both overlays at your registry
build-push.sh                 build all 11, or --only one; push immutable + floating tags
check-bases.sh                which services a new base image release made stale
scan-stack.sh                 scan a running namespace; diff two of them
cve-demo/                     emailservice built 3 ways, scanned and diffed
```

Deploy-time changes are in [`../overlays/hardened`](../overlays/hardened), and the UBI counterpart
in [`../overlays/ubi`](../overlays/ubi).

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

Both need `grype` or `trivy` and nothing else. Neither commits its output: CVE
counts are true for the day they were scanned, and a stale table in git reads as
a current claim. See [`cve-demo/README.md`](cve-demo/README.md) for how to read
the diff, including the two ways a scan can mislead you.
