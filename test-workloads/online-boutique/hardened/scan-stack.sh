#!/usr/bin/env bash
#
# Scan every image actually running in one or two OpenShift namespaces and
# report CVEs by severity -- per service and per stack.
#
#   ./scan-stack.sh online-boutique                       # one stack
#   ./scan-stack.sh online-boutique online-boutique-ubi   # diff two stacks
#
# Pairs with overlays/hardened and overlays/ubi: build both stacks
# (BASE=hardened then BASE=ubi ./build-push.sh ...), deploy both, then diff the
# namespaces. Services are matched across namespaces by image name, so the two
# only need to agree on repository names, not on tags.
#
# Where cve-demo/ isolates one service to make a clean argument, this measures
# the whole thing as deployed -- which is the number anyone asking "how much
# does this actually buy us" wants.
#
# Requires: oc (logged in), jq, and EITHER grype or trivy -- same as
# cve-demo/compare.sh. grype is preferred when both are present; neither needs
# credentials of its own, but the images must be pullable, so authenticate to
# the registry first (both read ~/.docker/config.json and $REGISTRY_AUTH_FILE).
#
# Results land in ./results-<namespace>/ ; report at ./results-stack-report.md.

set -euo pipefail

NS_A="${1:?usage: $0 <namespace> [namespace-to-compare]}"
NS_B="${2:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$HERE/results-stack-report.md"

have() { command -v "$1" >/dev/null 2>&1; }
for tool in oc jq; do
  have "$tool" || { echo "error: $tool not on PATH" >&2; exit 1; }
done
if   have grype; then SCANNER=grype
elif have trivy; then SCANNER=trivy
else
  echo "error: need grype or trivy on PATH" >&2
  echo "  grype: curl -sSfL https://get.anchore.io/grype | sh -s -- -b /usr/local/bin" >&2
  exit 1
fi
if [ "$SCANNER" = grype ] && ! grype db status >/dev/null 2>&1; then
  echo "error: grype's vulnerability database is not usable." >&2
  echo "  fix:  grype db delete && grype db update" >&2
  exit 1
fi

# Collect the images a namespace is really running, from the pods rather than
# the Deployments -- that way `oc set image` and any mutating admission webhook
# are accounted for, and initContainers are not missed.
collect() {
  oc get pods -n "$1" \
    -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' \
    | grep -v '^$' | sort -u
}

# Everything after the last / and before the first : -- frontend, cache, etc.
svc_of() { local b="${1##*/}"; echo "${b%%:*}"; }

scan_ns() {
  local ns="$1"
  local out="$HERE/results-$ns"
  mkdir -p "$out"
  : > "$out/by-service.tsv"
  local images; images=$(collect "$ns")
  [ -n "$images" ] || { echo "error: no running pods in namespace $ns" >&2; exit 1; }
  while read -r image; do
    local svc; svc=$(svc_of "$image")
    echo "==> [$ns] $SCANNER $image" >&2
    case "$SCANNER" in
      grype)
        # registry: explicitly -- without it grype probes the docker and podman
        # sockets first and fails with "podman not available: no host address"
        # on a host that only ever runs `podman build`.
        grype "registry:$image" -o json > "$out/$SCANNER-$svc.json"
        jq -r '.matches[]
               | [(.vulnerability.severity // "Unknown" | ascii_upcase),
                  .vulnerability.id, .artifact.name,
                  (.vulnerability.fix.state
                     | if . == null or . == "" then "unknown" else . end)] | @tsv' \
          "$out/$SCANNER-$svc.json" | sort -u > "$out/cves-$svc.tsv" ;;
      trivy)
        trivy image --quiet --image-src remote \
          --format json --output "$out/$SCANNER-$svc.json" "$image"
        jq -r '[ .Results[]? | .Vulnerabilities[]? ]
               | .[]
               | [(.Severity // "UNKNOWN" | ascii_upcase),
                  .VulnerabilityID, .PkgName,
                  (if (.FixedVersion // "") == "" then "not-fixed" else "fixed" end)] | @tsv' \
          "$out/$SCANNER-$svc.json" | sort -u > "$out/cves-$svc.tsv" ;;
    esac
    local c h m l t
    c=$(awk -F'\t' '$1=="CRITICAL"' "$out/cves-$svc.tsv" | wc -l | tr -d ' ')
    h=$(awk -F'\t' '$1=="HIGH"'     "$out/cves-$svc.tsv" | wc -l | tr -d ' ')
    m=$(awk -F'\t' '$1=="MEDIUM"'   "$out/cves-$svc.tsv" | wc -l | tr -d ' ')
    l=$(awk -F'\t' '$1=="LOW"'      "$out/cves-$svc.tsv" | wc -l | tr -d ' ')
    t=$(wc -l < "$out/cves-$svc.tsv" | tr -d ' ')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$svc" "$image" "$c" "$h" "$m" "$l" "$t" \
      >> "$out/by-service.tsv"
  done <<< "$images"
  sort -o "$out/by-service.tsv" "$out/by-service.tsv"
  # Stack totals are over DISTINCT CVE/package pairs across the whole namespace:
  # one glibc CVE present in eleven images is one thing to fix, not eleven.
  cat "$out"/cves-*.tsv | sort -u > "$out/cves-all.tsv"
}

col() { awk -F'\t' -v s="$2" '$1==s' "$1/cves-all.tsv" | wc -l | tr -d ' '; }
fixable() { awk -F'\t' '$4=="fixed"' "$1/cves-all.tsv" | wc -l | tr -d ' '; }

scan_ns "$NS_A"
[ -n "$NS_B" ] && scan_ns "$NS_B"

A="$HERE/results-$NS_A"
B="$HERE/results-$NS_B"

{
  echo "# Online Boutique — CVEs as deployed"
  echo
  echo "Generated $(date -u '+%Y-%m-%d %H:%M UTC') · scanner \`$SCANNER\`"
  echo
  if [ -n "$NS_B" ]; then
    echo "## Stack totals"
    echo
    echo "Distinct CVE/package pairs across all images in the namespace — one"
    echo "glibc CVE shared by eleven images counts once, because it is one thing"
    echo "to fix."
    echo
    echo "| severity | $NS_A | $NS_B |"
    echo "|---|---|---|"
    for sev in CRITICAL HIGH MEDIUM LOW; do
      printf '| %s | %s | %s |\n' "$sev" "$(col "$A" "$sev")" "$(col "$B" "$sev")"
    done
    printf '| **total** | **%s** | **%s** |\n' \
      "$(wc -l < "$A/cves-all.tsv" | tr -d ' ')" "$(wc -l < "$B/cves-all.tsv" | tr -d ' ')"
    printf '| of which fixable now | %s | %s |\n' "$(fixable "$A")" "$(fixable "$B")"
    printf '| distinct CVE ids (ignoring package) | %s | %s |\n' \
      "$(cut -f2 "$A/cves-all.tsv" | sort -u | wc -l | tr -d ' ')" \
      "$(cut -f2 "$B/cves-all.tsv" | sort -u | wc -l | tr -d ' ')"
    echo
    # The total is attack surface; the fixable count is work. They answer
    # different questions and a report giving only the first invites the reply
    # "so what do we do about it", which the second answers.
    echo "The totals above count CVE/package pairs: one CVE affecting three"
    echo "packages is three things to patch. The last row counts CVE ids instead,"
    echo "which is the unit RHACS reports -- compare like with like, because the"
    echo "two give materially different ratios between the same two namespaces."
    echo
    echo "A finding with no fix available is one to report, not to action --"
    echo "no rebuild clears it until the distro or the dependency moves. The"
    echo "fixable row is the part a rebuild would pick up today."
    echo
    # Severity totals hide the case that matters most to anyone gating on
    # criticals: if both sides carry the same ones, the base image is not what
    # decides that gate. Naming them is the difference between a number and a
    # decision.
    echo "## Critical findings, named"
    echo
    echo "| CVE | package | $NS_A | $NS_B | fix |"
    echo "|---|---|---|---|---|"
    join -t$'\t' -a1 -a2 -e '-' -o '0,1.2,2.2,1.3,2.3' \
      <(awk -F'\t' '$1=="CRITICAL"{print $2"\t"$3"\t"$4}' "$A/cves-all.tsv" | sort -u) \
      <(awk -F'\t' '$1=="CRITICAL"{print $2"\t"$3"\t"$4}' "$B/cves-all.tsv" | sort -u) \
      | awk -F'\t' '{
          pkg = ($2 != "-") ? $2 : $3;
          a   = ($2 != "-") ? "yes" : "—";
          b   = ($3 != "-") ? "yes" : "—";
          fix = ($4 != "-") ? $4 : $5;
          printf "| %s | `%s` | %s | %s | %s |\n", $1, pkg, a, b, fix }'
    echo
    echo "A critical present in both columns is not something the base image"
    echo "can fix -- it is in the application or its dependencies, which are"
    echo "identical across the two variants by construction."
    echo
    echo "## Per service"
    echo
    echo "| service | $NS_A (C/H/M/L) | $NS_B (C/H/M/L) | total delta |"
    echo "|---|---|---|---|"
    join -t$'\t' -a1 -a2 -e '-' -o '0,1.3,1.4,1.5,1.6,1.7,2.3,2.4,2.5,2.6,2.7' \
      <(sort -t$'\t' -k1,1 "$A/by-service.tsv") \
      <(sort -t$'\t' -k1,1 "$B/by-service.tsv") \
    | awk -F'\t' '{
        ta = ($6=="-") ? "" : $6; tb = ($11=="-") ? "" : $11;
        d = (ta=="" || tb=="") ? "n/a" : (tb-ta>0 ? "+" (tb-ta) : (tb-ta));
        printf "| `%s` | %s/%s/%s/%s | %s/%s/%s/%s | %s |\n",
               $1,$2,$3,$4,$5,$7,$8,$9,$10,d }'
    echo
    echo "## CVEs in $NS_B but not in $NS_A"
    echo
    echo '```'
    comm -13 <(cut -f2 "$A/cves-all.tsv" | sort -u) <(cut -f2 "$B/cves-all.tsv" | sort -u)
    echo '```'
    echo
    echo "## CVEs in $NS_A but not in $NS_B"
    echo
    echo '```'
    comm -23 <(cut -f2 "$A/cves-all.tsv" | sort -u) <(cut -f2 "$B/cves-all.tsv" | sort -u)
    echo '```'
  else
    echo "## Per service — $NS_A"
    echo
    echo "| service | image | CRITICAL | HIGH | MEDIUM | LOW | total |"
    echo "|---|---|---|---|---|---|---|"
    awk -F'\t' '{printf "| `%s` | `%s` | %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5,$6,$7}' \
      "$A/by-service.tsv"
    echo
    printf '**Stack total (distinct CVE/package pairs): %s**\n' \
      "$(wc -l < "$A/cves-all.tsv" | tr -d ' ')"
  fi
  echo
  echo "## Caveats"
  echo
  echo "- A scanner reports what it can match. A distroless image carries no RPM"
  echo "  database, so OS-level findings are matched from the SBOM the image"
  echo "  ships rather than from rpm -qa; a image with neither can under-report."
  echo "  Cross-check anything surprising with the other scanner or Red Hat ACS."
  echo "- Per-service rows count that image's own findings; the stack total"
  echo "  deduplicates across images, so the rows do not sum to the total."
  echo "- Counts move as the vulnerability database updates. Date any number you"
  echo "  quote, and re-run before quoting it again."
} > "$REPORT"

cat "$REPORT"
echo
echo "==> wrote $REPORT" >&2
