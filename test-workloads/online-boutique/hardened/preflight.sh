#!/usr/bin/env bash
#
# Check everything that could fail before you spend 40 minutes building.
#
#   ./preflight.sh                                    # hardened base set
#   BASE=ubi ./preflight.sh                           # UBI base set
#   ./preflight.sh registry.example.com:8443          # also check your registry
#   ./preflight.sh --build-check                      # + a real Go build/run test
#
# Resolves the three unknowns this directory's README flags -- whether the tags
# in bases.env exist, whether the Go runtime base works, and whether the Python
# runtime carries libstdc++ -- by asking the registry and the images directly.
#
# Requires skopeo and podman (or ENGINE=docker). Nothing is pushed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="${ENGINE:-podman}"
BASE="${BASE:-hardened}"
BUILD_CHECK=0
REGISTRY=""
for a in "$@"; do
  case "$a" in
    --build-check) BUILD_CHECK=1 ;;
    -*) echo "unknown option: $a" >&2; exit 2 ;;
    *) REGISTRY="$a" ;;
  esac
done

# shellcheck source=bases.env
. "$HERE/bases.env"

FAIL=0
pass() { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=1; }

echo "== tools"
for t in "$ENGINE" skopeo git jq; do
  if command -v "$t" >/dev/null; then pass "$t"; else fail "$t not on PATH"; fi
done
for t in grype trivy oc; do
  if command -v "$t" >/dev/null; then pass "$t"; else warn "$t not on PATH (needed later, not now)"; fi
done

echo
echo "== unknown 1: do the tags in bases.env exist? (BASE=$BASE)"
# The whole point of this section: a tag that does not exist is the single most
# likely reason a first run dies, and it dies 20 minutes in rather than now.
for var in GO_BUILDER GO_RUNTIME NODE_BUILDER NODE_RUNTIME PY_BUILDER PY_RUNTIME \
           JAVA_BUILDER JAVA_RUNTIME DOTNET_SDK DOTNET_RUNTIME CACHE_IMAGE; do
  img="${!var}"
  if skopeo inspect --raw "docker://$img" >/dev/null 2>&1; then
    pass "$var = $img"
  else
    fail "$var = $img  -- not found. Check the tag at https://images.redhat.com"
  fi
done

echo
echo "== unknown 2: is $GO_RUNTIME usable as a runtime base?"
if skopeo inspect "docker://$GO_RUNTIME" >/dev/null 2>&1; then
  size=$(skopeo inspect --raw "docker://$GO_RUNTIME" 2>/dev/null \
         | jq '[.layers[]?.size] | add // 0' 2>/dev/null || echo 0)
  human=$(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "$size bytes")
  if "$ENGINE" run --rm --entrypoint go "$GO_RUNTIME" version >/dev/null 2>&1; then
    warn "it carries the Go toolchain ($human compressed) -- works, but you are"
    warn "shipping a compiler. Prefer ubi9/ubi-micro or scratch: GO_RUNTIME=..."
  else
    pass "no Go toolchain in it, $human compressed -- a proper runtime base"
  fi
else
  fail "cannot inspect it; set GO_RUNTIME=registry.access.redhat.com/ubi9/ubi-micro"
fi

echo
echo "== unknown 3: does $PY_RUNTIME carry libstdc++?"
# grpcio's manylinux wheels link against libstdc++. If it is missing, the Python
# services build fine and then fail at import time, which is the worst way to
# find out.
if out=$("$ENGINE" run --rm --entrypoint python "$PY_RUNTIME" \
           -c "import ctypes; ctypes.CDLL('libstdc++.so.6'); print('present')" 2>&1); then
  pass "libstdc++.so.6 $out"
else
  fail "libstdc++.so.6 missing -- grpcio will fail to import at runtime."
  fail "Fix: add to the runtime stage of Containerfile.python (stage name 'builder')"
  fail "and Containerfile.loadgenerator, and 'deps' in cve-demo/Containerfile.*:"
  fail "  COPY --from=builder /usr/lib64/libstdc++.so.6* /usr/lib64/"
  printf '        (%s)\n' "$(echo "$out" | tail -1)"
fi

echo
echo "== end to end: can the Go pair build and run a static binary?"
if [ "$BUILD_CHECK" -eq 1 ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  cat > "$tmp/main.go" <<'GO'
package main
func main() { println("static binary ran") }
GO
  cat > "$tmp/go.mod" <<'MOD'
module preflight
go 1.21
MOD
  cat > "$tmp/Containerfile" <<EOF
FROM $GO_BUILDER AS b
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -o /out/probe .
FROM $GO_RUNTIME
COPY --from=b /out/probe /probe
ENTRYPOINT ["/probe"]
EOF
  if "$ENGINE" build -q -t preflight-probe "$tmp" >/dev/null 2>&1 \
     && "$ENGINE" run --rm preflight-probe 2>&1 | grep -q 'static binary ran'; then
    pass "built on $GO_BUILDER and ran on $GO_RUNTIME"
  else
    fail "the Go builder/runtime pair does not work end to end -- rerun without -q to see why:"
    fail "  $ENGINE build -t preflight-probe $tmp"
  fi
  "$ENGINE" image rm preflight-probe >/dev/null 2>&1
else
  warn "skipped -- pass --build-check to actually build and run a static binary"
fi

if [ -n "$REGISTRY" ]; then
  echo
  echo "== your registry ($REGISTRY)"
  if curl -skf --max-time 10 "https://$REGISTRY/v2/" >/dev/null \
     || curl -skf --max-time 10 -o /dev/null -w '%{http_code}' "https://$REGISTRY/v2/" \
        | grep -qE '401|200'; then
    pass "reachable over https"
  else
    warn "no answer on https://$REGISTRY/v2/ -- fine if it is plain http or behind a proxy"
  fi
  if "$ENGINE" login --get-login "$REGISTRY" >/dev/null 2>&1; then
    pass "logged in as $("$ENGINE" login --get-login "$REGISTRY" 2>/dev/null)"
  else
    fail "not logged in: $ENGINE login $REGISTRY"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "All checks passed. Next: cd cve-demo && ./compare.sh"
else
  echo "Fix the FAILs above before building. Every base image is overridable from"
  echo "the environment or by editing bases.env."
fi
exit "$FAIL"
