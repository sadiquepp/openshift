# Direct (In-Pod) NFS Mount from a Sandboxed Containers / CoCo Pod

This use case is the NFS equivalent of
[testing/kata-cc-pod-pv-block.yaml](https://github.com/sadiquepp/openshift/blob/main/coco/testing/kata-cc-pod-pv-block.yaml),
where a raw block PVC is formatted and mounted by a sidecar *inside* the Kata
guest. Here there is no PV, no PVC and no CSI driver at all: a container in the
pod runs `mount -t nfs` against a remote NFS server and reaches it over the pod
network.

The distinction matters for a confidential workload:

| | Kubernetes NFS volume / CSI | Direct in-pod mount (this doc) |
|---|---|---|
| Who mounts | kubelet, on the worker node | the container, inside the Kata/CoCo guest |
| Host visibility | share is mounted on the host and bind-mounted in | host never sees the share |
| Data path | host network stack | pod network, from inside the guest |
| Credentials | on the host / in the CSI driver | only inside the guest |

Because the mount never appears on the host, a compromised host cannot read the
share - the same reason the block-device example mounts the device in the guest
rather than letting the kubelet do it.

**This cannot be fully validated on `kata-cc` in one go, so test in two steps:**
first with `runtimeClassName: kata` (ordinary sandboxed containers - same guest
kernel and the same mount mechanics, but `oc exec` and logs are unrestricted),
then switch the same manifest to `kata-cc`.

## Contents

| File | Purpose |
|---|---|
| `setup-nfs-server.sh` | Stands up the kernel NFS server on the helper node and self-tests it |
| `Containerfile` | Builds `ubi-nfs-util` (ubi9 + `nfs-utils`), the image that provides `mount.nfs` inside the pod |
| [../testing/kata-pod-nfs-direct.yaml](https://github.com/sadiquepp/openshift/blob/main/coco/testing/kata-pod-nfs-direct.yaml) | Step 1 - single container, mounts and read/writes the share, prints every check |
| [../testing/kata-cc-pod-nfs-direct.yaml](https://github.com/sadiquepp/openshift/blob/main/coco/testing/kata-cc-pod-nfs-direct.yaml) | Step 2 - sidecar mount + shared PID namespace, same pattern as the block example |

## Prerequisites

* OSC operator installed and `KataConfig` applied, with the `kata` and `kata-cc`
  runtime classes present (see the [CoCo runbook](https://github.com/sadiquepp/openshift/tree/main/coco#install-osc-and-configure-coco)).
* The helper node is reachable from the OpenShift nodes on `2049/tcp`.
* A mirror registry the cluster can pull from (disconnected cluster) for the
  `ubi-nfs-util` image.

## Step 1 - NFS server on the helper

Run on the helper node as root. It installs `nfs-utils`, creates and exports
`/srv/nfs/kata`, sets the SELinux booleans, opens the firewall, and finishes
with a loopback `mount -t nfs` self-test:

```
sudo ./setup-nfs-server.sh
```

Override the defaults if your addressing differs:

```
sudo NFS_EXPORT_DIR=/srv/nfs/kata \
     NFS_CLIENT_CIDR=192.168.122.0/24 \
     ./setup-nfs-server.sh
```

The export is created as NFSv4-only on purpose - a single well-known port
(`2049/tcp`), no `rpcbind`/`mountd`/`statd` to open, and locking rides the same
connection. Set `NFS_ENABLE_V3=y` only if you need to fall back to v3 (see
[Troubleshooting](#troubleshooting)).

**`NFS_CLIENT_CIDR` must cover the OpenShift *node* addresses, not the pod
CIDR.** OVN-Kubernetes SNATs pod traffic leaving the cluster network to the node
IP, so the NFS server sees the node address, not the pod IP:

```
oc get nodes -o wide
```

Verify by hand:

```
exportfs -v
ss -lntp | grep 2049
cat /srv/nfs/kata/from-helper.txt     # seeded by the script, the pod will read this
```

## Step 2 - Build the NFS client image

`mount(8)` inside the pod execs `/sbin/mount.nfs` from the **container image**,
so the image has to carry `nfs-utils`. The Kata guest rootfs does not provide
it, and the stock `origin-hello-openshift` / `ubi9` images do not either.

Build on the helper (or any RHEL node with podman) and push to the mirror:

```
cd coco/nfs
export NFS_UTIL_IMAGE="<mirror_registry>/openshift_sandboxed_containers/ubi-nfs-util:latest"
podman build -t $NFS_UTIL_IMAGE -f Containerfile .
podman push $NFS_UTIL_IMAGE
```

On a disconnected cluster the build host needs the UBI repos (or build it on a
connected host and mirror the result).

## Step 3 - Single container test (`kata`)

Edit [../testing/kata-pod-nfs-direct.yaml](https://github.com/sadiquepp/openshift/blob/main/coco/testing/kata-pod-nfs-direct.yaml)
and replace the image, `NFS_SERVER` (helper IP) and `NFS_EXPORT`, then:

```
oc apply -f ../testing/kata-pod-nfs-direct.yaml
oc logs -f nfs-direct-check
```

The pod walks through the checks in order, so the logs tell you exactly where it
breaks:

1. **Guest kernel support** - `grep nfs /proc/filesystems`, falling back to
   `modprobe nfs`. This is the one genuinely open question in this exercise: the
   Kata guest kernel is a minimal kernel, and if `CONFIG_NFS_FS` is not built in
   and no `nfs.ko` ships in the guest rootfs, the mount fails with
   `unknown filesystem type 'nfs'` and no amount of server-side work will help.
   Find this out first - it decides whether the whole approach is viable.
2. **Reachability** - pod addressing/routes, `ping`, and `nc -vz <helper> 2049`
   from inside the guest.
3. **Mount** - `mount -t nfs -o vers=4.2,...`, then `findmnt` and `nfsstat -m`.
4. **Data path** - reads `from-helper.txt` (proves it is the remote share, not an
   `emptyDir`), writes `from-pod-<host>.txt` back, and prints `df -hT`.

Confirm the write landed on the helper:

```
ls -l /srv/nfs/kata/
```

Then confirm the host never saw the mount - on the node running the pod:

```
oc debug node/<node> -- chroot /host findmnt -t nfs4,nfs
```

That should return nothing for this share, which is the whole point.

## Step 4 - Sidecar pattern, then `kata-cc`

[../testing/kata-cc-pod-nfs-direct.yaml](https://github.com/sadiquepp/openshift/blob/main/coco/testing/kata-cc-pod-nfs-direct.yaml)
is the shape a real application needs, and mirrors the block-device example:

* A native sidecar (`initContainers` entry with `restartPolicy: Always`) mounts
  the share at `/mnt/nfs` and then `tail -f /dev/null`, because the mount lives
  in that container's mount namespace and disappears with it.
* `check-ready` blocks until the sidecar has dropped `.ready` on the share, so
  the application does not start against an empty directory.
* `shareProcessNamespace: true` lets the application container reach the mount
  as `/proc/<sidecar-pid>/root/mnt/nfs`; a `postStart` hook symlinks that to
  `/data`. A mount made in one container is *not* visible in another container's
  mount namespace - this indirection is unavoidable, exactly as in the block
  case.
* Unlike the block example, the sidecar resolves the peer by scanning
  `/proc/[0-9]*/root/mnt/nfs/.ready` instead of taking the second PID in the
  pod, which is less fragile if container start order changes.

Validate it on `kata` first:

```
sed 's/runtimeClassName: kata-cc/runtimeClassName: kata/' ../testing/kata-cc-pod-nfs-direct.yaml | oc apply -f -
oc logs nfs-unencrypted -c mount-nfs
oc exec nfs-unencrypted -c hello-openshift -- ls -l /data/
```

Then apply it unchanged (`kata-cc`) and compare:

```
oc apply -f ../testing/kata-cc-pod-nfs-direct.yaml
oc logs nfs-unencrypted -c mount-nfs
```

What to expect to differ under `kata-cc`:

* `oc exec` is denied unless the agent policy allows it - the default CoCo policy
  sets `ExecProcessRequest := false`. Use container logs for verification, or
  add the command to `policy_data.allowed_commands` the way
  [testing/ubi-pod.yaml](https://github.com/sadiquepp/openshift/blob/main/coco/testing/ubi-pod.yaml)
  does.
* Images are pulled *inside* the guest, so `ubi-nfs-util` must be pullable with
  the registry auth and CA baked into the guest (see
  [Rebuild RHCOS Layer Image](https://github.com/sadiquepp/openshift/tree/main/coco#rebuild-rhcos-layer-image-to-inject-custom-ca-and-registry-auth---ocp-418-only)).
* Guest memory: NFS page cache plus the extra container pushes memory use up;
  keep or raise `io.katacontainers.config.hypervisor.default_memory`.

## Security note for the confidential case

`sec=sys` gives you no authentication and no encryption - the share is trusted
on the basis of the client's IP, and the data crosses the pod network in the
clear. That is fine for this functional test, but for a confidential workload
the in-guest mount only protects the data from the *host*, not on the wire or at
rest on the NFS server. Options, in rough order of effort:

* `sec=krb5p` (Kerberos with privacy) - authenticated and encrypted on the wire;
  needs a keytab inside the guest, which is exactly the kind of secret Trustee
  should release rather than the manifest carrying it.
* Encrypt at the application layer, or keep a LUKS container file on the share
  and open it in the guest (key from Trustee) - the share then only ever holds
  ciphertext.
* Keep plain NFS, but on an isolated network and with the understanding that the
  NFS server is in the trust boundary.

## Does NFSv4 work over the pod network with NAT?

Yes, and NFSv4 is the right version precisely because of the NAT. Traffic from
the pod to the helper leaves the cluster network, so OVN-Kubernetes SNATs it to
the node address; the helper never sees the pod IP. What that costs:

* **Nothing for the data path.** Everything rides one client-initiated TCP
  connection to 2049 - no rpcbind, no separate mountd/lockd/statd, and
  `OPEN`/`LOCK` are in-protocol. SNAT has one flow to track. v4 is also
  TCP-only, so the reduced geneve pod MTU just clamps MSS.
* **Use 4.1 or later, not 4.0.** NFSv4.0 hands the server a callback address and
  the *server* opens an inbound connection to it for delegation recalls. Behind
  SNAT that address is the pod IP and is unreachable, so delegations stop being
  granted - a performance loss, not a correctness one. NFSv4.1 moved callbacks
  to a session backchannel over the existing connection, so nothing inbound is
  needed. The manifests pin `vers=4.2` for this reason.
* **NFSv3 is the version NAT actually breaks**, which is why
  `setup-nfs-server.sh` is v4-only: NLM/statd lock recovery needs the server to
  send `SM_NOTIFY` *to* the client's registered address, and behind NAT that is
  a pod IP.
* **Watch the source port.** The client uses a privileged port (`resvport`) and
  exports default to `secure`, which requires one. The kernel NAT core tries to
  keep the original port and otherwise stays inside the privileged range, and
  OVN's SNAT goes through that same code via OVS conntrack - but if it ever
  lands above 1023 the mount is refused with a correct export. Confirm on the
  helper with `ss -tn state established '( sport = :2049 )'`.
* **Conntrack is stateful**, so an evicted entry would hang a `hard` mount.
  NFSv4 lease renewal (90s default) keeps the mapping warm on an active mount.
* **Client identity.** Several pods behind one node IP are distinct clients from
  the same address, which is fine while their client IDs differ - Linux derives
  it from the hostname, so the pod name keeps it unique. Pods that explicitly
  set the same `hostname` can look to the server like one client rebooting, and
  the later one revokes the earlier one's state. Set
  `/sys/module/nfs/parameters/nfs4_unique_id` if that applies.

None of this differs between `runc`, `kata` and `kata-cc` - the guest gets the
pod IP over a tap device, so the client's view is the same.

### What the NAT costs the export ACL

This is the part that matters for a confidential workload. After SNAT the helper
sees the node IP, so `sec=sys` plus an IP allow-list authorises **every pod on
that node**, and the node itself - the export ACL no longer identifies the
workload. Ways back, in rough order of effort:

* An `EgressIP` pinning a per-namespace source address, so the export can
  allow-list the workload rather than the whole node. The trade-offs
  (concentration on the egress node, reconnects on failover) are written up in
  [observability/kafka](https://github.com/sadiquepp/openshift/tree/main/observability/kafka#reaching-an-external-broker-from-a-stable-address).
* A localnet/secondary attachment putting the pod directly on the storage VLAN -
  no NAT at all, and the pod carries a real address there. See the two-VLAN
  guides under [networking/](https://github.com/sadiquepp/openshift/tree/main/networking).
* Kerberos (`sec=krb5p`), so identity stops being the address altogether.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `mount: unknown filesystem type 'nfs'` | Guest kernel has no NFS client. Check `zcat /proc/config.gz \| grep -i CONFIG_NFS` (if `CONFIG_IKCONFIG_PROC` is set), `cat /proc/filesystems`, `ls /lib/modules/$(uname -r)/kernel/fs/nfs`. If it is genuinely absent, the kernel-mount approach is out - see fallbacks below. |
| `mount.nfs: command not found` / `helper program not found` | The container image lacks `nfs-utils` - use `ubi-nfs-util`, not the app image. |
| `No route to host` / `nc` to 2049 times out | Firewall on the helper, or the node cannot reach the helper. Test from the node: `oc debug node/<node> -- chroot /host nc -vz <helper> 2049`. |
| `access denied by server while mounting` | Export ACL does not cover the *node* IP (pod traffic is SNATed). Fix `NFS_CLIENT_CIDR` and `exportfs -rav`. |
| `access denied by server while mounting`, export ACL already correct | SNAT moved the client off a privileged source port and the export defaults to `secure`. Check with `ss -tn state established '( sport = :2049 )'` on the helper; add `insecure` to the export, or mount with `noresvport`. |
| `Operation not permitted` on mount | Container is not privileged, or the CoCo agent policy blocked it. |
| Mount works, writes fail with `Permission denied` | `no_root_squash` missing, or the container runs as a UID the server does not map. Check `ls -ln` on the mount. |
| Files show as `nobody:nobody` | NFSv4 idmapping - set the same `Domain =` in `/etc/idmapd.conf` on the helper and in the client image, or use numeric IDs (`nfs4_disable_idmapping=1`). |
| Pod hangs in `Terminating`, or I/O blocks when the helper goes away | `hard` mounts block by design. Use `soft,timeo=100,retrans=2` for the test if you prefer failures over hangs, and remember the sidecar must outlive the app container. |
| Mount is invisible in the app container | Expected - the mount is per mount-namespace. Use the sidecar + `/proc/<pid>/root` pattern from the step 4 manifest. |
| SELinux denials inside the guest | Add `-o context="system_u:object_r:nfs_t:s0"` to the mount options. |

### If the guest kernel has no NFS client

In rough order of practicality:

1. **Userspace NFS client (`libnfs`)** - no kernel support needed at all; the
   library speaks NFS over TCP 2049 directly. Good for an application you can
   relink or that can call `nfs-ls`/`nfs-cp`; not a POSIX mount.
2. **`fuse-nfs`** - gives you a real mountpoint via FUSE, but only if the guest
   kernel has `CONFIG_FUSE_FS`. Check `/proc/filesystems` for `fuse` before
   investing time here.
3. **NFSv3** (`NFS_ENABLE_V3=y`, `-o vers=3`) - worth one attempt if the guest
   kernel has `nfs` but not `nfs4`; needs `rpcbind`/`mountd`/`statd` reachable.
4. **Custom guest kernel / initrd** with `CONFIG_NFS_FS=m` - possible, since the
   CoCo runbook already rebuilds the layer image, but it puts you on an
   unsupported guest. Raise it with Red Hat before going down this path.
5. **Kubernetes NFS volume / CSI** - works today, but the kubelet mounts the
   share on the host, which defeats the requirement.

## Teardown

```
oc delete -f ../testing/kata-cc-pod-nfs-direct.yaml --ignore-not-found
oc delete -f ../testing/kata-pod-nfs-direct.yaml --ignore-not-found
```

On the helper:

```
rm -f /etc/exports.d/kata-coco.exports
exportfs -rav
systemctl disable --now nfs-server
firewall-cmd --permanent --remove-service=nfs && firewall-cmd --reload
# rm -rf /srv/nfs/kata   # only once you no longer need the test data
```
