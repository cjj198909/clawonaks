# AKS kubelet -> ACR pull
resource "azurerm_role_assignment" "aks_acr" {
  scope                = azurerm_container_registry.openclaw.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.openclaw.kubelet_identity[0].object_id
}

# APIM MI -> Cognitive Services OpenAI User (MI auth mode only)
resource "azurerm_role_assignment" "apim_ai_user" {
  count = var.enable_apim && var.apim_backend_auth_mode == "managed_identity" ? 1 : 0

  scope                = var.enable_ai_foundry ? azurerm_cognitive_account.ai_foundry[0].id : var.aoai_resource_id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_api_management.openclaw[0].identity[0].principal_id
}

# APIM MI -> Key Vault Secrets User (API Key mode: read Named Value)
resource "azurerm_role_assignment" "apim_kv_reader" {
  count = var.enable_apim && var.apim_backend_auth_mode == "api_key" ? 1 : 0

  scope                = azurerm_key_vault.openclaw.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_api_management.openclaw[0].identity[0].principal_id
}

# Admin MI -> APIM Service Contributor (dynamic subscription CRUD)
resource "azurerm_role_assignment" "admin_apim_contributor" {
  count = var.enable_apim ? 1 : 0

  scope                = azurerm_api_management.openclaw[0].id
  role_definition_name = "API Management Service Contributor"
  principal_id         = azurerm_user_assigned_identity.admin.principal_id
}

# Workload Identity: User-Assigned MI for sandbox pods
resource "azurerm_user_assigned_identity" "sandbox" {
  name                = "openclaw-sandbox-identity"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location
}

resource "azurerm_federated_identity_credential" "sandbox" {
  name                = "openclaw-sandbox-fedcred"
  resource_group_name = data.azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.sandbox.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.openclaw.oidc_issuer_url
  subject             = "system:serviceaccount:openclaw:openclaw-sandbox"
}

# Sandbox pods -> Key Vault Secrets User
# NOTE: Use .principal_id (object ID), NOT .id (resource ID)
resource "azurerm_role_assignment" "sandbox_kv_reader" {
  scope                = azurerm_key_vault.openclaw.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.sandbox.principal_id
}

# Admin Panel: User-Assigned MI for Key Vault write access
resource "azurerm_user_assigned_identity" "admin" {
  name                = "openclaw-admin-identity"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location
}

resource "azurerm_federated_identity_credential" "admin" {
  name                = "openclaw-admin-fedcred"
  resource_group_name = data.azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.admin.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.openclaw.oidc_issuer_url
  subject             = "system:serviceaccount:openclaw:openclaw-admin"
}

# Admin Panel -> Key Vault Secrets Officer (read + write secrets)
resource "azurerm_role_assignment" "admin_kv_officer" {
  scope                = azurerm_key_vault.openclaw.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_user_assigned_identity.admin.principal_id
}

# Deployer (whoever runs terraform apply) -> Key Vault Secrets Officer
# Required for install.sh Step 5 to write the Azure OpenAI key
resource "azurerm_role_assignment" "deployer_kv_officer" {
  scope                = azurerm_key_vault.openclaw.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}
