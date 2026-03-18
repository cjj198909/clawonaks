resource "azurerm_cognitive_account" "ai_foundry" {
  count = var.enable_ai_foundry ? 1 : 0

  name                  = "openclaw-ai-${random_id.suffix.hex}"
  location              = var.location
  resource_group_name   = data.azurerm_resource_group.main.name
  kind                  = "OpenAI"
  sku_name              = "S0"
  custom_subdomain_name = "openclaw-ai-${random_id.suffix.hex}"

  public_network_access_enabled = false

  network_acls {
    default_action = "Deny"
  }
}

resource "azurerm_cognitive_deployment" "gpt5" {
  count = var.enable_ai_foundry ? 1 : 0

  name                 = "gpt-5"
  cognitive_account_id = azurerm_cognitive_account.ai_foundry[0].id

  model {
    format  = "OpenAI"
    name    = "gpt-5"
    version = "latest"
  }

  sku {
    name     = "Standard"
    capacity = 60
  }
}
