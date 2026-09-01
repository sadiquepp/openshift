#!/usr/bin/env python3
"""Decode OTLP protobuf records from a Kafka topic.

    pip install opentelemetry-proto kafka-python
    python3 otlp_peek.py --topic otlp-traces --bootstrap kafka-1.example.com:9093 \
        --tls --ca ./kafka-ca.crt --sasl-user observability

Reads $KAFKA_PASSWORD for the SASL password.
"""
import argparse, os, sys
from kafka import KafkaConsumer
from opentelemetry.proto.collector.trace.v1.trace_service_pb2 import ExportTraceServiceRequest
from opentelemetry.proto.collector.metrics.v1.metrics_service_pb2 import ExportMetricsServiceRequest


def attr(kvs, key):
    """Pull one attribute out of an OTLP KeyValue list."""
    for kv in kvs:
        if kv.key == key:
            v = kv.value
            return v.string_value or (str(v.int_value) if v.HasField("int_value") else "")
    return ""


SPAN_KIND = {0: "UNSPECIFIED", 1: "INTERNAL", 2: "SERVER", 3: "CLIENT",
             4: "PRODUCER", 5: "CONSUMER"}
STATUS = {0: "UNSET", 1: "OK", 2: "ERROR"}


def anyvalue(v):
    """Render an OTLP AnyValue as a plain Python value."""
    which = v.WhichOneof("value")
    if which is None:
        return None
    if which == "array_value":
        return [anyvalue(x) for x in v.array_value.values]
    if which == "kvlist_value":
        return {kv.key: anyvalue(kv.value) for kv in v.kvlist_value.values}
    if which == "bytes_value":
        return v.bytes_value.hex()
    return getattr(v, which)


def all_attrs(kvs):
    return {kv.key: anyvalue(kv.value) for kv in kvs}


def ms(span):
    return (span.end_time_unix_nano - span.start_time_unix_nano) / 1e6


def detail_lines(span, indent):
    """The fields NOT already on a summary or tree line."""
    out = [f"{indent}span={span.span_id.hex()} parent={span.parent_span_id.hex() or '-'}"]
    if span.status.code or span.status.message:
        out.append(f"{indent}status={STATUS.get(span.status.code, span.status.code)}"
                   f"{'  ' + span.status.message if span.status.message else ''}")
    for k, v in all_attrs(span.attributes).items():
        out.append(f"{indent}attr {k} = {v}")
    for ev in span.events:
        out.append(f"{indent}event {ev.name} {all_attrs(ev.attributes) or ''}".rstrip())
    for ln in span.links:
        out.append(f"{indent}link trace={ln.trace_id.hex()} span={ln.span_id.hex()}")
    return out


def print_span_full(span, indent="    "):
    """Every field on a span, for the per-record view."""
    print(f"{indent}{span.name}")
    print(f"{indent}  kind={SPAN_KIND.get(span.kind, span.kind)}  {ms(span):.3f}ms")
    for line in detail_lines(span, indent + "  "):
        print(line)


def collect(payload, store, exclude=(), only_trace=None):
    """Parse one record and accumulate its spans into `store`, keyed by trace."""
    req = ExportTraceServiceRequest()
    req.ParseFromString(payload)
    n = 0
    for rs in req.resource_spans:
        ra = all_attrs(rs.resource.attributes)
        svc = ra.get("service.name", "<no service.name>")
        for ss in rs.scope_spans:
            for sp in ss.spans:
                if any(x in sp.name for x in exclude):
                    continue
                if only_trace and sp.trace_id.hex() != only_trace:
                    continue
                n += 1
                store.setdefault(sp.trace_id.hex(), []).append((svc, ra, ss.scope.name, sp))
    return n


def show_traces(payload, full=False, exclude=()):
    """Per-record view: what this one Kafka record contains."""
    req = ExportTraceServiceRequest()
    req.ParseFromString(payload)
    n = 0
    for rs in req.resource_spans:
        ra = all_attrs(rs.resource.attributes)
        svc = ra.get("service.name", "<no service.name>")
        k8s = [f"{k}={v}" for k, v in ra.items() if k.startswith("k8s.")]
        print(f"  resource: service.name={svc}"
              + (f"  {' '.join(k8s)}" if k8s
                 else "   [!] no k8s.* - k8sattributes not applied"))
        if full:
            for k, v in sorted(ra.items()):
                if k != "service.name" and not k.startswith("k8s."):
                    print(f"    resource-attr {k} = {v}")
        for ss in rs.scope_spans:
            if full and ss.scope.name:
                print(f"    scope: {ss.scope.name} {ss.scope.version}")
            for sp in ss.spans:
                if any(x in sp.name for x in exclude):
                    continue
                n += 1
                if full:
                    print_span_full(sp)
                else:
                    print(f"    {sp.name:<34} trace={sp.trace_id.hex()} "
                          f"span={sp.span_id.hex()} "
                          f"parent={sp.parent_span_id.hex() or '-':<16} "
                          f"kind={sp.kind} {ms(sp):.1f}ms")
    return n


def show_tree(store, min_spans=1, full=False):
    """Reassemble whole traces from every record read, largest first.

    This is the view that shows a distributed call: spans arrive in
    different batches, from different services, and are stitched back
    together by trace_id - which is exactly what a real backend does.
    """
    traces = sorted(store.items(), key=lambda kv: -len(kv[1]))
    shown = 0
    for tid, entries in traces:
        if len(entries) < min_spans:
            continue
        shown += 1
        spans = [(svc, sp) for svc, _ra, _sc, sp in entries]
        by_id = {sp.span_id.hex(): (svc, sp) for svc, sp in spans}
        services = sorted({svc for svc, _sp in spans})
        # Wall clock across the whole trace, not the longest single span.
        first = min(sp.start_time_unix_nano for _s, sp in spans)
        last = max(sp.end_time_unix_nano for _s, sp in spans)
        print(f"\ntrace {tid}  ({len(spans)} spans, {len(services)} service"
              f"{'s' if len(services) != 1 else ''}, {(last - first) / 1e6:.1f}ms)"
              f"  {', '.join(services)}")

        children, roots = {}, []
        for svc, sp in spans:
            parent = sp.parent_span_id.hex()
            if parent and parent in by_id:
                children.setdefault(parent, []).append((svc, sp))
            else:
                roots.append((svc, sp, bool(parent)))
        for lst in children.values():
            lst.sort(key=lambda x: x[1].start_time_unix_nano)
        roots.sort(key=lambda x: x[1].start_time_unix_nano)

        # A healthy trace has exactly one root. More than one means either the
        # parents were not among the records read, or the callers never
        # propagated context - and those two are told apart by whether the
        # orphans carry a parent_span_id at all.
        if len(roots) > 1:
            dangling = sum(1 for _s, _sp, had_parent in roots if had_parent)
            if dangling:
                print(f"  [!] {len(roots)} root spans, {dangling} of them naming a parent "
                      f"not in the records read - raise --max")
            else:
                print(f"  [!] {len(roots)} root spans, none with a parent: these share a "
                      f"trace_id but are not one call tree. Context propagation is "
                      f"incomplete upstream of {services[0] if len(services) == 1 else 'these services'}.")

        def walk(svc, sp, depth):
            print(f"  {'  ' * depth}{svc:<24} {sp.name:<52} "
                  f"{ms(sp):8.2f}ms  {SPAN_KIND.get(sp.kind, sp.kind)}")
            if full:
                for line in detail_lines(sp, "  " + "  " * depth + "    "):
                    print(line)
            for csvc, csp in children.get(sp.span_id.hex(), []):
                walk(csvc, csp, depth + 1)

        for svc, sp, _had in roots:
            walk(svc, sp, 0)
    return shown


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--bootstrap", required=True, help="host:port, comma separated")
    p.add_argument("--topic", required=True)
    p.add_argument("--max", type=int, default=1, help="Kafka records to read")
    p.add_argument("--full", action="store_true",
                   help="every field on each span: attributes, events, status, links")
    p.add_argument("--group", action="store_true",
                   help="reassemble whole traces across records, largest first")
    p.add_argument("--min-spans", type=int, default=1,
                   help="with --group, hide traces smaller than this")
    p.add_argument("--trace",
                   help="with --group, keep only this trace id. Use it to hunt "
                        "for the missing parents of a trace that came back as "
                        "several roots: raise --max and see whether the caller's "
                        "spans turn up in later records.")
    p.add_argument("--exclude", default="grpc.health.v1.Health/Check",
                   help="skip spans whose name contains any of these "
                        "(comma separated). Health probes are the default "
                        "because they are single-span traces that crowd out "
                        "real requests. Pass '' to keep everything.")
    p.add_argument("--timeout", type=int, default=20000, help="ms to wait for a record")
    p.add_argument("--tls", action="store_true")
    p.add_argument("--ca", help="PEM CA bundle for the broker")
    p.add_argument("--sasl-user")
    p.add_argument("--sasl-mechanism", default="SCRAM-SHA-512")
    args = p.parse_args()

    kw = {}
    if args.tls and args.sasl_user:
        kw["security_protocol"] = "SASL_SSL"
    elif args.tls:
        kw["security_protocol"] = "SSL"
    elif args.sasl_user:
        kw["security_protocol"] = "SASL_PLAINTEXT"
    if args.tls and args.ca:
        kw["ssl_cafile"] = args.ca
    if args.sasl_user:
        kw["sasl_mechanism"] = args.sasl_mechanism
        kw["sasl_plain_username"] = args.sasl_user
        kw["sasl_plain_password"] = os.environ["KAFKA_PASSWORD"]

    consumer = KafkaConsumer(
        args.topic,
        bootstrap_servers=args.bootstrap.split(","),
        auto_offset_reset="earliest",
        # WITHOUT THIS THE LOOP NEVER ENDS: kafka-python defaults
        # consumer_timeout_ms to inf, so `for msg in consumer` blocks forever
        # once the topic is drained rather than returning.
        consumer_timeout_ms=args.timeout,
        # No group_id: read without joining a consumer group, so this never
        # commits offsets and cannot disturb a real consumer of the same topic.
        group_id=None,
        **kw,
    )

    exclude = tuple(x for x in args.exclude.split(",") if x)
    is_metrics = "metric" in args.topic
    store, seen, items = {}, 0, 0
    for msg in consumer:
        seen += 1
        try:
            if is_metrics:
                print(f"record {seen}: partition {msg.partition} offset {msg.offset} "
                      f"{len(msg.value)} bytes")
                items += show_metrics(msg.value)
            elif args.group:
                items += collect(msg.value, store, exclude, args.trace)
            else:
                print(f"record {seen}: partition {msg.partition} offset {msg.offset} "
                      f"{len(msg.value)} bytes")
                items += show_traces(msg.value, full=args.full, exclude=exclude)
        except Exception as e:
            print(f"  !! record {seen} is not valid OTLP protobuf: {e}", file=sys.stderr)
            print("     Is the topic encoded otlp_json rather than otlp_proto?",
                  file=sys.stderr)
        if seen >= args.max:
            break

    if seen == 0:
        print(f"no records within {args.timeout}ms - topic empty, or wrong topic name",
              file=sys.stderr)
        sys.exit(1)

    if args.group:
        shown = show_tree(store, min_spans=args.min_spans, full=args.full)
        print(f"\n{seen} records -> {items} spans in {len(store)} traces; "
              f"{shown} with >= {args.min_spans} spans")
        if shown == 0:
            print("Nothing that big. Raise --max to read more records, or lower "
                  "--min-spans.", file=sys.stderr)
    else:
        print(f"\n{seen} records -> {items} items")
    return

if __name__ == "__main__":
    main()
