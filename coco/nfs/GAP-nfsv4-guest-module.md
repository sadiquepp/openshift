# Gap: Kata guest rootfs ships `nfs.ko` without `nfsv4.ko`, so in-guest NFS mounts fail

> **Do not file this yet - it is reported fixed.** Red Hat reports NFSv4 support
> landed in Kata **3.31.0-5**. To pick it up, upgrade to the latest 4.22 z-stream
> (kata v6), or to any of 4.22.11 - 4.22.18 (kata v5). Verify on an upgraded
> cluster before filing anything: if the mount works with no `modprobe` and no
> `hostPath`, this document is a historical record of the diagnosis on the
> affected versions, not a bug report. File only if the gap survives the
> upgrade.

Write-up for a Red Hat support case / Jira against OpenShift sandboxed containers.
Everything under **Evidence** was measured on the lab described below; the
**Root cause** section is analysis of upstream kernel behaviour that is
consistent with all of it.

---

## Suggested filing

| Field | Value |
|---|---|
| Summary | Kata guest rootfs ships `nfs.ko` without `nfsv4.ko`/`nfsv3.ko`, so NFS mounts from inside the guest fail with `EPROTONOSUPPORT` |
| Type | Bug (the shipped module set is internally inconsistent). May be re-triaged as an RFE if in-guest NFS was never intended to work - in that case the ask stands as a feature request, see **Request**. |
| Component | openshift-sandboxed-containers / Kata guest image (osbuilder-generated rootfs, and the confidential rootfs shipped in the RHCOS layer image) |
| Priority justification | Blocks the documented pattern of mounting storage *inside* a confidential guest, which is the only way to keep the share unreadable by the host |

## Environment

Re-verify these against the cluster immediately before filing - they are what
the lab ran when the evidence below was captured, not necessarily what it runs
now:

```
oc get csv -n openshift-sandboxed-containers-operator
oc get node <node> -o wide
oc exec <kata-pod> -- uname -r
```

| | |
|---|---|
| OSC operator | `sandboxed-containers-operator.v1.13.1` |
| OpenShift | 4.22 (`cri-o://1.35.6-4.rhaos4.22.git41f610b.el9`, kubelet `v1.35.6`) |
| Node OS | Red Hat Enterprise Linux CoreOS 9.8.20260812-0 |
| Runtime class | `kata` (plain sandboxed containers, non-confidential) |
| Guest kernel | `5.14.0-687.39.1.el9_8.x86_64` |
| Guest artefacts | `/var/cache/kata-containers/osbuilder-images/kata.{kernel,initrd}` |
| Confidential artefacts | `/usr/share/kata-containers/osbuilder-images/kata-cc.{kernel,initrd}`, module tree `6.12.0-211.16.1.el10_2.x86_64` |
| NFS server | RHEL, NFSv4.2, export `/srv/nfs/kata` with `rw,no_root_squash,insecure` |

## Steps to reproduce

1. Install the OSC operator and apply a `KataConfig` so the `kata` runtime class exists.
2. Stand up an NFSv4 server reachable from the cluster nodes and export a directory.
   The export needs `insecure` - see **Related** below.
3. Run a privileged pod with `runtimeClassName: kata` and an image carrying
   `nfs-utils` (for example `quay.io/rh-ee-chbutler/ubi-storage-util:latest`,
   which ships `nfs-utils-2.8.3-5.el10_2`).
4. From inside the pod:

   ```
   mount -t nfs -o vers=4.2,rw,hard,timeo=600,retrans=2 <server>:/srv/nfs/kata /mnt/nfs
   ```

### Actual result

```
mount.nfs: Protocol not supported for <server>:/srv/nfs/kata on /mnt/nfs
```

Identical for `vers=4.2`, `vers=4.1`, `vers=4.0` and `vers=4`. With
`-o nolock,vers=3` the same failure follows, once `mount.nfs`' own `rpc.statd`
check is bypassed.

### Expected result

The share mounts. The guest kernel is a RHEL kernel with a working NFS client -
see **Evidence 4**, where the identical mount succeeds after one module is added.

## Evidence

**1. The failure is not the network, the server or the export.** TCP 2049 is
reachable from inside the guest, and `showmount` lists the export:

```
# from inside the pod
showmount -e <server>
Export list for <server>:
/srv/nfs/kata 127.0.0.1/32,192.168.122.0/24
```

**2. `/proc/filesystems` is misleading - it lists both types:**

```
# from inside the pod
nodev	nfs
nodev	nfs4
```

**3. `/proc/modules` shows the version module is absent,** while its
dependencies are all loaded:

```
# from inside the pod, before any intervention
nfs 626688 1 nfsv4, Live
lockd 188416 1 nfs, Live
fscache 405504 1 nfs, Live
netfs 65536 2 nfs,fscache, Live
sunrpc 884736 3 nfsv4,nfs,lockd, Live
```

and the guest rootfs confirms why - no `nfsv4.ko`, no `nfsv3.ko`:

```
# on the node
# zcat /var/cache/kata-containers/osbuilder-images/kata.initrd | cpio -it 2>/dev/null | grep -iE 'nfs|sunrpc'
usr/lib/modules/5.14.0-687.39.1.el9_8.x86_64/kernel/net/sunrpc
usr/lib/modules/5.14.0-687.39.1.el9_8.x86_64/kernel/net/sunrpc/sunrpc.ko.xz
usr/lib/modules/5.14.0-687.39.1.el9_8.x86_64/kernel/fs/nfs_common
usr/lib/modules/5.14.0-687.39.1.el9_8.x86_64/kernel/fs/nfs_common/grace.ko.xz
usr/lib/modules/5.14.0-687.39.1.el9_8.x86_64/kernel/fs/nfs
usr/lib/modules/5.14.0-687.39.1.el9_8.x86_64/kernel/fs/nfs/nfs.ko.xz
```

**4. Adding the one missing module makes the mount work,** which proves the
guest kernel itself is capable and isolates the gap to the rootfs contents.
Taking the module from the node's own tree (the plain `kata` guest kernel is
built from the host kernel, so vermagic and signature both match):

```
V=5.14.0-687.39.1.el9_8.x86_64
oc debug node/<node> -- chroot /host tar czf - -C /usr/lib/modules/$V \
    kernel/fs kernel/net modules.dep modules.dep.bin modules.alias modules.alias.bin \
    modules.symbols modules.symbols.bin modules.builtin modules.builtin.bin modules.order \
  > /tmp/nfsmods.tgz
oc cp /tmp/nfsmods.tgz <pod>:/tmp/nfsmods.tgz

# in the pod
tar xzf /tmp/nfsmods.tgz -C /usr/lib/modules/$V
modprobe -S $V nfsv4
mount -t nfs -o vers=4.2,rw,hard,timeo=600,retrans=2 <server>:/srv/nfs/kata /mnt/nfs
```

Result - mounted, and read/write verified against data the server had seeded:

```
<server>:/srv/nfs/kata on /mnt/nfs type nfs4 (rw,relatime,vers=4.2,rsize=1048576,
wsize=1048576,namlen=255,hard,proto=tcp,timeo=600,retrans=2,sec=sys,
clientaddr=10.128.0.17,local_lock=none,addr=<server>)
```

**5. The confidential guest image shows the same pattern,** so the fix is needed
in both images, and as two separate changes - they are different kernel builds,
not variants of one:

```
# on the node
# zcat /usr/share/kata-containers/osbuilder-images/kata-cc.initrd | cpio -it 2>/dev/null | grep -i nfs
usr/lib/modules/6.12.0-211.16.1.el10_2.x86_64/kernel/fs/nfs
usr/lib/modules/6.12.0-211.16.1.el10_2.x86_64/kernel/fs/nfs/nfs.ko.xz
usr/lib/modules/6.12.0-211.16.1.el10_2.x86_64/kernel/fs/nfs_common
usr/lib/modules/6.12.0-211.16.1.el10_2.x86_64/kernel/fs/nfs_common/grace.ko.xz
usr/lib/modules/6.12.0-211.16.1.el10_2.x86_64/kernel/fs/nfs_common/nfs_localio.ko.xz
```

`nfs.ko` present, `nfsv4.ko` and `nfsv3.ko` absent - identical to the plain
`kata` rootfs in **Evidence 3**, at a different kernel (`6.12.0-211.16.1.el10_2`,
RHEL 10, against `5.14.0-687.39.1.el9_8`, RHEL 9, for plain `kata`).

Two caveats on this item, stated plainly rather than glossed:

- It has not been reproduced on a *running* CoCo guest; no SNP node was
  available. The mount failure is inferred from the image contents, by the same
  mechanism proven in **Evidence 3 and 4**.
- The file inspected is `kata-cc.initrd`, which is what the `kata-tdx` handler's
  `configuration.toml` references. The `kata-snp` handler on this node
  references `image = /usr/share/kata-containers/kata-containers-confidential.img`,
  which was not present on the node and so could not be inspected. The two are
  expected to be built from the same rootfs content, but that was not verified.

**And on the confidential side there is no workaround at all,** which is the
part that makes this worth fixing rather than documenting. The runtime injection
used in **Evidence 4** is not merely unacceptable inside a TEE - it is
technically impossible: the host's module tree is `5.14.0-687.39.1.el9_8` while
the confidential guest kernel is `6.12.0-211.16.1.el10_2`, so vermagic can never
match. Obtaining modules for that exact el10 build means obtaining them from the
confidential image itself, which is where `nfsv4.ko` is missing.

## Root cause (analysis)

`nfs.ko` registers *both* the `nfs` and `nfs4` `file_system_type` names and
resolves the version implementation lazily, via `request_module("nfsv%u")`, on
the first mount. With `nfsv4.ko` absent from the guest rootfs that request
fails and the mount returns `-EPROTONOSUPPORT`, surfacing as
`mount.nfs: Protocol not supported`.

Two consequences worth noting for triage:

- `/proc/filesystems` listing `nfs` and `nfs4` is **not** evidence that NFS is
  usable, which makes this gap easy to misdiagnose. `grep '^nfsv4 ' /proc/modules`
  is the real check.
- Shipping `nfs.ko`, `sunrpc.ko`, `grace.ko`, `lockd.ko`, `fscache.ko` and
  `netfs.ko` *without* any version module leaves a client that can never mount
  anything. That internal inconsistency is the basis for filing this as a bug
  rather than a feature request.

## Request

Include the NFS version modules in the Kata guest rootfs, for both the
osbuilder-generated plain `kata` image and the confidential rootfs shipped in
the RHCOS layer image:

- `kernel/fs/nfs/nfsv4.ko` - required for any NFSv4.x mount
- `kernel/fs/nfs/nfsv3.ko` - if NFSv3 is to be usable at all
- optionally the pNFS layout drivers (`blocklayout`, `filelayout`, `flexfilelayout`)
- with `modules.dep`/`modules.alias` regenerated so `modprobe` resolves them

Building `CONFIG_NFS_FS`/`CONFIG_NFS_V4` into the guest kernel would work
equally well. Either way the module set should be self-consistent: ship the
version modules alongside `nfs.ko`, or ship neither.

If they cannot be included by default, the alternative ask is a supported and
**attested** way to add a kernel module to a confidential guest. Note that
`initdata` is already bound into the attestation report (HOSTDATA on SNP), so a
mechanism built on it would keep the module inside the measured boundary -
unlike anything injected from the host at runtime, which is the only option
available today and is not acceptable inside a TEE. Since OCP 4.20 removed the
customer-side initrd rebuild in favour of `initdata` and Trustee, there is
currently no attested path for this at all.

## Why the existing workarounds are not sufficient

| Workaround | Why it does not close the gap |
|---|---|
| `hostPath` the host's `/usr/lib/modules` into the pod and `modprobe` | Works for plain `kata`, because its guest kernel is built from the host's. **Unacceptable for CoCo** - it loads host-supplied kernel code inside the TEE, precisely the influence a confidential guest exists to deny - and in any case **impossible** there: the host tree is `5.14.0-687.39.1.el9_8` and the confidential guest kernel is `6.12.0-211.16.1.el10_2`, so vermagic can never match. Also needs `privileged` and `hostPath` in the SCC. |
| Bake the `.ko` into the workload image | Must match the guest `uname -r` exactly, so it breaks on every kernel update; and for CoCo it is still code arriving from outside the attested image. For the confidential guest it is also unclear where a customer would obtain modules for the `6.12.0-211.16.1.el10_2` build other than from the confidential image itself, which is the image missing the module. |
| Rebuild the confidential rootfs/initrd to add the module | **No longer a cheap option.** Repacking the initrd was once something customers already did to inject a corporate CA and registry auth, but that is obsolete: since OCP 4.20 registry credentials are served by Trustee and the CA is injected via `initdata`, so the supported flow involves no customer-side rebuild of the guest artefacts at all. Reintroducing one for a single module means leaving the supported path and owning a modified guest image. |
| `kernel_modules` in `configuration.toml`, or the `io.katacontainers.config.agent.kernel_modules` annotation | No help: kata-agent's `modprobe` also resolves from the guest rootfs, so it can only load modules that are already there. |
| Userspace NFS client (`fuse-nfs`, `libnfs`) | Needs no kernel module and `fuse` is present in the guest, but it is not packaged in RHEL, performs worse than the kernel client, and does not give POSIX locking. |
| Kubernetes NFS volume or an NFS CSI driver | The kubelet mounts the share **on the host**, which defeats the entire requirement. |

## Impact / use case

A confidential workload needs its storage mounted *inside* the TEE, so that a
compromised or untrusted host cannot read it. Mounting the share from within the
guest over the pod network achieves that: the host, and the kubelet, never see
the filesystem. This mirrors the raw-block pattern already in use, where a
sidecar formats and mounts a block PVC inside the guest instead of letting the
kubelet do it.

Without the version module, NFS is the one storage type that cannot be used this
way, even though the guest kernel fully supports it.

## Related (not part of this request)

An in-pod NFS mount additionally requires `insecure` on the export. OVN-Kubernetes
SNATs pod traffic leaving the cluster network and does not preserve the client's
reserved source port - a mount arrived at the server from port `33839` - and
`nfsd`'s `nfsd_originating_port_ok()` returns `nfserr_perm` for a non-reserved
port unless the export says `insecure`, surfacing as
`mount.nfs: Operation not permitted`. The pod cannot influence the translation.
This is correct behaviour on all sides rather than a defect, but it is
non-obvious and worth a line in the OSC documentation if in-guest NFS becomes
supported.
