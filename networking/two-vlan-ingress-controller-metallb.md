# OpenShift Dual-VLAN Ingress with MetalLB

This repository contains the complete configuration for a high-availability, dual-VLAN ingress architecture on bare-metal OpenShift. It utilizes **MetalLB** for LoadBalancer VIPs and **NMState** for host-level networking and kernel tuning.

---

## 1. Install and Initialize Operators
Install the **NMState** and **MetalLB** Operators from the OpenShift OperatorHub. Once installed, apply this manifest to initialize the required background daemons:

```yaml
cat <<EOF > 01-init.yaml
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
---
apiVersion: metallb.io/v1beta1
kind: MetalLB
metadata:
  name: metallb
  namespace: metallb-system
EOF
```
## 2. Node Network Configuration (NMState)
Configure physical VLAN interfaces on the worker nodes. Note: `forwarding: true` is required to allow the Linux kernel to pass traffic from the secondary VLAN interface into the OpenShift SDN.

- Worker 1 Policy
```yaml
# 02-nncp-worker1.yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: vlan-static-worker1
spec:
  nodeSelector:
    kubernetes.io/hostname: "worker1"
  desiredState:
    interfaces:
      - name: enp7s0.10
        type: vlan
        state: up
        vlan: 
          base-iface: enp7s0
          id: 10
        ipv4:
          enabled: true
          dhcp: false
          forwarding: true
          address: 
            - ip: 192.168.10.11
              prefix-length: 24
      - name: enp7s0.20
        type: vlan
        state: up
        vlan: 
          base-iface: enp7s0
          id: 20
        ipv4:
          enabled: true
          dhcp: false
          forwarding: true
          address: 
            - ip: 192.168.20.11
              prefix-length: 24
```

- Worker 2 Policy
```yaml
# 02-nncp-worker2.yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: vlan-static-worker2
spec:
  nodeSelector:
    kubernetes.io/hostname: "worker2"
  desiredState:
    interfaces:
      - name: enp7s0.10
        type: vlan
        state: up
        vlan: 
          base-iface: enp7s0
          id: 10
        ipv4:
          enabled: true
          dhcp: false
          forwarding: true
          address: 
            - ip: 192.168.10.12
              prefix-length: 24
      - name: enp7s0.20
        type: vlan
        state: up
        vlan: 
          base-iface: enp7s0
          id: 20
        ipv4:
          enabled: true
          dhcp: false
          forwarding: true
          address: 
            - ip: 192.168.20.12
              prefix-length: 24
```

## 3. MetalLB LoadBalancer Configuration
Define the virtual IP pools and L2 advertisements. The nodeSelectors ensure MetalLB only announces VIPs from nodes physically connected to the VLAN trunk.

- For VLAN 10

```yaml
# 03-metallb-config.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: vlan-10-pool
  namespace: metallb-system
spec:
  addresses: ["192.168.10.100-192.168.10.100"]
  autoAssign: true
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: vlan-10-adv
  namespace: metallb-system
spec:
  ipAddressPools: 
    - vlan-10-pool
  interfaces: 
    - enp7s0.10
  nodeSelectors: 
    - matchLabels: 
        node-role.kubernetes.io/ingress: ""
```

- For VLAN 20

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: vlan-20-pool
  namespace: metallb-system
spec:
  addresses: ["192.168.20.100-192.168.20.100"]
  autoAssign: true
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: vlan-20-adv
  namespace: metallb-system
spec:
  ipAddressPools: 
    - vlan-20-pool
  interfaces: 
    - enp7s0.20
  nodeSelectors: 
    - matchLabels: 
        node-role.kubernetes.io/ingress: ""
```

## 4. Ingress Controller Sharding
Deploy custom Ingress Controllers. We use podAntiAffinity to ensure one router pod exists on every ingress node to prevent traffic hangs under the Local traffic policy.

- VLAN 10 Ingress Controller.
```yaml
# 04-ingress-vlan10.yaml
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: ingress-vlan-10
  namespace: openshift-ingress-operator
spec:
  domain: vlan10.apps.redhat.local
  replicas: 2
  endpointPublishingStrategy:
    type: LoadBalancerService
  nodePlacement:
    nodeSelector:
      matchLabels: 
        node-role.kubernetes.io/ingress: ""
  routeSelector:
    matchLabels: 
      network: vlan-10
```

- VLAN 20 Ingress Controller.
```yaml
# 04-ingress-vlan20.yaml
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: ingress-vlan-20
  namespace: openshift-ingress-operator
spec:
  domain: vlan20.apps.redhat.local
  replicas: 2
  endpointPublishingStrategy:
    type: LoadBalancerService
  nodePlacement:
    nodeSelector:
      matchLabels: 
        node-role.kubernetes.io/ingress: ""
  routeSelector:
    matchLabels: 
      network: vlan-20
```

## 5. Post-Deployment Fixes (The "Trinity")
The following manual steps are required to stabilize the routing path and prevent the Operator from reverting critical changes.

1. Shard Default Controller
Prevent the default ingress controller from intercepting VLAN routes:

```bash
oc patch ingresscontroller default -n openshift-ingress-operator --type=merge -p '{"spec":{"routeSelector":{"matchExpressions":[{"key":"network","operator":"NotIn","values":["vlan-10","vlan-20"]}]}}}'
```

2. Lock Management State
Set VLAN controllers to Unmanaged to preserve externalTrafficPolicy settings:

```bash
oc patch ingresscontroller ingress-vlan-10 -n openshift-ingress-operator --type=merge -p '{"spec":{"managementState":"Unmanaged"}}'
oc patch ingresscontroller ingress-vlan-20 -n openshift-ingress-operator --type=merge -p '{"spec":{"managementState":"Unmanaged"}}'
```

3. Force Cluster Traffic Policy
Update the generated Services to ensure the TCP handshake succeeds across nodes:

```bash
oc patch svc router-ingress-vlan-10 -n openshift-ingress -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
oc patch svc router-ingress-vlan-20 -n openshift-ingress -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
```

4. Enable Loose Reverse Path Filtering
Allow asymmetric routing. Run on all ingress nodes via oc debug node:

```bash
sysctl -w net.ipv4.conf.all.rp_filter=2
```

## 6. Testing Commands
Deploy Sample App & Create Route:

1. Create a test project and app
```bash
oc new-project antigravity-test
oc new-app --docker-image=openshift/hello-openshift
```

2. Create route and label it for the VLAN 10 shard
```bash
oc create route edge hello-vlan10 --service=hello-openshift --hostname=hello.vlan10.apps.redhat.local
oc label route hello-vlan10 network=vlan-10
```

3. Verify Connectivity from External RHEL Host:

```bash
# 1. Test ARP (L2)
arping -I eth1.10 192.168.10.100

# 2. Test Connection (L4/L7)
curl -v -k --resolve hello.vlan10.apps.redhat.local:443:192.168.10.100 https://hello.vlan10.apps.redhat.local
```