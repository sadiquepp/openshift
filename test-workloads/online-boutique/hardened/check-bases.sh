#!/usr/bin/env bash
#
# Which services are stale because their base image moved?
#
#   ./check-bases.sh registry.example.com:8443/online-boutique
#   ./check-bases.sh registry.example.com:8443/online-boutique v0.10.6
#
# When Red Hat ships a CVE fix, the fixed base image is pushed under the same
# tag with a new digest. An image you built last week still contains the old
# one. build-push.sh stamps the builder and runtime digests onto every image it
# builds, so this compares what each image was built FROM against what that tag
# resolves to now, and names the services whose rebuild is overdue.
#
# Reads the registry only -- no cluster, no local images, nothing pulled beyond
# manifests. Exits 1 if anything is stale, so it works as a cron or CI gate.
#
#   ./check-bases.sh <dest> || BASE=hardened ./build-push.sh <dest> --only "$(...)"
#
# Requires skopeo and jq. BASE must match the set the images were built with;
# it is also read back from each image's label and mismatches are reported.

set -uo pipefail

DEST="${1:?usage: $0 <registry>/<namespace> [upstream-version]}"
VERSION="${2:-v0.10.6}"
BASE="${BASE:-hardened}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bases.env
. "$HERE/bases.env"

for t in skopeo jq; do
  command -v "$t" >/dev/null || { echo "error: $t not on PATH" >&2; exit 2; }
done

SERVICES="frontend productcatalogservice checkoutservice shippingservice
currencyservice paymentservice emailservice recommendationservice loadgenerator
adservice cartservice"

FLOAT="${VERSION}${TAG_SUFFIX}"

# Resolve each distinct base tag once rather than per service.
declare -A LIVE
resolve() {
  local img="$1"
  [ -n "${LIVE[$img]:-}" ] && return 0
  LIVE[$img]=$(skopeo inspect --format '{{.Digest}}' "docker://$img" 2>/dev/null || echo unreachable)
}
for v in GO_BUILDER GO_RUNTIME NODE_BUILDER NODE_RUNTIME PY_BUILDER PY_RUNTIME \
         JAVA_BUILDER JAVA_RUNTIME DOTNET_SDK DOTNET_RUNTIME; do
  resolve "${!v}"
done

# Both an image ref and a digest contain a colon, so these stay as three
# separate arguments -- packing them into one delimited string does not survive.
compare() {
  local role="$1" name="$2" recorded="$3"
  [ -n "$name" ] || return 0
  resolve "$name"
  local live="${LIVE[$name]}"
  case "$live" in
    unreachable)  printf ' %s=unreachable' "$role" ;;
    "$recorded")  ;;
    *)            printf ' %s moved' "$role" ;;
  esac
}

STALE=""
UNKNOWN=""
printf '%-24s %-10s %s\n' SERVICE STATUS DETAIL
printf '%-24s %-10s %s\n' ------- ------ ------

for svc in $SERVICES; do
  cfg=$(skopeo inspect --format '{{json .Labels}}' "docker://$DEST/$svc:$FLOAT" 2>/dev/null)
  if [ -z "$cfg" ] || [ "$cfg" = "null" ]; then
    printf '%-24s %-10s %s\n' "$svc" "ABSENT" "not in $DEST at :$FLOAT -- never built?"
    UNKNOWN="$UNKNOWN $svc"
    continue
  fi

  built_rt_name=$(echo "$cfg" | jq -r '."org.opencontainers.image.base.name" // empty')
  built_rt_dig=$(echo  "$cfg" | jq -r '."org.opencontainers.image.base.digest" // empty')
  built_bd_name=$(echo "$cfg" | jq -r '."online-boutique.build.builder-base.name" // empty')
  built_bd_dig=$(echo  "$cfg" | jq -r '."online-boutique.build.builder-base.digest" // empty')
  built_set=$(echo     "$cfg" | jq -r '."online-boutique.build.base-set" // empty')
  built_rev=$(echo     "$cfg" | jq -r '."org.opencontainers.image.revision" // empty')

  if [ -z "$built_rt_dig" ]; then
    printf '%-24s %-10s %s\n' "$svc" "NO LABEL" "built before digest stamping -- rebuild to start tracking"
    UNKNOWN="$UNKNOWN $svc"
    continue
  fi
  if [ -n "$built_set" ] && [ "$built_set" != "$BASE" ]; then
    printf '%-24s %-10s %s\n' "$svc" "OTHER SET" "built with BASE=$built_set, checking against BASE=$BASE"
    continue
  fi

  reasons="$(compare runtime "$built_rt_name" "$built_rt_dig")"
  reasons="$reasons$(compare builder "$built_bd_name" "$built_bd_dig")"

  if [ -n "$reasons" ]; then
    printf '%-24s %-10s %s\n' "$svc" "STALE" "build $built_rev:$reasons"
    STALE="$STALE $svc"
  else
    printf '%-24s %-10s %s\n' "$svc" "current" "build $built_rev"
  fi
done

echo
if [ -n "$UNKNOWN" ]; then
  echo "Not tracked:$UNKNOWN"
fi
if [ -n "$STALE" ]; then
  echo "Stale:$STALE"
  echo
  echo "Rebuild just those:"
  echo "  BASE=$BASE ./build-push.sh $DEST $VERSION --only $(echo $STALE | tr ' ' ',')"
  exit 1
fi
echo "All built services are on the current base images."
exit 0
