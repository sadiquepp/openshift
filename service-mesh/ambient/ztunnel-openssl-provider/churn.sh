#!/bin/sh
# Connection-churn latency test. Runs INSIDE the load-client pod (busybox sh/awk):
#
#   oc -n online-boutique-ambient exec -i load-client -- sh -s -- [REQUESTS] [WORKERS] [URL] < churn.sh
#
#   REQUESTS  timed requests, one after another (default 600)
#   WORKERS   untimed background loops hitting the same URL while the timed
#             requests run, to add concurrent connection setups (default 0)
#   URL       default http://frontend/_healthz -- answered by frontend alone,
#             so no other service adds latency
#
# Every curl is a new process, so every request is a new TCP connection. With
# POOL_MAX_STREAMS_PER_CONNECTION=1 on ztunnel, it is also a new HBONE (mTLS)
# connection on both ztunnels.
#
# Output: one summary line. Non-200 responses are counted, not timed.

N=${1:-600}
W=${2:-0}
URL=${3:-http://frontend/_healthz}

pids=""
i=0
while [ "$i" -lt "$W" ]; do
  ( while :; do curl -s -o /dev/null --max-time 5 "$URL"; done ) &
  pids="$pids $!"
  i=$((i + 1))
done
[ "$W" -gt 0 ] && sleep 2

j=0
while [ "$j" -lt "$N" ]; do
  curl -s -o /dev/null --max-time 5 -w '%{http_code} %{time_total}\n' "$URL"
  j=$((j + 1))
done | awk -v n="$N" -v w="$W" '
  $1 == "200" { print $2 * 1000; next }
  { err++ }
  END { printf "# requests=%d workers=%d errors=%d\n", n, w, err + 0 }
' | sort -n | awk '
  /^#/ { hdr = $0; sub(/^# /, "", hdr); next }
  { a[++c] = $1 }
  function pct(p,   k) { k = int(c * p + 0.5); if (k < 1) k = 1; if (k > c) k = c; return a[k] }
  END {
    if (c == 0) { print hdr " ok=0"; exit 1 }
    printf "%s ok=%d p50=%.2fms p90=%.2fms p95=%.2fms p99=%.2fms max=%.2fms\n",
      hdr, c, pct(0.50), pct(0.90), pct(0.95), pct(0.99), a[c]
  }'

if [ -n "$pids" ]; then
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null
fi
exit 0
