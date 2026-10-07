#!/usr/bin/env bash
#
# Point both overlays at your registry.
#
#   export REGISTRY=registry.example.com:8443
#   ./set-registry.sh
#
# Takes $REGISTRY/$NAMESPACE from the environment (see registry.env), or a
# <registry>/<namespace> argument, which overrides it.
#
# Rewrites every `newName:` in ../overlays/hardened and ../overlays/ubi, keeping
# each image's own last path component. Idempotent: run it again with a different
# value and it rewrites from whatever is there now, placeholder or not.
#
# Pass --check to print what the overlays currently point at and change nothing.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAYS=("$HERE/../overlays/hardened/kustomization.yaml" "$HERE/../overlays/ubi/kustomization.yaml")

if [ "${1:-}" = "--check" ]; then
  for f in "${OVERLAYS[@]}"; do
    echo "== ${f#"$HERE/../"}"
    grep -E '^\s+newName:' "$f" | sed -E 's|^\s+newName: (.*)/[^/]+$|  \1|' | sort -u
  done
  exit 0
fi

# shellcheck source=registry.env
. "$HERE/registry.env"
[ $# -gt 0 ] && DEST="$1"        # positional still wins over the environment
require_registry "$0" || exit 1
DEST="${DEST%/}"

case "$DEST" in
  */*) ;;
  *) echo "error: expected <registry>/<namespace>, e.g. registry.example.com:8443/online-boutique" >&2
     echo "       a bare registry with no namespace would put 13 repositories at its root" >&2
     exit 1 ;;
esac

for f in "${OVERLAYS[@]}"; do
  sed -i -E "s|^(\s+newName: ).*/([^/]+)$|\1${DEST}/\2|" "$f"
  echo "==> $(grep -cE '^\s+newName:' "$f") images repointed in ${f#"$HERE/../"}"
done

echo
echo "Now: oc apply -k overlays/hardened   (and overlays/ubi for the comparison)"
