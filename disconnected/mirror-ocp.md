# OpenShift 4.20 Disconnected Installation: Mirroring with oc-mirror v2

This guide outlines the process for mirroring images for a disconnected installation of OpenShift Container Platform 4.20 using the `oc-mirror` plugin v2. 

### Assumptions
The bastion node possesses the necessary connectivity to the public internet for image retrieval and direct access to Enterprise Registry to push the images.

---

## Step 1: Download and Install OpenShift Tools
Retrieve the OpenShift CLI, the `oc-mirror` plugin, and the pull-secret directly from Red Hat's mirrors. 

Execute the following commands to download, extract, and configure the binaries globally:

```bash
# Download tools
wget https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/4.20.13/openshift-client-linux.tar.gz
wget https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/latest/oc-mirror.tar.gz

# Extract tools
tar -xvf openshift-client-linux.tar.gz
tar -xvf oc-mirror.tar.gz

# Move binaries to /usr/bin for global access
sudo cp oc oc-mirror /usr/bin/
sudo chmod 0755 /usr/bin/oc /usr/bin/oc-mirror
```

You must also get the pull secret from the Red Hat Console and save it in a file named `pull-secret.txt`.

---

## Step 2: Configure Container Authentication
Log in to your Enterprise Registry and set up your `.docker/config.json` so `oc-mirror` can seamlessly push and pull images.

Run the following commands to set your variables and configure Podman authentication:

```bash
# Set variables
export REGISTRY_USERNAME=<username>
export REGISTRY_PASSWORD=<password>
export REGISTRY_URL=<registry_url>
export REGISTRY_PORT=<registry_port>

# Log in to the registry using podman. 
# This converts pull-secret.txt to json format and appends registry credentials to it.
podman login --authfile /home/ec2-user/pull-secret.txt \
  -u ${REGISTRY_USERNAME} \
  -p ${REGISTRY_PASSWORD} \
  ${REGISTRY_URL}:${REGISTRY_PORT}
```

Ensure the pull secret is available for standard Docker/OC toolchains:

```bash
mkdir -p /home/ec2-user/.docker
cp /home/ec2-user/pull-secret.txt /home/ec2-user/.docker/config.json
```

---

## Step 3: Create the ImageSetConfiguration
Generate an `imageset-config.yaml` to pull version 4.20.13, Advanced Cluster Manager, and Multi Cluster Engine. Add more versions and operators if needed.

Create a file named `imageset-config.yaml` in `/home/ec2-user/` with the following YAML content:

```yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
      - name: stable-4.20
        minVersion: 4.20.13
        maxVersion: 4.20.13
  graph: true
  operators:
    - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.20
      packages:
        - name: advanced-cluster-management
        - name: multicluster-engine
  additionalImages:
    - name: registry.redhat.io/ubi8/ubi:latest
```

---

## Step 4: Execute the Mirroring Process
Run the `oc-mirror` command to download the payload from Red Hat and push it to your Nexus registry.

Execute the following mirror commands:

```bash
mkdir -p /home/ec2-user/oc-mirror-output

# Mirror the images
oc mirror -c imageset-config.yaml \
  --workspace file://oc-mirror-output/ \
  docker://${REGISTRY_URL}:${REGISTRY_PORT} \
  --v2
```

---

## Step 5: Extract the OpenShift Installer
Once mirroring is complete, extract the `openshift-install` binary directly from your Nexus mirror registry so it perfectly matches the 4.20.13 payload version.

Run the following commands to extract the installer and make it executable, then repeat the process for `ccoctl`:

```bash
oc adm release extract -a /home/ec2-user/pull-secret.txt \
  --command=openshift-install \
  "${REGISTRY_URL}:${REGISTRY_PORT}/openshift/release-images:4.20.13-x86_64"

# Move it to your bin directory
sudo mv openshift-install /usr/bin/
sudo chmod +x /usr/bin/openshift-install
```

---

## Step 6: Update install-config.yaml
From `oc-mirror-output/working-dir/cluster-resources/idms-oc-mirror.yaml`, add the generated configuration to your `install-config.yaml`. 

Your updated block should look similar to this:

```yaml
imageDigestSources:
- mirrors:
  - ${REGISTRY_URL}:${REGISTRY_PORT}/openshift/release
source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
- mirrors:
  - ${REGISTRY_URL}:${REGISTRY_PORT}/openshift/release-images
source: quay.io/openshift-release-dev/ocp-release
```

Incorporate the pull secret into `install-config.yaml` to facilitate authentication with Enterprise Registry:

```yaml
pullSecret: '{"auths": {"${REGISTRY_URL}:${REGISTRY_PORT}": {"auth": "base64 of username password"} }}'
```

If Enterprise Registry necessitates an additional Certificate Authority (CA) trust bundle, it should be appended to the `install-config.yaml` file:

```yaml
additionalTrustBundle: |
  -----BEGIN CERTIFICATE-----
  -----END CERTIFICATE-----
```

---

## Step 7: Populate OperatorHub from Enterprise Registry
Upon completion of the cluster installation, the cluster must be configured to access the operators from Enterprise Registry.

Disable default cluster operator sources:
```bash
oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'
```

Apply the manifests:
```bash
oc apply -f oc-mirror-output/working-dir/cluster-resources
```
