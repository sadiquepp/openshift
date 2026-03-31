# OpenShift Dual-VLAN Ingress with MetalLB

This repository contains the complete configuration for a high-availability, dual-VLAN ingress architecture on bare-metal OpenShift. It utilizes **MetalLB** for LoadBalancer VIPs and **NMState** for host-level networking and kernel tuning.

---
## 1. Label your Ingress Nodes

```bash
oc label node worker1 node-role.kubernetes.io/ingress=""
oc label node worker2 node-role.kubernetes.io/ingress=""
```

## 2. Install and Initialize Operators
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
- Apply it
```bash
oc apply -f 01-init.yaml
```

## 3. Node Network Configuration (NMState)
Configure physical VLAN interfaces on the worker nodes.

- Worker 1 Policy
```yaml
cat <<EOF > 02-nncp-worker1.yaml
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
          address: 
            - ip: 192.168.20.11
              prefix-length: 24
EOF
```
- Apply it
```bash
oc apply -f 02-nncp-worker1.yaml
```
- Worker 2 Policy
```yaml
cat <<EOF > 03-nncp-worker2.yaml
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
          address: 
            - ip: 192.168.20.12
              prefix-length: 24
EOF
```
- Apply it
```bash
oc apply -f 03-nncp-worker2.yaml
```
## 4. Apply Tuned Profile to enable ip_forarding, rp_Filter    

```yaml
cat <<EOF > 04-tuned.yaml
apiVersion: tuned.openshift.io/v1
kind: Tuned
metadata:
  name: ingress-kernel-tuning
  namespace: openshift-cluster-node-tuning-operator
spec:
  profile:
  - name: ingress-forwarding
    data: |
      [sysctl]
      net.ipv4.ip_forward=1
      net.ipv4.conf.all.forwarding=1
      net.ipv4.conf.all.rp_filter=2
  recommend:
  - priority: 20
    profile: ingress-forwarding
    operand:
      nodeSelector:
        node-role.kubernetes.io/ingress: ""
EOF
```
- Apply it
```bash
oc apply -f 04-tuned.yaml
```

## 5. MetalLB LoadBalancer Configuration
Define the virtual IP pools and L2 advertisements. The nodeSelectors ensure MetalLB only announces VIPs from nodes physically connected to the VLAN trunk.

- For VLAN 10

```yaml
cat <<EOF > 04-metallb-config.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: vlan-10-pool
  namespace: metallb-system
spec:
  addresses: ["192.168.10.100-192.168.10.105"]
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
EOF
```
- Apply it
```bash
oc apply -f 05-metallb-config.yaml
```
- For VLAN 20

```yaml
cat <<EOF > 06-metallb-config.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: vlan-20-pool
  namespace: metallb-system
spec:
  addresses: ["192.168.20.100-192.168.20.105"]
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
EOF
```
- Apply it
```bash
oc apply -f 06-metallb-config.yaml
```
## 6. Ingress Controller Sharding
Deploy custom Ingress Controllers. We use podAntiAffinity to ensure one router pod exists on every ingress node to prevent traffic hangs under the Local traffic policy.

- VLAN 10 Ingress Controller.
```yaml
cat <<EOF > 06-ingress-vlan10.yaml
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: ingress-vlan-10
  namespace: openshift-ingress-operator
spec:
  domain: vlan10.apps.redhat.local
  replicas: 2
  endpointPublishingStrategy:
    type: Private
  nodePlacement:
    nodeSelector:
      matchLabels: 
        node-role.kubernetes.io/ingress: ""
  routeSelector:
    matchLabels: 
      network: vlan-10
EOF
```
- Apply it
```bash
oc apply -f 07-ingress-vlan10.yaml
```
- Create service manually.
```yaml
cat <<EOF > 08-ingress-vlan10-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: manual-vlan-10-ingress
  namespace: openshift-ingress
  annotations:
    metallb.universe.tf/address-pool: vlan-10-pool
    metallb.universe.tf/loadBalancerIPs: 192.168.10.100
spec:
  type: LoadBalancer
  externalTrafficPolicy: Cluster
  selector:
    ingresscontroller.operator.openshift.io/deployment-ingresscontroller: ingress-vlan-10
  ports:
  - name: http
    protocol: TCP
    port: 80
    targetPort: 80
  - name: https
    protocol: TCP
    port: 443
    targetPort: 443
EOF
```
- Apply it
```bash
oc apply -f 08-ingress-vlan10-service.yaml
```
- VLAN 20 Ingress Controller.
```yaml
cat <<EOF > 08-ingress-vlan20.yaml
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: ingress-vlan-20
  namespace: openshift-ingress-operator
spec:
  domain: vlan20.apps.redhat.local
  replicas: 2
  endpointPublishingStrategy:
    type: Private
  nodePlacement:
    nodeSelector:
      matchLabels: 
        node-role.kubernetes.io/ingress: ""
  routeSelector:
    matchLabels: 
      network: vlan-20
EOF
```
- Apply it
```bash
oc apply -f 08-ingress-vlan20.yaml
```
- Create service manually.
```yaml
cat <<EOF > 09-ingress-vlan20-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: manual-vlan-20-ingress
  namespace: openshift-ingress
  annotations:
    metallb.universe.tf/address-pool: vlan-20-pool
    metallb.universe.tf/loadBalancerIPs: 192.168.20.100
spec:
  type: LoadBalancer
  externalTrafficPolicy: Cluster
  selector:
    ingresscontroller.operator.openshift.io/deployment-ingresscontroller: ingress-vlan-20
  ports:
  - name: http
    protocol: TCP
    port: 80
    targetPort: 80
  - name: https
    protocol: TCP
    port: 443
    targetPort: 443
EOF
```
- Apply it
```bash
oc apply -f 09-ingress-vlan20-service.yaml
```
## 7. Post-Deployment Fixes (The "Trinity")
The following manual steps are required to stabilize the routing path and prevent the Operator from reverting critical changes.

1. Shard Default Controller
Prevent the default ingress controller from intercepting VLAN routes:

```bash
oc patch ingresscontroller default -n openshift-ingress-operator --type=merge -p '{"spec":{"routeSelector":{"matchExpressions":[{"key":"network","operator":"NotIn","values":["vlan-10","vlan-20"]}]}}}'
```
## 8. Testing Commands
Deploy Sample App & Create Route:

1. Create a test project and app
```bash
oc new-project vlan10
```

2. Create test hello-openshift application.
```yaml
cat <<EOF > 09-hello-openshift.yaml
apiVersion: v1
kind: Pod
metadata:
  name: hello-openshift
  namespace: vlan10
  labels:
    app: hello-openshift
spec:
  containers:
    - name: hello-openshift
      image: quay.io/openshift/origin-hello-openshift
      ports:
        - containerPort: 8888
      securityContext:
        privileged: false
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        runAsUser: 1001
        capabilities:
          drop:
            - ALL
        seccompProfile:
          type: RuntimeDefault
---
kind: Service
apiVersion: v1
metadata:
  name: hello-openshift-service
  namespace: vlan10
  labels:
    app: hello-openshift
spec:
  selector:
    app: hello-openshift
  ports:
    - port: 8888
EOF
```
- Apply it
```bash
oc apply -f 09-hello-openshift.yaml
```

3. Create route and label it for the VLAN 10 shard
```yaml
cat <<EOF > 10-hello-openshift-route.yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: hello-openshift
  namespace: vlan10
  labels:
    network: vlan-10
spec:
  host: hello-openshift.vlan10.apps.redhat.local
  to:
    kind: Service
    name: hello-openshift-service
  tls:
    termination: edge
EOF
```
- Apply it
```bash
oc apply -f 10-hello-openshift-route.yaml
```

4. Verify Connectivity from External RHEL Host:

```bash
# 1. Test ARP (L2)
arping -I eth1.10 192.168.10.100

# 2. Test Connection (L4/L7)
curl -v -k --resolve hello.vlan10.apps.redhat.local:443:192.168.10.100 https://hello.vlan10.apps.redhat.local
```