## Adding Security while deploying from Hive/ACM for Spoke Cluster API NLB
When deploying OpenShift on AWS using openshift-install, an additional security group for the API Network Load Balancer (NLB) can be incorporated by following the steps outlined in [this doc](https://github.com/sadiquepp/openshift/blob/main/aws/docs/security-group-nlb.md) The question is how to achieve the equivalent configuration during a deployment managed by ACM/Hive.


## Step1: Add reference to ClusterDeployment Customization
Update `ClusterDeployment.spec.provisioning.customizationRef` with the reference to the customization

```yaml
  provisioning:
    customizationRef:
      name: api-lb-sg
```

## Add Customizations
Subsequently, scroll down to the end of the YAML file and append additional YAML entries to specify the customizaiton ro add dditional Security Group ID for API Network Load Balancer.

```yaml
---
apiVersion: hive.openshift.io/v1
kind: ClusterDeploymentCustomization
metadata:
  name: api-lb-sg
  namespace: cluster1
spec:
  installerManifestPatches:
    - manifestSelector:
        glob: cluster-api/02_infra-cluster.yaml
      patches:
        - op: add
          path: /spec/controlPlaneLoadBalancer/additionalSecurityGroups
          valueJSON: "[]"
        - op: add
          path: /spec/controlPlaneLoadBalancer/additionalSecurityGroups/-
          valueJSON: '"sg-0cc571fe1ac5fe77f"'
```
The security group identifier in the final line must be replaced with the specific value applicable to your environment.
