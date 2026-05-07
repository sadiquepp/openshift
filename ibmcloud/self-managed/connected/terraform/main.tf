terraform {
  required_version = ">= 1.5"
  required_providers {
    ibm = {
      source  = "IBM-Cloud/ibm"
      version = "~> 1.70"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "ibm" {
  region           = var.ibmcloud_region
  ibmcloud_api_key = var.ibmcloud_api_key != "" ? var.ibmcloud_api_key : null
}

resource "ibm_resource_group" "created" {
  count = var.create_resource_group ? 1 : 0
  name  = var.resource_group_name
}

data "ibm_resource_group" "existing" {
  count = var.create_resource_group ? 0 : 1
  name  = var.resource_group_name
}

locals {
  resource_group_id = var.create_resource_group ? ibm_resource_group.created[0].id : data.ibm_resource_group.existing[0].id
}
