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

# Credentials live for one shell and the route hostname changes per cluster, so
# a run the next morning starts by rediscovering all of it. If rox.env exists
# beside this script it is sourced first -- gitignored, and the documented place
# to keep ROX_CENTRAL_ADDRESS/ROX_CA and one credential. Real values in the
# environment still win over the file.
if [ -f rox.env ]; then
  echo "sourcing rox.env" >&2
  # shellcheck disable=SC1091
  . ./rox.env
fi

NS_A="${1:-}"; NS_B="${2:-}"
[ -n "$NS_A" ] || { echo "usage: $0 <namespace> [namespace]" >&2; exit 2; }
[ -n "${ROX_CENTRAL_ADDRESS:-}" ] || {
  echo "set ROX_CENTRAL_ADDRESS, e.g." >&2
  echo "  export ROX_CENTRAL_ADDRESS=\"\$(oc -n stackrox get route central -o jsonpath='{.spec.host}'):443\"" >&2
  exit 2; }
# roxctl refuses to pick between credentials: with both ROX_API_TOKEN and
# ROX_ADMIN_PASSWORD set it fails every call with "cannot use basic and
# token-based authentication at the same time". The password is usually left
# over from generating the init bundle. This script's contract is token auth,
# so drop the password for its own child processes rather than failing.
if [ -n "${ROX_API_TOKEN:-}" ] && [ -n "${ROX_ADMIN_PASSWORD:-}" ]; then
  echo "note: ROX_API_TOKEN and ROX_ADMIN_PASSWORD are both set; using the" >&2
  echo "      token (roxctl accepts only one credential)." >&2
  unset ROX_ADMIN_PASSWORD
fi
if [ -n "${ROX_API_TOKEN:-}" ]; then
  AUTH_NOTE="API token"
elif [ -n "${ROX_ADMIN_PASSWORD:-}" ]; then
  AUTH_NOTE="admin password (basic auth)"
else
  echo "set a credential: ROX_API_TOKEN, or ROX_ADMIN_PASSWORD which is still" >&2
  echo "readable off the cluster when a token has been lost:" >&2
  echo "  read -rs ROX_ADMIN_PASSWORD < <(oc -n stackrox get secret central-htpasswd \\" >&2
  echo "    -o jsonpath='{.data.password}' | base64 -d); export ROX_ADMIN_PASSWORD" >&2
  exit 2
fi
for t in roxctl oc jq; do command -v "$t" >/dev/null || { echo "$t not on PATH" >&2; exit 2; }; done

OUT="results-acs"; mkdir -p "$OUT"

# Numbers here move for three different reasons -- a rebuilt image, a refreshed
# vulnerability store, a VEX reclassification -- and results-acs/ is overwritten
# every run, so a shift used to be unattributable after the fact. A published
# fix for libXtst appeared mid-measurement and was only noticed because someone
# happened to ask why a count had changed.
#
# Each run therefore keeps a normalized, diffable snapshot here and reports what
# changed since the last one. Kept outside results-acs/ so clearing scan output
# does not throw away the history.
HIST="${ACS_HISTORY:-acs-history}"
NOW="$(date -u +%Y%m%dT%H%M%SZ)"
PREV_DIR="$( { ls -1d "$HIST"/*/ 2>/dev/null || true; } | sort | tail -1)"
PREV_DIR="${PREV_DIR%/}"
mkdir -p "$HIST/$NOW"

# Scanner V4 loads its vulnerability store on first start and refuses matching
# until that finishes:
#
#   FailedPrecondition: the matcher is not initialized: initial load for the
#   vulnerability store is in progress
#
# That is a warm-up, not a fault -- the image indexes fine, only the matching
# step is unavailable. Without this wait, every image in both namespaces is
# attempted against an unready matcher and the run reports two dozen failures
# that mean nothing except "too early".
#
# Probing with a real scan is deliberate: it tests the path the scan actually
# takes, where a pod readiness check would not -- the matcher reports Ready
# while the store is still loading, which is why the error reaches the client.
wait_for_matcher() {
  local probe="$1" waited=0 step=20 out dots=0
  local limit="${ROX_MATCHER_TIMEOUT:-1800}"
  while :; do
    if out="$("${ROX[@]}" image scan --image "$probe" -o json 2>&1 >/dev/null)"; then
      [ "$dots" -eq 1 ] && echo " ready" >&2
      return 0
    fi
    case "$out" in
      *"matcher is not initialized"*|*"vulnerability store is in progress"*) ;;
      *) [ "$dots" -eq 1 ] && echo >&2
         return 0 ;;   # a different error: let the per-image loop report it
    esac
    if [ "$waited" -ge "$limit" ]; then
      [ "$dots" -eq 1 ] && echo >&2
      local pretty
      if [ "$limit" -ge 60 ]; then pretty="$((limit/60)) minutes"; else pretty="${limit}s"; fi
      echo "Scanner V4's vulnerability store is still loading after $pretty." >&2
      echo "  oc -n stackrox logs -l app=scanner-v4-matcher --tail=20" >&2
      echo >&2
      echo "On a disconnected cluster this never completes on its own: Central" >&2
      echo "cannot reach Red Hat's definitions, so they have to be uploaded" >&2
      echo "manually and egress.connectivityPolicy set to Offline. A Central" >&2
      echo "that cannot load definitions runs normally and reports nothing," >&2
      echo "which is why this waits rather than scanning into the void." >&2
      echo >&2
      echo "Raise the wait with ROX_MATCHER_TIMEOUT=<seconds>." >&2
      return 1
    fi
    if [ "$waited" -eq 0 ]; then
      printf '==> waiting for Scanner V4 to finish loading its vulnerability store' >&2
      dots=1
    fi
    printf '.' >&2
    sleep "$step"; waited=$((waited+step))
  done
}

# TLS. The operator exposes Central through a passthrough route, so Central
# presents its own self-signed certificate with SANs central.stackrox and
# central.stackrox.svc -- not the route hostname. Verification therefore fails
# on both the name and the issuer, and the earlier version of this script
# refused --insecure-skip-tls-verify while offering no way to supply a CA,
# which left no working option at all.
#
# Set ROX_CA to a CA file. Two arrangements work:
#
#   a) Central's own CA, addressing it by a name its certificate carries:
#        oc -n stackrox get secret central-tls -o jsonpath='{.data.ca\.pem}' \
#          | base64 -d > central-ca.pem
#        oc -n stackrox port-forward svc/central 8443:443 &
#        echo "127.0.0.1 central.stackrox" >> /etc/hosts
#        export ROX_CENTRAL_ADDRESS=central.stackrox:8443 ROX_CA=central-ca.pem
#
#   b) give Central a certificate valid for its route (defaultTLSSecret, see
#      README) and use the issuer of that -- for the cluster's own ingress
#      certificate, the router CA. Better for repeated use.
#
# ROX_INSECURE=1 is the escape hatch, and it is reported in the output so a
# number never silently comes from an unauthenticated server.
ROX=(roxctl -e "$ROX_CENTRAL_ADDRESS")
TLS_NOTE=""
if [ -n "${ROX_CA:-}" ]; then
  [ -f "$ROX_CA" ] || { echo "ROX_CA=$ROX_CA does not exist" >&2; exit 2; }
  ROX+=(--ca "$ROX_CA")
  TLS_NOTE="verified against \`$ROX_CA\`"
elif [ "${ROX_INSECURE:-0}" = 1 ]; then
  ROX+=(--insecure-skip-tls-verify)
  TLS_NOTE="**TLS verification disabled** (ROX_INSECURE=1)"
else
  echo "error: no CA for Central. Set ROX_CA to a CA file, or ROX_INSECURE=1 to" >&2
  echo "  skip verification deliberately. The operator's route is passthrough, so" >&2
  echo "  Central presents a certificate for central.stackrox, not the route" >&2
  echo "  hostname -- see the header of this script for the two ways to fix it." >&2
  exit 2
fi

# Central caches scan results per image NAME, tag included. Re-scanning a tag
# whose digest has moved therefore returns the result for the image that tag
# used to point at. That is how a cache rebuilt on UBI kept reporting Alpine
# package versions (zlib 1.3.2-r0) through a rollout and two re-scans, with
# every other number in the report byte-identical -- the signature of a served
# cache rather than a re-read. --force makes Central re-pull instead.
#
# A forced re-pull needs write on the Image resource (the Continuous
# Integration role has it; a read-only token does not), so a refusal falls back
# to the cached path once and says so, rather than failing every image.
FORCE=()
if [ "${ROX_FORCE:-1}" = 1 ]; then FORCE=(--force); fi
FORCE_REFUSED=0

scan_one() {
  local img="$1" out="$2" err="$3"
  "${ROX[@]}" image scan "${FORCE[@]}" --image "$img" -o json >"$out" 2>"$err" && return 0
  if [ "${#FORCE[@]}" -gt 0 ] \
     && grep -qiE 'permission|not author|forbidden|denied|\b403\b' "$err"; then
    FORCE=(); FORCE_REFUSED=1
    "${ROX[@]}" image scan --image "$img" -o json >"$out" 2>"$err" && return 0
  fi
  return 1
}

scan_ns() {
  local ns="$1" dir="$OUT/$1"
  mkdir -p "$dir"
  # Drop the previous run's files: an image removed from the namespace would
  # otherwise linger as a JSON file and keep contributing to the totals. Safe
  # to discard now that each run is snapshotted under $HIST.
  rm -f "$dir"/*.json
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

  # Scanning reads the images the pods are RUNNING, which is the right thing to
  # measure and the thing that makes a rebuild invisible until it is rolled out.
  # A rebuilt tag in the registry with an unrestarted pod means this report
  # describes the old image while the registry holds the new one -- and the
  # giveaway is subtle: a cache image that still reports Alpine package
  # versions (1.3.2-r0) after being rebuilt on UBI. Compare the digest the pod
  # is running against the digest the tag now resolves to.
  if command -v skopeo >/dev/null; then
    local stale=""
    while IFS=$'\t' read -r pimg pdig; do
      [ -n "$pimg" ] || continue
      case "$pdig" in *@sha256:*) pdig="${pdig##*@}" ;; *) continue ;; esac
      local now
      now="$(skopeo inspect --format '{{.Digest}}' "docker://$pimg" 2>/dev/null || true)"
      [ -n "$now" ] || continue
      [ "$now" = "$pdig" ] || stale="$stale ${pimg##*/}"
    done < <(oc get pods -n "$ns" -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.image}{"\t"}{.imageID}{"\n"}{end}{end}' 2>/dev/null | sort -u)
    if [ -n "$stale" ]; then
      echo "    WARNING: running a different digest than the tag now resolves to:" >&2
      echo "            $stale" >&2
      echo "            The scan reads the tag, so these numbers describe the" >&2
      echo "            NEW image in the registry -- not what the cluster runs." >&2
      echo "            Roll out before treating them as the deployed state:" >&2
      echo "              oc rollout restart deployment -n $ns" >&2
    fi
  fi

  local n=0
  while IFS= read -r img; do
    local svc="${img##*/}"; svc="${svc%%:*}"; svc="${svc%%@*}"
    printf '    %-28s' "$svc"
    if scan_one "$img" "$dir/$svc.json" "$dir/$svc.err"; then
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

# Find CVE ids by VALUE, not by key name. An earlier version selected objects
# carrying "cve"/"id" plus "severity" -- reasonable-looking shapes, and wrong:
# roxctl emits cveId and cveSeverity. It therefore counted zero for every image
# while the JSON held fourteen findings each, and the report then offered the
# documented hardened-image caveat as the explanation. A broken counter that
# produces plausible evidence for a hypothesis is worse than one that crashes.
#
# Matching the values sidesteps key names entirely: anything that looks like a
# vulnerability identifier is one, wherever it sits. The anchor matters -- the
# records also carry cveInfo URLs ending in the same id, and an unanchored test
# would count those a second time.
count_cves() {
  local f="$1"
  jq -r '[ .. | scalars | tostring
           | select(test("^(CVE-[0-9]|RHSA-[0-9]|GHSA-[0-9a-z])"; "i")) ]
         | unique | length' "$f" 2>/dev/null || echo "?"
}

# Central reports Red Hat's own severities (CRITICAL / IMPORTANT / MODERATE /
# LOW), not grype's CRITICAL/HIGH/MEDIUM/LOW, and it publishes them in a summary
# block per image. Those are the vendor's own numbers, so use them rather than
# re-deriving severities from the records -- but only when the block is there.
sev_totals() {
  jq -s -r '[ .[] | .. | objects | select(has("IMPORTANT") or has("MODERATE")) ]
            | if length == 0 then "" else
                (map(.CRITICAL // 0) | add | tostring) + "/" +
                (map(.IMPORTANT // 0) | add | tostring) + "/" +
                (map(.MODERATE // 0) | add | tostring) + "/" +
                (map(.LOW // 0) | add | tostring)
              end' "$@" 2>/dev/null || echo ""
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
  local total=0 zero=0 scanned=0 persum=0
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    local svc c; svc="$(basename "$f" .json)"; c="$(count_cves "$f")"
    printf '| %s | %s |\n' "$svc" "$c"
    scanned=$((scanned+1))
    case "$c" in
      ''|'?'|0) zero=$((zero+1)) ;;
      *) persum=$((persum+c)) ;;
    esac
  done
  if [ -f "$dir/.failed" ]; then
    while IFS= read -r svc; do printf '| %s | **scan failed** |\n' "$svc"; done < "$dir/.failed"
  fi

  local sevs=""
  if [ "$scanned" -gt 0 ]; then sevs="$(sev_totals "$dir"/*.json)"; fi
  if [ -n "$sevs" ]; then
    printf '\nSeverities as Central grades them (CRITICAL/IMPORTANT/MODERATE/LOW),\n'
    printf 'summed over images so one shared CVE counts once per image: **%s**\n' "$sevs"
  fi
  # Summing per-image counts counts a shared CVE once per image. scan-stack.sh
  # reports pairs distinct across the whole namespace, and the two reports get
  # read side by side, so compute the same thing here.
  if [ "$scanned" -gt 0 ]; then
    total="$(jq -s -r '[ .[] | .. | scalars | tostring
                         | select(test("^(CVE-[0-9]|RHSA-[0-9]|GHSA-[0-9a-z])"; "i")) ]
                       | unique | length' "$dir"/*.json 2>/dev/null || echo 0)"
  fi
  printf '\n%s scanned' "$scanned"
  [ "$zero" -gt 0 ]   && printf ', %s with no findings' "$zero"
  [ "$failed" -gt 0 ] && printf ', %s not scanned' "$failed"
  printf '\n\n**%s CVEs distinct across the namespace**, counting each CVE once.\n' "$total"
  printf '%s counting each image separately, which double counts anything shared.\n' "$persum"
  # The headline counts any identifier appearing anywhere in the JSON, which is
  # deliberate -- roxctl's key names move between versions. The snapshot counts
  # the id of each finding. An advisory URL or description naming a second CVE
  # shows up in the first and not the second, so say so rather than leave two
  # totals for the same thing standing side by side.
  if [ -f "$HIST/$NOW/cves.tsv" ] && [ "${total:-0}" != 0 ]; then
    rec="$(awk -F'\t' -v ns="$ns" '$1 == ns { c[$3] = 1 }
                                    END { n = 0; for (k in c) n++; print n }' \
           "$HIST/$NOW/cves.tsv" 2>/dev/null || echo "")"
    if [ -n "$rec" ] && [ "$rec" != "$total" ]; then
      printf '\n%s of those are identifiers found in record text (an advisory URL\n' \
        "$((total - rec))"
      printf 'or description naming another CVE) rather than the id of a finding.\n'
      printf 'The change report below counts the %s findings, which is why the two\n' "$rec"
      printf 'numbers differ.\n'
    fi
  fi
  printf '\nNote the unit: this counts distinct CVE **ids**, while scan-stack.sh\n'
  printf 'counts distinct CVE/**package pairs** -- one CVE affecting three packages\n'
  printf 'is 1 here and 3 there. The two totals are not interchangeable, and\n'
  printf 'neither are ratios derived from them.\n'

  # Who has to fix it. Two signals in each record, and together they turn a
  # count into a work list:
  #
  #   cveInfo -> access.redhat.com  the OS layer, Red Hat's advisory data
  #   cveInfo -> osv.dev / github   an application dependency, ecosystem data
  #   componentFixedVersion set     a fix exists; empty means none published
  #
  # expat 2.8.5-1.2.hum1 with an access.redhat.com link and no fixed version is
  # Red Hat's to ship and nothing a rebuild reaches. pyasn1 0.5.0 with a PYSEC
  # link and fixedVersion 0.6.4 is a line in requirements.txt. Those are
  # different jobs for different people, and the severity table cannot tell
  # them apart.
  if [ "$scanned" -gt 0 ]; then
    local split
    # Host lists come from observed output rather than guesswork: a real run
    # produced access.redhat.com, osv.dev, go.dev, nvd.nist.gov and
    # security.alpinelinux.org. go.dev is the Go module advisory database, so
    # an application dependency. The Alpine tracker is an OS source, which is
    # how a redis:alpine image inside the UBI stack shows up. nvd.nist.gov
    # covers every ecosystem, so it stays unattributed rather than guessed.
    split="$(jq -s -r '
      [ .[] | .. | objects | select(has("cveId") and has("componentName")) ] as $v
      | "redhat\\.com|security\\.alpinelinux\\.org|security-tracker\\.debian\\.org|ubuntu\\.com" as $osre
      | "osv\\.dev|github\\.com|go\\.dev|pypi\\.org|npmjs\\.com" as $appre
      | ($v | map(select((.cveInfo // "") | test($osre))))  as $os
      | ($v | map(select((.cveInfo // "") | test($appre)))) as $app
      | ($v | map(select((.cveInfo // "")
                 | (test($osre) or test($appre)) | not))) as $other
      | "os_total=\($os | map(.cveId) | unique | length) " +
        "os_fixable=\($os | map(select((.componentFixedVersion // "") != "")) | map(.cveId) | unique | length) " +
        "app_total=\($app | map(.cveId) | unique | length) " +
        "app_fixable=\($app | map(select((.componentFixedVersion // "") != "")) | map(.cveId) | unique | length) " +
        "other_total=\($other | map(.cveId) | unique | length) " +
        "other_fixable=\($other | map(select((.componentFixedVersion // "") != "")) | map(.cveId) | unique | length) " +
        "other_srcs=\($other | map((.cveInfo // "none") | sub("^https?://";"") | split("/")[0])
                        | unique | join(",") | if . == "" then "none" else . end)"
      ' "$dir"/*.json 2>/dev/null || true)"
    if [ -n "$split" ]; then
      eval "$split"
      printf '\n| layer | distinct CVEs | with a fix published | whose |\n'
      printf '|---|---|---|---|\n'
      printf '| OS packages (distro advisories) | %s | %s | the distro, once the base image ships it |\n' \
        "${os_total:-0}" "${os_fixable:-0}"
      printf '| application dependencies (OSV/GHSA/go.dev) | %s | %s | yours, in the dependency manifest |\n' \
        "${app_total:-0}" "${app_fixable:-0}"
      # Without this the rows above do not sum to the namespace total, and a
      # table that does not add up casts doubt on the parts that are right.
      # Naming the advisory hosts makes the remainder diagnosable.
      if [ "${other_total:-0}" -gt 0 ]; then
        printf '| other advisory sources | %s | %s | from: %s |\n' \
          "$other_total" "${other_fixable:-0}" "${other_srcs:-unknown}"
      fi
      printf '\nA published fix is the vendor advisory, not a fix you can obtain. An\n'
      printf 'OS-package fix reaches you only once the base image ships it, which\n'
      printf 'can lag the advisory -- check with check-bases.sh before promising a\n'
      printf 'rebuild clears one. An application fix is actionable immediately.\n'
      printf 'A row without a fix is a\n'
      printf 'number to report: nothing downstream of the vendor clears it.\n'
      printf 'Rows can over-sum against the namespace total: one CVE can affect\n'
      printf 'both an OS package and an application one, and counts in both layers\n'
      printf 'because it is two pieces of work.\n'
    fi
  fi

  # The hardened-image caveat explains a SUCCESSFUL scan that found nothing. It
  # does not explain a scan that never ran, and offering it there sends the
  # reader to the wrong document.
  # TOTAL-COMPONENTS 0 means Central catalogued nothing in the image -- it
  # could not read it, which is a different statement from finding nothing
  # wrong. A self-contained .NET publish on a distroless base has no package
  # metadata ACS recognises, and reporting that as 0 findings alongside images
  # reporting hundreds is the exact confusion this report exists to prevent.
  local unread=""
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    if [ "$(jq -r '[ .. | objects | select(has("TOTAL-COMPONENTS"))
                     | .["TOTAL-COMPONENTS"] ] | add // 1' "$f" 2>/dev/null)" = "0" ]; then
      unread="$unread $(basename "$f" .json)"
    fi
  done
  if [ -n "$unread" ]; then
    printf '\n**No components catalogued in:**%s\n' "$unread"
    printf 'Central read no packages at all in those, so their zero is "could not\n'
    printf 'read" rather than "nothing found" -- they contribute nothing to the\n'
    printf 'totals above and must not be counted as clean. A self-contained binary\n'
    printf 'on a distroless base is the usual cause: no rpm database, no language\n'
    printf 'manifest, nothing to enumerate.\n'
  fi

  if [ "$zero" -gt 0 ]; then
    printf '\n%s image(s) returned no findings. Not proof of clean -- check one:\n' "$zero"
    printf '    jq "." %s/<image>.json | head -40\n' "$dir"
    # Only raise the known issue when the whole namespace came back empty.
    # Firing it for one image while eleven others report hundreds points the
    # reader at a product gap that demonstrably is not happening.
    if [ "$zero" -eq "$scanned" ] && [ "$scanned" -gt 1 ]; then
      printf '\nEVERY image returned nothing while scanning successfully, which is\n'
      printf 'the pattern the RHACS 4.11 known issue describes for Red Hat hardened\n'
      printf 'images (Project Hummingbird) -- see README.md. Compare the other\n'
      printf 'namespace before concluding anything.\n'
    fi
  fi
}

# One probe before either namespace, using an image that is actually deployed.
FIRST_IMG="$(oc get pods -n "$NS_A" -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)"
if [ -n "$FIRST_IMG" ]; then
  # Say this BEFORE the call. The probe is a real server-side scan and can take
  # several minutes on a first index, during which an earlier version printed
  # nothing at all -- indistinguishable from a hang. Interrupting it there is
  # what puts "matcher error: ... context canceled" in the matcher's log: the
  # client left, so the server abandoned the query. It is a symptom of the
  # Ctrl-C, not a fault to chase.
  echo "==> checking Central is ready to match (a first scan can take several" >&2
  echo "    minutes server-side; no output until it answers)" >&2
  wait_for_matcher "$FIRST_IMG" || exit 1
fi

# One row per namespace/image/CVE/component, tolerant about key names for the
# same reason the counter is: roxctl's layout differs across versions.
snapshot_tsv() {
  local ns f svc
  for ns in "$NS_A" ${NS_B:+"$NS_B"}; do
    [ -d "$OUT/$ns" ] || continue
    for f in "$OUT/$ns"/*.json; do
      [ -e "$f" ] || continue
      svc="$(basename "$f" .json)"
      jq -r --arg ns "$ns" --arg img "$svc" '
        [ .. | objects
          | (.cveId // .cve // .id // .name // empty) as $c
          | select(($c | type) == "string"
                   and ($c | test("^(CVE-[0-9]|RHSA-[0-9]|GHSA-[0-9a-z])"; "i")))
          | [ $ns, $img, $c,
              ((.cveSeverity // .severity // "") | tostring),
              ((.componentName // .name // "") | tostring),
              ((.componentVersion // .version // "") | tostring),
              (.componentFixedVersion // .fixedBy // null
                 | if . == null or . == "" then "-" else tostring end) ]
        ] | unique[] | @tsv' "$f" 2>/dev/null
    done
  done | sort -u
}

diff_section() {
  local prev="$1" prev_ts="$2" cur="$3"
  printf '\n## Changes since %s\n' "$prev_ts"
  awk -F'\t' -v cap="${ACS_DIFF_CAP:-15}" -v nslist="$NS_A,${NS_B:-}" '
    function emit(title, body,   n, lines, i, j) {
      if (body == "") { printf "%s: none\n\n", title; return }
      n = split(body, lines, "\n"); i = 0
      printf "%s:\n\n```\n", title
      for (j = 1; j <= n; j++) {
        if (lines[j] == "") continue
        if (++i <= cap) print lines[j]
      }
      if (i > cap) printf "  ... and %d more\n", i - cap
      printf "```\n\n"
    }
    NR == FNR {
      k = $1 "\t" $3 "\t" $5
      p[k] = $7; pl[++pi] = k; pcomp[k] = $6
      pc[$1 SUBSEP $3] = 1
      next
    }
    {
      k = $1 "\t" $3 "\t" $5
      c[k] = $7
      cc[$1 SUBSEP $3] = 1
      if (!(k in p))
        add[$1] = add[$1] sprintf("  + %-16s %s %s%s\n", $3, $5, $6,
                                  ($7 == "-" ? "" : "   fix " $7))
      else if (p[k] == "-" && $7 != "-")
        nf[$1] = nf[$1] sprintf("  * %-16s %s %s   fix now published: %s\n",
                                $3, $5, $6, $7)
      else if (p[k] != "-" && $7 == "-")
        lf[$1] = lf[$1] sprintf("  ! %-16s %s   fix %s no longer offered\n",
                                $3, $5, p[k])
    }
    END {
      for (i = 1; i <= pi; i++) {
        k = pl[i]
        if (k in c || k in seen) continue
        seen[k] = 1; split(k, a, "\t")
        rem[a[1]] = rem[a[1]] sprintf("  - %-16s %s %s\n", a[2], a[3], pcomp[k])
      }
      for (x in pc) { split(x, a, SUBSEP); pn[a[1]]++ }
      for (x in cc) { split(x, a, SUBSEP); cn[a[1]]++ }
      n = split(nslist, ns, ",")
      for (i = 1; i <= n; i++) {
        s = ns[i]; if (s == "") continue
        printf "\n### %s\n\n", s
        printf "distinct CVE ids: **%d -> %d**\n\n", pn[s] + 0, cn[s] + 0
        emit("gone", rem[s])
        emit("new", add[s])
        emit("fix became available", nf[s])
        emit("fix withdrawn", lf[s])
      }
      print "A CVE can leave without being fixed: a VEX statement reclassifying"
      print "a package as not affected removes it, and so does a rebuild that"
      print "drops the package. Compare against check-bases.sh before reading a"
      print "change as patching."
    }
  ' "$prev" "$cur"
}

scan_ns "$NS_A" || true
[ -n "$NS_B" ] && { scan_ns "$NS_B" || true; }

snapshot_tsv > "$HIST/$NOW/cves.tsv"

{
  echo "# RHACS scan — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "Central: \`$ROX_CENTRAL_ADDRESS\` — $TLS_NOTE, $AUTH_NOTE"
  echo
  if [ "${#FORCE[@]}" -gt 0 ]; then
    echo "Scanned with \`--force\`: Central re-pulled each image rather than"
    echo "serving a cached result for the tag."
  elif [ "$FORCE_REFUSED" = 1 ]; then
    echo "**\`--force\` was refused** (needs write on the Image resource), so these"
    echo "may be Central's cached scans — for a rebuilt tag, that means the image"
    echo "it used to point at. Use a token with the Continuous Integration role."
  else
    echo "**\`ROX_FORCE=0\`**: these may be Central's cached scans — for a rebuilt"
    echo "tag, that means the image it used to point at."
  fi
  report "$NS_A"
  [ -n "$NS_B" ] && report "$NS_B"
  if [ -n "$PREV_DIR" ] && [ -f "$PREV_DIR/cves.tsv" ]; then
    diff_section "$PREV_DIR/cves.tsv" "$(basename "$PREV_DIR")" "$HIST/$NOW/cves.tsv"
  else
    printf '\n## Changes since last run\n\n'
    printf 'No previous snapshot. This run is the baseline; the next one will\n'
    printf 'report what moved and why it is attributable.\n'
  fi
} | tee "$OUT/report.md"
cp "$OUT/report.md" "$HIST/$NOW/report.md"

# Keep the history bounded; a snapshot is two small text files.
KEEP="${ACS_HISTORY_KEEP:-20}"
{ ls -1d "$HIST"/*/ 2>/dev/null || true; } | sort | head -n "-$KEEP" \
  | while read -r d; do
  rm -rf "$d"
done
echo
echo "raw JSON kept under $OUT/ -- no re-scan needed to ask a follow-up question"
