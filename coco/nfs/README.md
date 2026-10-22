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
first with `runtimeClassName: kata` (ordinary sandboxed containers - same mount
mechanics and the same network path, but `oc exec` and logs are unrestricted),
then switch the same manifest to `kata-cc`.

Note what the first step does *not* prove. The two handlers boot different
kernel *generations*, not variants of one build, so nothing about the guest
kernel transfers between them. On OSC 1.13.1:

| Handler | Artefacts (from `/etc/kata-containers/<handler>/configuration.toml`) | Guest kernel |
|---|---|---|
| `kata` | `/var/cache/kata-containers/osbuilder-images/kata.{kernel,initrd}`, built on the node | `5.14.0-687.39.1.el9_8` - the RHCOS kernel version |
| `kata-snp` (`kata-cc`) | `/usr/share/kata-containers/osbuilder-images/kata-cc.kernel` plus `image = kata-containers-confidential.img`, shipped prebuilt | `6.12.0-211.16.1.el10_2` - RHEL 10 |

So re-run the `/proc/filesystems` check under `kata-cc`; a pass under `kata` only
establishes the mechanics and the network path.

**The `.ko` files in these images are the signal; `/proc/filesystems` is not.**
`nfs.ko` registers *both* the `nfs` and `nfs4` filesystem names and then loads
the version implementation on demand via `request_module("nfsv4")`. So `nfs4`
appearing in `/proc/filesystems` proves only that `nfs.ko` is loaded. If
`nfsv4.ko` is absent from the guest rootfs, that `request_module` fails and every
4.x mount returns `EPROTONOSUPPORT` - `mount.nfs: Protocol not supported`. List
the module tree in the handler's initrd or image and look for `nfsv4.ko` and
`nfsv3.ko` by name.

### Which kernel is "the guest kernel"

Two kernels are involved. RHCOS boots on the bare metal and runs the node; the
pod's VM boots a separate kernel that OSC ships under
`/usr/share/kata-containers/` and launches per the handler's
`configuration.toml` (for SNP, the files the CoCo runbook already edits at
`/etc/kata-containers/snp/`). The container processes run against that inner
kernel, so that is where `CONFIG_NFS_FS` has to be:

```
oc exec nfs-direct-check -- uname -r
oc get node <node> -o jsonpath='{.status.nodeInfo.kernelVersion}'
```

Those differ. The `ubi-nfs-util` image supplies `mount.nfs` in userspace, but no
container image can supply a filesystem driver - it is built into the guest
kernel or loadable from the guest's `/lib/modules`.

As a control, run the same manifest with no `runtimeClassName` at all: a
privileged runc pod shares the RHCOS kernel, which certainly has an NFS client.
If it mounts under runc and fails under `kata`, the guest kernel is the cause.

## What has been verified so far

| Check | Result |
|---|---|
| **Direct in-pod NFSv4.2 mount under `kata`** | **Works.** Mounted `nfs4 vers=4.2,proto=tcp,rsize=1048576,wsize=1048576,hard,sec=sys` from inside the Kata guest over the pod network; read back the file the helper had seeded and wrote to the share. `df` showed the helper's filesystem, not the guest's virtiofs rootfs. First measured on OSC 1.13.1, `kata-containers-3.31.0-4.rhaos4.22.el9`, guest kernel `5.14.0-687.39.1.el9_8.x86_64`, RHCOS 9.8.20260812-0, three-node compact cluster - with the module workaround. Re-verified with no workaround at all on OCP 4.22.18 / `kata-containers-3.31.0-5`. |
| Prerequisite | `insecure` on the export, per the SNAT'd source port above. That is the whole list from `kata-containers-3.31.0-5` onwards. On earlier builds a `modprobe nfsv4` was also needed, because the guest rootfs shipped `nfs.ko` with no version module and every 4.x mount returned `Protocol not supported` - see [Post-upgrade result](#post-upgrade-result---fixed). |
| The v4 callback address | The mount recorded `clientaddr=10.128.0.17` - the *pod* IP, unreachable from the server. Harmless on 4.1+, where the backchannel shares the connection; on 4.0 it would silently cost all delegations. |
| Why `/proc/filesystems` is not the check | `nfs` and `nfs4` are registered by `nfs.ko` alone, before any version module is loaded - so that listing says nothing about whether a mount will work. `grep '^nfsv4 ' /proc/modules` is the check. `fuse` is also present, making `fuse-nfs` a live fallback. |
| Pod-network path, export and ACL | **Good.** 2049 reachable from inside the guest (pod `10.128.0.17` SNAT'd to the node, server `192.168.122.202`), `showmount -e` lists the export with the script's own ACL, so nothing network-, firewall- or export-side is in the way. |
| Client userspace | **Available off the shelf.** `quay.io/rh-ee-chbutler/ubi-storage-util:latest` ships `nfs-utils-2.8.3-5.el10_2` with `mount.nfs` and `mount.nfs4`, so no image build is needed. Note it is el10 userspace over an el9 guest kernel. |
| Probe really ran in the VM | **Yes.** `/sys/class/dmi/id/sys_vendor` reads `Red Hat` (a RHEL KVM guest); the bare metal would read `Dell Inc.`. The guest kernel version matching the node's is expected for the RHEL-derived OSC guest kernel, and is not evidence of a runc fallback. |
| `kata-cc` | **Not tested** - no SNP node available, and `kata-snp`'s configured `image = kata-containers-confidential.img` is not present on the node. Its el10 module tree shows the *same* `nfs.ko`-without-`nfsv4.ko` pattern, so expect the same failure until proven otherwise. |
| The sidecar pattern | **Not tested** - the single-container path is proven, the sidecar + shared-PID-namespace indirection is not. |

So the requirement is feasible on plain sandboxed containers today, given the
module load and the `insecure` export. How the module gets into the guest is the
part that needs a real answer before this goes anywhere near production:
`testing/kata-pod-nfs-direct.yaml` takes it from the host's module tree over a
`hostPath`, which works because the plain `kata` guest kernel is built from the
host's. That is a lab expedient twice over - it breaks on any kernel update,
since the module must match `uname -r` exactly, and for `kata-cc` it would mean
loading host-supplied kernel code inside the TEE, which hands the host exactly
the influence the confidential guest exists to deny. For CoCo the module has to
ship in the attested guest rootfs, so the real fix is Red Hat shipping
`nfsv4.ko` in it - there is no customer-side path that keeps the module inside
the measured boundary, since OCP 4.20 replaced the initrd rebuild with
`initdata` and Trustee.

## Pre-upgrade baseline and post-upgrade validation

Red Hat reports NFSv4 support landed in Kata **3.31.0-5**, reachable via the
latest 4.22 z-stream or any of 4.22.11 - 4.22.18. Recorded baseline from the
affected cluster, for comparison after the upgrade:

```
# oc debug node/<node> -- chroot /host bash -c '
#   rpm -q kata-containers
#   ls -l --time-style=full-iso /var/cache/kata-containers/osbuilder-images/
#   I=/var/cache/kata-containers/osbuilder-images/kata.initrd
#   echo "entries: $(zcat "$I" | cpio -it 2>/dev/null | wc -l)"
#   zcat "$I" | cpio -it 2>/dev/null | grep -E "nfs|sunrpc" || echo "NO-NFS-MODULES"
#   true'

kata-containers-3.31.0-4.rhaos4.22.el9.x86_64

drwxr-xr-x. 2 root root 25 2026-10-22 09:32:23 5.14.0-687.39.1.el9_8.x86_64
lrwxrwxrwx. 1 root root 40 2026-10-22 09:32:23 kata.initrd -> 5.14.0-687.39.1.el9_8.x86_64/kata.initrd
lrwxrwxrwx. 1 root root 49 2026-10-22 09:32:23 kata.kernel -> /lib/modules/5.14.0-687.39.1.el9_8.x86_64/vmlinuz

entries: 721
usr/lib/modules/5.14.0-687.39.1.el9_8.x86_64/kernel/net/sunrpc/sunrpc.ko.xz
usr/lib/modules/5.14.0-687.39.1.el9_8.x86_64/kernel/fs/nfs_common/grace.ko.xz
usr/lib/modules/5.14.0-687.39.1.el9_8.x86_64/kernel/fs/nfs/nfs.ko.xz
```

Two things that output settles. `kata.kernel` is a symlink to the host's own
`vmlinuz`, so the plain `kata` guest boots the RHCOS kernel itself - the kernel's
NFS capability was never in question, only which modules the initrd carries. And
the initrd cache is a directory **keyed by kernel version**, so a z-stream that
bumps the kernel forces a fresh build, while one that ships a new
`kata-containers` RPM without a kernel change will reuse the existing directory
and leave the old module list in place.

Baseline for the confidential handler, which is shaped differently - those
artefacts are prebuilt files rather than generated per kernel:

```
# oc debug node/<node> -- chroot /host rpm -qf \
#     /usr/share/kata-containers/osbuilder-images/kata-cc.kernel \
#     /usr/share/kata-containers/osbuilder-images/kata-cc.initrd
kata-containers-3.31.0-4.rhaos4.22.el9.x86_64
kata-containers-3.31.0-4.rhaos4.22.el9.x86_64

# zcat /usr/share/kata-containers/osbuilder-images/kata-cc.initrd | cpio -it | grep -i nfs
usr/lib/modules/6.12.0-211.16.1.el10_2.x86_64/kernel/fs/nfs/nfs.ko.xz
usr/lib/modules/6.12.0-211.16.1.el10_2.x86_64/kernel/fs/nfs_common/grace.ko.xz
usr/lib/modules/6.12.0-211.16.1.el10_2.x86_64/kernel/fs/nfs_common/nfs_localio.ko.xz
```

Same `nfs.ko`-without-`nfsv4.ko` pattern, at a RHEL 10 kernel against RHEL 9 for
plain `kata`. The `rpm -qf` result is the useful part: the confidential kernel
and initrd ship in the **same** `kata-containers` RPM, so one z-stream upgrade
should carry the fix into both runtimes - and into `kata-cc` it arrives inside
the attested guest image, which is the only acceptable way for a confidential
workload.

Both follow-up checks came back, and both matter:

* **NFS is not compiled in either.** `modules.builtin` in `kata-cc.initrd` has no
  NFS entries, so the confidential guest would fail exactly as the plain one
  does. `kata-cc.kernel` is itself a symlink to a bundled
  `6.12.0-211.16.1.el10_2.x86_64/vmlinuz`.
* **Ignore the `image =` path in `kata-snp/configuration.toml`.** It names a
  `kata-containers-confidential.img` that the RPM does not ship and that is not
  on the node, but that is a legacy reference from the 4.18 layered-image era -
  the location changed in later versions, and its absence is not evidence of
  anything. The confidential rootfs for this build is `kata-cc.initrd`, shipped
  by the RPM.

The module list itself comes from dracut configs shipped in the same RPM, at
`/usr/libexec/kata-containers/osbuilder/dracut/` (`dracut-kata-cc.conf` and
siblings). For plain `kata`, whose initrd is generated on the node from that
config, this is the lever the upstream fix most likely pulls - and possibly a
local workaround via a drop-in plus a regenerate. It is not a lever for
`kata-cc`, whose initrd ships prebuilt: rebuilding that locally would change
what gets measured for attestation.

### Post-upgrade result - fixed

Upgraded to **OCP 4.22.18**, `kata-containers-3.31.0-5.rhaos4.22.el9`. The
module arrived in both guest images:

| | Before (3.31.0-4) | After (3.31.0-5) |
|---|---|---|
| plain `kata` initrd | 721 entries, no `nfsv4.ko` | 728 entries, **`nfsv4.ko`** |
| confidential `kata-cc.initrd` | 977 entries, no `nfsv4.ko` | 983 entries, **`nfsv4.ko`** |
| GSS / Kerberos | absent | **`auth_rpcgss.ko`, `rpcsec_gss_krb5.ko`** in both |
| `nfsv3.ko` | absent | still absent |
| NFS built in? | no | no - still modular, loaded on demand |

Recorded output, same commands as the baselines above (directory entries
trimmed, `.ko` files kept):

```
# plain kata
# rpm -q kata-containers
kata-containers-3.31.0-5.rhaos4.22.el9.x86_64

drwxr-xr-x. 2 root root 25 2026-10-22 14:56:34 5.14.0-687.55.1.el9_8.x86_64
lrwxrwxrwx. 1 root root 40 2026-10-22 14:56:34 kata.initrd -> 5.14.0-687.55.1.el9_8.x86_64/kata.initrd
lrwxrwxrwx. 1 root root 49 2026-10-22 14:56:34 kata.kernel -> /lib/modules/5.14.0-687.55.1.el9_8.x86_64/vmlinuz

entries: 728
usr/lib/modules/5.14.0-687.55.1.el9_8.x86_64/kernel/net/sunrpc/sunrpc.ko.xz
usr/lib/modules/5.14.0-687.55.1.el9_8.x86_64/kernel/net/sunrpc/auth_gss/rpcsec_gss_krb5.ko.xz
usr/lib/modules/5.14.0-687.55.1.el9_8.x86_64/kernel/net/sunrpc/auth_gss/auth_rpcgss.ko.xz
usr/lib/modules/5.14.0-687.55.1.el9_8.x86_64/kernel/fs/nfs_common/grace.ko.xz
usr/lib/modules/5.14.0-687.55.1.el9_8.x86_64/kernel/fs/nfs/nfsv4.ko.xz        <-- new
usr/lib/modules/5.14.0-687.55.1.el9_8.x86_64/kernel/fs/nfs/nfs.ko.xz
```

```
# confidential guest
# grep -E '^\s*(kernel|initrd|image)\s*=' /etc/kata-containers/kata-snp/configuration.toml
kernel = "/usr/share/kata-containers/osbuilder-images/kata-cc.kernel"
initrd = "/usr/share/kata-containers/osbuilder-images/kata-cc.initrd"

entries: 983
usr/lib/modules/6.12.0-211.16.1.el10_2.x86_64/kernel/fs/nfs/nfs.ko.xz
usr/lib/modules/6.12.0-211.16.1.el10_2.x86_64/kernel/fs/nfs/nfsv4.ko.xz       <-- new
usr/lib/modules/6.12.0-211.16.1.el10_2.x86_64/kernel/fs/nfs_common/grace.ko.xz
usr/lib/modules/6.12.0-211.16.1.el10_2.x86_64/kernel/fs/nfs_common/nfs_localio.ko.xz
usr/lib/modules/6.12.0-211.16.1.el10_2.x86_64/kernel/net/sunrpc/auth_gss/auth_rpcgss.ko.xz
usr/lib/modules/6.12.0-211.16.1.el10_2.x86_64/kernel/net/sunrpc/auth_gss/rpcsec_gss_krb5.ko.xz
usr/lib/modules/6.12.0-211.16.1.el10_2.x86_64/kernel/net/sunrpc/sunrpc.ko.xz
no nfs builtins
```

Note the `kata-snp` handler now reads `initrd = .../kata-cc.initrd`; the
`image =` path it carried before was the legacy 4.18 location.

And from inside a running `kata` pod at mount time, with nothing loaded by hand:

```
# grep -E '^(nfs|nfsv4|sunrpc) ' /proc/modules
nfsv4 1290240 0 - Live
nfs 626688 1 nfsv4, Live
sunrpc 884736 5 nfsv4,nfs,lockd,rpcsec_gss_krb5,auth_rpcgss, Live
```

Three consequences:

* **No `modprobe` and no `hostPath` are needed any more.** The kernel's
  on-demand `request_module("nfsv4")` now succeeds, so both manifests in
  `testing/` were stripped back to a plain mount. `/proc/modules` is still the
  check if anything misbehaves, never `/proc/filesystems`.
* **`sec=krb5p` became possible.** `rpcsec_gss_krb5.ko` is new in both guests,
  so an in-guest mount can be authenticated and encrypted rather than trusting
  a source IP - see [the security note](#security-note-for-the-confidential-case),
  and prefer a keytab released by Trustee over one baked into a manifest.
* **NFSv3 is still unavailable**, which costs nothing: `nfsv3.ko` is absent and
  v3's lock recovery needs the server to reach the pod IP, which the SNAT breaks.

The kernel moved in this upgrade (`5.14.0-687.39.1` to `5.14.0-687.55.1`), so
the per-kernel cache directory was rebuilt automatically - mtime confirmed
post-upgrade. Had the kernel not moved, the stale directory would have been
reused and would need forcing:
`rm -rf /var/cache/kata-containers/osbuilder-images/*` then
`systemctl restart kata-osbuilder-generate.service`, with no Kata pods on the
node and after reading `systemctl cat`.

`insecure` on the export is unrelated to this fix and still required.

The end-to-end mount was then re-run on the stripped-down manifest and passed:
`nfsv4` auto-loaded at mount time (`/proc/modules` showed it `Live` with
refcount 0, loaded by `request_module`, with `rpcsec_gss_krb5` and
`auth_rpcgss` alongside), the export mounted `nfs4 vers=4.2`, the seeded file
read back, and `df` inside the guest showed the helper's 255G filesystem
distinct from the 150G virtiofs rootfs. No `modprobe`, no `hostPath`, no access
to the host's modules.

Still outstanding: the sidecar pattern, `sec=krb5p`, and anything `kata-cc`,
which needs an SNP node.

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

The script also sets `insecure` on the export, which is required for a mount
made from a pod and is not the alarming thing its name suggests - see
[What `insecure` means, in plain terms](#what-insecure-means-in-plain-terms).

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
* **The export must say `insecure`.** This is measured, not a caveat: the client
  uses a privileged port (`resvport`) and exports default to `secure`, which
  requires one, but OVN's SNAT does **not** preserve the privileged port range -
  on this lab a mount arrived from port `33839`. `nfsd`'s
  `nfsd_originating_port_ok()` then returns `nfserr_perm`, which reaches the
  client as `mount.nfs: Operation not permitted`. The pod cannot influence the
  translation, so the export has to allow a non-reserved port. Confirm what the
  server sees with `ss -Htn state all '( sport = :2049 )'` on the helper while
  the mount is in flight. The same line gives the source address, which is the
  node IP of whichever node the pod landed on - check it against `oc get nodes
  -o wide` rather than assuming a particular node, which is the other reason the
  export ACL wants the node subnet and not a single address.
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

### What `insecure` means, in plain terms

The name is misleading. `insecure` does not turn off encryption, authentication,
permissions, or the list of who may mount the share. It controls exactly one
thing: **whether the server insists the client connect from a port number below
1024.**

Here is the background. On Unix, only the root user may open a port below 1024 -
those are the "reserved" ports. Decades ago NFS borrowed that as a cheap trust
signal: if a mount request arrives from a low port, then root on the client
machine must have sent it, so it is probably the operating system's own NFS
client rather than some program an ordinary user wrote. `secure` (the default)
means "require a low port". `insecure` means "accept any port". That is the
whole difference.

It was never a strong check. Anyone with root on a client machine can open a low
port and send whatever they like, so the test only ever separated *root on the
client* from *an ordinary user on the client*. If you do not trust root on the
machines in your export list, `secure` was not protecting you from them anyway.

**Why the pod needs it.** The NFS client inside the Kata guest does the right
thing and opens a reserved port. But the traffic leaves the cluster through
OVN's address translation, which rewrites the source port on the way out - in
this lab a mount arrived at the server from port 33839. The server sees a high
port, concludes "untrusted program", and refuses with `Operation not permitted`.
The pod cannot prevent this; the rewrite happens outside the guest, after the
packet has left. So the choice is `insecure` or no mount at all.

**What you still have.** Everything else about the export is unchanged: the IP
allow-list still decides who may mount, `rw`/`ro` still applies, root squashing
still applies, and the security flavour (`sec=sys`, `sec=krb5p`) is untouched.
What you give up is the ability to tell root from non-root on the client - which
in this topology was already gone, because every pod on a node reaches the
server as that node's single address regardless.

If it helps, read the option as "accept connections from high port numbers"
rather than "be insecure". The real protection for this share is the export's
address list, and `sec=krb5p` if you need more than that.

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
| `mount.nfs: Protocol not supported`, for every `vers=4.x` | The version module is missing from the guest rootfs, not the kernel. `grep -iE 'nfs\|sunrpc' /proc/modules` shows `nfs` loaded without `nfsv4`; the handler's initrd has no `nfsv4.ko`. Load it from the pod (see below). |
| `mount: unknown filesystem type 'nfs'` | Guest kernel has no NFS client. Check `zcat /proc/config.gz \| grep -i CONFIG_NFS` (if `CONFIG_IKCONFIG_PROC` is set), `cat /proc/filesystems`, `ls /lib/modules/$(uname -r)/kernel/fs/nfs`. If it is genuinely absent, the kernel-mount approach is out - see fallbacks below. |
| `mount.nfs: command not found` / `helper program not found` | The container image lacks `nfs-utils` - use `ubi-nfs-util`, not the app image. |
| `No route to host` / `nc` to 2049 times out | Firewall on the helper, or the node cannot reach the helper. Test from the node: `oc debug node/<node> -- chroot /host nc -vz <helper> 2049`. |
| `access denied by server while mounting` | Export ACL does not cover the *node* IP (pod traffic is SNATed). Fix `NFS_CLIENT_CIDR` and `exportfs -rav`. |
| `mount.nfs: Operation not permitted` | The export lacks `insecure` and SNAT moved the client off a reserved port, so `nfsd` returns `nfserr_perm`. Confirmed on this lab. Add `insecure` and `exportfs -rav`. |
| `Operation not permitted` on mount | Container is not privileged, or the CoCo agent policy blocked it. |
| Mount works, writes fail with `Permission denied` | `no_root_squash` missing, or the container runs as a UID the server does not map. Check `ls -ln` on the mount. |
| Files show as `nobody:nobody` | NFSv4 idmapping - set the same `Domain =` in `/etc/idmapd.conf` on the helper and in the client image, or use numeric IDs (`nfs4_disable_idmapping=1`). |
| Pod hangs in `Terminating`, or I/O blocks when the helper goes away | `hard` mounts block by design. Use `soft,timeo=100,retrans=2` for the test if you prefer failures over hangs, and remember the sidecar must outlive the app container. |
| Mount is invisible in the app container | Expected - the mount is per mount-namespace. Use the sidecar + `/proc/<pid>/root` pattern from the step 4 manifest. |
| SELinux denials inside the guest | Add `-o context="system_u:object_r:nfs_t:s0"` to the mount options. |

### If the guest kernel has no NFS client

Distinguish two cases first, because they have different answers. If
`/proc/modules` shows `nfs` loaded but a 4.x mount returns `Protocol not
supported`, the kernel is capable and only the version module is missing - start
at 1. If `nfs` is absent from `/proc/filesystems` altogether, the kernel has no
client at all - start at 4.

1. **Load the version module from the pod** - *historical, for builds before
   `kata-containers-3.31.0-5`, which ships `nfsv4.ko` in both guest rootfs
   images.* The node's own module tree has
   `nfsv4.ko` for the exact guest kernel version, Red Hat signed, and a
   privileged container can load a module from its own filesystem into the guest
   kernel. Pull the tree off the node, drop it in the pod, `modprobe`, mount:

   ```
   V=$(oc exec <pod> -- uname -r)

   oc debug node/<node> -- chroot /host tar czf - -C /usr/lib/modules/$V \
       kernel/fs kernel/net modules.dep modules.dep.bin modules.alias \
       modules.alias.bin modules.symbols modules.symbols.bin modules.builtin \
       modules.builtin.bin modules.order > /tmp/nfsmods.tgz

   oc cp /tmp/nfsmods.tgz <pod>:/tmp/nfsmods.tgz
   oc exec <pod> -- bash -c "mkdir -p /usr/lib/modules/$V \
       && tar xzf /tmp/nfsmods.tgz -C /usr/lib/modules/$V \
       && modprobe -S $V nfsv4 && grep -iE 'nfs|sunrpc' /proc/modules"
   ```

   For a real workload, bake the same files into the client image and
   `modprobe` in the mount sidecar before mounting. It works, but the module has
   to match the guest kernel *exactly*, so it breaks on every kernel update -
   treat it as a lab workaround and raise the missing module with Red Hat.
2. **Userspace NFS client (`libnfs`)** - no kernel support needed at all; the
   library speaks NFS over TCP 2049 directly. Good for an application you can
   relink or that can call `nfs-ls`/`nfs-cp`; not a POSIX mount.
3. **`fuse-nfs`** - gives you a real mountpoint via FUSE, and `fuse` is present
   in this guest kernel, so it is a live option.
4. **Custom guest kernel / initrd** - possible but no longer cheap. Repacking
   the initrd used to be something a CoCo deployment did anyway to inject a
   corporate CA; since OCP 4.20 that is handled by `initdata` and Trustee, so
   rebuilding it for one module means leaving the supported path. Raise it with
   Red Hat instead - see
   [GAP-nfsv4-guest-module.md](https://github.com/sadiquepp/openshift/blob/main/coco/nfs/GAP-nfsv4-guest-module.md).
5. **Kubernetes NFS volume / CSI** - works today, but the kubelet mounts the
   share on the host, which defeats the requirement.

NFSv3 is not on this list: `nfsv3.ko` is missing from the same rootfs, so it
fails identically, and its lock recovery needs the server to call back to the
pod IP, which the SNAT breaks.

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
