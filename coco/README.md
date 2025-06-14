* Source https://www.redhat.com/en/blog/introducing-confidential-containers-bare-metal Refer to the intall-helpers scripts to understand more and have any confusion.

# Install Disconnected SNO

* Set up mirror registry for disconnected SNO. An example ImageSetConfiguration can be found at imageset-config.yaml

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

* Set trustee version 0.2.0 or 0.3.0

```
export TRUSTEE_VERSION="0.3.0"
```
Or Install from CLI.
* Create a Namespace, OperatorGorup and Subscription.

```
oc create -f trustee/${TRUSTEE_VERSION}/ns.yaml
oc create -f trustee/${TRUSTEE_VERSION}/og.yaml
oc create -f trustee/${TRUSTEE_VERSION}/subscription.yaml
```
* For disconnected environment, installation of operator may fail which requires editing csv and changing the URL for registry.redhat.io/openshift4/ose-kube-rbac-proxy-rhel9 to use the @sha256 which can be obtained from mirror registry.

* Patch the csv to specify image for Trustee.

For Trustee 0.2.0
```
export TRUSTEE_IMAGE=<mirror-registtry-url:/openshift_sandboxed_containers/kbs:v0.10.1
oc patch -n trustee-operator-system clusterserviceversion.operators.coreos.com/trustee-operator.v0.2.0 --type=json -p="[{"op": "replace","path": "/spec/install/spec/deployments/0/spec/template/spec/containers/1/env/1/value","value": "$TRUSTEE_IMAGE"}]"
```
For Trustee 0.3.0
```
export TRUSTEE_IMAGE="<mirror-registtry-url:/location_/kbs:version"
oc patch -n trustee-operator-system clusterserviceversion.operators.coreos.com/trustee-operator.v0.3.0 --type=json -p="[{"op": "replace","path": "/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/1/value","value": "$TRUSTEE_IMAGE"}]"
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
oc create -f trustee/${TRUSTEE_VERSION}/kbs-cm.yaml
```

* Create RVPS configmap
```
oc create -f trustee/${TRUSTEE_VERSION}/rvps-cm.yaml
```

* Create resource policy configmap
```
oc create -f trustee/${TRUSTEE_VERSION}/resource-policy-cm.yaml
```

* Only for Trustee 0.3.0. Create attestation Policy ConfigMap.
```
oc create -f trustee/${TRUSTEE_VERSION}/attestation-policy.yaml
```
* Create few secrets to serve via Trustee. Create kbsres1 secret only if it doesn't exist. This is just an example. May need to create different secrets for application use cases.
```
oc create secret generic kbsres1 --from-literal key1=res1val1 -n trustee-operator-system
```

* Create KBSConfig. Update the HTTP_PROXY, HTTPS_PROXY and NO_PROXY variables if needed and uncomment proxy lines including KbsEnvVars if proxy needs to be configured to reach AMD site.
```
oc create -f trustee/${TRUSTEE_VERSION}/kbsconfig.yaml
```
# Install OSC and Configure CoCo

* Install OpenShift SandBox Container Operator.

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
* For OCP 4.18 - Follow the procedure available at https://github.com/sadiquepp/openshift/tree/main/coco#rebuild-rhcos-layer-image-to-inject-custom-ca-and-registry-auth---ocp-418-only to rebuild the rhcos-layer image to inject customer CA and registry authentication, push the rebuilt rhcos-layer image to mirror registry and then use that rebuilt rhcos-layer image in the configmap below.

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
export kernel_params="agent.aa_kbc_params=cc_kbc::$trustee_url agent.image_registry_auth=file:///.docker/config.json"
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

# Support Mirror Registry with CustomCA and Authentication - OCP 4.16 only

* Do not follow this procedure for OCP-4.18. Follow the procedure to rebuild the rhcoc-layer image instead available at https://github.com/sadiquepp/openshift/tree/main/coco#rebuild-rhcos-layer-image-to-inject-custom-ca-and-registry-auth---ocp-418-only and then use that rebuild rhcos-layer image in the configmap

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

# Rebuild RHCOS Layer Image to Inject custom CA and Registry Auth - OCP 4.18 Only

* By default coco baremtal rhcos layer image only supports unauthenticated mirror registry that uses certificates signed by a Public CA. To support authenticated mirror registry that uses a certificate singed by internal corporate CA, both authentication credentials and Coporate CA certificate needs to be injected to the initrd within the layer image by rebuilding the image. Follow the below steps for that.

* Mirror original rhcos layer image to mirror registry

```
quay.io/openshift_sandboxed_containers/rhcos-layer/ocp-4.18:snp-0.2.0
```
* Extract the pull secret and keep it handy for use in a later step.
```
oc get secrets -n openshift-config pull-secret -o jsonpath="{.data.\.dockerconfigjson}" | base64 -d > auth.json
```
* Follow below steps on RHEL node with podman or using oc debug.

* Combine all the CA certs to a single file 

* If additionalTrustBundle: is used in install-config.yaml, easiest way is to locat it on the node at /etc/pki/ca-trust/source/anchors/openshift-config-user-ca-bundle.crt. If no, create the file manually.

```
mkdir /tmp/rhcos-layer-image-custom
cat cert1.crt cert2.crt > tls.crt

or (only works on oc debug session) 

cp /etc/pki/ca-trust/source/anchors/openshift-config-user-ca-bundle.crt tls.crt
```
* Add registry auth details to the /tmp/rhcos-layer-image-custom. The content of auth.json is the pull secret extracted in previous step. Can use vi and copy paste the pull secret if the file is not on the node.

* Download the Containerfile osc/Containerfile

* Build the new layer image. Specify the source image

```
export RHCOS_BASE_IMAGE="<mirror_registry>/openshift_sandboxed_containers/rhcos-layer/ocp-4.18:snp-0.2.0"
```

* Set the name of the new layer image.
```
export RHCOS_NEW_IMAGE="<mirror_registry>/openshift_sandboxed_containers/rhcos-layer/ocp-4.18-ca-auth:snp-0.2.0"
```

* Build the image. Ensure you have the tls.crt and auth.json files in the current directory along with the Containerfile.

```
sudo podman build --build-arg RHCOS_COCO_IMAGE=$RHCOS_BASE_IMAGE \
             --build-arg CA_CERTS_FILE=tls.crt \
             --build-arg REGISTRY_AUTH_FILE=auth.json \
             --env CA_CERTS_FILE=tls.crt \
             --env REGISTRY_AUTH_FILE=auth.json \
             -t $RHCOS_NEW_IMAGE -f Containerfile .
```

* Push the image to the registry

```
podman push <mirror_registry>/openshift_sandboxed_containers/rhcos-layer/ocp-4.18-ca-auth:snp-0.2.0 
```

# Rebuild Trustee Image to Embedd SNP/SEV node certs for disconnected attestation

* Mirror the base image and support image to the local mirror.

```
quay.io/bpradipt/kbs:v0.12.0-offline-genoa
quay.io/openshift_sandboxed_containers/coco-tools:0.2.0
```

* Assume the base image now is available in local mirror 
```
local-mirror-url:port/bpradipt/kbs:v0.12.0-offline-genoa
```

* Get the VCEK Base URL. This needs to be done for each node in the cluster that the trustee is going to manage.
```
export nodename=<SET_NODE_NAME>
sudo podman run --privileged local-mirror-url:port/openshift_sandboxed_containers/coco-tools:0.2.0 /tools/snphost show vcek-url | cut -d '?' -f 1 > vcek_base_url_$nodename.txt

echo "VCEK_BASE_URL: $vcek_base_url_$nodename.txt"
```
* Make sure that it shows a URL like below.
```
https://kdsintf.amd.com/vcek/v1/Genoa/126A06A956658EF040D5DF52D438BB78DBB8E8C1C6244B420513B00ECCF1E6P2556C926FD913N8F5A80C209M83042077871919E4F1EBB62B296B36E084B57096
```

* Get microcode details. Create a CoCo pod using the following manifest. Note the nodeName attribute to specify the node name.

```
apiVersion: v1
kind: Pod
metadata:
  name: coco-guest
  labels:
    app: coco-guest
  annotations:
    io.katacontainers.config.hypervisor.default_memory: "4096"
    io.katacontainers.config.hypervisor.kernel_params: "agent.guest_components_rest_api=all"
spec:
  runtimeClassName: kata-cc
  nodeName: <SET_NODE_NAME>
  containers:
    - name: snp-guest
      image: <local-mirror-url>/ubi9/ubi:9.3
      command:
        - sleep
        - "36000"
      securityContext:
        privileged: false
        seccompProfile:
          type: RuntimeDefault

```

* Get the attestation report from the pod
```
oc exec -it coco-guest -- curl http://127.0.0.1:8006/aa/evidence?runtime_data=test > attestation_report_$nodename.txt
```
* Example attestation report will look like this.

```
{"attestation_report":{"version":2,"guest_svn":0,"policy":196608,"family_id":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"image_id":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"vmpl":0,"sig_algo":1,"current_tcb":{"bootloader":3,"tee":0,"_reserved":[0,0,0,0],"snp":14,"microcode":213},"plat_info":3,"_author_key_en":0,"_reserved_0":0,"report_data":[116,101,115,116,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"measurement":[107,67,65,98,108,85,117,74,87,159,166,168,234,207,110,213,69,182,57,105,28,26,207,155,66,152,21,69,69,61,187,11,201,239,219,240,0,186,50,210,46,176,220,230,58,46,165,196],"host_data":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"id_key_digest":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"author_key_digest":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"report_id":[207,178,90,248,247,236,197,216,163,82,209,161,3,179,79,185,22,60,203,201,87,68,90,138,55,126,173,121,94,22,200,229],"report_id_ma":[255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255],"reported_tcb":{"bootloader":3,"tee":0,"_reserved":[0,0,0,0],"snp":14,"microcode":213},"_reserved_1":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"chip_id":[18,106,6,169,86,101,142,240,64,213,223,82,212,56,187,120,219,184,232,193,198,36,75,66,5,19,176,14,204,241,230,226,69,108,146,95,217,19,232,245,168,12,32,159,131,5,32,119,135,25,25,228,241,235,182,43,41,107,54,224,132,181,112,149],"committed_tcb":{"bootloader":3,"tee":0,"_reserved":[0,0,0,0],"snp":14,"microcode":213},"current_build":8,"current_minor":55,"current_major":1,"_reserved_2":0,"committed_build":8,"committed_minor":55,"committed_major":1,"_reserved_3":0,"launch_tcb":{"bootloader":3,"tee":0,"_reserved":[0,0,0,0],"snp":14,"microcode":213},"_reserved_4":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"signature":{"r":[35,144,203,195,9,66,140,113,127,82,60,247,126,202,136,125,219,197,159,111,241,112,220,14,185,189,117,90,29,5,46,71,230,17,22,39,23,224,5,198,141,189,19,221,167,31,76,89,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"s":[70,240,157,202,100,64,112,30,253,116,69,197,118,16,227,106,47,152,192,17,26,228,185,12,24,150,152,70,187,244,104,221,205,242,175,14,226,159,119,145,253,27,72,58,104,9,32,94,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"_reserved":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}},"cert_chain":null}
```

* Get the bootloader, tee, snp and microcode versions from the attestation report
```
eval $(cat ./attestation_report_node1.txt | jq -r '
  .attestation_report.reported_tcb |
  "export bootloader=\(.bootloader);
   export tee=\(.tee);
   export snp=\(.snp);
   export microcode=\(.microcode);"
')

echo "Bootloader: $bootloader"
echo "TEE: $tee"
echo "SNP: $snp"
echo "Microcode: $microcode"
```

* Download the VCEK cert for every SNP node from AMD website. The VCEK download URL will be in the below form,
```
"$VCEK_BASE_URL?blSPL=$bootloader&teeSPL=$tee&snpSPL=$snp&ucodeSPL=$microcode"
```
* Check the VCEK_BASE_URL  to see if it's Genoa or Milan. Download Genoa and Milan certs in separate directories. For example,the following downloads the Genoa certificate

```
export VCEK_URL_NODE1="$VCEK_BASE_URL?blSPL=$bootloader&teeSPL=$tee&snpSPL=$snp&ucodeSPL=$microcode"

mkdir -p ek/genoa
curl -L -o ek/genoa/vcek_node1.crt $VCEK_URL_NODE1
```
* Build KBS image with embedded cert.

* This can be done from an oc debug session if needed.

```
oc debug node/name
chroot /host
mkdir -p /tmp/kbs
cd /tmp/kbs
mkdir -p ek/genoa ek/milan
```
* Copy all the downloaded certs to the node /tmp/kbs/ek/genoa or /tmp/kbs/ek/milan

*  Use the following Containerfile to build KBS image with embedded certs for Genoa family nodes
```
ARG KBS_IMAGE=mirror-registry-url/openshift_sandboxed_containers/kbs:v0.12.0-offline-genoa
FROM $KBS_IMAGE

RUN mkdir -p /etc/kbs/snp/ek

COPY ek/genoa/* /etc/kbs/snp/ek/
```
* If the trustee manages milan system copy the milan certs and change the KBS_IMAGE to use milan image.

* Build a new image that includes the certs.

```
export KBS_IMAGE_MILAN=mirror-registry-url/openshift_sandboxed_containers/kbs:v0.12.0-offline-genoa-embedded-cluster1
podman build -t $KBS_IMAGE_MILAN -f Containerfile .

```
* Push the image to the mirror.

```
podman push mirror-registry-url/openshift_sandboxed_containers/kbs:v0.12.0-offline-genoa-embedded-cluster1
```

* Patch the trustee csv to use the new image.
```
oc patch csv -n trustee-operator-system trustee-operator.v0.3.0 --type='json' -p="[{'op': 'replace', 'path': '/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/1/value', 'value':$KBS_IMAGE_GENOA}]"

```

* Test the attestation following the details at https://github.com/sadiquepp/openshift/tree/main/coco#testing-attestation-from-trustee
