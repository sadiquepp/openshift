# OpenShift Service Mesh 3

The same walkthrough built two ways: Online Boutique in an Istio mesh, from install to
mTLS to L4 and L7 authorization policy.

| | [`ambient/`](ambient) | [`sidecar/`](sidecar) |
|---|---|---|
| Data plane | ztunnel per node (L4), plus a waypoint Envoy per namespace where you need L7 | An Envoy container in every pod |
| App namespace | `online-boutique` | `online-boutique-sidecar` |
| OpenShift | 4.19+, OVN local gateway mode, no FIPS | 4.19+ as written (4.18 with Gateway API CRDs), FIPS supported |
| Service Mesh | 3.2+ | 3.0+ |
| Explains | [How ambient differs from sidecar](ambient/README.md#how-ambient-differs-from-sidecar-mode), [how ztunnel works](ambient/README.md#how-ztunnel-works) | [How the sidecar works](sidecar/README.md#how-the-sidecar-works), [side-by-side comparison](sidecar/README.md#6-compare-the-two) |

**To compare both on one cluster,** install the ambient mesh (`ambient/01` to `05`),
then deploy both overlays. An ambient-profile istiod also injects sidecars, so the
sidecar overlay needs no second control plane. Do not apply `sidecar/03-istio.yaml` on
top of an ambient install, because it is the same `Istio/default` resource.

**For only one of them,** use that directory alone. Each README is self-contained.
