# Terraform manages ONLY the DNS prerequisites for OpenShift SNO.
#
# Scope boundary:
#   Terraform owns:  This resource group + the Azure DNS zone.
#   openshift-install owns: Everything else (VNet, VMs, LBs, NSGs, IPs,
#                           DNS A records, storage, managed identities).
#
# Never add resources that openshift-install creates. Adding them here will
# cause resource ownership conflicts and make cluster destroy unreliable.

resource "azurerm_resource_group" "dns" {
  name     = var.dns_resource_group_name
  location = var.azure_region
  tags     = var.tags
}

resource "azurerm_dns_zone" "base" {
  name                = var.dns_zone_name
  resource_group_name = azurerm_resource_group.dns.name
  tags                = var.tags
}
