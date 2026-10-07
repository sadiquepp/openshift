#!/usr/bin/env bash
#
# Rebuild Online Boutique service images on Red Hat Hardened Images (or UBI) and
# push them to a local registry.
#
# Red Hat Hardened Images are BASE images, not application images -- there is no
# hardened "online boutique" to repoint at. Google publishes the 11 service
# images prebuilt from Alpine, distroless and Ubuntu-chiseled bases, so putting
# this workload on hardened images means rebuilding each service from upstream
# source. That is what this script does.
#
#   ./build-push.sh registry.example.com:8443/online-boutique
#   ./build-push.sh registry.example.com:8443/online-boutique v0.10.6
#   ./build-push.sh registry.example.com:8443/online-boutique --only emailservice
#   SERVICES="emailservice adservice" ./build-push.sh registry.example.com:8443/ob
#
# This is NOT a one-time bootstrap. The reason to take on the rebuild is that
# patching stops being somebody else's release cadence -- which only pays off if
# you can rerun it. --only rebuilds one service when its base image moves;
# check-bases.sh tells you which ones those are.
#
# BASE selects the base-image set from bases.env:
#
#   BASE=hardened ./build-push.sh ...   Red Hat Hardened Images (the default)
#   BASE=ubi      ./build-push.sh ...   UBI 9, pushed with a -ubi tag suffix
#
# Build both and you have two complete stacks in one registry to compare --
# see cve-demo/ for the per-image CVE diff and scan-stack.sh for the whole-stack
# one. The Containerfiles are shared: only the base images differ.
#
# Every image is pushed under TWO tags:
#
#   <version>-<build-id><suffix>   immutable; what you deploy
#   <version><suffix>              floating convenience pointer
#
# Deploy the immutable one. The app version alone cannot identify a rebuild --
# a CVE fix in the base image changes the image without changing the app -- and
# these manifests set no imagePullPolicy, so a moved tag may never be re-pulled
# on a node that has it cached.
#
# Requires: podman (or docker, see ENGINE), skopeo, git, network access to
# GitHub, to the base-image registry, and to whatever each language's package
# manager pulls from. Log in to the destination first: podman login <registry>.

set -euo pipefail

DEST=""
VERSION=""
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="${2:?--only needs a comma- or space-separated service list}"; shift 2 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) if [ -z "$DEST" ]; then DEST="$1"; elif [ -z "$VERSION" ]; then VERSION="$1"; fi; shift ;;
  esac
done
: "${DEST:?usage: $0 <registry>/<namespace> [upstream-version] [--only svc,svc]}"
VERSION="${VERSION:-v0.10.6}"

ENGINE="${ENGINE:-podman}"
BASE="${BASE:-hardened}"
BUILD_ID="${BUILD_ID:-b$(date -u +%Y%m%d)}"
WORKDIR="${WORKDIR:-$(mktemp -d)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Every base image comes from here, and every one is overridable from the
# environment. Confirm what the catalogs actually ship -- https://images.redhat.com
# for hardened, catalog.redhat.com for UBI -- before the first run, or just run
# ./preflight.sh.
# shellcheck source=bases.env
. "$HERE/bases.env"

ALL_SERVICES="frontend productcatalogservice checkoutservice shippingservice
currencyservice paymentservice emailservice recommendationservice loadgenerator
adservice cartservice cache"

SERVICES="${SERVICES:-}"
[ -n "$ONLY" ] && SERVICES="${ONLY//,/ }"
SERVICES="${SERVICES:-$ALL_SERVICES}"

# service -> Containerfile, build context, base images, extra build args.
# A table rather than a straight-line script, so one service can be rebuilt on
# its own without rebuilding the other ten.
recipe() {
  CF=""; CTX=""; BUILDER_IMG=""; RUNTIME_IMG=""; ARGS=()
  case "$1" in
    frontend|productcatalogservice|checkoutservice|shippingservice)
      CF=Containerfile.go;   CTX="src/$1"
      BUILDER_IMG="$GO_BUILDER";     RUNTIME_IMG="$GO_RUNTIME" ;;
    currencyservice)
      CF=Containerfile.node; CTX="src/$1"
      BUILDER_IMG="$NODE_BUILDER";   RUNTIME_IMG="$NODE_RUNTIME"
      ARGS=(--build-arg "ENTRY=server.js") ;;
    paymentservice)
      CF=Containerfile.node; CTX="src/$1"
      BUILDER_IMG="$NODE_BUILDER";   RUNTIME_IMG="$NODE_RUNTIME"
      ARGS=(--build-arg "ENTRY=index.js") ;;
    emailservice)
      CF=Containerfile.python; CTX="src/$1"
      BUILDER_IMG="$PY_BUILDER";     RUNTIME_IMG="$PY_RUNTIME"
      ARGS=(--build-arg "ENTRY=email_server.py") ;;
    recommendationservice)
      CF=Containerfile.python; CTX="src/$1"
      BUILDER_IMG="$PY_BUILDER";     RUNTIME_IMG="$PY_RUNTIME"
      ARGS=(--build-arg "ENTRY=recommendation_server.py") ;;
    loadgenerator)
      CF=Containerfile.loadgenerator; CTX="src/$1"
      BUILDER_IMG="$PY_BUILDER";     RUNTIME_IMG="$PY_RUNTIME" ;;
    adservice)
      CF=Containerfile.java; CTX="src/$1"
      BUILDER_IMG="$JAVA_BUILDER";   RUNTIME_IMG="$JAVA_RUNTIME" ;;
    cartservice)
      CF=Containerfile.dotnet; CTX="src/cartservice/src"
      BUILDER_IMG="$DOTNET_SDK";     RUNTIME_IMG="$DOTNET_RUNTIME" ;;
    cache)
      CF="";  CTX="" ;;   # mirrored, not built
    *)
      echo "error: unknown service '$1'" >&2
      echo "       known: $(echo $ALL_SERVICES)" >&2
      exit 2 ;;
  esac
}

for s in $SERVICES; do recipe "$s"; done   # validate the list before any work

digest_of() { skopeo inspect --format '{{.Digest}}' "docker://$1" 2>/dev/null || echo unknown; }

NEED_SRC=0
for s in $SERVICES; do [ "$s" = cache ] || NEED_SRC=1; done
SRC="$WORKDIR/microservices-demo"
if [ "$NEED_SRC" -eq 1 ] && [ ! -d "$SRC" ]; then
  echo "==> cloning upstream $VERSION into $SRC"
  git clone --depth 1 --branch "$VERSION" \
    https://github.com/GoogleCloudPlatform/microservices-demo.git "$SRC"
fi

TAG="${VERSION}-${BUILD_ID}${TAG_SUFFIX}"
FLOAT="${VERSION}${TAG_SUFFIX}"

build_one() {
  local service="$1"
  recipe "$service"
  local image="$DEST/$service:$TAG"

  # Record which base images went in, as labels on the image itself. State in a
  # registry outlives any laptop, and check-bases.sh reads it back to work out
  # what a new base image release makes stale. The two OCI annotations are the
  # standard ones for a base image; the builder has no standard annotation.
  local bdig rdig
  bdig=$(digest_of "$BUILDER_IMG")
  rdig=$(digest_of "$RUNTIME_IMG")

  echo "==> building $image"
  echo "    builder $BUILDER_IMG@$bdig"
  echo "    runtime $RUNTIME_IMG@$rdig"
  "$ENGINE" build \
    --file "$HERE/$CF" \
    --tag "$image" \
    --build-arg "BUILDER=$BUILDER_IMG" \
    --build-arg "RUNTIME=$RUNTIME_IMG" \
    --label "org.opencontainers.image.base.name=$RUNTIME_IMG" \
    --label "org.opencontainers.image.base.digest=$rdig" \
    --label "org.opencontainers.image.version=$VERSION" \
    --label "org.opencontainers.image.revision=$BUILD_ID" \
    --label "online-boutique.build.builder-base.name=$BUILDER_IMG" \
    --label "online-boutique.build.builder-base.digest=$bdig" \
    --label "online-boutique.build.base-set=$BASE" \
    "${ARGS[@]}" \
    "$SRC/$CTX"

  "$ENGINE" tag "$image" "$DEST/$service:$FLOAT"
  echo "==> pushing $TAG and $FLOAT"
  "$ENGINE" push "$image"
  "$ENGINE" push "$DEST/$service:$FLOAT"
  printf '    %s@%s\n' "$DEST/$service" "$(digest_of "$image")"
}

for service in $SERVICES; do
  if [ "$service" = cache ]; then
    # redis-cart runs a stock image -- no build, just a copy into the registry.
    echo "==> copying $CACHE_IMAGE -> $DEST/cache:$TAG"
    skopeo copy "docker://$CACHE_IMAGE" "docker://$DEST/cache:$TAG"
    skopeo copy "docker://$CACHE_IMAGE" "docker://$DEST/cache:$FLOAT"
  else
    build_one "$service"
  fi
done

echo
echo "Built on BASE=$BASE and pushed under $DEST:"
echo "  immutable  $TAG   <- deploy this"
echo "  floating   $FLOAT"
echo
case "$BASE" in
  hardened) OVERLAY=overlays/hardened ;;
  ubi)      OVERLAY=overlays/ubi ;;
esac
# `kustomize edit set image` keys on the ORIGINAL image name -- the one the
# vendored manifests reference -- not on the rewritten one. Keying on the new
# name silently appends a second entry that matches nothing.
UPSTREAM=us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo
echo "To roll it out, point the overlay at the immutable tag and apply:"
echo "  cd ../$OVERLAY && kustomize edit set image \\"
for service in $SERVICES; do
  if [ "$service" = cache ]; then
    echo "      redis=$DEST/cache:$TAG \\"
  else
    echo "      $UPSTREAM/$service=$DEST/$service:$TAG \\"
  fi
done
echo "   && oc apply -k ."
