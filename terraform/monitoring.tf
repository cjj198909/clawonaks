resource "azurerm_log_analytics_workspace" "openclaw" {
  name                = "openclaw-logs"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "openclaw" {
  name                = "openclaw-insights"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.main.name
  workspace_id        = azurerm_log_analytics_workspace.openclaw.id
  application_type    = "web"
}
