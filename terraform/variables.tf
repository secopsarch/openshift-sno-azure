variable "subscription_id" {
  description = "Azure subscription ID where the DNS resource group will be created."
  type        = string
}

variable "azure_region" {
  description = "Azure region for the DNS resource group. Should match the OpenShift cluster region."
  type        = string
  default     = "eastus2"
}

variable "dns_resource_group_name" {
  description = "Name of the resource group that will contain the Azure DNS zone. This value must match baseDomainResourceGroupName in install-config.yaml."
  type        = string
  default     = "sno-dns-rg"
}

variable "dns_zone_name" {
  description = "The public DNS zone name to create in Azure. This becomes the baseDomain in install-config.yaml. Example: ocplab1.arunkube.org"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all Terraform-managed resources."
  type        = map(string)
  default = {
    project    = "openshift-sno"
    managed-by = "terraform"
    phase      = "phase1"
  }
}
