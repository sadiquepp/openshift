#!/usr/bin/env bash
#
# Check everything that could fail before you spend 40 minutes building.
#
#   export REGISTRY=registry.example.com:8443
#   ./preflight.sh                                    # hardened base set
#   ./preflight.sh --build-check                      # + a real Go build/run test
#   BASE=ubi ./preflight.sh                           # UBI base set
#
# REGISTRY is read from the environment (see registry.env); passing it as an
# argument still works and overrides. Without it, every check runs except the
# registry reachability and login one.
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
for a in "$@"; do
  case "$a" in
    --build-check) BUILD_CHECK=1 ;;
    -*) echo "unknown option: $a" >&2; exit 2 ;;
    *) REGISTRY="$a" ;;   # positional still wins over the environment
  esac
done

# shellcheck source=registry.env
. "$HERE/registry.env"
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
if command -v oc >/dev/null; then pass "oc"; else warn "oc not on PATH (needed to deploy, not to build)"; fi
# One scanner is enough. grype and trivy use overlapping but different
# vulnerability databases, so the second is a cross-check, not a requirement --
# useful when a distroless image's count looks implausibly low.
if command -v grype >/dev/null; then
  # A downloaded-but-unhydrated database is the common grype failure: it reports
  # "failed to hydrate" then "database does not exist", usually from no disk
  # space or a cache written by an older grype with a different db format.
  if grype db status >/dev/null 2>&1; then
    pass "grype (vulnerability db ok)"
  else
    fail "grype's vulnerability db is not usable -- grype db delete && grype db update"
    fail "  needs ~1GB free in \${GRYPE_DB_CACHE_DIR:-~/.cache/grype}"
  fi
  command -v trivy >/dev/null && pass "trivy (second opinion)" \
    || printf '  --    trivy not installed (optional second opinion)\n'
elif command -v trivy >/dev/null; then
  pass "trivy"
  printf '  --    grype not installed (optional second opinion)\n'
else
  warn "no scanner yet -- needed for cve-demo/ and scan-stack.sh, not for building:"
  warn "  curl -sSfL https://get.anchore.io/grype | sh -s -- -b /usr/local/bin"
fi

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
echo "== hi/nodejs majors available"
# The node major is an application compatibility decision, not a detail to
# leave on :latest -- a build on node 26 fails outright, because upstream's
# @google-cloud/profiler pulls a native addon with no prebuilt for that ABI
# that will not compile against current V8 headers. The catalog does not
# document which majors it carries, so ask it, and say which one is configured.
NODE_FOUND=""
for maj in 24 22 20; do
  if skopeo inspect --raw "docker://registry.access.redhat.com/hi/nodejs:${maj}" >/dev/null 2>&1; then
    pass "hi/nodejs:${maj}"
    [ -z "$NODE_FOUND" ] && NODE_FOUND="$maj"
  else
    printf '  --    hi/nodejs:%s (not present)\n' "$maj"
  fi
done
case "$NODE_BUILDER" in
  *:latest*|*:latest-builder*)
    warn "NODE_BUILDER is on a floating tag: $NODE_BUILDER"
    warn "  a node major bump can break the native addon build without warning."
    warn "  pin it: NODE_MAJOR=${NODE_FOUND:-22}" ;;
esac
if [ -z "$NODE_FOUND" ]; then
  warn "none of the probed majors resolved -- check the catalog for the tag"
  warn "  naming scheme and set NODE_MAJOR accordingly"
fi

echo
echo "== minimal base candidates for static binaries"
# The Go services produce a static binary and need a base that holds it and
# nothing else. Which minimal images the hardened catalog actually ships is not
# something the docs pin down, so ask the registry and report what is there.
FOUND_MINIMAL=""
# Ordered by fitness for this job, not by size: a static Go binary wants a base
# with no libc at all, which is what a `static` image is for. The rest are
# fallbacks in descending preference, ending with the one UBI option.
for cand in registry.access.redhat.com/hi/static:latest \
            registry.access.redhat.com/hi/ubi-micro:latest \
            registry.access.redhat.com/hi/ubi-minimal:latest \
            registry.access.redhat.com/hi/base:latest \
            registry.access.redhat.com/ubi9/ubi-micro:latest; do
  if skopeo inspect --raw "docker://$cand" >/dev/null 2>&1; then
    pass "$cand"
    [ -z "$FOUND_MINIMAL" ] && FOUND_MINIMAL="$cand"
  else
    printf '  --    %s (not present)\n' "$cand"
  fi
done
if [ -n "$FOUND_MINIMAL" ] && [ "$FOUND_MINIMAL" != "$GO_RUNTIME" ]; then
  warn "best fit available is $FOUND_MINIMAL, but GO_RUNTIME is $GO_RUNTIME"
  warn "  set GO_RUNTIME=$FOUND_MINIMAL (or edit bases.env) and rerun --build-check"
fi

echo
echo "== unknown 2: is $GO_RUNTIME usable as a runtime base?"
if skopeo inspect "docker://$GO_RUNTIME" >/dev/null 2>&1; then
  # For a multi-arch image `--raw` returns an image index whose top level has
  # .manifests and no .layers at all, so summing .layers there yields nothing.
  # Resolve one platform first, then sum that manifest's layers.
  raw=$(skopeo inspect --raw "docker://$GO_RUNTIME" 2>/dev/null)
  if [ "$(echo "$raw" | jq -r 'has("manifests")')" = true ]; then
    child=$(echo "$raw" | jq -r '[.manifests[] | select(.platform.architecture=="amd64")][0].digest // .manifests[0].digest')
    raw=$(skopeo inspect --raw "docker://${GO_RUNTIME%%:*}@$child" 2>/dev/null)
  fi
  size=$(echo "$raw" | jq '[.layers[]?.size] | add // 0' 2>/dev/null || echo 0)
  human=$(numfmt --to=iec --suffix=B "${size:-0}" 2>/dev/null || echo "${size:-0} bytes")
  if "$ENGINE" run --rm --entrypoint go "$GO_RUNTIME" version >/dev/null 2>&1; then
    warn "it carries the Go toolchain ($human compressed) -- works, but you are"
    warn "shipping a compiler. Prefer hi/static or scratch -- see the probe above."
  else
    pass "no Go toolchain in it, $human compressed -- a proper runtime base"
  fi
else
  fail "cannot inspect it; set GO_RUNTIME to one of the candidates probed above"
fi

echo
echo "== unknown 3: what is the interpreter called, and is libstdc++ there?"
# Which name exists matters: RHEL and Fedora ship /usr/bin/python3 and only
# provide a bare `python` if python-unversioned-command is installed, so an
# ENTRYPOINT of ["python", ...] fails with a crun "executable file not found"
# that looks exactly like a missing interpreter. Find the name first, then use
# it for the library check -- otherwise a naming problem reads as a missing
# libstdc++.
PY_EXE=""
for cand in python3 python; do
  if "$ENGINE" run --rm --entrypoint "$cand" "$PY_RUNTIME" -c 'pass' >/dev/null 2>&1; then
    PY_EXE="$cand"; break
  fi
done
if [ -z "$PY_EXE" ]; then
  fail "neither python3 nor python runs in $PY_RUNTIME -- check the image"
else
  if [ "$PY_EXE" = python3 ]; then
    pass "interpreter is python3 (no bare \`python\`) -- which is what the Containerfiles use"
  else
    warn "only a bare \`python\` works here; the Containerfiles call python3"
  fi
  # grpcio's manylinux wheels link against libstdc++. If it is missing, the
  # Python services build fine and then fail at import, which is the worst way
  # to find out.
  if out=$("$ENGINE" run --rm --entrypoint "$PY_EXE" "$PY_RUNTIME" \
             -c "import ctypes; ctypes.CDLL('libstdc++.so.6'); print('present')" 2>&1); then
    pass "libstdc++.so.6 $out"
  else
    fail "libstdc++.so.6 missing -- grpcio will fail to import at runtime."
    fail "Fix: add to the runtime stage of Containerfile.python and"
    fail "Containerfile.loadgenerator (stage 'builder'), and cve-demo/ (stage 'deps'):"
    fail "  COPY --from=builder /usr/lib64/libstdc++.so.6* /usr/lib64/"
    printf '        (%s)\n' "$(echo "$out" | tail -1)"
  fi
fi

echo
echo "== build stages: which user do the -builder images run as?"
# A non-root builder cannot write into a WORKDIR-created directory, because that
# directory is owned by root. That is what breaks `pip --prefix=/install`, dnf,
# gradle and dotnet publish, and it surfaces only after the download finishes.
# Every build stage in this directory declares USER 0 for exactly this reason;
# this check reports the fact so an edited Containerfile that drops it has an
# obvious explanation.
if uid=$("$ENGINE" run --rm --entrypoint id "$PY_BUILDER" -u 2>/dev/null); then
  if [ "$uid" = 0 ]; then
    pass "$PY_BUILDER runs as root -- USER 0 in the build stages is a no-op"
  else
    pass "$PY_BUILDER runs as uid $uid -- which is why build stages declare USER 0"
  fi
else
  warn "could not read the builder's uid (no \`id\` in the image?) -- not fatal"
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

if [ -n "${REGISTRY:-}" ]; then
  echo
  echo "== your registry ($REGISTRY)"
  # No -f here: a registry that wants credentials answers /v2/ with 401, which
  # -f reports as failure. 401 means it is up and talking, which is the question.
  code=$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "https://$REGISTRY/v2/" 2>/dev/null)
  case "$code" in
    200|401|403) pass "reachable over https (/v2/ returned $code)" ;;
    000)         warn "no https answer -- fine if it is plain http or behind a proxy" ;;
    *)           warn "/v2/ returned $code" ;;
  esac
  if "$ENGINE" login --get-login "$REGISTRY" >/dev/null 2>&1; then
    pass "logged in as $("$ENGINE" login --get-login "$REGISTRY" 2>/dev/null)"
  else
    fail "not logged in: $ENGINE login $REGISTRY"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  if [ -z "${REGISTRY:-}" ]; then
    echo "All base-image checks passed. Set REGISTRY and rerun to check the registry too:"
    echo "  export REGISTRY=registry.example.com:8443"
  else
    echo "All checks passed. Next: ./set-registry.sh && (cd cve-demo && ./compare.sh)"
  fi
else
  echo "Fix the FAILs above before building. Every base image is overridable from"
  echo "the environment or by editing bases.env."
fi
exit "$FAIL"
