# Findings: Online Boutique on Red Hat Hardened Images, measured against UBI

A point-in-time result, not a standing claim. Figures are aggregate counts over
images built from public upstream source on public base images; nothing here
names infrastructure or describes a production estate. Raw scan output stays
out of the repository (`results-acs/`, `results/` are gitignored) — re-run the
scripts to reproduce rather than trusting these numbers to still hold.

**Measured** 2026-10-09 · **Scanner** RHACS 4.x, Scanner V4, CSAF/VEX data
· **Workload** [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo)
v0.10.6, 12 images per namespace, same source built twice

- [What was measured](#what-was-measured)
- [The result](#the-result)
- [What it supports](#what-it-supports)
- [What it does not support](#what-it-does-not-support)
- [Where the hardened residue comes from](#where-the-hardened-residue-comes-from)
- [What "fix published" does and does not mean](#what-fix-published-does-and-does-not-mean)
- [The scanners disagree, and the disagreements are informative](#the-scanners-disagree-and-the-disagreements-are-informative)
- [Pitfalls that silently invalidate a run](#pitfalls-that-silently-invalidate-a-run)
- [Reproducing it](#reproducing-it)

## What was measured

Two namespaces running the same application from the same source commit, built
twice:

| | base images | namespace |
|---|---|---|
| hardened | `registry.access.redhat.com/hi/*` (Project Hummingbird, distroless) | `online-boutique` |
| UBI | `registry.access.redhat.com/ubi9/*` | `online-boutique-ubi` |

Both pushed to a local registry and deployed by kustomize overlays. The
comparison is therefore base-image choice, holding application source,
dependency manifests and build recipes constant — not two different
applications.

One deliberate correction along the way: the UBI `cache` image was originally
upstream's `redis:alpine`, which is neither UBI nor Red Hat. A comparison
containing it was not UBI-versus-hardened. Valkey is now built from source on
`ubi9/ubi` and shipped on `ubi9/ubi-minimal`
([`Containerfile.valkey`](Containerfile.valkey)), so all 12 images on each side
are genuinely from the base set they claim.

## The result

Distinct CVE **ids** per namespace, each counted once however many images or
packages carry it:

| | hardened | UBI | ratio |
|---|---|---|---|
| **distinct CVE ids** | **142** | **355** | 2.5× |
| per-image sum (double counts shared) | 264 | 1608 | 6.1× |
| CRITICAL | **10** | **10** | 1.0× |
| IMPORTANT | 106 | 178 | 1.7× |
| MODERATE | 90 | 805 | 8.9× |
| LOW | 61 | 599 | 9.8× |

Split by who owns the fix:

| layer | hardened | of which fix published | UBI | of which fix published |
|---|---|---|---|---|
| OS packages (distro advisories) | **7** | 1 | **224** | 4 |
| application dependencies (OSV/GHSA/go.dev) | 115 | 112 | 114 | 111 |
| other (nvd.nist.gov) | 21 | 20 | 22 | 22 |

Layers can over-sum against the namespace total: one CVE affecting both an OS
package and an application package is two pieces of work and counts in both.

## What it supports

**The OS layer is ~32× smaller.** 7 findings against 224. This is the
attack-surface result, and it is the honest headline — not the 2.5× on the
namespace total, which is diluted by an application layer that is identical by
construction.

**Neither image is better patched.** Hardened has 1 OS fix published and
**zero obtainable**; UBI has 4 of 224. So the difference is not a backlog the
hardened side has worked through — it is roughly 220 findings that nobody has a
fix for and that the hardened image simply never carries. Those are the ones
that would appear in every future scan, every report, every audit, forever,
with no action available.

**The critical count is identical: 10 vs 10.** All ten are in the application
layer, because that layer is the same source with the same dependency manifests
built twice. This is the most useful single fact in the measurement: the OS
layer contributes **zero** criticals on either side. Distroless removes a large
volume of unfixable low-and-moderate noise and does nothing about the
vulnerabilities most likely to matter.

**The actionable work is in the application layer and is unchanged by the base
image.** 115 findings with 112 fixable on hardened, 114 with 111 on UBI. That
is where dependency upgrades move the number, and where getting to zero is
achievable — see "Driving the application layer toward zero" in the
[README](README.md).

## What it does not support

**"RHACS cannot scan hardened images."** It scanned all 24. If your RHACS
version carries that known issue, verify it against your own install rather
than assuming.

**"`cartservice` is clean."** ACS reports `TOTAL-COMPONENTS: 0` for it on both
sides — a self-contained .NET binary with no rpm database and no language
manifest to enumerate. That is a coverage gap, not a hardening result, and it
is symmetric so it does not bias the comparison. grype reads the same image
successfully, which is the argument for running two scanners.

**Any cross-tool ratio.** Counting units differ: this document counts distinct
CVE ids; `scan-stack.sh` counts distinct CVE/**package pairs**. One CVE
affecting three packages is 1 here and 3 there. Ratios derived from one are not
comparable with ratios derived from the other.

## Where the hardened residue comes from

All seven OS findings, attributed:

| source | base image | CVEs | fix |
|---|---|---|---|
| `libX11` ×3, `libXtst` ×1 | `hi/openjdk:21` — `adservice` only | 4 | `libXtst` only: `1.2.5-5.1.hum1` |
| `python3.12`, `python3.12-libs` | `hi/python` | 2 | none |
| `valkey` | `hi/valkey` | 1 | none |

**Four of the seven are X11 client libraries in a headless gRPC service.**
Java's AWT links `libX11` and `libXtst`, so `hi/openjdk:21` ships them whether
or not a display exists; `-Djava.awt.headless=true` changes runtime behaviour,
not the package manifest. Confirmed by attribution: only `adservice` reports
them.

The corollary is that hardened's remaining OS surface is a function of **base
selection**, not patching. Three base images account for all of it, and
dropping the single Java service would take it from 7 to 3. On the UBI side
that lever barely exists: its 224 are spread across all twelve images, because
each carries a full el9 package set regardless of what it runs.

## What "fix published" does and does not mean

A published fix is a **vendor advisory**, not a fix you can obtain.

`libXtst` CVE-2026-94286 is fixed in `1.2.5-5.1.hum1`. `hi/openjdk:21` still
ships `1.2.5-5`, so `check-bases.sh` reads `adservice` as current and a rebuild
changes nothing. Hardened's actionable OS work is therefore **zero**, with one
fix in flight upstream — not the "1" the layer table shows.

This asymmetry is worth stating in any report: an **application** fix is
actionable the moment it publishes, because the manifest is yours. An
**OS-package** fix is actionable only once the base image ships it, which can
lag the advisory by days. Always check `check-bases.sh` before promising that a
rebuild clears an OS finding.

## The scanners disagree, and the disagreements are informative

| | reads hardened images | identifies the OS | reads `cartservice` | notable artifact |
|---|---|---|---|---|
| RHACS Scanner V4 | yes | yes (`hi/*` as Red Hat) | no | — |
| grype | yes | yes (`hummingbird:rolling`) | yes | rangeless false positives |
| trivy | partially | **no** | yes | silently skips the OS layer |

**grype reported an openssl CVE backwards.** CVE-2026-84783 appeared against
the hardened image. Its database holds `fix=3.5.8-0.1.hum1 state=fixed`
*alongside* rangeless records — entries with no version constraint, which match
every version. `grype --why` renders the match as `matched on none (unknown)`,
which is the tell. ACS, using Red Hat's own VEX data, reports that CVE in
**7 UBI images and 0 hardened**: real on UBI, fixed on hardened. grype had it
inverted, and a report built on grype alone would have claimed the hardened
image was worse on exactly the package the vendor had already fixed.

**trivy cannot identify the OS of a hardened image** and reports `OS: none`.
It then skips OS-package analysis entirely and says so only in a log line —
which `--quiet` hides. A trivy run therefore shows a hardened image with a
near-empty OS layer for the wrong reason, and the comparison looks dramatic
while measuring nothing.

Both artifacts point the same way: for Red Hat Hardened Images, prefer the
scanner consuming Red Hat's VEX data, and treat a single scanner's OS-layer
verdict as a hypothesis.

## Pitfalls that silently invalidate a run

Each of these produced plausible, stable, wrong numbers before being caught.
None announced itself.

**Central caches scan results per image name, tag included.** Re-scanning a tag
whose digest has moved returns the result for the image that tag used to point
at. A `cache` image rebuilt from Alpine onto UBI kept reporting `zlib 1.3.2-r0`
— an `apk` version — through a rebuild, a rollout and two re-scans. The tell was
that *every other number was byte-identical* across runs; a genuine re-read of
24 images does not reproduce to the digit. `acs-scan.sh` now passes `--force`.

**A rebuilt tag is invisible to a node that cached it.** Kubernetes defaults
`imagePullPolicy` to `IfNotPresent` for any tag that is not `:latest`, and
`oc rollout restart` only recreates the pod — which finds the tag present and
does not re-pull. The overlays set `Always`, but deployments created before that
patch keep the default, and no amount of rebuilding or restarting dislodges it.
Re-apply the overlay.

**The scan reads tags, not running digests.** Image lists come from the pod
spec, so a scan describes what the tag resolves to *now*. If pods run an older
digest the numbers are a valid image comparison but not a statement about what
is deployed. `acs-scan.sh` warns, names the deployments whose pull policy is not
`Always`, and says which remedy applies.

**One stale image in a "UBI" namespace is not a UBI namespace.** The Alpine
`cache` image inflated UBI's OS count with `apk` findings and undercut the
headline. Audit that every image in a set is actually from that set.

**Counts move for reasons unrelated to your changes.** A refreshed vulnerability
store, a VEX reclassification, and a rebuilt image all shift numbers, and an
unchanged total can hide offsetting changes — an OS row went from 8/0 to 7/1
with one CVE leaving and a different one gaining a fix. `acs-scan.sh` snapshots
each run to `acs-history/` and reports `gone` / `new` / `fix became available`
against the previous one. `gone` is not `fixed`: a VEX statement removes a CVE
with nothing patched.

## Reproducing it

```bash
cd test-workloads/online-boutique/hardened
./check-bases.sh                      # and BASE=ubi ./check-bases.sh
BASE=hardened ./build-push.sh         # rebuild anything stale, both sets
BASE=ubi      ./build-push.sh
oc apply -k ../overlays/hardened -n online-boutique
oc apply -k ../overlays/ubi      -n online-boutique-ubi

cd ../../../acs
./acs-scan.sh online-boutique online-boutique-ubi
```

See [`acs/README.md`](../../../acs/README.md) for installing RHACS and supplying
credentials, and [`README.md`](README.md) for the build, the six things that are
not an image swap, and the per-service findings.

A run is trustworthy when it prints no staleness warning, says
`Scanned with --force`, and both `check-bases.sh` invocations report every
service current. Anything else is measuring an image you are not running.
