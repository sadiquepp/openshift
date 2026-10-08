#!/usr/bin/env bash
# Scan every image running in one or two namespaces with RHACS, and diff them.
#
#   export ROX_CENTRAL_ADDRESS=central-stackrox.apps.example.com:443
#   export ROX_API_TOKEN=...            # Platform Configuration > Integrations
#   ./acs-scan.sh online-boutique online-boutique-ubi
#
# Writes results-acs/<namespace>/<service>.json plus a report, and keeps the
# raw JSON so questions can be answered later without re-scanning.
#
# Uses `roxctl image scan` per image rather than Central's bulk export API.
# The export endpoint (/v1/export/vuln-mgmt/workloads) exists and would be one
# call, but its namespace filter syntax and response schema are not documented
# in anything public, and a report built on a guessed schema reports zeroes
# that look like clean images. roxctl's per-image interface is documented and
# stable; the cost is one call per image.
set -euo pipefail
cd "$(dirname "$0")"

NS_A="${1:-}"; NS_B="${2:-}"
[ -n "$NS_A" ] || { echo "usage: $0 <namespace> [namespace]" >&2; exit 2; }
for v in ROX_CENTRAL_ADDRESS ROX_API_TOKEN; do
  [ -n "${!v:-}" ] || { echo "set $v (see the header of this script)" >&2; exit 2; }
done
for t in roxctl oc jq; do command -v "$t" >/dev/null || { echo "$t not on PATH" >&2; exit 2; }; done

OUT="results-acs"; mkdir -p "$OUT"
# --insecure-skip-tls-verify is NOT set: a scanner you cannot authenticate is
# not a scanner. If Central's route uses a private CA, trust it on this host
# rather than turning verification off.
ROX=(roxctl -e "$ROX_CENTRAL_ADDRESS")

scan_ns() {
  local ns="$1" dir="$OUT/$1"
  mkdir -p "$dir"
  echo "==> $ns"
  # Images as the cluster actually runs them, deduplicated. Reading pods rather
  # than Deployments catches whatever is really there, including anything the
  # overlay did not set.
  local images
  images=$(oc get pods -n "$ns" -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' \
           | grep -v '^$' | sort -u)
  [ -n "$images" ] || { echo "    no running images in $ns" >&2; return 1; }

  local n=0
  while IFS= read -r img; do
    local svc="${img##*/}"; svc="${svc%%:*}"; svc="${svc%%@*}"
    printf '    %-28s' "$svc"
    if "${ROX[@]}" image scan --image "$img" -o json > "$dir/$svc.json" 2>"$dir/$svc.err"; then
      printf 'ok\n'
    else
      printf 'FAILED (see %s)\n' "$dir/$svc.err"
      # Keep going: one unscannable image should not cost the whole run, and
      # which images fail is itself a finding -- see the README on hardened
      # images.
      echo '{}' > "$dir/$svc.json"
    fi
    n=$((n+1))
  done <<<"$images"
  echo "    $n images"
}

# roxctl's JSON layout differs across versions, so find the vulnerability list
# by shape instead of by path: any object carrying a CVE-like id and a severity.
# When that finds nothing, the report says so rather than printing zero, because
# zero findings and zero parsed findings are not the same claim.
count_cves() {
  local f="$1"
  jq -r '[ .. | objects
           | select((has("cve") or has("id")) and (has("severity") or has("Severity")))
           | ((.cve // .id) | tostring) ]
         | map(select(test("^(CVE|GHSA|RHSA)-"; "i"))) | unique | length' "$f" 2>/dev/null || echo "?"
}

report() {
  local ns="$1" dir="$OUT/$1"
  printf '\n### %s\n\n' "$ns"
  printf '| image | distinct CVEs |\n|---|---|\n'
  local total=0 unparsed=0
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    local svc c; svc="$(basename "$f" .json)"; c="$(count_cves "$f")"
    printf '| %s | %s |\n' "$svc" "$c"
    case "$c" in
      ''|'?'|0) unparsed=$((unparsed+1)) ;;
      *) total=$((total+c)) ;;
    esac
  done
  printf '\n%s images, %s distinct CVEs counted' "$(ls -1 "$dir"/*.json 2>/dev/null | wc -l | tr -d ' ')" "$total"
  [ "$unparsed" -gt 0 ] && printf ', %s reporting zero or unparsed' "$unparsed"
  printf '\n'
  if [ "$unparsed" -gt 0 ]; then
    printf '\nZero is not the same as clean. Check one of those files directly:\n'
    printf '    jq "." %s/<image>.json | head -40\n' "$dir"
    printf 'RHACS 4.11 is documented as not reporting vulnerabilities for Red Hat\n'
    printf 'hardened images (Project Hummingbird) -- see README.md.\n'
  fi
}

scan_ns "$NS_A" || true
[ -n "$NS_B" ] && { scan_ns "$NS_B" || true; }

{
  echo "# RHACS scan — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "Central: \`$ROX_CENTRAL_ADDRESS\`"
  report "$NS_A"
  [ -n "$NS_B" ] && report "$NS_B"
} | tee "$OUT/report.md"
echo
echo "raw JSON kept under $OUT/ -- no re-scan needed to ask a follow-up question"
