resource "azurerm_api_management" "openclaw" {
  count = var.enable_apim ? 1 : 0

  name                = "openclaw-apim"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.main.name
  publisher_name      = "OpenClaw"
  publisher_email     = var.admin_email
  sku_name            = "StandardV2_1"

  identity {
    type = "SystemAssigned"
  }

  # StandardV2 does NOT support virtual_network_type = "Internal".
  # Only PremiumV2 supports full VNet injection for v2 tiers.
  # Security is maintained through:
  # 1. APIM subscription keys (per-agent, useless without knowing the endpoint)
  # 2. Azure OpenAI key in Named Value (never exposed to pods)
  # 3. Rate limiting via llm-token-limit policy (60K TPM per agent)
  # TODO: Migrate to PremiumV2 for Internal VNet if budget allows.
}

# NOTE: Private DNS zone + A record removed.
# StandardV2 does not support Internal VNet mode (no private IP).
# If migrating to PremiumV2, restore the Private DNS Zone + A Record + VNet Link.
# See git history for the original blocks.

# APIM Logger is now created by install-v2.sh via az CLI.
