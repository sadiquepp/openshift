- Set the Variables.
```bash
export AWS_REGION=ap-southeast-1
export CLUSTER_DOMAIN=upi.sadiqueonline.com
export CLUSTER_NAME=cluster1
export VPC_CIDR=172.16.1.0/16
export SUBNET_ID_AZ1=
export SUBNET_ID_AZ2=
export SUBNET_ID_AZ3=
export REGISTRY_URL=mirror.hub.mylab.com
export REGISTRY_PORT=8443
export REGISTRY_PASSWORD_BASE64=""
```
- Generate install-config.yaml. Update certificate at the end.
```bash
cat <<EOF > install-config.yaml
apiVersion: v1
baseDomain: ${CLUSTER_DOMAIN}
credentialsMode: Manual
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform: {}
  replicas: 3
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform: {}
  replicas: 3
metadata:
  creationTimestamp: null
  name: ${CLUSTER_NAME}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: ${VPC_CIDR}
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  aws:
    region: ${AWS_REGION}
    subnets: 
    - ${SUBNET_ID_AZ1}
    - ${SUBNET_ID_AZ2}
    - ${SUBNET_ID_AZ3}
    serviceEndpoints:
      - name: sts
        url: https://sts.${AWS_REGION}.amazonaws.com
publish: Internal
pullSecret: '{"auths":{"${REGISTRY_URL}:${REGISTRY_PORT}": {"auth": "${REGISTRY_PASSWORD_BASE64}"} }}'
imageDigestSources:
- mirrors:
  - ${REGISTRY_URL}:${REGISTRY_PORT}/openshift/release-images
  source: quay.io/openshift-release-dev/ocp-release
- mirrors:
  - ${REGISTRY_URL}:${REGISTRY_PORT}/openshift/release
  source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
sshKey: |
  ssh-rsa key
additionalTrustBundle: |
    -----BEGIN CERTIFICATE-----
    -----END CERTIFICATE-----
EOF
```
