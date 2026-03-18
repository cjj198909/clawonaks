# ---------------------------------------------------------------------------
# Private DNS Zones
# ---------------------------------------------------------------------------

resource "azurerm_private_dns_zone" "cognitive" {
  count = var.enable_ai_foundry ? 1 : 0

  name                = "privatelink.cognitiveservices.azure.com"
  resource_group_name = data.azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone" "storage_file" {
  name                = "privatelink.file.core.windows.net"
  resource_group_name = data.azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone" "keyvault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = data.azurerm_resource_group.main.name
}

# ---------------------------------------------------------------------------
# VNet Links
# ---------------------------------------------------------------------------

resource "azurerm_private_dns_zone_virtual_network_link" "cognitive" {
  count = var.enable_ai_foundry ? 1 : 0

  name                  = "cognitive-vnet-link"
  resource_group_name   = data.azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.cognitive[0].name
  virtual_network_id    = azurerm_virtual_network.main.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage_file" {
  name                  = "storage-file-vnet-link"
  resource_group_name   = data.azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.storage_file.name
  virtual_network_id    = azurerm_virtual_network.main.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "keyvault" {
  name                  = "keyvault-vnet-link"
  resource_group_name   = data.azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.keyvault.name
  virtual_network_id    = azurerm_virtual_network.main.id
}

# ---------------------------------------------------------------------------
# Private Endpoints
# ---------------------------------------------------------------------------

# AI Foundry PE
resource "azurerm_private_endpoint" "ai_foundry" {
  count = var.enable_ai_foundry ? 1 : 0

  name                = "pe-ai-foundry"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "ai-foundry-connection"
    private_connection_resource_id = azurerm_cognitive_account.ai_foundry[0].id
    is_manual_connection           = false
    subresource_names              = ["account"]
  }

  private_dns_zone_group {
    name                 = "ai-foundry-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.cognitive[0].id]
  }
}

# Storage Files PE
resource "azurerm_private_endpoint" "storage_files" {
  name                = "pe-storage-files"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "files-connection"
    private_connection_resource_id = azurerm_storage_account.openclaw.id
    is_manual_connection           = false
    subresource_names              = ["file"]
  }

  private_dns_zone_group {
    name                 = "files-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage_file.id]
  }
}

# Key Vault PE
resource "azurerm_private_endpoint" "keyvault" {
  name                = "pe-keyvault"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "kv-connection"
    private_connection_resource_id = azurerm_key_vault.openclaw.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "kv-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.keyvault.id]
  }
}
