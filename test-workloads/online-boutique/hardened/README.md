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
| `python:3.14-alpine` | `hi/python:3.14-builder` / `:3.14` | |
| `eclipse-temurin:25-jre-alpine` | `hi/openjdk:25-builder` / `:25` | |
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

1. **Tags.** Everything here assumes `hi/python:3.14`, `hi/openjdk:25`, `hi/dotnet-sdk:10.0`,
   `hi/go:latest`, `hi/nodejs:latest`. They are variables in both the Containerfiles and
   `build-push.sh` precisely so they can be corrected in one place. `cartservice` targets `net10.0`
   and `adservice` builds on JDK 24+ — if the catalog's versions are older, those two need
   `TargetFramework` / Gradle toolchain adjustment, which is the one place this could get genuinely
   annoying.
2. **Whether `hi/go:latest` is usable as a runtime base** for a static binary, or whether the `go`
   image is builder-only. If it is builder-only, set `GO_RUNTIME` to `ubi9/ubi-micro` or `scratch` —
   these four services speak plaintext gRPC in-cluster and need neither a CA bundle nor tzdata.
3. **Whether `hi/python` carries `libstdc++`.** `grpcio`'s manylinux wheels link against it;
   upstream installs it explicitly on Alpine. If the runtime variant omits it, copy it out of the
   builder stage. This is the single most likely runtime failure in the whole set, and it shows up
   as an `ImportError` on `grpc._cython`, not at build time.

## Running it

```bash
podman login registry.example.com:8443
./build-push.sh registry.example.com:8443/online-boutique
```

Builds all 11 services from a shallow clone of upstream `v0.10.6`, pushes each, and mirrors
`hi/valkey` alongside them. Override the version with a second argument, any base image with the
`GO_BUILDER`/`PY_RUNTIME`/… environment variables, and the engine with `ENGINE=docker`.

Then set your registry in [`../overlays/hardened/kustomization.yaml`](../overlays/hardened/kustomization.yaml)
— it ships with the repo's usual `registry.example.com:8443` placeholder — and:

```bash
oc apply -k test-workloads/online-boutique/overlays/hardened
```

```bash
oc get route frontend -n online-boutique -o jsonpath='https://{.spec.host}{"\n"}'
```

The overlay builds on `overlays/default`, so the namespace, labels and the SCC patches all come
from the same place they always did.

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
build-push.sh                 clone upstream, build all 11, push, mirror valkey
```

The matching deploy-time changes are in [`../overlays/hardened`](../overlays/hardened).
