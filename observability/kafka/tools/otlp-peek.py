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


def show_traces(payload):
    req = ExportTraceServiceRequest()
    req.ParseFromString(payload)
    n = 0
    for rs in req.resource_spans:
        svc = attr(rs.resource.attributes, "service.name") or "<no service.name>"
        ns = attr(rs.resource.attributes, "k8s.namespace.name")
        pod = attr(rs.resource.attributes, "k8s.pod.name")
        print(f"  resource: service.name={svc}"
              + (f"  k8s={ns}/{pod}" if ns or pod else "   [!] no k8s.* - k8sattributes not applied"))
        for ss in rs.scope_spans:
            for sp in ss.spans:
                n += 1
                ms = (sp.end_time_unix_nano - sp.start_time_unix_nano) / 1e6
                print(f"    {sp.name:<34} trace={sp.trace_id.hex()} "
                      f"span={sp.span_id.hex()} parent={sp.parent_span_id.hex() or '-':<16} "
                      f"kind={sp.kind} {ms:.1f}ms")
    return n


def show_metrics(payload):
    req = ExportMetricsServiceRequest()
    req.ParseFromString(payload)
    n = 0
    for rm in req.resource_metrics:
        svc = attr(rm.resource.attributes, "service.name") or "<no service.name>"
        names = [m.name for sm in rm.scope_metrics for m in sm.metrics]
        n += len(names)
        print(f"  resource: service.name={svc}  ({len(names)} metrics)")
        for name in sorted(set(names))[:10]:
            print(f"    {name}")
        if len(set(names)) > 10:
            print(f"    ... and {len(set(names)) - 10} more")
    return n


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--bootstrap", required=True, help="host:port, comma separated")
    p.add_argument("--topic", required=True)
    p.add_argument("--max", type=int, default=1, help="records to read")
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

    decode = show_metrics if "metric" in args.topic else show_traces
    seen = 0
    for msg in consumer:
        seen += 1
        print(f"record {seen}: partition {msg.partition} offset {msg.offset} "
              f"{len(msg.value)} bytes")
        try:
            items = decode(msg.value)
            print(f"  -> {items} items in this batch")
        except Exception as e:
            print(f"  !! not valid OTLP protobuf: {e}", file=sys.stderr)
            print("     Is the topic encoded otlp_json rather than otlp_proto?", file=sys.stderr)
        if seen >= args.max:
            break
    if seen == 0:
        print(f"no records within {args.timeout}ms - topic empty, or wrong topic name",
              file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
