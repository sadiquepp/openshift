#!/usr/bin/env bash
#
# Rebuild all 11 Online Boutique service images on Red Hat Hardened Images and
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
# Requires: podman (or docker, see ENGINE), git, network access to GitHub, to
# registry.access.redhat.com, and to whatever each language's package manager
# pulls from (proxy.golang.org, registry.npmjs.org, pypi.org, nuget.org, Maven
# Central). Log in to the destination first: podman login <registry>.
#
# The two images that are NOT built here:
#   redis:alpine  -> mirror registry.access.redhat.com/hi/valkey instead
#   busybox       -> dropped; see ../overlays/hardened/kustomization.yaml
# Both are handled in the overlay.

set -euo pipefail

DEST="${1:?usage: $0 <registry>/<namespace> [upstream-version]}"
VERSION="${2:-v0.10.6}"
ENGINE="${ENGINE:-podman}"
BASE="${BASE:-hardened}"
WORKDIR="${WORKDIR:-$(mktemp -d)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Every base image comes from here, and every one is overridable from the
# environment. Confirm what the catalogs actually ship -- https://images.redhat.com
# for hardened, catalog.redhat.com for UBI -- before the first run.
# shellcheck source=bases.env
. "$HERE/bases.env"

SRC="$WORKDIR/microservices-demo"
if [ ! -d "$SRC" ]; then
  echo "==> cloning upstream $VERSION into $SRC"
  git clone --depth 1 --branch "$VERSION" \
    https://github.com/GoogleCloudPlatform/microservices-demo.git "$SRC"
fi

build() {
  local service="$1" containerfile="$2" context="$3"; shift 3
  local image="$DEST/$service:${VERSION}${TAG_SUFFIX}"
  echo "==> building $image"
  "$ENGINE" build \
    --file "$HERE/$containerfile" \
    --tag "$image" \
    "$@" \
    "$SRC/$context"
  echo "==> pushing $image"
  "$ENGINE" push "$image"
}

for service in frontend productcatalogservice checkoutservice shippingservice; do
  build "$service" Containerfile.go "src/$service" \
    --build-arg "BUILDER=$GO_BUILDER" \
    --build-arg "RUNTIME=$GO_RUNTIME"
done

build currencyservice Containerfile.node src/currencyservice \
  --build-arg "BUILDER=$NODE_BUILDER" \
  --build-arg "RUNTIME=$NODE_RUNTIME" \
  --build-arg "ENTRY=server.js"

build paymentservice Containerfile.node src/paymentservice \
  --build-arg "BUILDER=$NODE_BUILDER" \
  --build-arg "RUNTIME=$NODE_RUNTIME" \
  --build-arg "ENTRY=index.js"

build emailservice Containerfile.python src/emailservice \
  --build-arg "BUILDER=$PY_BUILDER" \
  --build-arg "RUNTIME=$PY_RUNTIME" \
  --build-arg "ENTRY=email_server.py"

build recommendationservice Containerfile.python src/recommendationservice \
  --build-arg "BUILDER=$PY_BUILDER" \
  --build-arg "RUNTIME=$PY_RUNTIME" \
  --build-arg "ENTRY=recommendation_server.py"

build loadgenerator Containerfile.loadgenerator src/loadgenerator \
  --build-arg "BUILDER=$PY_BUILDER" \
  --build-arg "RUNTIME=$PY_RUNTIME"

build adservice Containerfile.java src/adservice \
  --build-arg "BUILDER=$JAVA_BUILDER" \
  --build-arg "RUNTIME=$JAVA_RUNTIME"

build cartservice Containerfile.dotnet src/cartservice/src \
  --build-arg "SDK=$DOTNET_SDK" \
  --build-arg "RUNTIME=$DOTNET_RUNTIME"

# redis-cart runs a stock image -- no build, just a copy into the local registry.
echo "==> copying $CACHE_IMAGE -> $DEST/cache:${VERSION}${TAG_SUFFIX}"
skopeo copy "docker://$CACHE_IMAGE" "docker://$DEST/cache:${VERSION}${TAG_SUFFIX}"

echo
echo "All 11 service images built on BASE=$BASE and pushed under $DEST,"
echo "plus the cache image, tagged ${VERSION}${TAG_SUFFIX}."
case "$BASE" in
  hardened) echo "Set the registry in ../overlays/hardened/kustomization.yaml and apply it." ;;
  ubi)      echo "Set the registry in ../overlays/ubi/kustomization.yaml and apply it." ;;
esac
