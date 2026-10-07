# Online Boutique adservice (Java/gRPC, Gradle) on Red Hat Hardened Images.
# Build context is src/adservice in an upstream checkout.
#
# Two things change relative to upstream, both because the runtime image is
# distroless:
#
# 1. Upstream's entrypoint is /app/build/install/hipstershop/bin/AdService, the
#    launcher SHELL SCRIPT that Gradle's installDist generates. There is no
#    /bin/sh in the runtime image, so the JVM is invoked directly instead. The
#    main class comes from build.gradle (mainClass.set('hipstershop.AdService')).
#    java expands the /app/lib/* classpath wildcard itself -- no shell involved.
# 2. Only the jars are carried over, not build/install's bin/ directory.
#
# The build stage needs network access: ./gradlew downloadRepos fetches the
# dependency jars. That is a build-host concern, not a cluster one.

# JDK 21, not upstream's 24/25: build.gradle sets
#   sourceCompatibility = targetCompatibility = JavaVersion.VERSION_21
# so 21 is all this service needs, it is what UBI 9 ships (which keeps the
# cve-demo comparison fair), and an older JDK is the safer bet against the
# Gradle wrapper's supported-JDK range.
ARG BUILDER=registry.access.redhat.com/hi/openjdk:21-builder
ARG RUNTIME=registry.access.redhat.com/hi/openjdk:21

FROM ${BUILDER} AS builder
WORKDIR /app
COPY . ./
RUN chmod +x gradlew \
 && ./gradlew --no-daemon downloadRepos \
 && ./gradlew --no-daemon installDist \
 && chmod -R a+rX /app/build/install

FROM ${RUNTIME}
WORKDIR /app
COPY --from=builder /app/build/install/hipstershop/lib /app/lib
EXPOSE 9555
# readOnlyRootFilesystem is set on this container, so keep the JVM from trying to
# write /tmp/hsperfdata_<uid>. It only warns if it cannot, but silence is better.
ENTRYPOINT ["java", "-XX:-UsePerfData", "-cp", "/app/lib/*", "hipstershop.AdService"]
