#!/usr/bin/env python3
"""
trace-analyze.py — phase 3 of observability/aiops

Computes the diagnosis from a trace. The model narrates what this returns; it
does not derive it. That is deliberate: a mid-size model handed a raw waterfall
with no baseline will say something fluent and wrong, and a demo needs the same
verdict every time it runs.

Everything below is arithmetic over span timings:

  * total request duration, and how it compares to a baseline
  * the repeated-call (N+1) pattern: same operation, how many times, serial or
    overlapping, and how much of the request it accounts for
  * in-process vs on-the-wire, from the client/server span delta — the one
    discriminator that separates "the service is slow" from "the network is
    slow", and the thing flows cannot tell you
  * payment ordering: how much of the request happened after the charge
  * the suspect service

What it deliberately does NOT do is name a root cause. An un-instrumented
sleep emits no span, so the trace can prove "unattributed in-process time in
GetProduct" and no more. Naming EXTRA_LATENCY needs a second signal — the
workload config or the startup log — and the output says so rather than
guessing.

Usage:
  # from a saved trace (testable offline, which is how this is rehearsed)
  ./trace-analyze.py --file trace.json
  cat trace.json | ./trace-analyze.py

  # fetch by id (TEMPO_BASE must be reachable: a port-forward locally, or the
  # in-cluster service URL when this runs as an MCP tool)
  export TEMPO_BASE=https://127.0.0.1:18080/api/traces/v1/dev/tempo
  ./trace-analyze.py --trace-id 7ea4acd35045bf243cc9b5031ef25a43

  # find the slowest recent one first
  ./trace-analyze.py --slowest --service checkoutservice --min-ms 250

  --json        machine-readable, for the MCP wrapper
  --baseline-ms the clean total to compare against (omit to skip the ratio)
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import shutil
import socket
import ssl
import subprocess
import sys
import time
import urllib.parse
import urllib.request

# Span names follow three conventions in this workload because three languages
# emit them: Go as `hipstershop.X/Y`, Python as `/hipstershop.X/Y`, Node as
# `grpc.hipstershop.X/Y`. Matching on equality silently misses two thirds of
# them, so everything here compares on the normalised tail.
INFRA_SPANS = (
    "opentelemetry.proto.collector",
    "grpc.health.v1.Health",
)

SPAN_KIND_CLIENT = 3
SPAN_KIND_SERVER = 2

# Protobuf's JSON mapping serialises enums by NAME, so Tempo returns
# "SPAN_KIND_SERVER" where the wire format has 2. Both forms appear in the
# wild depending on the exporter, and the kind is what separates a caller from
# a callee here — get it wrong and every finding below is noise rather than an
# error. So accept either and say so loudly if neither is present.
_SPAN_KINDS = {
    "SPAN_KIND_UNSPECIFIED": 0,
    "SPAN_KIND_INTERNAL": 1,
    "SPAN_KIND_SERVER": 2,
    "SPAN_KIND_CLIENT": 3,
    "SPAN_KIND_PRODUCER": 4,
    "SPAN_KIND_CONSUMER": 5,
}


def parse_kind(raw) -> int:
    if raw is None or raw == "":
        return 0
    if isinstance(raw, bool):
        return 0
    if isinstance(raw, int):
        return raw
    text = str(raw).strip()
    if text.isdigit():
        return int(text)
    return _SPAN_KINDS.get(text.upper(), 0)


def normalise(name: str) -> str:
    """`grpc.hipstershop.Svc/Op`, `/hipstershop.Svc/Op` -> `Svc/Op`."""
    n = name.lstrip("/")
    for prefix in ("grpc.", "hipstershop.", "grpc.hipstershop."):
        if n.startswith(prefix):
            n = n[len(prefix):]
    return n.lstrip("/")


class Span:
    __slots__ = ("service", "name", "op", "kind", "start", "end", "ms")

    def __init__(self, service, name, kind, start, end):
        self.service = service
        self.name = name
        self.op = normalise(name)
        self.kind = kind
        self.start = start
        self.end = end
        self.ms = (end - start) / 1e6

    @property
    def is_infra(self) -> bool:
        return any(p in self.name for p in INFRA_SPANS)


def self_ms(s: Span, spans: list[Span]) -> float:
    """Duration minus whatever is nested inside it.

    Total duration is useless for attribution: the root span contains the whole
    request, so ranking by it always blames the frontend and always declares
    the outermost call "in-process". Self time is the part a span is actually
    responsible for, and it is computed from the union of what it contains so
    that concurrent children are not double-counted.
    """
    inner = [(o.start, o.end) for o in spans
             if o is not s and o.start >= s.start and o.end <= s.end
             and o.end > o.start and (o.end - o.start) < (s.end - s.start)]
    merged: list[list[int]] = []
    for a, b in sorted(inner):
        if merged and a <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    covered = sum(b - a for a, b in merged)
    return max(0.0, (s.end - s.start - covered) / 1e6)


def parse_trace(doc: dict) -> list[Span]:
    """OTLP JSON as Tempo returns it, under `batches` or `resourceSpans`."""
    spans: list[Span] = []
    for rs in doc.get("batches") or doc.get("resourceSpans") or []:
        service = "?"
        for attr in (rs.get("resource") or {}).get("attributes") or []:
            if attr.get("key") == "service.name":
                v = attr.get("value") or {}
                service = v.get("stringValue") or v.get("string_value") or "?"
        scopes = rs.get("scopeSpans") or rs.get("instrumentationLibrarySpans") or []
        for scope in scopes:
            for sp in scope.get("spans") or []:
                try:
                    start = int(sp.get("startTimeUnixNano") or 0)
                    end = int(sp.get("endTimeUnixNano") or 0)
                except (TypeError, ValueError):
                    continue
                if not start or end < start:
                    continue
                spans.append(Span(service, sp.get("name") or "?",
                                  parse_kind(sp.get("kind")), start, end))
    spans.sort(key=lambda s: s.start)
    return spans


def analyse(spans: list[Span], baseline_ms: float | None) -> dict:
    real = [s for s in spans if not s.is_infra]
    if not real:
        return {"error": "no application spans in this trace"}

    if not any(s.kind in (SPAN_KIND_CLIENT, SPAN_KIND_SERVER) for s in real):
        return {"error": (
            "no client or server spans — every span decoded as kind "
            f"{sorted({s.kind for s in real})}. The client/server split drives "
            "every finding here, so this would be noise rather than analysis. "
            "Check how the exporter encodes `kind`.")}

    t0 = min(s.start for s in real)
    t1 = max(s.end for s in real)
    total_ms = (t1 - t0) / 1e6
    root = max(real, key=lambda s: s.ms)

    out: dict = {
        "total_ms": round(total_ms, 1),
        "span_count": len(real),
        "root": {"service": root.service, "name": root.name,
                 "ms": round(root.ms, 1)},
        "findings": [],
    }
    if baseline_ms:
        out["baseline_ms"] = baseline_ms
        out["slowdown"] = round(total_ms / baseline_ms, 1) if baseline_ms else None

    # ── repeated calls ──────────────────────────────────────────────────────
    # Keyed by (caller, operation), not by operation alone. The same operation
    # repeated from two different callers is two different N+1 sites, and
    # merging them hides the structure: here checkoutservice's nine serial
    # calls before the charge and the frontend's five after it are separate
    # findings with separate consequences.
    groups: dict[tuple[str, str], list[Span]] = {}
    for s in real:
        if s.kind == SPAN_KIND_CLIENT:
            groups.setdefault((s.service, s.op), []).append(s)

    repeats = []
    for (caller, op), callers in groups.items():
        if len(callers) < 3:
            continue
        callers.sort(key=lambda s: s.start)
        agg = sum(c.ms for c in callers)
        # Tolerance, because "serial" is a claim the narrative rests on and it
        # must not flip on clock jitter. Spans are nanosecond-stamped across
        # processes, so genuinely sequential calls routinely overlap by a few
        # microseconds. Only an overlap worth more than a millisecond, or more
        # than a twentieth of a call, counts as real concurrency.
        tol_ns = max(1e6, (agg / len(callers)) * 1e6 * 0.05)
        overlap = any(a.end - b.start > tol_ns for a, b in zip(callers, callers[1:]))
        repeats.append({
            "caller": caller,
            "operation": op,
            "calls": len(callers),
            "total_ms": round(agg, 1),
            "share_pct": round(agg / total_ms * 100) if total_ms else 0,
            "serial": not overlap,
            "mean_ms": round(agg / len(callers), 1),
            "first_at_ms": round((callers[0].start - t0) / 1e6, 1),
        })
    repeats.sort(key=lambda r: -r["total_ms"])
    out["repeated_calls"] = repeats

    # ── in-process vs on the wire ───────────────────────────────────────────
    # The discriminator. Pair each client span with the server span it
    # contains: if the server span is nearly as long, the time is inside the
    # callee. If the gap is large, it is transit, serialisation or client
    # overhead — and that is what flow data can localise and traces cannot.
    pairs = []
    servers = [s for s in real if s.kind == SPAN_KIND_SERVER]
    for c in (s for s in real if s.kind == SPAN_KIND_CLIENT):
        inner = [s for s in servers
                 if s.op == c.op and s.start >= c.start and s.end <= c.end]
        if not inner:
            continue
        srv = max(inner, key=lambda s: s.ms)
        pairs.append({
            "operation": c.op,
            "callee": srv.service,
            "client_ms": round(c.ms, 1),
            "server_ms": round(srv.ms, 1),
            "delta_ms": round(c.ms - srv.ms, 1),
            "in_callee_pct": round(srv.ms / c.ms * 100, 1) if c.ms else 0,
        })
        pairs[-1]["server_self_ms"] = round(self_ms(srv, real), 1)

    # Rank by the callee's SELF time, aggregated across repeats. Ranking by
    # client duration picks the outermost call every time — PlaceOrder's server
    # span fills PlaceOrder's client span by construction, which says nothing.
    # Self time finds where the request actually terminates.
    by_op: dict[str, float] = {}
    for p in pairs:
        by_op[p["operation"]] = by_op.get(p["operation"], 0.0) + p.get("server_self_ms", 0.0)
    pairs.sort(key=lambda p: (-by_op.get(p["operation"], 0.0), -p["client_ms"]))
    out["client_server_pairs"] = pairs[:5]

    slow = [p for p in pairs
            if p["client_ms"] >= 50 and p.get("server_self_ms", 0) >= 10]
    if slow:
        worst = slow[0]
        if worst["in_callee_pct"] >= 90:
            out["location"] = {
                "verdict": "in-process",
                "service": worst["callee"],
                "evidence": (
                    f"{worst['operation']}: client {worst['client_ms']}ms vs "
                    f"server {worst['server_ms']}ms, a {worst['delta_ms']}ms gap "
                    f"({worst['in_callee_pct']}% of the call is inside "
                    f"{worst['callee']})"
                ),
                "rules_out": "network transit, and any downstream dependency "
                             "(no child span accounts for the time)",
            }
        else:
            out["location"] = {
                "verdict": "between the services",
                "service": worst["callee"],
                "evidence": (
                    f"{worst['operation']}: client {worst['client_ms']}ms vs "
                    f"server {worst['server_ms']}ms — only "
                    f"{worst['in_callee_pct']}% is inside {worst['callee']}"
                ),
                "rules_out": "the callee's own handler",
            }

    # Childless spans are their own finding: an uninstrumented callee is
    # indistinguishable from a fast one, and expensive when it is neither.
    childless = [
        {"service": s.service, "operation": s.op, "ms": round(s.ms, 1)}
        for s in real
        if s.kind == SPAN_KIND_CLIENT and s.ms >= 50
        and not any(o.op == s.op and o.kind == SPAN_KIND_SERVER
                    and o.start >= s.start and o.end <= s.end for o in real)
    ]
    out["opaque_spans"] = sorted(childless, key=lambda c: -c["ms"])[:5]

    # ── payment ordering ────────────────────────────────────────────────────
    # Only a trace can establish this, and it is the finding a customer
    # actually feels: the money moved, and then they kept waiting.
    charge = next((s for s in real
                   if s.op.endswith("PaymentService/Charge")
                   and s.kind == SPAN_KIND_CLIENT), None)
    if charge is None:
        charge = next((s for s in real if s.op.endswith("PaymentService/Charge")), None)
    if charge:
        after_ms = (t1 - charge.end) / 1e6
        following = sorted(
            ({"service": s.service, "operation": s.op, "ms": round(s.ms, 1)}
             for s in real
             if s.start >= charge.end and s.kind != SPAN_KIND_SERVER and s.ms >= 1),
            key=lambda x: -x["ms"])
        out["payment_ordering"] = {
            "charge_completed_at_ms": round((charge.end - t0) / 1e6, 1),
            "request_continued_ms": round(after_ms, 1),
            "share_pct": round(after_ms / total_ms * 100) if total_ms else 0,
            "work_after_charge": following[:6],
        }

    # ── suspect ─────────────────────────────────────────────────────────────
    # Self time again: total server time blames whoever holds the root span,
    # because it contains the whole request.
    cost: dict[str, float] = {}
    for sp_ in real:
        if sp_.kind == SPAN_KIND_SERVER:
            cost[sp_.service] = cost.get(sp_.service, 0.0) + self_ms(sp_, real)
    if cost:
        svc, ms = max(cost.items(), key=lambda kv: kv[1])
        out["suspect"] = {
            "service": svc,
            "self_time_ms": round(ms, 1),
            "share_pct": round(ms / total_ms * 100) if total_ms else 0,
        }

    return out


def render(a: dict) -> str:
    if "error" in a:
        return f"ANALYSIS FAILED: {a['error']}"
    L: list[str] = []
    r = a["root"]
    line = f"REQUEST   {r['service']} {r['name']}  {a['total_ms']}ms  ({a['span_count']} spans)"
    L.append(line)
    if a.get("slowdown"):
        L.append(f"BASELINE  {a['baseline_ms']}ms  ->  {a['slowdown']}x slower")

    for rep in a.get("repeated_calls", [])[:3]:
        L.append("")
        L.append(f"REPEATED  {rep['caller']} called {rep['operation']} "
                 f"{rep['calls']}x, starting at {rep['first_at_ms']}ms")
        L.append(f"          {rep['total_ms']}ms total, {rep['share_pct']}% of the request"
                 f" ({rep['mean_ms']}ms each)")
        L.append("          " + ("serial - the cost adds up rather than overlapping"
                                 if rep["serial"] else "overlapping - partly concurrent"))

    loc = a.get("location")
    if loc:
        L.append("")
        L.append(f"LOCATION  {loc['verdict']}: {loc['service']}")
        L.append(f"          {loc['evidence']}")
        L.append(f"          rules out {loc['rules_out']}")

    if a.get("opaque_spans"):
        L.append("")
        L.append("OPAQUE    calls with no server span - the callee is not instrumented:")
        for o in a["opaque_spans"][:3]:
            L.append(f"          {o['operation']} {o['ms']}ms (from {o['service']})")

    po = a.get("payment_ordering")
    if po:
        L.append("")
        L.append(f"ORDERING  charge completed at {po['charge_completed_at_ms']}ms")
        L.append(f"          the request continued for {po['request_continued_ms']}ms"
                 f" after that - {po['share_pct']}% of the total wait")
        if po["work_after_charge"]:
            names = ", ".join(f"{w['operation']} {w['ms']}ms"
                              for w in po["work_after_charge"][:4])
            L.append(f"          after the charge: {names}")

    if a.get("suspect"):
        L.append("")
        sus = a["suspect"]
        L.append(f"SUSPECT   {sus['service']} - {sus['self_time_ms']}ms of self time,"
                 f" {sus['share_pct']}% of the request")

    L.append("")
    L.append("NOT IN THE TRACE")
    L.append("          A root cause inside the handler emits no span, so this")
    L.append("          cannot name one. Confirm with a second signal: the")
    L.append("          workload's configuration, and its startup log.")
    return "\n".join(L)


# ── Tempo access (used by --trace-id / --slowest, and by the MCP wrapper) ────
def _oc() -> str:
    return shutil.which("oc") or shutil.which("kubectl") or ""


def _token() -> str:
    t = os.environ.get("TEMPO_TOKEN", "")
    if t:
        return t
    sa = "/var/run/secrets/kubernetes.io/serviceaccount/token"
    try:
        with open(sa) as fh:
            return fh.read().strip()
    except OSError:
        pass
    # Running from a workstation or bastion: ask oc rather than making the
    # caller export a token by hand.
    oc = _oc()
    if oc:
        try:
            out = subprocess.run([oc, "whoami", "-t"], capture_output=True,
                                 timeout=15)
            if out.returncode == 0:
                return out.stdout.decode().strip()
        except (OSError, subprocess.SubprocessError):
            pass
    return ""


@contextlib.contextmanager
def port_forward(namespace: str, service: str, remote: int, local: int):
    """Hold an `oc port-forward` open, and wait until it actually accepts.

    Backgrounding the forward by hand and running straight into it is a race:
    the shell reports the job started, the forward is not yet listening, and
    the first request dies on ECONNREFUSED. Waiting for the socket removes the
    race rather than documenting it.
    """
    oc = _oc()
    if not oc:
        raise SystemExit("oc/kubectl not on PATH, needed for --port-forward")
    try:
        with socket.create_connection(("127.0.0.1", local), timeout=0.5):
            raise SystemExit(
                f"127.0.0.1:{local} is already in use — probably a port-forward "
                f"left over from an earlier run. That is not harmless: it may "
                f"point at a different service and return plausible but wrong "
                f"data. Close it (pkill -f 'port-forward.*{local}') or pass "
                f"--local-port.")
    except OSError:
        pass
    proc = subprocess.Popen(
        [oc, "port-forward", "-n", namespace, f"svc/{service}", f"{local}:{remote}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        deadline = time.time() + 25
        ready = False
        while time.time() < deadline:
            if proc.poll() is not None:
                err = (proc.stderr.read() or b"").decode().strip()[:400]
                raise SystemExit(f"port-forward exited: {err or 'no output'}")
            try:
                with socket.create_connection(("127.0.0.1", local), timeout=0.5):
                    ready = True
                    break
            except OSError:
                time.sleep(0.4)
        if not ready:
            raise SystemExit(
                f"port-forward to svc/{service} did not start listening on "
                f"127.0.0.1:{local} within 25s")
        yield
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.SubprocessError:
            proc.kill()


def _get(url: str) -> dict:
    ctx = ssl.create_default_context()
    # The Tempo gateway serves a cluster-signed certificate. In-cluster the
    # service CA is trusted; over a port-forward the hostname is 127.0.0.1 and
    # never matches, so verification cannot succeed either way without pinning
    # the bundle. This path is a read of our own telemetry, so it is not worth
    # a CA plumbing exercise - but it is why this must not be reused for
    # anything that carries a credential outward.
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {_token()}"})
    with urllib.request.urlopen(req, timeout=30, context=ctx) as resp:
        return json.loads(resp.read().decode())


def fetch_trace(base: str, trace_id: str) -> dict:
    return _get(f"{base.rstrip('/')}/api/traces/{trace_id}")


def find_slowest(base: str, service: str, min_ms: int, lookback_s: int) -> str | None:
    import time
    now = int(time.time())
    q = f'{{ resource.service.name = "{service}"'
    if min_ms:
        q += f" && trace:duration > {min_ms}ms"
    q += " }"
    url = (f"{base.rstrip('/')}/api/search?"
           + urllib.parse.urlencode({"q": q, "limit": 50,
                                     "start": now - lookback_s, "end": now}))
    traces = _get(url).get("traces") or []
    best, best_ms = None, -1.0
    for t in traces:
        try:
            ms = float(t.get("durationMs") or 0)
        except (TypeError, ValueError):
            ms = 0.0
        tid = t.get("traceID") or t.get("traceId")
        if tid and ms > best_ms:
            best, best_ms = tid, ms
    return best


def main() -> int:
    p = argparse.ArgumentParser(description="Compute a trace's diagnosis.")
    src = p.add_mutually_exclusive_group()
    src.add_argument("--file", help="trace JSON on disk ('-' for stdin)")
    src.add_argument("--trace-id", help="fetch this id from TEMPO_BASE")
    src.add_argument("--slowest", action="store_true",
                     help="search TEMPO_BASE for the slowest recent trace")
    p.add_argument("--service", default="checkoutservice", help="with --slowest")
    p.add_argument("--min-ms", type=int, default=250, help="with --slowest")
    p.add_argument("--lookback", type=int, default=900,
                   help="with --slowest, seconds (default 900)")
    p.add_argument("--tempo-base", default=os.environ.get("TEMPO_BASE", ""))
    p.add_argument("--baseline-ms", type=float, default=None)
    p.add_argument("--json", action="store_true")
    # Local convenience. In-cluster (the MCP wrapper) TEMPO_BASE points at the
    # service and none of this is used.
    p.add_argument("--namespace", default="tracing-system")
    p.add_argument("--tempo-service", default="tempo-tempo-gateway")
    p.add_argument("--tenant", default="dev")
    p.add_argument("--local-port", type=int, default=18080)
    p.add_argument("--port-forward", action="store_true",
                   help="open an oc port-forward to Tempo for this run "
                        "(default when no --tempo-base/$TEMPO_BASE is set)")
    args = p.parse_args()

    if args.trace_id or args.slowest:
        forward = args.port_forward or not args.tempo_base
        base = args.tempo_base or (
            f"https://127.0.0.1:{args.local_port}"
            f"/api/traces/v1/{args.tenant}/tempo")

        def run() -> dict:
            tid = args.trace_id
            if args.slowest:
                tid = find_slowest(base, args.service, args.min_ms, args.lookback)
                if not tid:
                    raise SystemExit(
                        f"no trace over {args.min_ms}ms for {args.service} in "
                        f"the last {args.lookback}s")
                print(f"# trace {tid}", file=sys.stderr)
            return fetch_trace(base, tid)

        if forward:
            with port_forward(args.namespace, args.tempo_service, 8080,
                              args.local_port):
                doc = run()
        else:
            doc = run()
    else:
        fh = sys.stdin if (not args.file or args.file == "-") else open(args.file)
        doc = json.load(fh)

    result = analyse(parse_trace(doc), args.baseline_ms)
    print(json.dumps(result, indent=2) if args.json else render(result))
    return 0 if "error" not in result else 1


if __name__ == "__main__":
    sys.exit(main())
