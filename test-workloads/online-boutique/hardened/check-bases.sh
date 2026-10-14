#!/usr/bin/env bash
#
# Which services are stale because their base image moved?
#
#   export REGISTRY=registry.example.com:8443
#   ./check-bases.sh
#
# Takes $REGISTRY/$NAMESPACE and $VERSION from the environment (see
# registry.env); a <registry>/<namespace> [version] argument pair overrides.
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
#   ./check-bases.sh || BASE=hardened ./build-push.sh --only <the services it named>
#
# Requires skopeo and jq. BASE must match the set the images were built with;
# it is also read back from each image's label and mismatches are reported.

set -uo pipefail

BASE="${BASE:-hardened}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=registry.env
. "$HERE/registry.env"
ARGS_GIVEN=0
[ $# -gt 0 ] && { DEST="$1"; ARGS_GIVEN=1; }   # positional still wins
[ $# -gt 1 ] && VERSION="$2"
require_registry "$0" || exit 1
# shellcheck source=bases.env
. "$HERE/bases.env"

for t in skopeo jq; do
  command -v "$t" >/dev/null || { echo "error: $t not on PATH" >&2; exit 2; }
done

SERVICES="frontend productcatalogservice checkoutservice shippingservice
currencyservice paymentservice emailservice recommendationservice loadgenerator
adservice cartservice"
if [ "${CACHE_BUILD:-0}" = 1 ]; then
  SERVICES="$SERVICES cache"
fi

FLOAT="${VERSION}${TAG_SUFFIX}"

# Resolve each distinct base tag once rather than per service.
declare -A LIVE
resolve() {
  local img="$1"
  [ -n "${LIVE[$img]:-}" ] && return 0
  LIVE[$img]=$(skopeo inspect --format '{{.Digest}}' "docker://$img" 2>/dev/null || echo unreachable)
}
BASE_VARS="GO_BUILDER GO_RUNTIME NODE_BUILDER NODE_RUNTIME PY_BUILDER PY_RUNTIME
JAVA_BUILDER JAVA_RUNTIME DOTNET_SDK DOTNET_RUNTIME"
# Only defined in the base set that builds the cache image.
if [ "${CACHE_BUILD:-0}" = 1 ]; then
  BASE_VARS="$BASE_VARS VALKEY_BUILDER VALKEY_RUNTIME"
fi
for v in $BASE_VARS; do
  resolve "${!v}"
done

# Both an image ref and a digest contain a colon, so these stay as three
# separate arguments -- packing them into one delimited string does not survive.
compare() {
  local role="$1" name="$2" recorded="$3"
  [ -n "$name" ] || return 0
  resolve "$name"
  local live="${LIVE[$name]}"
  case "$recorded" in
    # build-push.sh stamps this when it could not prove which base content the
    # build actually used (ALLOW_STALE_BASE=1, or PULL=never). Reporting it as
    # stale is deliberate: an unprovable base must not read as current.
    unverified|unknown)
      printf ' %s=%s' "$role" "$recorded"; return 0 ;;
  esac
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

if [ "${CACHE_BUILD:-0}" != 1 ]; then
  printf '%-24s %-10s %s\n' cache MIRRORED \
    "copied from ${CACHE_IMAGE:-upstream} -- not built here, no base to track"
fi

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
  PFX=""
  if [ "${CACHE_BUILD:-0}" = 1 ]; then PFX="CACHE_BUILD=1 "; fi
  if [ "$ARGS_GIVEN" -eq 1 ]; then
    echo "  ${PFX}BASE=$BASE ./build-push.sh $DEST $VERSION --only $(echo $STALE | tr ' ' ',')"
  else
    # REGISTRY is already exported in this shell, so the short form is enough.
    echo "  ${PFX}BASE=$BASE ./build-push.sh --only $(echo $STALE | tr ' ' ',')"
  fi
  exit 1
fi
echo "All built services are on the current base images."
exit 0
