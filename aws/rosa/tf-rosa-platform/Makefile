# Makefile — profile-based equivalent of the AAP workflow
# Use this if you prefer named AWS profiles over assume_role ARNs.
# Each target maps to one AAP job template.
#
# Prerequisites:
#   ~/.aws/credentials contains [vpc-owner] and [rosa-account] profiles
#   OR set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY before each target.

PLAN_FLAGS   ?= -out=tfplan
APPLY_FLAGS  ?= tfplan

# ── Full workflow (all four steps in sequence) ────────────────────────────────

.PHONY: all
all: step1 step2 step3 step4

# ── Step 1: Disconnected VPC — VPC owner account ──────────────────────────────

.PHONY: step1
step1:
	AWS_PROFILE=vpc-owner terraform apply $(PLAN_FLAGS) \
	  -target=module.disconnected_vpc
	AWS_PROFILE=vpc-owner terraform apply $(APPLY_FLAGS)

# ── Step 2: ROSA roles — ROSA cluster account ─────────────────────────────────

.PHONY: step2
step2:
	AWS_PROFILE=rosa-account terraform apply $(PLAN_FLAGS) \
	  -target=module.rosa_roles
	AWS_PROFILE=rosa-account terraform apply $(APPLY_FLAGS)

# ── Step 3: Share subnets — VPC owner account ─────────────────────────────────

.PHONY: step3
step3:
	AWS_PROFILE=vpc-owner terraform apply $(PLAN_FLAGS) \
	  -target=module.share_subnets
	AWS_PROFILE=vpc-owner terraform apply $(APPLY_FLAGS)

# ── Step 4: Bastion EC2 — ROSA cluster account ────────────────────────────────

.PHONY: step4
step4:
	AWS_PROFILE=rosa-account terraform apply $(PLAN_FLAGS) \
	  -target=module.installer_ec2
	AWS_PROFILE=rosa-account terraform apply $(APPLY_FLAGS)

# ── Teardown (reverse order) ──────────────────────────────────────────────────

.PHONY: destroy
destroy:
	AWS_PROFILE=rosa-account  terraform destroy -target=module.installer_ec2
	AWS_PROFILE=vpc-owner     terraform destroy -target=module.share_subnets
	AWS_PROFILE=rosa-account  terraform destroy -target=module.rosa_roles
	AWS_PROFILE=vpc-owner     terraform destroy -target=module.disconnected_vpc

.PHONY: init
init:
	terraform init
