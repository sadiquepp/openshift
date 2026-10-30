#!/usr/bin/env bash
#
# Pin image digests into a kustomization, from a list of built images.
#
#   pin-digests.sh [--check] <kustomization.yaml>
#
# Reads one `<image-ref>@sha256:<digest>` per line on stdin -- exactly the form
# the build pipeline reports:
#
#   oc -n boutique-ci get taskrun -l tekton.dev/pipelineTask=build \
#     -o jsonpath='{range .items[*]}{.status.results[?(@.name=="IMAGE_URL")].value}{"@"}{.status.results[?(@.name=="IMAGE_DIGEST")].value}{"\n"}{end}'
#
# and rewrites the `digest:` (or `newTag:`) of each matching `images:` entry in
# the file, matching on the SERVICE NAME -- the last path component of
# `newName:`. Everything else in the file, comments included, is left byte for
# byte as it was, which is why this edits lines rather than loading the YAML.
#
# --check reports what would change and writes nothing. Exit 1 means the file
# is out of date, so it works as a CI gate.
#
# IT FAILS RATHER THAN SILENTLY DOING LESS THAN ASKED:
#
#   - a service on stdin with no matching entry in the file is an error. That
#     is the failure this whole design is wary of -- an image override that
#     matches nothing leaves the previous value in place and the mistake only
#     appears as a pod running something unexpected.
#   - the same service twice on stdin is an error. It means two base sets were
#     piped in at once (both tags end in the same service name), and one would
#     have overwritten the other.
#   - an entry carrying both digest: and newTag: is an error. kustomize treats
#     them as mutually exclusive and the result would be ambiguous.
set -euo pipefail

CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

FILE="${1:-}"
[ -n "$FILE" ] || { echo "usage: $0 [--check] <kustomization.yaml>" >&2; exit 2; }
[ -f "$FILE" ] || { echo "no such file: $FILE" >&2; exit 2; }

declare -A SEEN=()
WANT="$(mktemp)"; trap 'rm -f "$WANT" "$WANT.new"' EXIT

# service<TAB>digest, from stdin. Parsing is deliberate about the registry
# port: take the basename first, so the colon in host:port is never seen.
while IFS= read -r line; do
  [ -n "${line// }" ] || continue
  case "$line" in *@sha256:*) ;; *)
    echo "not an <image>@sha256:<digest> line: $line" >&2; exit 2 ;;
  esac
  digest="sha256:${line##*@sha256:}"
  ref="${line%@sha256:*}"
  base="${ref##*/}"            # frontend:v0.10.6-b2026...
  svc="${base%%:*}"            # frontend
  [ -n "$svc" ] || { echo "cannot read a service name from: $line" >&2; exit 2; }
  if [ -n "${SEEN[$svc]:-}" ]; then
    echo "service '$svc' appears twice on stdin -- are two base sets piped in together?" >&2
    exit 2
  fi
  SEEN[$svc]=1
  printf '%s\t%s\n' "$svc" "$digest" >> "$WANT"
done

[ -s "$WANT" ] || { echo "nothing on stdin" >&2; exit 2; }

awk -v want="$WANT" -v check="$CHECK" -v file="$FILE" '
  BEGIN {
    while ((getline line < want) > 0) {
      split(line, f, "\t"); d[f[1]] = f[2]
    }
  }
  # newName: <registry>/<path>/<service>   -- the service this entry is for.
  /^[[:space:]]*newName:[[:space:]]*[^[:space:]]+/ {
    n = $NF; sub(/.*\//, "", n); svc = n
  }
  # A new entry starts here, so forget the previous service.
  /^[[:space:]]*-[[:space:]]+name:/ { svc = "" }

  /^[[:space:]]*(digest|newTag):[[:space:]]*[^[:space:]]+/ {
    if (svc != "" && svc in d) {
      if (seen[svc]) {
        printf "%s: entry for %s carries both digest: and newTag:\n", file, svc > "/dev/stderr"
        bad = 1
      }
      seen[svc] = 1
      match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
      old = $NF
      if (old != d[svc]) {
        printf "  %-24s %s -> %s\n", svc, old, d[svc] > "/dev/stderr"
        changed++
      }
      print ind "digest: " d[svc]
      next
    }
  }
  { print }
  END {
    missing = ""
    for (s in d) if (!seen[s]) missing = missing " " s
    if (missing != "") {
      printf "%s: no images entry for:%s\n", file, missing > "/dev/stderr"
      printf "  (an override that matches nothing leaves the old value in place)\n" > "/dev/stderr"
      exit 3
    }
    if (bad) exit 3
    printf "%d of %d entries changed\n", changed, length(d) > "/dev/stderr"
    exit (check && changed > 0) ? 1 : 0
  }
' "$FILE" > "$WANT.new" || {
  rc=$?
  [ "$rc" = 1 ] && { echo "$FILE is out of date" >&2; exit 1; }
  exit "$rc"
}

if [ "$CHECK" = 1 ]; then
  echo "$FILE is up to date" >&2
else
  cat "$WANT.new" > "$FILE"
  echo "wrote $FILE" >&2
fi
