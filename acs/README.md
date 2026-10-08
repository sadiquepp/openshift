# Red Hat Advanced Cluster Security — install, and scan two namespaces

Artifacts to stand up RHACS on an OpenShift cluster and scan the two Online
Boutique namespaces built by
[`test-workloads/online-boutique/hardened`](../test-workloads/online-boutique/hardened):
`online-boutique` (Red Hat Hardened Images) and `online-boutique-ubi` (UBI 9).

## Read this before you install

**RHACS 4.11 is documented as not reporting vulnerabilities for Red Hat
hardened images.** The [4.11 release
notes](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/release_notes/release-notes-411)
list under known issues that a data gap in the Red Hat VEX security data feed
stopped vulnerability reporting for Red Hat hardened images (Project
Hummingbird) as of 15 July 2026, with Product Security working to restore it.
The same notes also carry a new-feature entry saying Clair can scan hardened
images and cross-reference VEX metadata, and they do not reconcile the two.

So expect the `online-boutique` side to come back thin or empty, and do not read
that as a clean result — it is the same "unreadable looks identical to clean"
failure that makes an unread base image the most dangerous scan outcome. That
asymmetry is worth measuring deliberately: a scanner that reports nothing for
one variant and hundreds for the other tells you something real about tooling
readiness for hardened images, which is a finding, just not the one you went
looking for.

RHACS is still worth installing for everything else — policy enforcement,
admission control, runtime, and the application layer in both namespaces.

## Install order

The order is not stylistic. SecuredCluster depends on certificates Central
generates, so it cannot come first.

### 1. Operator

```bash
oc apply -f 01-operator.yaml
oc -n rhacs-operator get csv -w          # wait for Succeeded
```

Confirm the channel before applying, since it varies by version and by whether
the catalog is mirrored:

```bash
oc get packagemanifest rhacs-operator -n openshift-marketplace \
  -o jsonpath='{.status.defaultChannel}{"\n"}'
```

Nothing returned means the operator is not in the cluster's catalog. On a
disconnected cluster it has to be mirrored and published through a
`CatalogSource` first — see [`../disconnected/`](../disconnected) — and then
`source:` in `01-operator.yaml` points at that CatalogSource.

### 2. Central

```bash
oc apply -f 02-central.yaml
oc -n stackrox get pods -w
```

Then check which scanner you got, because it determines whose vulnerability
data answers your questions:

```bash
oc -n stackrox get pods | grep -i scanner
```

`scanner-v4-*` pods mean Scanner V4, which reads Red Hat's own CSAF/VEX data and
is the default for new installs from 4.8 onward. A lone `scanner-*` plus
`scanner-db-*` is the older StackRox Scanner, deprecated since 4.6.

**Disconnected clusters:** set `egress.connectivityPolicy: Offline` in
`02-central.yaml` and upload vulnerability definitions manually. Without them
Central runs normally and reports no vulnerabilities — indistinguishable from a
clean cluster, and the single most likely way to get a misleading result here.

### 3. Init bundle

`roxctl` needs credentials, and nothing has given it any yet — hence
`no credentials found for central-...:443`. The operator generated an admin
password; put it in the environment rather than on the command line, because an
argument is visible in `ps` and persists in shell history:

```bash
export ROX_CENTRAL_ADDRESS="$(oc -n stackrox get route central -o jsonpath='{.spec.host}'):443"
export ROX_ADMIN_PASSWORD="$(oc -n stackrox get secret central-htpasswd -o jsonpath='{.data.password}' | base64 -d)"
```

`roxctl` reads `ROX_ADMIN_PASSWORD` for basic auth, so no flag is needed:

```bash
roxctl -e "$ROX_CENTRAL_ADDRESS" \
  central init-bundles generate online-boutique --output-secrets init-bundle.yaml
oc -n stackrox create -f init-bundle.yaml
```

Three things that trip this up:

- **`-p` means different things on different subcommands.** On
  `central init-bundles generate` it is the basic-auth password; on
  `central generate` it *sets* the admin password. The environment variable
  avoids the ambiguity.
- **TLS.** Central's route is served with the cluster's ingress certificate,
  which this host may not trust, and the failure looks like a connection
  problem rather than a trust problem. Supply the CA rather than disabling
  verification:

  ```bash
  oc -n openshift-ingress-operator get secret router-ca \
    -o jsonpath='{.data.tls\.crt}' | base64 -d > router-ca.crt
  roxctl -e "$ROX_CENTRAL_ADDRESS" --ca router-ca.crt central init-bundles generate ...
  ```

  `--insecure-skip-tls-verify` also "works", and means you are feeding
  vulnerability decisions from a server you have not authenticated. Don't.
- **The admin password is for getting started.** Red Hat's own docs say it is
  for testing and not for production. For the scan step below, and anything
  automated, use an API token instead — tokens need no interactive login and
  can be scoped to a role.

`init-bundle.yaml` contains cluster credentials. It is covered by this
directory's `.gitignore` under that exact name — **delete it once applied**, and
if you rename it, do not commit it.

### 4. SecuredCluster

Set `clusterName` in `03-secured-cluster.yaml` first, then:

```bash
oc apply -f 03-secured-cluster.yaml
oc -n stackrox get pods -w               # sensor, collector, admission-control
```

## Scan the two namespaces

Create an API token in the portal under **Platform Configuration →
Integrations → API Token**, with a role that can read vulnerability data.

```bash
export ROX_CENTRAL_ADDRESS="$(oc -n stackrox get route central -o jsonpath='{.spec.host}'):443"
export ROX_API_TOKEN=...
./acs-scan.sh online-boutique online-boutique-ubi
```

[`acs-scan.sh`](acs-scan.sh) reads the images the two namespaces are actually
running, scans each with `roxctl image scan`, keeps the raw JSON under
`results-acs/`, and writes a per-image table for both namespaces.

Two things about how it reports:

- It finds the vulnerability list **by shape** rather than by a fixed JSON path,
  because `roxctl`'s layout differs across versions and a hard-coded path that
  misses prints zero — which reads as a clean image. Where it cannot parse a
  file it says so instead of counting it as clean.
- It distinguishes **zero findings** from **zero parsed findings** in the
  summary line, and points at the hardened-image caveat above when any appear.

It uses `roxctl image scan` per image rather than Central's bulk export API
(`/v1/export/vuln-mgmt/workloads`). That endpoint exists and would be one call,
but its namespace filter syntax and response schema are not publicly
documented, and a report built on a guessed schema is worse than one built on a
slower documented interface.

TLS verification is not disabled anywhere. If Central's route uses a private CA,
trust it on the host running the scan rather than passing
`--insecure-skip-tls-verify` — a scanner you cannot authenticate is not a
scanner.

## Comparing against the other scanners

[`../test-workloads/online-boutique/hardened/cve-demo/`](../test-workloads/online-boutique/hardened/cve-demo)
runs grype and trivy over the same images and documents how the two disagree.
Read those results alongside these rather than subtracting them: **advisory
identifiers do not line up between scanners** — the same urllib3 advisory comes
back as `GHSA-…` from grype and `CVE-…` from trivy — so a cross-scanner set
difference is noise. Compare the tables, not the id sets.

## Removing it

```bash
oc delete -f 03-secured-cluster.yaml
oc delete -f 02-central.yaml
oc delete -f 01-operator.yaml
oc delete namespace stackrox rhacs-operator
```

Delete the SecuredCluster before Central, or the sensor spends its shutdown
retrying against a Central that is already gone.
