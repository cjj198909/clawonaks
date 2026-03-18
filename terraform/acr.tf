resource "azurerm_container_registry" "openclaw" {
  name                = "openclawacr${random_id.suffix.hex}"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = false
}
