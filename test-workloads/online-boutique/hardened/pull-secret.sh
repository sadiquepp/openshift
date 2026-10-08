#!/usr/bin/env bash
# Give a deployed namespace credentials to pull from your registry.
#
#   REGISTRY=registry.example.com:8443 \
#   REGISTRY_USER=robot REGISTRY_PASSWORD=... ./pull-secret.sh [namespace]
#
# Run this AFTER `oc apply -k`, not before. The ordering is not a style
# preference: the namespace and all twelve ServiceAccounts come from the
# manifests, so a secret created first has nowhere to live and nothing to link
# to -- `oc create secret -n online-boutique` simply fails with "namespaces
# not found". This script checks and says so rather than half-applying.
#
# It is idempotent: re-run it after adding a service, rotating a credential, or
# any apply that creates a new ServiceAccount, since linking only affects
# ServiceAccounts that exist at the time.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=registry.env
. ./registry.env

NS="${1:-$NAMESPACE}"
SECRET="${SECRET_NAME:-mirror-creds}"

[ -n "${REGISTRY:-}" ] || { echo "set REGISTRY (see registry.env)" >&2; exit 2; }
command -v oc >/dev/null || { echo "oc not on PATH" >&2; exit 2; }

# The namespace is the whole point of this check. Deploying first is cheap to
# say and expensive to discover.
if ! oc get namespace "$NS" >/dev/null 2>&1; then
  cat >&2 <<EOF
namespace "$NS" does not exist yet.

The manifests create it, along with the ServiceAccounts this secret has to be
linked to, so deploy first and then come back:

  cd ../overlays/hardened && oc apply -k .
  cd - && ./pull-secret.sh $NS

The pods will sit in ImagePullBackOff until then, which is expected and not a
sign the deploy failed.
EOF
  exit 1
fi

# Credentials from the environment, or prompted. Not from the command line:
# arguments are visible in the process list and land in shell history, and a
# registry password is exactly the thing not to leave in either.
if [ -z "${REGISTRY_USER:-}" ]; then
  if [ -t 0 ]; then read -r -p "registry username for $REGISTRY: " REGISTRY_USER
  else echo "set REGISTRY_USER" >&2; exit 2; fi
fi
if [ -z "${REGISTRY_PASSWORD:-}" ]; then
  if [ -t 0 ]; then read -r -s -p "registry password for $REGISTRY_USER: " REGISTRY_PASSWORD; echo
  else echo "set REGISTRY_PASSWORD" >&2; exit 2; fi
fi

# Replace rather than patch. `oc create --dry-run -o yaml | oc apply -f -` is
# the usual idempotency trick, but it renders the credential into a pipeline
# where any stray `set -x` or error trace would print it. Delete-then-create
# keeps the secret out of this script's output entirely.
if oc get secret "$SECRET" -n "$NS" >/dev/null 2>&1; then
  echo "==> replacing existing secret $SECRET in $NS"
  oc delete secret "$SECRET" -n "$NS" >/dev/null
fi
oc create secret docker-registry "$SECRET" -n "$NS" \
  --docker-server="$REGISTRY" \
  --docker-username="$REGISTRY_USER" \
  --docker-password="$REGISTRY_PASSWORD" >/dev/null
echo "==> created $SECRET in $NS for $REGISTRY"

# Discover the ServiceAccounts rather than hardcoding a count. The workload
# ships one per service today; a count baked in here would be wrong the first
# time anybody adds or removes one.
N=0
for sa in $(oc get sa -n "$NS" -o name); do
  oc secrets link "${sa#*/}" "$SECRET" --for=pull -n "$NS"
  N=$((N+1))
done
echo "==> linked to $N ServiceAccounts"

# Linking resolves at pod creation, so pods that already failed to pull keep
# failing -- the kubelet retries the pull, not the ServiceAccount lookup. The
# secret is useless until something recreates them, which is the step people
# miss and then conclude the credentials are wrong.
echo "==> restarting workloads so existing pods pick the secret up"
oc rollout restart deployment -n "$NS" >/dev/null 2>&1 \
  || echo "    (no deployments to restart yet)"
echo
echo "Watch them come up:"
echo "  oc get pods -n $NS -w"
