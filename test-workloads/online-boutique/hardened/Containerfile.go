# Online Boutique Go services on Red Hat Hardened Images.
#
# Covers frontend, productcatalogservice, checkoutservice and shippingservice.
# Build context is the service's own directory in an upstream microservices-demo
# checkout (src/<service>), exactly like upstream's own Dockerfile.
#
# These four are the easy ones: upstream already builds with CGO_ENABLED=0, so
# the result is a static binary with no libc dependency at all. Nothing about it
# cares that the build moved from Alpine/musl to a glibc-based hardened image.

ARG BUILDER=registry.access.redhat.com/hi/go:latest-builder
# The runtime stage only has to hold a static binary, so this is hi/static --
# the hardened counterpart of the gcr.io/distroless/static that upstream's own
# Dockerfile uses here. NOT hi/go:latest, which works but carries the Go
# toolchain. ubi-micro or scratch also work; these services speak plaintext
# gRPC in-cluster and need neither a CA bundle nor tzdata.
ARG RUNTIME=registry.access.redhat.com/hi/static:latest

FROM ${BUILDER} AS builder
# The -builder variants run as a non-root user, and a directory created by
# WORKDIR is owned by root, so an unprivileged RUN cannot write into it --
# installs, dnf, chmod and the compiler all fail with EACCES. Build stages
# therefore run as root. Nothing from this stage ships: the runtime stage below
# keeps its base image's non-root user, and OpenShift assigns its own UID from
# the namespace range regardless.
USER 0
WORKDIR /src
COPY . ./
RUN go mod download \
 && CGO_ENABLED=0 go build -ldflags="-s -w" -o /out/server .
# frontend ships templates/ and static/, productcatalogservice ships
# products.json; checkoutservice and shippingservice ship neither. Copy whatever
# is there rather than keeping four near-identical Containerfiles.
RUN for extra in templates static products.json; do \
      if [ -e "$extra" ]; then cp -r "$extra" /out/; fi; \
    done \
 && chmod -R a+rX /out

FROM ${RUNTIME}
WORKDIR /app
COPY --from=builder /out/ /app/
ENV GOTRACEBACK=single
ENTRYPOINT ["/app/server"]
