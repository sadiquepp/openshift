#!/usr/bin/env bash
#
# preflight-platform.sh — phase 4a of observability/aiops
#
# Reports what this cluster's catalogs actually offer for the platform the demo
# needs: RHOAI, AAP, TrustyAI, ZTWI/SPIRE and optionally Connectivity Link.
# READ-ONLY — `oc get` only, nothing is created.
#
# Why this exists. Writing the install roles from memory of these operators'
# APIs is how you get a confidently wrong role: RHOAI's DataScienceCluster has
# changed group and version more than once, its component toggles differ by
# release, and AAP's CR is a different kind in 2.4 than in 2.5. Phase 1 took
# the same approach and it caught four wrong assumptions before any of them
# reached the cluster.
#
# Usage:
#   export KUBECONFIG=~/.kube/config
#   ./scripts/preflight-platform.sh
#
# Paste the OPERATOR FACTS block back and the roles get written against it.

set -uo pipefail

MARKETPLACE="${MARKETPLACE:-openshift-marketplace}"

c_red=$'\033[1;31m'; c_green=$'\033[1;32m'; c_yellow=$'\033[1;33m'
c_blue=$'\033[1;34m'; c_dim=$'\033[2m'; c_reset=$'\033[0m'

section() { printf '\n%s== %s%s\n' "$c_blue" "$*" "$c_reset"; }
ok()      { printf '  %s[ ok ]%s %s\n' "$c_green"  "$c_reset" "$*"; }
warn()    { printf '  %s[warn]%s %s\n' "$c_yellow" "$c_reset" "$*"; }
bad()     { printf '  %s[fail]%s %s\n' "$c_red"    "$c_reset" "$*"; }
note()    { printf '  %s%s%s\n'        "$c_dim"    "$*" "$c_reset"; }

OC="$(command -v oc || true)"
[[ -n "$OC" ]] || { bad "oc not on PATH"; exit 1; }
"$OC" whoami >/dev/null 2>&1 || { bad "not logged in"; exit 1; }

FACTS=()

# ─────────────────────────────────────────────────────────────────────────────
section "0. Cluster"
VER="$("$OC" get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null)"
ok "OpenShift ${VER:-unknown}"
FACTS+=("openshift            ${VER:-unknown}")

SC="$("$OC" get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}' 2>/dev/null)"
if [[ -n "$SC" ]]; then
  ok "default StorageClass: ${SC}"
else
  bad "no default StorageClass — RHOAI and AAP both need one"
fi
FACTS+=("default storageclass ${SC:-<none>}")

# GPU decides nothing now that the demo is recorded, but record it: it is the
# one thing that would force a different environment.
GPU="$("$OC" get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{" "}{end}' 2>/dev/null | tr -s ' ')"
if [[ -n "${GPU// /}" ]]; then
  ok "GPU allocatable: ${GPU}"
  FACTS+=("gpu                  ${GPU}")
else
  note "no nvidia.com/gpu on any node — CPU inference only"
  FACTS+=("gpu                  none")
fi

section "1. Worker headroom"
"$OC" get nodes -l node-role.kubernetes.io/worker -o custom-columns=\
NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory \
  --no-headers 2>/dev/null | while read -r n c m; do
  note "$(printf '%-10s %-9s %s' "$n" "$c" "$m")"
done
note "Compare against 'oc adm top nodes' — these are allocatable, not free."

# ─────────────────────────────────────────────────────────────────────────────
# Catalog facts. A PackageManifest tells us the real package name, its
# channels, the default channel and the version each channel currently
# resolves to — which is what the Subscription needs and what differs between
# clusters.
# ─────────────────────────────────────────────────────────────────────────────
# Every PackageManifest on the cluster, once: name, defaultChannel, catalog.
# Fetched up front so the fragment search below costs one API call rather than
# one per operator.
ALL_PKGS=""
load_packages() {
  ALL_PKGS="$("$OC" get packagemanifests -A \
    -o 'jsonpath={range .items[*]}{.metadata.name}{" "}{.status.defaultChannel}{" "}{.status.catalogSource}{"\n"}{end}' \
    2>/dev/null | sort -u)"
}

probe_package() {
  # $1 = label, $2 = a FRAGMENT of the package name.
  #
  # Matched as a fragment across every catalog rather than looked up by exact
  # name. An exact lookup reports MISSING when a package has merely been
  # renamed, which is a false negative that reads like "this operator is
  # unavailable" — and these names do move between releases. ocp-onpremise's
  # SPIRE role does it this way and it is the better technique.
  local label="$1" frag="$2"
  [[ -z "$ALL_PKGS" ]] && load_packages

  local matches
  matches="$(printf '%s\n' "$ALL_PKGS" | grep -i -- "$frag" || true)"
  if [[ -z "$matches" ]]; then
    warn "${label}: nothing matching '${frag}' in any catalog on this cluster"
    FACTS+=("$(printf '%-20s NO MATCH for fragment %s' "$label" "$frag")")
    return 1
  fi

  local n
  n="$(grep -c . <<<"$matches")"
  if [[ "$n" -gt 1 ]]; then
    note "${label}: ${n} packages match '${frag}':"
    while read -r nm ch cat; do
      [[ -n "$nm" ]] && note "$(printf '  %-52s default=%-14s %s' "$nm" "${ch:-?}" "${cat:-?}")"
    done <<<"$matches"
  fi

  local pkg
  pkg="$(head -1 <<<"$matches" | awk '{print $1}')"
  local json
  json="$("$OC" get packagemanifest "$pkg" -n "$MARKETPLACE" -o json 2>/dev/null)"
  if [[ -z "$json" ]]; then
    warn "${label}: '${pkg}' listed but could not be read"
    FACTS+=("$(printf '%-20s UNREADABLE (%s)' "$label" "$pkg")")
    return 1
  fi
  printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
st = d.get("status", {})
default = st.get("defaultChannel", "")
cat = st.get("catalogSource", "")
rows = []
for ch in st.get("channels", []) or []:
    name = ch.get("name", "")
    csv = ch.get("currentCSV", "")
    ver = (ch.get("currentCSVDesc") or {}).get("version", "")
    rows.append((name, csv, ver, name == default))
print("CATALOG\t%s" % cat)
for name, csv, ver, isdef in rows:
    print("CHAN\t%s\t%s\t%s\t%s" % (name, ver, csv, "default" if isdef else ""))
' | while IFS=$'\t' read -r kind a b c dflt; do
      case "$kind" in
        CATALOG) ok "${label}: in catalog '${a}'" ;;
        CHAN)    note "$(printf '  channel %-18s version %-14s %s' "$a" "${b:-?}" "${dflt}")" ;;
      esac
    done

  local dch dver
  dch="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",{}).get("defaultChannel",""))')"
  dver="$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin).get("status", {})
dch = d.get("defaultChannel", "")
for ch in d.get("channels", []) or []:
    if ch.get("name") == dch:
        print((ch.get("currentCSVDesc") or {}).get("version", ""))
        break
')"
  FACTS+=("$(printf '%-20s %s channel=%s version=%s' "$label" "$pkg" "${dch:-?}" "${dver:-?}")")
}

section "2. Operator packages"
probe_package "RHOAI"        "rhods"
probe_package "AAP"          "ansible-automation-platform"
probe_package "TrustyAI"     "trustyai"
probe_package "ZTWI/SPIRE"   "zero-trust"
probe_package "SPIRE (alt)"  "spire"
probe_package "Connectivity" "kuadrant"

# Last resort for anything still unmatched: show every operator whose name
# hints at identity or guardrails, so a rename is visible rather than silent.
section "2b. Anything identity- or trust-shaped in the catalogs"
printf '%s\n' "$ALL_PKGS" | grep -iE "spiffe|spire|zero|trust|guard|identity" \
  | while read -r nm ch cat; do
      [[ -n "$nm" ]] && note "$(printf '%-56s default=%-14s %s' "$nm" "${ch:-?}" "${cat:-?}")"
    done || note "(nothing)"

# ─────────────────────────────────────────────────────────────────────────────
section "3. What the CRDs will actually be called"
# The group and version of these CRs move between releases, and guessing is how
# a role ends up applying a manifest the API server rejects. Only present once
# the operator is installed, so absence here is expected and not a failure.
for crd in \
  dscinitializations.dscinitialization.opendatahub.io \
  datascienceclusters.datasciencecluster.opendatahub.io \
  ansibleautomationplatforms.aap.ansible.com \
  automationcontrollers.automationcontroller.ansible.com \
  trustyaiservices.trustyai.opendatahub.io \
  clusterspiffeids.spire.spiffe.io \
  ; do
  got="$("$OC" get crd "$crd" -o jsonpath='{range .spec.versions[*]}{.name}{" "}{end}' 2>/dev/null)"
  if [[ -n "$got" ]]; then
    ok "$(printf '%-62s %s' "$crd" "$got")"
  else
    note "$(printf '%-62s absent' "$crd")"
  fi
done

section "4. Already installed"
for ns in redhat-ods-operator redhat-ods-applications aap ansible-automation-platform \
          trustyai-system zero-trust-workload-identity-manager; do
  if "$OC" get ns "$ns" >/dev/null 2>&1; then
    warn "namespace ${ns} already exists"
  fi
done
CSVS="$("$OC" get csv -A --no-headers 2>/dev/null | grep -icE "rhods|ansible-automation|trustyai|spiffe|kuadrant" || true)"
note "existing CSVs matching the platform: ${CSVS:-0}"

# ─────────────────────────────────────────────────────────────────────────────
section "OPERATOR FACTS"
for f in "${FACTS[@]}"; do printf '  %s\n' "$f"; done
printf '\n%sPaste this block back to continue with phase 4a.%s\n' "$c_dim" "$c_reset"
