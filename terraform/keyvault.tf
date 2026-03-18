resource "azurerm_key_vault" "openclaw" {
  name                = "openclaw-kv-${random_id.suffix.hex}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.main.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true

  # TODO: revert to Deny after feishu secrets are set
  public_network_access_enabled = true

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }
}
