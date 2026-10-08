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
# roxctl refuses to pick between credentials: with both ROX_API_TOKEN and
# ROX_ADMIN_PASSWORD set it fails every call with "cannot use basic and
# token-based authentication at the same time". The password is usually left
# over from generating the init bundle. This script's contract is token auth,
# so drop the password for its own child processes rather than failing.
if [ -n "${ROX_ADMIN_PASSWORD:-}" ]; then
  echo "note: ROX_ADMIN_PASSWORD is set and would conflict with ROX_API_TOKEN;" >&2
  echo "      ignoring it for this run (roxctl accepts only one credential)." >&2
  unset ROX_ADMIN_PASSWORD
fi
for t in roxctl oc jq; do command -v "$t" >/dev/null || { echo "$t not on PATH" >&2; exit 2; }; done

OUT="results-acs"; mkdir -p "$OUT"
# --insecure-skip-tls-verify is NOT set: a scanner you cannot authenticate is
# not a scanner. If Central's route uses a private CA, trust it on this host
# rather than turning verification off.
ROX=(roxctl -e "$ROX_CENTRAL_ADDRESS")

scan_ns() {
  local ns="$1" dir="$OUT/$1"
  mkdir -p "$dir"
  # Stale markers from a previous run would be reported as this run's failures.
  rm -f "$dir/.failed"
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
      # Keep going -- one unscannable image should not cost the whole run -- but
      # do NOT leave a parseable empty document behind. An earlier version wrote
      # {} here, which the report then counted as zero findings, so a run where
      # every scan failed rendered as a table of zeros under a caveat about
      # hardened images. A failure has to stay distinguishable from a clean
      # result, which is the entire point of the caveat.
      rm -f "$dir/$svc.json"
      printf '%s\n' "$svc" >> "$dir/.failed"
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

  local failed=0
  [ -f "$dir/.failed" ] && failed=$(wc -l < "$dir/.failed" | tr -d ' ')

  # Lead with failures. A scan that did not run tells you nothing about the
  # image, and burying that under a table makes it look like data.
  if [ "$failed" -gt 0 ]; then
    printf '**%s of %s scans failed.** The reason, once:\n\n```\n' \
      "$failed" "$(( failed + $(ls -1 "$dir"/*.json 2>/dev/null | wc -l | tr -d ' ') ))"
    # One representative error rather than twelve identical ones.
    head -3 "$dir/$(head -1 "$dir/.failed").err" 2>/dev/null | sed 's/^/  /'
    printf '```\n\nNothing below describes those images.\n\n'
  fi

  printf '| image | distinct CVEs |\n|---|---|\n'
  local total=0 zero=0 scanned=0
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    local svc c; svc="$(basename "$f" .json)"; c="$(count_cves "$f")"
    printf '| %s | %s |\n' "$svc" "$c"
    scanned=$((scanned+1))
    case "$c" in
      ''|'?'|0) zero=$((zero+1)) ;;
      *) total=$((total+c)) ;;
    esac
  done
  if [ -f "$dir/.failed" ]; then
    while IFS= read -r svc; do printf '| %s | **scan failed** |\n' "$svc"; done < "$dir/.failed"
  fi

  printf '\n%s scanned, %s distinct CVEs counted' "$scanned" "$total"
  [ "$zero" -gt 0 ]   && printf ', %s scanned clean or unparsed' "$zero"
  [ "$failed" -gt 0 ] && printf ', %s not scanned' "$failed"
  printf '\n'

  # The hardened-image caveat explains a SUCCESSFUL scan that found nothing. It
  # does not explain a scan that never ran, and offering it there sends the
  # reader to the wrong document.
  if [ "$zero" -gt 0 ]; then
    printf '\nZero findings from a successful scan is still not proof of clean.\n'
    printf 'Check one directly:\n    jq "." %s/<image>.json | head -40\n' "$dir"
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
