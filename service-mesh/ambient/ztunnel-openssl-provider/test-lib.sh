# shellcheck shell=bash
# Helpers for README.md. Source them from the repository root, in bash:
#
#   source service-mesh/ambient/ztunnel-openssl-provider/test-lib.sh
#
# Needs oc logged in as cluster-admin (oc debug node), curl, and the
# load-client pod from load-client.yaml.
#
# Tunables (set before sourcing, or export later):
#   NS        Online Boutique namespace        (default online-boutique-ambient)
#   REQUESTS  timed requests per pass          (default 1000)
#   WORKERS   background loops, concurrent pass (default 4)
#   RESULTS   where results are written        (default $D/results)

D=${D:-service-mesh/ambient/ztunnel-openssl-provider}
NS=${NS:-online-boutique-ambient}
REQUESTS=${REQUESTS:-1000}
WORKERS=${WORKERS:-4}
RESULTS=${RESULTS:-$D/results}
PPROF_PORT=${PPROF_PORT:-25000}

# Sets CLIENT_NODE (load-client) and SERVER_NODE (frontend).
nodes() {
  CLIENT_NODE=$(oc -n "$NS" get pod load-client -o jsonpath='{.spec.nodeName}')
  SERVER_NODE=$(oc -n "$NS" get pod -l app=frontend -o jsonpath='{.items[0].spec.nodeName}')
  echo "client node (load-client): $CLIENT_NODE"
  echo "server node (frontend):    $SERVER_NODE"
  if [ -z "$CLIENT_NODE" ] || [ -z "$SERVER_NODE" ] || [ "$CLIENT_NODE" = "$SERVER_NODE" ]; then
    echo "load-client and frontend must run on two different nodes" >&2
    return 1
  fi
}

# ztunnel pod name on node $1.
zt_pod() {
  oc -n ztunnel get pod -l app=ztunnel --field-selector spec.nodeName="$1" \
    -o jsonpath='{.items[0].metadata.name}'
}

# Runs a command on node $1's host. Quiet, and exits 0 even if the command finds nothing.
on_node() {
  oc debug node/"$1" -q -- chroot /host sh -c "$2" 2>/dev/null
}

# Number of mappings of the OpenSSL FIPS provider in node $1's ztunnel process.
# Above 0 means OpenSSL is running in FIPS mode in that process.
fips_maps() {
  # shellcheck disable=SC2016  # expanded on the node, not here
  on_node "$1" 'p=$(pgrep -xo ztunnel) || { echo "no-ztunnel-process"; exit 0; }
                grep -c "ossl-modules/fips.so" /proc/$p/maps || true'
}

# CPU seconds (user + system, all threads) used so far by node $1's ztunnel process.
zt_cpu() {
  # shellcheck disable=SC2016  # expanded on the node, not here
  on_node "$1" 'p=$(pgrep -xo ztunnel) || exit 0
                awk -v hz="$(getconf CLK_TCK)" "{ printf \"%.3f\n\", (\$14 + \$15) / hz }" /proc/$p/stat'
}

# What is running: image digest and FIPS state per node, and the test env vars.
zt_status() {
  oc -n ztunnel rollout status ds/ztunnel --timeout=5m >/dev/null || return 1
  local n p
  for n in "$CLIENT_NODE" "$SERVER_NODE"; do
    p=$(zt_pod "$n")
    printf '%s  %s\n    image:    %s\n    fips.so:  %s mapping(s)\n' "$n" "$p" \
      "$(oc -n ztunnel get pod "$p" -o jsonpath='{.status.containerStatuses[0].imageID}')" \
      "$(fips_maps "$n")"
  done
  printf 'env: '
  oc -n ztunnel get ds ztunnel \
    -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' |
    grep -E '^(POOL_MAX_STREAMS_PER_CONNECTION|ZTUNNEL_WORKER_THREADS|OPENSSL_FORCE_FIPS_MODE)=' |
    tr '\n' ' '
  echo
}

# Runs churn.sh in load-client: churn <requests> <workers>
churn() {
  oc -n "$NS" exec -i load-client -- sh -s -- "$1" "$2" < "$D/churn.sh"
}

# One complete run. Writes everything to $RESULTS/<label>/.
#   pass 1: sequential requests, ztunnel CPU per request on both nodes
#   pass 2: requests with WORKERS concurrent loops, CPU profile of the client-side ztunnel
run_test() {
  local label=${1:?usage: run_test <label>}
  local out=$RESULTS/$label c0 s0 c1 s1 t0 secs pf prof
  mkdir -p "$out"

  echo "== $label: status"
  zt_status | tee "$out/status.txt"

  echo "== $label: warm-up"
  churn 50 0 >/dev/null

  echo "== $label: pass 1, $REQUESTS sequential requests"
  c0=$(zt_cpu "$CLIENT_NODE") s0=$(zt_cpu "$SERVER_NODE")
  t0=$SECONDS
  churn "$REQUESTS" 0 | tee "$out/latency-sequential.txt"
  secs=$((SECONDS - t0))
  c1=$(zt_cpu "$CLIENT_NODE") s1=$(zt_cpu "$SERVER_NODE")
  awk -v c0="$c0" -v c1="$c1" -v s0="$s0" -v s1="$s1" -v n="$REQUESTS" -v t="$secs" 'BEGIN {
    printf "ztunnel CPU per request: client %.3f ms, server %.3f ms (%d requests, window %ds incl. ~10s idle)\n",
      (c1 - c0) * 1000 / n, (s1 - s0) * 1000 / n, n, t }' | tee "$out/cpu-per-request.txt"

  echo "== $label: pass 2, $REQUESTS requests + $WORKERS concurrent loops, profiling client ztunnel"
  oc -n ztunnel port-forward "pod/$(zt_pod "$CLIENT_NODE")" "$PPROF_PORT:15000" >/dev/null 2>&1 &
  pf=$!
  sleep 3
  curl -sS -o "$out/cpu-client-ztunnel.pb" \
    "http://localhost:$PPROF_PORT/debug/pprof/profile?seconds=30&frequency=1000" &
  prof=$!
  churn "$REQUESTS" "$WORKERS" | tee "$out/latency-concurrent.txt"
  wait "$prof"
  kill "$pf" 2>/dev/null
  wait "$pf" 2>/dev/null
  ls -l "$out/cpu-client-ztunnel.pb"
  echo "== $label: done, results in $out"
}
