#!/usr/bin/env bash
# Build a test ztunnel image: the image your mesh runs, with the ztunnel binary
# rebuilt from the same source commit plus the patches in this directory, using
# the crypto backend you choose.
#
# Usage:
#   [BACKEND=openssl|aws-lc|ring|boring] ./build-test-image.sh <base-image> <target-image>
#
#   <base-image>    the ztunnel image the cluster runs now, ideally by digest:
#                   oc -n ztunnel get ds ztunnel -o jsonpath='{.spec.template.spec.containers[0].image}'
#   <target-image>  where to push the result, somewhere the cluster can pull from
#
# Environment overrides:
#   BACKEND         crypto backend to build with (default openssl, as OSSM ships)
#   PLATFORM        default linux/amd64 (linux/arm64 for Graviton nodes)
#   SOURCE_URL      ztunnel git repo, if the base image does not record it
#   SOURCE_COMMIT   ztunnel commit, if the base image does not record it
#   WORK            source checkout directory (default ./.work/ztunnel)
#   PATCHES         patch files to apply, in order (default ./0*.patch)
#
# Needs podman and git, and `podman login` to the base image's registry
# (registry.redhat.io for OSSM) and to the target registry. Build on a host of
# the target architecture: emulated builds work but are very slow.
set -euo pipefail

BASE=${1:?usage: $0 <base-image> <target-image>}
TARGET=${2:?usage: $0 <base-image> <target-image>}
HERE=$(cd "$(dirname "$0")" && pwd)
BACKEND=${BACKEND:-openssl}
PLATFORM=${PLATFORM:-linux/amd64}
WORK=${WORK:-$HERE/.work/ztunnel}
if [ -n "${PATCHES:-}" ]; then
  read -r -a PATCH_LIST <<<"$PATCHES"
else
  PATCH_LIST=("$HERE"/0*.patch)
fi
# Present in a binary built with all the patches here (the shared cached provider).
MARKER=7ztunnel3tls3lib8PROVIDER
# Present in a binary built with only the first, OpenSSL-only patch.
MARKER_OPENSSL_ONLY=22build_openssl_provider

case "$BACKEND" in
  openssl) CARGO_FEATURE=tls-openssl; BUILD_PACKAGES="openssl-devel" ;;
  aws-lc)  CARGO_FEATURE=tls-aws-lc;  BUILD_PACKAGES="cmake clang gcc-c++ perl" ;;
  ring)    CARGO_FEATURE=tls-ring;    BUILD_PACKAGES="" ;;
  boring)  CARGO_FEATURE=tls-boring;  BUILD_PACKAGES="cmake clang clang-libs gcc-c++ perl golang" ;;
  *) echo "BACKEND must be one of: openssl aws-lc ring boring" >&2; exit 1 ;;
esac

say() { printf '\n==> %s\n' "$*"; }

extract_binary() { # <image> <dest>
  local path c
  path=$(podman image inspect "$1" \
    --format '{{if .Config.Entrypoint}}{{index .Config.Entrypoint 0}}{{else}}{{index .Config.Cmd 0}}{{end}}')
  case "$path" in
    /*ztunnel) ;;
    *) echo "Entrypoint of $1 is '$path', not a ztunnel binary" >&2; return 1 ;;
  esac
  c=$(podman create --platform "$PLATFORM" "$1")
  podman cp "$c:$path" "$2"
  podman rm "$c" >/dev/null
  echo "$path"
}

say "Pulling $BASE"
podman pull -q --platform "$PLATFORM" "$BASE" >/dev/null

say "Inspecting the base image's ztunnel binary"
mkdir -p "$HERE/.work"
ZTUNNEL_PATH=$(extract_binary "$BASE" "$HERE/.work/ztunnel-base")
RUSTLS_OPENSSL=$(grep -a -o 'rustls-openssl-0\.[0-9]*\.[0-9]*' "$HERE/.work/ztunnel-base" | head -1 || true)
echo "binary:         $ZTUNNEL_PATH"
echo "rustls-openssl: ${RUSTLS_OPENSSL:-not found (not an OpenSSL build?)}"
if grep -a -q -e "$MARKER" -e "$MARKER_OPENSSL_ONLY" "$HERE/.work/ztunnel-base"; then
  echo "The base image already contains the patch. Nothing to do." >&2
  exit 1
fi

say "Finding the source commit the base image was built from"
HIST=$(podman history --no-trunc --format '{{.CreatedBy}}' "$BASE")
SOURCE_COMMIT=${SOURCE_COMMIT:-$(grep -o 'ZTUNNEL_GIT_SHA=[0-9a-f]\{40\}' <<<"$HIST" | head -1 | cut -d= -f2 || true)}
SOURCE_URL=${SOURCE_URL:-$(grep -o 'ZTUNNEL_GIT_URL=[^ ]*' <<<"$HIST" | head -1 | cut -d= -f2 || true)}
if [ -z "$SOURCE_COMMIT" ] || [ -z "$SOURCE_URL" ]; then
  echo "The base image does not record ZTUNNEL_GIT_SHA / ZTUNNEL_GIT_URL." >&2
  echo "Set SOURCE_URL and SOURCE_COMMIT and run again." >&2
  exit 1
fi
echo "source: $SOURCE_URL @ $SOURCE_COMMIT"

say "Checking out the source and applying ${#PATCH_LIST[@]} patch(es)"
[ -d "$WORK/.git" ] || git clone -q "$SOURCE_URL" "$WORK"
git -C "$WORK" am --abort 2>/dev/null || true
git -C "$WORK" fetch -q origin "$SOURCE_COMMIT" 2>/dev/null || git -C "$WORK" fetch -q origin
git -C "$WORK" checkout -q -f -B test/cache-provider "$SOURCE_COMMIT"
for p in "${PATCH_LIST[@]}"; do
  if ! git -C "$WORK" -c user.name=test -c user.email=test@localhost am -q "$p"; then
    git -C "$WORK" am --abort || true
    echo "$(basename "$p") does not apply to $SOURCE_COMMIT; it needs rebasing for this version." >&2
    exit 1
  fi
done
git -C "$WORK" log --oneline -$((${#PATCH_LIST[@]} + 1))

# A build with only the OpenSSL-only patch has no shared provider; check for its own symbol.
EXPECT=$MARKER
git -C "$WORK" grep -q 'static PROVIDER' -- src/tls/lib.rs || EXPECT=$MARKER_OPENSSL_ONLY
if [ "$EXPECT" = "$MARKER_OPENSSL_ONLY" ] && [ "$BACKEND" != openssl ]; then
  echo "The applied patches only change the OpenSSL backend; BACKEND=$BACKEND would test nothing." >&2
  exit 1
fi

say "Building $TARGET (backend: $BACKEND)"
podman build --platform "$PLATFORM" \
  -f "$HERE/Containerfile" \
  --build-arg BASE="$BASE" \
  --build-arg ZTUNNEL_PATH="$ZTUNNEL_PATH" \
  --build-arg BACKEND="$BACKEND" \
  --build-arg CARGO_FEATURE="$CARGO_FEATURE" \
  --build-arg BUILD_PACKAGES="$BUILD_PACKAGES" \
  --build-arg MARKER="$EXPECT" \
  -t "$TARGET" "$WORK"

say "Verifying $TARGET"
extract_binary "$TARGET" "$HERE/.work/ztunnel-test" >/dev/null
if ! grep -a -q "$EXPECT" "$HERE/.work/ztunnel-test"; then
  echo "The built image does not contain the patch." >&2
  exit 1
fi
echo "patch:   present"
echo "backend: $BACKEND"
[ "$BACKEND" = openssl ] &&
  echo "rustls-openssl: $(grep -a -o 'rustls-openssl-0\.[0-9]*\.[0-9]*' "$HERE/.work/ztunnel-test" | head -1)"

say "Pushing $TARGET"
podman push --digestfile "$HERE/.work/digest" "$TARGET"
REPO=$TARGET
case "${REPO##*/}" in *:*) REPO=${REPO%:*} ;; esac
echo
echo "Pushed. Use this reference in the ZTunnel CR:"
echo "  $REPO@$(cat "$HERE/.work/digest")"
