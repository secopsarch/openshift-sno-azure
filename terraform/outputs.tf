output "dns_zone_name" {
  description = "The Azure DNS zone name. Use this as baseDomain in install-config.yaml."
  value       = azurerm_dns_zone.base.name
}

output "dns_resource_group_name" {
  description = "The resource group containing the DNS zone. Use this as baseDomainResourceGroupName in install-config.yaml."
  value       = azurerm_resource_group.dns.name
}

output "dns_name_servers" {
  description = "Azure DNS name servers assigned to the zone. Add these as NS records in your parent domain (labX.arunkube.org) to delegate ocp.labX.arunkube.org to Azure DNS."
  value       = azurerm_dns_zone.base.name_servers
}

output "ns_delegation_instructions" {
  description = "Human-readable reminder for NS delegation."
  value = <<-EOT
    Add the following NS records to your parent zone (at your registrar or parent DNS zone):

    Zone: ${var.dns_zone_name}
    NS records to add:
    ${join("\n    ", azurerm_dns_zone.base.name_servers)}

    After adding NS records, verify with:
      dig NS ${var.dns_zone_name} @8.8.8.8 +short

    Do NOT run openshift-install until NS delegation is verified.
  EOT
}
