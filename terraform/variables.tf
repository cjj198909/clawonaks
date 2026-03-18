variable "resource_group" {
  description = "Pre-existing resource group name"
  type        = string
  default     = "openclaw-rg"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastasia"
}

variable "cluster_name" {
  description = "AKS cluster name"
  type        = string
  default     = "openclaw-aks"
}

variable "admin_email" {
  description = "APIM publisher email"
  type        = string
}

variable "agent_ids" {
  description = "Set of agent IDs for APIM subscriptions"
  type        = set(string)
  default     = []
}

variable "enable_apim" {
  description = "Deploy APIM resources (set false for initial infra testing)"
  type        = bool
  default     = true
}

variable "enable_ai_foundry" {
  description = "Deploy Azure OpenAI / AI Foundry resources (set false if using external endpoint)"
  type        = bool
  default     = true
}

variable "apim_backend_auth_mode" {
  description = "APIM backend auth: 'api_key' (Named Value from KV) or 'managed_identity'"
  type        = string
  default     = "api_key"

  validation {
    condition     = contains(["api_key", "managed_identity"], var.apim_backend_auth_mode)
    error_message = "Must be 'api_key' or 'managed_identity'."
  }
}

variable "aoai_endpoint" {
  description = "External Azure OpenAI endpoint URL (required when apim_backend_auth_mode = 'api_key')"
  type        = string
  default     = ""
}

variable "aoai_api_version" {
  description = "Azure OpenAI API version (injected as query parameter by APIM policy)"
  type        = string
  default     = "2025-04-01-preview"
}

variable "aoai_resource_id" {
  description = "Azure OpenAI resource ID (required when apim_backend_auth_mode = 'managed_identity' for RBAC)"
  type        = string
  default     = ""
}
