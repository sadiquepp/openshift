# AZ Failure Resilience Test

Manifests proving an application survives the loss of one AWS Availability Zone:
9 replicas spread 3/3/3 across three AZs, rescheduled onto the survivors when a
zone dies, with workers auto-scaled if the survivors are full, and rebalanced
back to 3/3/3 when the zone returns.

**The full runbook — design rationale, deploy steps, three AZ-failure simulation
methods with their trade-offs, expected timeline, verification and
troubleshooting — is in [resilience-testing.md](resilience-testing.md).**

Quick start, against a three-AZ cluster built from
[`aws/self-managed/connected`](../README.md):

```bash
INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
sed -i "s/<infra-id>/${INFRA_ID}/g" 06-machineautoscaler.yaml 07-machinehealthcheck.yaml

oc apply -f 01-namespace.yaml -f 02-deployment.yaml -f 03-service-route.yaml -f 04-pdb.yaml
oc apply -f 05-clusterautoscaler.yaml -f 06-machineautoscaler.yaml -f 07-machinehealthcheck.yaml
oc apply -f 08-descheduler-operator.yaml
oc get csv -n openshift-kube-descheduler-operator -w   # wait for Succeeded
oc apply -f 09-kubedescheduler.yaml

./simulate/verify-spread.sh    # confirm the 3/3/3 baseline
```

Substitute `<infra-id>`, `<vpc-id>`, `<account-id>` and the `us-east-1a/b/c`
zone names before applying.
