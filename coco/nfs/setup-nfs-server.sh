#!/usr/bin/env bash
#
# Set up a kernel NFS server to test direct (in-pod) NFS
# mounts from sandboxed containers / CoCo pods.
#
# Run this on the NFS server (RHEL 8/9) as root. It is idempotent.
#
#   sudo ./setup-nfs-server.sh
#
# Override any of the defaults with environment variables, eg
#
#   sudo NFS_EXPORT_DIR=/srv/nfs/kata NFS_CLIENT_CIDR=192.168.122.0/24 ./setup-nfs-server.sh
#
set -euo pipefail

# Directory exported to the pods.
NFS_EXPORT_DIR="${NFS_EXPORT_DIR:-/srv/nfs/kata}"
# Who is allowed to mount. Pod traffic leaving the cluster network is SNATed to
# the node IP, so this must cover the OpenShift *node* addresses, not the pod CIDR.
NFS_CLIENT_CIDR="${NFS_CLIENT_CIDR:-192.168.122.0/24}"
# insecure is REQUIRED for a mount made from inside a pod, and is not optional.
# mount.nfs opens a reserved source port, but OVN SNATs pod traffic leaving the
# cluster network and does not preserve the privileged port range - measured at
# 33839 on this lab. nfsd's nfsd_originating_port_ok() then returns nfserr_perm
# for a non-reserved port unless the export says insecure, which surfaces as
# "mount.nfs: Operation not permitted". The pod cannot influence the translation.
# no_root_squash is needed because the test container mounts and writes as root
# inside the Kata guest. Drop it once the application runs as a normal UID.
NFS_EXPORT_OPTS="${NFS_EXPORT_OPTS:-rw,sync,no_wdelay,no_subtree_check,no_root_squash,insecure}"
# Serve NFSv4 only (single port 2049/tcp). Set to "y" to also enable NFSv3,
# which additionally needs rpcbind/mountd/statd ports opened.
NFS_ENABLE_V3="${NFS_ENABLE_V3:-n}"
EXPORTS_FILE="/etc/exports.d/kata-coco.exports"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run this script as root." >&2
  exit 1
fi

echo "== Installing nfs-utils"
dnf -y install nfs-utils

echo "== Creating export directory ${NFS_EXPORT_DIR}"
mkdir -p "${NFS_EXPORT_DIR}"
# The test pod writes as root and no_root_squash is set, so ownership only
# matters for non-root clients. 0777 keeps the test simple.
chmod 0777 "${NFS_EXPORT_DIR}"

# Seed a file so the pod can prove it is reading data served by the NFS server and
# not a local emptyDir.
if [[ ! -e "${NFS_EXPORT_DIR}/from-nfs-server.txt" ]]; then
  echo "written on $(hostname -f) at $(date -Is)" > "${NFS_EXPORT_DIR}/from-nfs-server.txt"
fi

if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
  echo "== Labelling ${NFS_EXPORT_DIR} for NFS export (SELinux)"
  # nfs_export_all_rw lets the kernel server export a directory that is not
  # explicitly labelled public_content_rw_t.
  setsebool -P nfs_export_all_rw 1
  setsebool -P nfs_export_all_ro 1
  if command -v semanage >/dev/null 2>&1; then
    semanage fcontext -a -t public_content_rw_t "${NFS_EXPORT_DIR}(/.*)?" 2>/dev/null \
      || semanage fcontext -m -t public_content_rw_t "${NFS_EXPORT_DIR}(/.*)?"
    restorecon -Rv "${NFS_EXPORT_DIR}"
  fi
fi

echo "== Configuring NFS protocol versions (v3 enabled: ${NFS_ENABLE_V3})"
if [[ "${NFS_ENABLE_V3}" == "y" ]]; then
  sed -i -e 's/^[# ]*vers3[ ]*=.*/vers3=y/' /etc/nfs.conf
  grep -q '^vers3=y' /etc/nfs.conf || sed -i '/^\[nfsd\]/a vers3=y' /etc/nfs.conf
else
  sed -i -e 's/^[# ]*vers3[ ]*=.*/vers3=n/' /etc/nfs.conf
  grep -q '^vers3=n' /etc/nfs.conf || sed -i '/^\[nfsd\]/a vers3=n' /etc/nfs.conf
fi

echo "== Writing ${EXPORTS_FILE}"
mkdir -p /etc/exports.d
cat > "${EXPORTS_FILE}" <<EOF
# Managed by coco/nfs/setup-nfs-server.sh - direct in-pod NFS mount test.
${NFS_EXPORT_DIR} ${NFS_CLIENT_CIDR}(${NFS_EXPORT_OPTS})
# localhost is exported so the self-test at the end of this script can mount it.
${NFS_EXPORT_DIR} 127.0.0.1/32(${NFS_EXPORT_OPTS})
EOF

echo "== Enabling and starting nfs-server"
systemctl enable --now nfs-server
exportfs -rav

if systemctl is-active --quiet firewalld; then
  echo "== Opening firewall ports"
  firewall-cmd --permanent --add-service=nfs
  if [[ "${NFS_ENABLE_V3}" == "y" ]]; then
    firewall-cmd --permanent --add-service=rpc-bind
    firewall-cmd --permanent --add-service=mountd
  fi
  firewall-cmd --reload
else
  echo "== firewalld is not running, skipping firewall configuration"
  echo "   Make sure 2049/tcp is reachable from the OpenShift nodes."
fi

echo
echo "== Current exports"
exportfs -v
echo
echo "== Local mount self-test"
TESTDIR="$(mktemp -d)"
if mount -t nfs -o vers=4.2 "127.0.0.1:${NFS_EXPORT_DIR}" "${TESTDIR}"; then
  ls -l "${TESTDIR}"
  umount "${TESTDIR}"
  echo "   OK: server is serving ${NFS_EXPORT_DIR} over NFSv4.2"
else
  echo "   FAILED: local mount did not work, fix the server before testing the pod" >&2
fi
rmdir "${TESTDIR}"

echo
echo "Export ready. Use this in the pod manifest:"
echo "  NFS_SERVER=$(hostname -I | awk '{print $1}')"
echo "  NFS_EXPORT=${NFS_EXPORT_DIR}"
