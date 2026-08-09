# setup-bastion.yaml → roles migration

This version is built from an actual `git clone` of your repo
(`sadiquepp/openshift`, `cloud/self-managed/disconnected/`), not
reconstructed from scraped/rendered GitHub pages — every task, template,
and vars file below is a byte-for-byte copy or an exact re-transcription of
your real `setup-bastion.yaml`. Verified (see "Verification performed"
below), not just asserted.

## What's real vs. new

**Copied verbatim from your repo, unchanged:**
- `vars/aws.yaml`, `vars/azure.yaml`, `vars/gcp.yaml`, `vars/common.yaml`
- `roles/bastion_base/files/squid.conf`
- `roles/bastion_base/templates/{aws,azure,gcp}/squid-allow-list.txt.j2`
- `roles/bastion_base/tasks/cloud-setup/{aws,azure,gcp}.yaml`
- `roles/mirror_registry/templates/{imageset-config.yaml.j2, registry-trust.yaml.j2, apply-cluster-update.sh.j2}`
- `roles/openshift_installer_prep/templates/{aws,azure,gcp}/install-config.yaml.j2`
- `roles/openshift_installer_prep/tasks/cco/{aws,azure,gcp}.yaml`
- `roles/hcp_provisioning/templates/aws/{create-self-managed-hcp.sh.j2, hosted-cluster-hcp-pvt.yaml.j2, hypershift-secrets.yaml.j2}`
- `roles/hcp_provisioning/tasks/workaround.yaml`
- `tasks/scripts/azure.yaml` (kept at play level — see below)

**Rewritten but content-identical** (only the enclosing structure changed
— from a flat play's `tasks:` list to a role's `tasks/main.yml`):
- `roles/bastion_base/tasks/main.yml`
- `roles/mirror_registry/tasks/main.yml`
- `roles/openshift_installer_prep/tasks/main.yml`
- `roles/hcp_provisioning/tasks/main.yml`

**Genuinely new** (not in your original playbook at all):
- `roles/olm_catalog_suppression/` (both `tasks/main.yml` and
  `defaults/main.yml`) — the empty-catalog-image work from earlier in this
  conversation, packaged as its own role.

**Not copied — files that exist in your repo but aren't referenced by
`setup-bastion.yaml`** (so out of scope for this split): the various
`templates/aws/rosa-create-cluster-hcp*.sh.j2` and
`rosa-delete-cluster-hcp*.sh.j2` files, and
`templates/azure/{az-aro-create,install-cluster,reinstall-cluster}.sh.j2`.
If another playbook renders these, that playbook needs its own equivalent
treatment — not addressed here.

**Confirmed AWS-only today:** `create-self-managed-hcp.sh.j2`,
`hosted-cluster-hcp-pvt.yaml.j2`, and `hypershift-secrets.yaml.j2` only
exist under `templates/aws/` in your repo — no Azure/GCP equivalents exist
yet, so `hcp_provisioning/templates/` only has an `aws/` subdirectory.
This isn't an assumption — confirmed by the actual repo tree.

## Verification performed

1. **YAML syntax** — every `.yml`/`.yaml` file in this bundle (19 files)
   parses cleanly with `yaml.safe_load_all()`. Zero failures.
2. **Task-for-task fidelity** — extracted the ordered list of all 56 task
   `name:` fields from your real `setup-bastion.yaml` via YAML parse (not
   regex), and the same from the 4 role files combined + the one task kept
   at play level. Result: **exact set equality, zero missing, zero
   extra, zero duplicates.** 13 tasks in `bastion_base`, 21 in
   `mirror_registry`, 17 in `openshift_installer_prep`, 4 in
   `hcp_provisioning`, 1 (`Cloud-specific helper scripts`) left at the
   play level = 56, matching the original exactly.

## What still needs your attention

1. **`tasks/scripts/{{ cloud_provider }}.yaml`** — only `azure.yaml`
   exists in your repo under this path; there's no `aws.yaml` or
   `gcp.yaml`. The original playbook's `fileglob` guard already handles
   this gracefully (skips the include if the file doesn't exist), and the
   orchestrator preserves that exact guard. Left at the play level rather
   than folded into a role, same reasoning as before: it's a generic
   per-cloud hook, not clearly owned by any one role's responsibility —
   worth revisiting once you know what's likely to go in an `aws.yaml`/
   `gcp.yaml` version of it.

2. **New variable to set:** `olm_suppress_default_catalogs: true` in
   whichever `vars/*.yaml` you want it active for — defaults to `false`
   (role skipped) if unset, so existing environments are unaffected until
   you opt in.

3. **Duplicate CA read, preserved as-is:** your original file reads the
   Quay root CA from disk *twice* — once in the (now)
   `openshift_installer_prep` role (conditional on `install_dir_check`,
   feeds the `install-config.yaml` CA append) and again, unconditionally,
   in the (now) `mirror_registry` role (feeds `mirror_registry_ca_cert`
   used by `registry-trust.yaml.j2` and everything downstream, including
   `hcp_provisioning` and `olm_catalog_suppression`). This is carried over
   exactly as your original does it — not something introduced by the
   split — flagging only so it doesn't look like a bug during review.

## Suggested verification before replacing the original file

```bash
ansible-playbook setup-bastion.yaml --syntax-check
ansible-playbook setup-bastion.yaml --check --diff   # dry-run against a test bastion
```

Run against a disposable/test bastion first — several tasks are
`stat`-gated for idempotency but a few aren't (Terraform repo file, VNC
user, Squid restart), so a dry run won't catch everything a real apply
would.
