* Source https://www.redhat.com/en/blog/introducing-confidential-containers-bare-metal Refer to the intall-helpers scripts to understand more and have any confusion.

# Install Disconnected SNO

* Set up mirror registry for disconnected SNO. An example ImageSetConfiguration can be found at imageset-config.yaml
Below Images needs to be mirrored explicitly.
```
  - name: quay.io/openshift_sandboxed_containers/rhcos-layer/ocp-4.16:snp-0.1.0
  - name: quay.io/openshift_sandboxed_containers/kbs:v0.10.1
```
* Develop install-config.yaml using the example given. Update baseDomain, machineNetwork, installationDisk, pullSecret, imageContentSource, sshKey and additionalTrustBundle as needed.

* Develop agent-config.yaml using the example given. Update rendezvousIP, interface name, macAddress and other details appropriately.

* Extract openshift-install from release image on mirror registry, eg

```
oc adm release extract -a pull-secret.txt --icsp-file=<icsp-file.yaml> --command=openshift-install mirror.hub.mylab.com:8443/openshift/release-images:4.18.5-x86_64
```

* Copy the install-config.yaml and agent-config.yaml to a directory eg "ocp" and create the ISO

```
./openshift-install --dir ocp/ agent create image
```
* Boot the SNO node using the ISO to install OCP.

* Apply the manifests to support operators from local mirror registry.

* Disable all default operator sources.
```
oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'
```

# Install and Configure Trustee Operator

* Install OpenShift Trustee.

Install From OpenShift GUI by following the default steps to install an Operator.

Or Install from CLI.
* Create a Namespace, OperatorGorup and Subscription.

```
oc create -f trustee/ns.yaml
oc create -f trustee/og.yaml
oc create -f trustee/subscription.yaml
```
* For disconnected environment, installation of operator may fail which requires editing csv and changing the URL for registry.redhat.io/openshift4/ose-kube-rbac-proxy-rhel9 to use the @sha256 which can be obtained from mirror registry.

* Patch the csv to specify image for Trustee.
```
export TRUSTEE_IMAGE=<mirror-registtry-url:/openshift_sandboxed_containers/kbs:v0.10.1
oc patch -n trustee-operator-system clusterserviceversion.operators.coreos.com/trustee-operator.v0.2.0 --type=json -p="[{"op": "replace","path": "/spec/install/spec/deployments/0/spec/template/spec/containers/1/env/1/value","value": "$TRUSTEE_IMAGE"}]"
```
* Create secrets

```
openssl genpkey -algorithm ed25519 >privateKey
openssl pkey -in privateKey -pubout -out publicKey
```
* Create kbs-auth-public-key secret if it does not exist.
```
oc create secret generic kbs-auth-public-key --from-file=publicKey -n trustee-operator-system
```

* Create KBS configmap
```
oc create -f trustee/kbs-cm.yaml
```

* Create RVPS configmap
```
oc create -f trustee/rvps-cm.yaml
```

* Create resource policy configmap
```
oc create -f trustee/resource-policy-cm.yaml
```

* Create few secrets to serve via Trustee. Create kbsres1 secret only if it doesn't exist. This is just an example. May need to create different secrets for application use cases.
```
oc create secret generic kbsres1 --from-literal key1=res1val1 -n trustee-operator-system
```

* Create KBSConfig. Update the HTTP_PROXY, HTTPS_PROXY and NO_PROXY variables if needed and uncomment proxy lines including KbsEnvVars if proxy needs to be configured to reach AMD site.
```
oc create -f trustee/kbsconfig.yaml
```
# Install OSC and Configure CoCo

* Install OpenShift SandBox Container Operator. v1.8.1
Install From OpenShift GUI by following the default steps to install an Operator.

Or Install from CLI.
* Create a Namespace, OperatorGorup and Subscription.

```
oc create -f osc/ns.yaml
oc create -f osc/og.yaml
oc create -f osc/subscription.yaml
```
* Create CoCo feature gate ConfigMap
```
oc create -f osc/osc-fg-cm.yaml
```
* Create Layered Image FG ConfigMap. Update the Image location to local mirror for disconnected environment.

```
oc create -f osc/layeredimage-cm-snp.yaml
```

* Create KataConfig
```
oc create -f osc/kata-config.yaml
```

* Wait for the mcp to get fully updated.
```
oc get mcp master
```

* Install NFD Operator.
Install From OpenShift GUI by following the default steps to install an Operator.

Or Install from CLI.
* Create a Namespace, OperatorGroup an Subscription.

```
oc create -f nfd/ns.yaml
oc create -f nfd/og.yaml
oc create -f nfd/subscription.yaml
```
* Edit nfd/nfd-cr.yaml and point the spec.operand.image to point to the image location in the mirror registry. Then apply NFD CR

```
oc create -f nfd/nfd-cr.yaml
```
* Create AMD SNP-SEV rules

```
oc create -f nfd/amd-rules.yaml 
```
* Verif that the node has below label added by NFD before proceeding to next section

```
oc get nodes -l "amd.feature.node.kubernetes.io/snp=true"
```

* Create Runtime Class
```
oc create -f osc/runtime-class.yaml
```

* Set Agent Kernel Parameters. Export Trustee URL variable. Use the service url if trustee on the same cluster as coco containers. eg http://kbs-service.trustee-operator-system:8080 Use the Route to the svc if trustee is on remote cluster.
```
export trustee_url="Trustee URL"
```

* Set Kernel Paratmer variable
```
export kernel_params="agent.aa_kbc_params=cc_kbc::$trustee_url"
```
* Set the base64 into a variable called source
```
export source=`echo "[hypervisor.qemu]
kernel_params=\"$kernel_params\"" | base64 -w0`
```
* Edit the set-kernel-parameter-kata-agent.yaml and replace the $source with the base64 value from above which can be obtained from "echo $source". Then Create MC for Kernel config
```
oc create -f osc/set-kernel-parameter-kata-agent.yaml
```

# Basic Testing

* Modify testing/hello-openshift.yaml to update the image location of hello openshif to local mirror

* Create the test pod

```
oc create -f testing/hello-openshift.yaml
```
* Expose the route

```
oc expose service hello-openshift-service -l app=hello-openshift
APP_URL=$(oc get routes/hello-openshift-service -o jsonpath='{.spec.host}')
```
* Access the App

```
curl ${APP_URL}
```

* Verif that the pod is running in Kata VM
```
oc debug node/master-0
ps aux | grep qemu-kv
```
* How to validate the pod is encrypted im memory?

# Testing Attestation from Trustee

* Modify testing/ubi-pod.yaml to update the image location to local mirror

*  Create the coco encrypted POD

```
oc create -f testing/ubi-pod.yaml
```
* Fetch the key from trustee. If attestation is successful, you will get the key as output.

```
oc project default
oc exec -it ocp-cc-pod -- curl -s http://127.0.0.1:8006/cdh/resource/default/kbsres1/key1 && echo ""
```

# Support Mirror Registry with CustomCA and Authentication

* Delete all the pods that use runtime class "kata" or "kata-cc"

* Delete runtimeclass kata-cc

* Delete KataConfig

* Wait for the system to reboot and mcp to get updated. Ensure that the rhcos layer for coco is removed before proceeding. "oc get nodes"

* Upgrade or re-install Sandboxed Containers Operator to 1.9.0 version.

* Edit or recreate the layered-image-deploy-cm ConigMap in openshift-sandboxed-containers-operator ns to update the image in osImageURL to the new rhcos layer image.

* Create KataConfig

* Wait for the system to reboot to the new layered image and confirm that the system is rebooted to the new image.

* Extract the pull secret and keep it handy for use in a later step.
```
oc get secrets -n openshift-config pull-secret -o jsonpath="{.data.\.dockerconfigjson}" | base64 -d > config.json
```
* Customize Initrd after login to the SNO via oc debug node/name.

```
oc debug node/name
chroot /host
```

* Unpack Initrd

```
export INITRD="/usr/share/kata-containers/kata-containers-initrd-confidential.img"
rm -fr /tmp/initrd
mkdir -p /tmp/initrd && cd /tmp/initrd
zcat $INITRD |  cpio -idmv
```
* Add custom CA to initrd. If additionalTrustBundle: is used in install-config.yaml, easiest way it to locat it on the node at /etc/pki/ca-trust/source/anchors/openshift-config-user-ca-bundle.crt. If no, create the file manually.

```
cd /tmp/initrd
mkdir -p etc/ssl/certs
cp /etc/pki/ca-trust/source/anchors/openshift-config-user-ca-bundle.crt ./etc/ssl/certs/ca-certificates.crt
```

* Add registry auth details to initrd. The content of /tmp/config.json is the pull secret extracted in previous step. Can use vi and copy paste the pull secret if the file is not on the node.
```
cd /tmp/initrd
mkdir -p .docker
cp /tmp/config.json .docker/config.json
```

* Repack the initrd.

```
mount -o remount,rw /usr
find . | cpio -o -c -R root:root | gzip -9 > /usr/share/kata-containers/rhcos-coco-custom-ca.initrd

chcon --reference /usr/share/kata-containers/kata-containers-initrd-confidential.img /usr/share/kata-containers/rhcos-coco-custom-ca.initrd
```
* Updat the configuration file on the node to point to the new custom initrd image. Just comment out the existing initrd and create a new line for new initrd. . Do not make any other changes.

```
vi  /etc/kata-containers/snp/configuration.toml
[hypervisor.qemu]
#initrd = "/usr/share/kata-containers/rhcos-coco-snp.initrd"
initrd = "/usr/share/kata-containers/rhcos-coco-custom-ca.initrd"
```
* Exit oc debug.

* Create runtime class kata-cc

* Set Agent Kernel Parameters. Export Trustee URL variable. Use the service url if trustee on the same cluster as coco containers. eg http://kbs-service.trustee-operator-system:8080 Use the Route to the svc if trustee is on remote cluster. Extend it to add registry auth.

```
export trustee_url="http://kbs-service.trustee-operator-system:8080"
```
* Set Kernel Paratmer variable

```
export kernel_params="agent.aa_kbc_params=cc_kbc::$trustee_url agent.image_registry_auth=file:///.docker/config.json"
```

* Set the base64 into a variable called source

```
export source=`echo "[hypervisor.qemu]
kernel_params=\"$kernel_params\"" | base64 -w0`
```
* Edit the set-kernel-parameter-kata-agent.yaml and replace the $source with the base64 value from above which can be obtained from "echo $source". Then Create MC for Kernel config

```
oc apply -f osc/set-kernel-parameter-kata-agent.yaml
```

* This will reboot the node and update the MC with the new values.

* Test creation of coco pod. Use annotation io.katacontainers.config.hypervisor.default_memory: "4096" it may be needed.
```
io.katacontainers.config.hypervisor.default_memory: "4096"
```
