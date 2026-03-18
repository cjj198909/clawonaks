output "aks_fqdn" {
  value = azurerm_kubernetes_cluster.openclaw.fqdn
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.openclaw.name
}

output "acr_name" {
  value = azurerm_container_registry.openclaw.name
}

output "acr_login_server" {
  value = azurerm_container_registry.openclaw.login_server
}

output "apim_private_url" {
  value = var.enable_apim ? "https://${azurerm_api_management.openclaw[0].name}.azure-api.net" : ""
}

output "apim_private_ip" {
  value = ""  # StandardV2 has no private IP (no Internal VNet support)
}

output "keyvault_name" {
  value = azurerm_key_vault.openclaw.name
}

output "sandbox_identity_client_id" {
  value = azurerm_user_assigned_identity.sandbox.client_id
}

output "resource_group" {
  value = data.azurerm_resource_group.main.name
}

output "apim_name" {
  value = var.enable_apim ? azurerm_api_management.openclaw[0].name : ""
}

output "storage_account_name" {
  value = azurerm_storage_account.openclaw.name
}

output "admin_identity_client_id" {
  value = azurerm_user_assigned_identity.admin.client_id
}

output "apim_gateway_url" {
  description = "APIM gateway base URL for agent config"
  value       = var.enable_apim ? "https://${azurerm_api_management.openclaw[0].name}.azure-api.net" : ""
}

output "app_insights_instrumentation_key" {
  value     = azurerm_application_insights.openclaw.instrumentation_key
  sensitive = true
}
