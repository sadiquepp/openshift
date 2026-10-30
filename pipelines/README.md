# Building and deploying Online Boutique with Tekton and Argo CD

Automating what [`test-workloads/online-boutique/hardened/build-push.sh`](../test-workloads/online-boutique/hardened/build-push.sh)
does by hand: rebuild eleven services on two base sets — Red Hat Hardened
Images and UBI — push them to a local registry, and let Argo CD deploy both
namespaces.

This directory is a **work in progress**: phase 1 is here and runnable, the
later phases are designed but not written. The design decisions are recorded
below because they are the part worth reading; the YAML is the easy part.

- [Why this is worth automating](#why-this-is-worth-automating)
- [Phase 1: one service, end to end](#phase-1-one-service-end-to-end)
- [Decisions, and why](#decisions-and-why)
- [The remaining phases](#the-remaining-phases)
- [Things that will bite](#things-that-will-bite)

## Why this is worth automating

Hardened base images move. Over one day in October 2026, six of eleven
hardened services and five of eleven UBI services went stale — `check-bases.sh`
reports it, and a human then has to rebuild, roll out and re-measure. That loop
is the whole operational cost of distroless base images, and it is the thing a
pipeline removes.

The measurement that motivates it is in
[`FINDINGS.md`](../test-workloads/online-boutique/hardened/FINDINGS.md).

## Phase 1: one service, end to end

Deliberately not the matrix. Everything that goes wrong on a first
buildah-on-OpenShift build goes wrong here too, and is far easier to read in
one TaskRun than in one of twenty-two.

```bash
# 1. the operator. Confirm the channel against your catalog first -- the file
#    says how, and there is no stable channel for this one.
oc apply -f 01-operator.yaml
oc get tektonconfig config -w        # wait for Ready before continuing

# 2. namespace, service account, SCC
oc apply -f 02-rbac.yaml

#    Prove the SCC grant before running anything -- must print yes
oc auth can-i use scc/pipelines-scc \
  --as=system:serviceaccount:boutique-ci:boutique-builder -n boutique-ci

oc -n boutique-ci create secret docker-registry registry-auth \
  --docker-server=registry.example.com:8443 \
  --docker-username='<user>' --docker-password='<password>'

#    and the CA that signed the registry certificate, if it is a private one.
#    Already trusting it on the NODES does not make this pod trust it.
oc -n boutique-ci create configmap registry-ca \
  --from-file=ca.crt=/path/to/registry-ca.crt

oc apply -f tasks/ -f pipeline-build-service.yaml

# 3. start a run. The committed example carries the placeholder registry, as
#    everything in this repo does, so substitute rather than edit it -- that
#    keeps your real host out of a commit and gives each run a fresh build id.
export REGISTRY=registry.example.com:8443          # yours; see registry.env
sed -e "s|registry.example.com:8443|$REGISTRY|" \
    -e "s|b20261021|b$(date -u +%Y%m%d)|" \
    runs/build-frontend-hardened.yaml | oc -n boutique-ci create -f -

tkn -n boutique-ci pipelinerun logs -L -f
```

### Getting `tkn`, or doing without it

`tkn` is convenience, not a requirement. The operator serves a version-matched
binary from the cluster, which also works on a disconnected one, so prefer that
over a download from the internet:

```bash
oc get consoleclidownload                       # what this cluster offers
oc get consoleclidownload tkn \
  -o jsonpath='{range .spec.links[*]}{.href}{"\t"}{.text}{"\n"}{end}'

# then the linux-amd64 link from that list; the route uses the ingress
# certificate, so --cacert takes the router CA (same file ../acs/ uses)
curl -sSL --cacert router-ca.crt -o /tmp/tkn.tar.gz '<href>'
sudo tar xzf /tmp/tkn.tar.gz -C /usr/local/bin tkn
tkn version
```

Everything here can be done with `oc` alone:

| `tkn` | `oc` |
|---|---|
| `tkn pipelinerun logs -L -f` | `oc logs -f -l tekton.dev/pipelineRun=<run> --all-containers --max-log-requests=10` |
| `tkn pipelinerun list` | `oc get pipelinerun` |
| `tkn pipelinerun describe <run>` | `oc describe pipelinerun <run>` |
| `tkn taskrun list` | `oc get taskrun` |

`--max-log-requests` is needed because a PipelineRun has several pods and `oc`
refuses to stream more than five at once by default. For a single failing task
it is simpler to go straight at its pod:

```bash
oc get taskrun -o custom-columns=NAME:.metadata.name,OK:.status.conditions[0].reason
oc logs <taskrun>-pod --all-containers
```

If you would rather keep a filled-in copy, name it `runs/local-<something>.yaml`
— that pattern is gitignored here.

**The registry string has to agree in three places**, and two of them fail in
ways that do not mention the registry:

| where | value |
|---|---|
| the `REGISTRY` param above | `host:port/namespace` |
| `--docker-server` on the `registry-auth` secret | `host:port` only |
| the kustomize overlays, later, via `set-registry.sh` | `host:port/namespace` |

`--docker-server` must match the host and port **exactly** as they appear in
the image reference. A mismatch means buildah finds no credential entry for
that host and the push fails as a plain 401, which reads like a wrong password.

`oc create`, not `oc apply`, for the run: a PipelineRun is immutable and the
manifest uses `generateName`.

Done when the run is green and the image is in your registry with its labels:

```bash
# $REGISTRY is still exported from the run above; the build id is the REVISION
# the run used, which `oc get pipelinerun -o jsonpath` will tell you:
BUILD_ID=$(oc -n boutique-ci get pipelinerun --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1:].spec.params[?(@.name=="REVISION")].value}')

skopeo inspect --format '{{json .Labels}}' \
  "docker://$REGISTRY/online-boutique/frontend:v0.10.6-$BUILD_ID" | jq
```

Expect all seven: both `*.base.name`/`*.base.digest` pairs,
`org.opencontainers.image.version`, `org.opencontainers.image.revision` and
`online-boutique.build.base-set`.

If the host running `skopeo` does not trust the registry CA, add
`--cert-dir=<dir holding ca.crt>` — the same certificate the pipeline needs,
and a third trust store after the nodes and the build pod.

Those labels are what `check-bases.sh` reads. If they are present and correct,
the pipeline has reproduced what `build-push.sh` produces, and the rest is
fan-out.

**One gap to know about now, because phase 4 depends on it.**
`check-bases.sh` inspects the *floating* tag — `$VERSION$TAG_SUFFIX`, e.g.
`:v0.10.6` — and the pipeline pushes only the immutable
`:v0.10.6-<build-id>`. So it reports a pipeline-built service as
`ABSENT ... never built?` even though the image is there. Dropping the
floating tag was deliberate, so the fix is not to start pushing it again.
Either teach `check-bases.sh` a tag argument, or have phase 4 read the digests
from the GitOps overlay, which is where they will live once phase 3 writes them
back. The second is better — it compares what is *deployed* against the current
base, rather than what happens to be tagged.

### What it does

Two clones, because the inputs live in two places — upstream holds the
application source, this repository holds the Containerfiles:

```
clone-upstream ─┐
clone-recipes ──┼─► build ─► push ─► IMAGE_DIGEST
resolve-builder ┤
resolve-runtime ┘
```

The two `resolve-*` tasks run `skopeo inspect` on the base tags **before** the
build, so the digest stamped into the image is the base the build actually
used, not whatever the tag points at when the build finishes.

### Seeing runs in the web console

The operator ships a dynamic console plugin that adds the Pipelines pages to
the OpenShift console. Whether it is enabled for you depends on your version —
check before changing anything:

```bash
oc get consoleplugin pipelines-console-plugin                    # does it exist?
oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}{"\n"}'
```

If `pipelines-console-plugin` is already in that list, you are done. Otherwise
**append** to the list:

```bash
oc patch console.operator.openshift.io cluster --type=json \
  -p '[{"op":"add","path":"/spec/plugins/-","value":"pipelines-console-plugin"}]'
```

If the first command printed nothing for `spec.plugins` — no list at all — the
path has to create it instead:

```bash
oc patch console.operator.openshift.io cluster --type=json \
  -p '[{"op":"add","path":"/spec/plugins","value":["pipelines-console-plugin"]}]'
```

> **Do not use a merge patch here.**
> `oc patch ... --type=merge -p '{"spec":{"plugins":["pipelines-console-plugin"]}}'`
> **replaces** the whole list and silently turns off every other console plugin
> on the cluster. On a cluster that also runs Logging or GitOps, those pages
> just vanish, with nothing in the console to say why. The `/spec/plugins/-`
> JSON-patch path appends, which is why it is used above.
>
> The append is also not idempotent — run it twice and the name is listed
> twice. That is why the check comes first.

The console redeploys, which takes a minute or two, and the browser needs a
hard refresh before the new pages appear:

```bash
oc rollout status -n openshift-console deploy/console
```

Two known issues worth recognising rather than debugging from scratch:

- The plugin needs OpenShift 4.15 or later.
- From Pipelines 1.18 the Results API is enabled by default, and the
  operator's default Tekton Results TLS secret produced a bad-certificate
  error that broke the plugin ([SRVKP-7859](https://issues.redhat.com/browse/SRVKP-7859)).
  If the Pipelines pages load but show no data, look at the
  `pipelines-console-plugin` and Results pods before suspecting your pipeline.

The statistics on the Pipelines overview page need Tekton Results installed;
without it those panels stay empty, which is not a plugin fault.

## Decisions, and why

### Our own build task rather than the shipped `buildah`

The shipped task is reachable through the cluster resolver and for a simple
build you should use it. It does not fit here. Every Containerfile takes two to
four `--build-arg` values and each image carries six `--label` values, and the
shipped task passes all of them through `BUILD_EXTRA_ARGS` — **a single
string**. An array value containing a space broke on the migration from the
deprecated ClusterTask ([SRVKP-7213](https://issues.redhat.com/browse/SRVKP-7213)),
and multi-line continuation fails with `accepts at most 1 arg(s)`
([SRVKP-8513](https://issues.redhat.com/browse/SRVKP-8513)). Ten flags in one
string with no quoting of your own is a trap.

So [`tasks/build-service.yaml`](tasks/build-service.yaml) takes build args as a
real array and the seven labels as named parameters, where a missing one is a
validation error rather than a silently absent label.

### ClusterTasks are gone

Deprecated in OpenShift Pipelines 1.10; the cluster resolver has been GA since
1.11, and the shipped tasks live in the `openshift-pipelines` namespace. Most
tutorials still write `taskRef: {kind: ClusterTask}` and will not work.

### No floating tag

`build-push.sh` pushes both `v0.10.6-b20261021` and a floating `v0.10.6`. The
pipeline pushes **only the immutable one**.

The floating tag is why a rebuilt image was invisible twice in one measurement
session: Kubernetes defaults `imagePullPolicy` to `IfNotPresent` for any tag
that is not `:latest`, so a node that had cached the tag kept serving the old
layers, and `oc rollout restart` did not help because the tag was still
present. The overlays work around it with `imagePullPolicy: Always`.

Under GitOps the workaround is unnecessary: the pipeline knows the digest it
just produced, writes it into the overlay, and Argo CD deploys that. A digest
cannot go stale. The deployed image, the scanned image and the image
`check-bases.sh` reasons about become the same object, and rollback is
`git revert`.

### Pipeline commits the digest; not Argo CD Image Updater

Image Updater exists to *discover* digests for images you did not build. The
pipeline already has `IMAGE_DIGEST` as a task result. Its `argocd` write-back
mode does not touch Git at all, which defeats the point.

Kustomize's `images:` entries take a `digest:` field, mutually exclusive with
`newTag`. One write-back task at the end of the pipeline updates every service
in one commit — not one commit per service, which is how concurrent builds
collide.

### Unprivileged buildah, as a matter of credibility

The default `pipeline` service account gets `pipelines-scc` (anyuid plus
SETFCAP), and the shipped buildah task uses the `vfs` storage driver because
`overlay` needs more privilege. Red Hat's guidance is that the simplest way to
guarantee every image builds is to run buildah as root under the `privileged`
SCC.

**Do not reach for that here without thinking.** These pipelines exist to
produce hardened images; a privileged builder is the first thing a reviewer
will point at. Order of preference, with the ladder written out in
[`02-rbac.yaml`](02-rbac.yaml): `pipelines-scc` first, then the documented
unprivileged buildah setup for your version, then the `buildah-ns` task that
OpenShift Pipelines 1.20 added, and only then `privileged`, with a reason.

The unprivileged SCC is **not** reproduced in this repository on purpose: it
differs between versions, so copy it from the OpenShift Pipelines documentation
for the version you run rather than from here or a blog.

## The remaining phases

**Phase 2 — matrix.** `matrix` fans one PipelineTask over the eleven services;
`BASE_SET` stays a pipeline parameter, so two PipelineRuns cover both sets. The
per-service recipe (Containerfile, context, extra build args) moves out of the
PipelineRun and into the matrix, mirroring `recipe()` in `build-push.sh`.
Matrix was alpha, then beta, so your version decides whether it needs a
feature level. Set it on the `TektonConfig` the operator created, not on the
`feature-flags` ConfigMap — `spec.pipeline` is projected into that ConfigMap, so
a hand edit there is liable to be reconciled away. The command is in
[`01-operator.yaml`](01-operator.yaml).

`cache` is the exception, as it is in `build-push.sh`: mirrored with
`skopeo-copy` unless `CACHE_BUILD=1`, in which case it is a normal build from
`Containerfile.valkey`.

**Phase 3 — Argo CD.** Two Applications, one per overlay, through the Red Hat
OpenShift GitOps operator. `redis-cart` needs a sync wave before `cartservice`.
The write-back task from the decision above closes the loop.

**Phase 4 — rebuild only what went stale.** A cron trigger runs the
`check-bases.sh` logic and starts a PipelineRun for the services it names. This
is the phase that pays for the whole exercise.

**Phase 5 — gate and provenance.** `roxctl image check` against an RHACS policy
such as "fixable CVSS >= 7", failing the build. Red Hat's pattern downloads
`roxctl` from Central each run so client and server versions match. Then Tekton
Chains for build provenance. The gate is a live demonstration of the finding:
the hardened side passes where UBI may not.

## Things that will bite

**An SCC grant that silently grants nothing.** Binding to the generated
`system:openshift:scc:<name>` ClusterRole is the usual shorthand, but a
RoleBinding naming a ClusterRole that does not exist is created successfully
and confers nothing. The symptom arrives one task later, when the build pod is
rejected with `provider "pipelines-scc": Forbidden: not usable by user or
serviceaccount` in a list of twenty other SCCs — and the clone tasks will have
passed, because they do not request `SETFCAP` and run happily under
`restricted-v2`. `02-rbac.yaml` spells the rule out instead of relying on a
generated name, and the `oc auth can-i use scc/...` check above settles it in
one command.

**Two trust stores, one certificate.** Making the *nodes* trust a private
registry CA (step 5 of the hardened README) does not make the *build pod* trust
it. The build succeeds and the push fails:

```
Error: pushing image ... pinging container registry registry.example.com:8443:
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

The `registrycerts` workspace carries the CA, and the tasks pass it as
`--cert-dir`; buildah would otherwise look only in
`/etc/containers/certs.d/<host:port>/`, which the image does not have. If you
do not have the CA file to hand, the cluster has it — it is in the ConfigMap
the image config points at:

```bash
oc get image.config.openshift.io/cluster -o jsonpath='{.spec.additionalTrustedCA.name}{"\n"}'
oc -n openshift-config get cm <that-name> -o json | jq -r '.data | to_entries[0].value' \
  > registry-ca.crt
```

The key in that ConfigMap is the registry hostname with the port written
`..8443`, which is OpenShift's own encoding, not a typo.

**`--docker-server` must match exactly**, port included, or buildah will not
find the credential entry and the push fails as a 401 that reads like bad
credentials.

**Shared RWO workspaces deadlock.** Twenty-two matrix builds against one PVC
will serialise or fail. Use a `volumeClaimTemplate` per run, or RWX.

**Egress.** Build pods pull hardened bases from `registry.access.redhat.com`.
On a disconnected cluster they need the mirror instead — see [`disconnected/`](../disconnected/).

**Build time.** The .NET and Java services dominate. Phase 4 exists partly
because rebuilding all twenty-two when two bases moved is waste.

**Argo CD self-heal versus a manual `oc apply -k`.** Once an Application owns a
namespace, hand-applied changes are reverted. That is the point, but it will
surprise you the first time a debugging edit disappears.
