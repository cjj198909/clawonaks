# APIM subscriptions are managed dynamically by Admin Panel.
# Each agent gets a subscription created via `az apim subscription create`
# during the Admin Panel creation flow. See spec §5.2.
#
# The old static `for_each = var.agent_ids` approach is removed because
# agents are created/deleted at runtime, not at Terraform apply time.
