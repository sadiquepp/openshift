## Additional Configuration: Security Group for API NLB
The addition of a new Security Group for the API NLB is not directly supported through `install-config.yaml`. This configuration must be incorporated into the manifest prior to the cluster deployment. 

Follow these subsequent steps to inject the configuration:

Create a directory and copy the install config into it:
```bash
mkdir install-dir
cp install-config.yaml install-dir/
```

Generate the manifests:
```bash
openshift-install create manifests --dir install-dir
```

Modify `install-dir/cluster-api/02_infra-cluster.yaml` and include the security group identifiers under `spec.controlPlaneLoadBalancer` utilizing `additionalSecurityGroups`:

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: AWSCluster
metadata:
  creationTimestamp: null
  name: on1-xt1-5fxqv
  namespace: openshift-cluster-api-guests
spec:
  additionalTags:
    kubernetes.io/cluster/on1-xt1-5fxqv: owned
  bastion:
    enabled: false
  controlPlaneEndpoint:
    host:
    port: 0
  controlPlaneLoadBalancer:
    additionalSecurityGroups:
    - sg-0c536a73fde8d0cd6
    additionalListeners:
    - healthCheck:
```

Copy any other STS manifests to the relevant directories, and then create the cluster:
```bash
openshift-install create cluster --dir install-dir --log-level debug
```