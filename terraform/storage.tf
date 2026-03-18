resource "azurerm_storage_account" "openclaw" {
  name                     = "openclawst${random_id.suffix.hex}"
  resource_group_name      = data.azurerm_resource_group.main.name
  location                 = var.location
  account_tier             = "Premium"
  account_replication_type = "LRS"
  account_kind             = "FileStorage"
  https_traffic_only_enabled    = false  # Required for NFS shares
  shared_access_key_enabled     = false  # NFS doesn't use shared keys; avoids drift

  # TODO: revert to Deny after NFS mount is verified
  public_network_access_enabled = true

  network_rules {
    default_action             = "Allow"
    bypass                     = ["AzureServices"]
    virtual_network_subnet_ids = [azurerm_subnet.aks.id]
  }
}

resource "azurerm_storage_share" "openclaw" {
  name               = "openclaw-data"
  storage_account_id = azurerm_storage_account.openclaw.id
  enabled_protocol   = "NFS"
  quota              = 100
}
