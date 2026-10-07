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
HI="${HI_REGISTRY:-registry.access.redhat.com/hi}"
WORKDIR="${WORKDIR:-$(mktemp -d)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Tags are deliberately variables: confirm what the catalog actually ships at
# https://images.redhat.com before the first run and override as needed.
GO_BUILDER="${GO_BUILDER:-$HI/go:latest-builder}"
GO_RUNTIME="${GO_RUNTIME:-$HI/go:latest}"
NODE_BUILDER="${NODE_BUILDER:-$HI/nodejs:latest-builder}"
NODE_RUNTIME="${NODE_RUNTIME:-$HI/nodejs:latest}"
PY_BUILDER="${PY_BUILDER:-$HI/python:3.14-builder}"
PY_RUNTIME="${PY_RUNTIME:-$HI/python:3.14}"
JAVA_BUILDER="${JAVA_BUILDER:-$HI/openjdk:25-builder}"
JAVA_RUNTIME="${JAVA_RUNTIME:-$HI/openjdk:25}"
DOTNET_SDK="${DOTNET_SDK:-$HI/dotnet-sdk:10.0}"
DOTNET_RUNTIME="${DOTNET_RUNTIME:-$HI/dotnet-runtime:10.0}"

SRC="$WORKDIR/microservices-demo"
if [ ! -d "$SRC" ]; then
  echo "==> cloning upstream $VERSION into $SRC"
  git clone --depth 1 --branch "$VERSION" \
    https://github.com/GoogleCloudPlatform/microservices-demo.git "$SRC"
fi

build() {
  local service="$1" containerfile="$2" context="$3"; shift 3
  local image="$DEST/$service:$VERSION"
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
echo "==> copying $HI/valkey -> $DEST/valkey"
skopeo copy "docker://$HI/valkey:latest" "docker://$DEST/valkey:latest"

echo
echo "All 11 service images built and pushed under $DEST, plus valkey."
echo "Now set the registry in ../overlays/hardened/kustomization.yaml and apply it."
