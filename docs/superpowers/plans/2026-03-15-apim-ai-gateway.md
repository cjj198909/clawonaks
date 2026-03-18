# APIM AI Gateway Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable APIM as an Internal VNet AI Gateway between AKS agent pods and Azure OpenAI, eliminating direct API key exposure in sandboxes.

**Architecture:** APIM StandardV2 (Internal VNet) sits between Kata VM pods and Azure OpenAI. Pods hold only APIM subscription keys (VNet-internal, useless externally). APIM authenticates to backend via API Key (Named Value from KV) or Managed Identity (switchable). Backend Pool with Circuit Breaker provides resilience.

**Tech Stack:** Terraform (azurerm + azapi), Helm Chart, Node.js (Admin Panel), APIM XML policies

**Spec:** `docs/superpowers/specs/2026-03-15-apim-ai-gateway-design.md`

---

## File Structure

### New files
| File | Responsibility |
|------|---------------|
| `terraform/apim-backend.tf` | azapi_resource: Backend entity + Backend Pool + Circuit Breaker |
| `terraform/apim-named-values.tf` | APIM Named Value referencing KV `azure-openai-key` (API Key mode) |
| `policies/ai-gateway.xml.tftpl` | Terraform template: APIM policy with auth mode branching |

### Modified files
| File | Changes |
|------|---------|
| `terraform/versions.tf` | Add `azapi` provider |
| `terraform/variables.tf` | Add `apim_backend_auth_mode`, `aoai_endpoint`, `aoai_resource_id` |
| `terraform/apim.tf` | Already correct (`count = var.enable_apim`), no changes needed |
| `terraform/apim-api.tf` | Decouple from `enable_ai_foundry`, configurable `service_url` |
| `terraform/apim-subscriptions.tf` | Remove static subscriptions, add comment |
| `terraform/identity.tf` | Add 3 new conditional role assignments |
| `terraform/outputs.tf` | Add `apim_gateway_url`, `apim_api_id` |
| `terraform/terraform.tfvars` | Add APIM vars for deployment |
| `policies/ai-gateway.xml` | Keep as reference (renamed copy becomes `.tftpl`) |
| `charts/openclaw/values.yaml` | Add `apim:` section |
| `charts/openclaw/ci/test-values.yaml` | Add test APIM values |
| `charts/openclaw/templates/agent-template-cm.yaml` | APIM-aware SPC + init container |
| `charts/openclaw/templates/admin-deployment.yaml` | Inject APIM env vars |
| `admin/server.js` | APIM subscription create/delete in agent lifecycle |
| `scripts/install.sh` | Add `--enable-apim`, `--apim-auth-mode` args, APIM values generation |

---

## Chunk 1: Terraform Infrastructure

### Task 1: Add azapi provider

**Files:**
- Modify: `terraform/versions.tf`

- [ ] **Step 1: Add azapi provider to required_providers**

In `terraform/versions.tf`, add the `azapi` provider block inside `required_providers`:

```hcl
terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.3"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}
```

- [ ] **Step 2: Validate**

Run: `cd terraform && terraform init -upgrade && terraform validate`
Expected: "Success! The configuration is valid."

- [ ] **Step 3: Commit**

```bash
git add terraform/versions.tf
git commit -m "feat(apim): add azapi provider for backend pool support"
```

---

### Task 2: Add new Terraform variables

**Files:**
- Modify: `terraform/variables.tf`
- Modify: `terraform/terraform.tfvars`

- [ ] **Step 1: Add new variables**

Append to `terraform/variables.tf` after the existing `enable_ai_foundry` variable (after line 40):

```hcl
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

variable "aoai_resource_id" {
  description = "Azure OpenAI resource ID (required when apim_backend_auth_mode = 'managed_identity' for RBAC)"
  type        = string
  default     = ""
}
```

- [ ] **Step 2: Update terraform.tfvars**

Add APIM-related vars to `terraform/terraform.tfvars` (keep `enable_apim = false` for now — actual deployment tested later):

```hcl
resource_group         = "openclaw-rg"
location               = "westus2"
cluster_name           = "openclaw-aks"
admin_email            = "admin@MngEnv647263.onmicrosoft.com"
agent_ids              = ["alice"]
enable_apim            = false
enable_ai_foundry      = false
apim_backend_auth_mode = "api_key"
aoai_endpoint          = "https://xxx.openai.azure.com"
```

- [ ] **Step 3: Validate**

Run: `cd terraform && terraform validate`
Expected: "Success! The configuration is valid."

- [ ] **Step 4: Commit**

```bash
git add terraform/variables.tf terraform/terraform.tfvars
git commit -m "feat(apim): add backend auth mode, aoai_endpoint, aoai_resource_id variables"
```

---

### Task 3: Rewrite apim-api.tf — decouple from enable_ai_foundry

**Files:**
- Modify: `terraform/apim-api.tf`

- [ ] **Step 1: Rewrite apim-api.tf**

Replace the entire file content. Key changes:
- Condition: `var.enable_apim` only (remove `enable_ai_foundry` dependency)
- `service_url`: configurable based on auth mode
- Policy: use `templatefile()` with the new `.tftpl` template

```hcl
# APIM API definition for Azure OpenAI proxy
resource "azurerm_api_management_api" "openai" {
  count = var.enable_apim ? 1 : 0

  name                  = "azure-openai"
  resource_group_name   = data.azurerm_resource_group.main.name
  api_management_name   = azurerm_api_management.openclaw[0].name
  revision              = "1"
  display_name          = "Azure OpenAI"
  path                  = "openai"
  protocols             = ["https"]
  subscription_required = true

  # Subscription key sent as header, parameter name = "api-key" is common but
  # we use "Ocp-Apim-Subscription-Key" (APIM default) so agents send that header.
}

resource "azurerm_api_management_api_policy" "openai" {
  count = var.enable_apim ? 1 : 0

  api_name            = azurerm_api_management_api.openai[0].name
  api_management_name = azurerm_api_management.openclaw[0].name
  resource_group_name = data.azurerm_resource_group.main.name

  xml_content = templatefile("${path.module}/../policies/ai-gateway.xml.tftpl", {
    auth_mode = var.apim_backend_auth_mode
  })
}
```

> **Note:** `service_url` is intentionally omitted from the API resource because routing is handled by the `<set-backend-service>` policy directive pointing to the Backend Pool.

- [ ] **Step 2: Commit (validation deferred to after Task 5)**

> **Note:** `terraform validate` will fail here because `ai-gateway.xml.tftpl` doesn't exist yet (created in Task 5). Validation runs in Task 5 Step 2 after both files exist.

```bash
git add terraform/apim-api.tf
git commit -m "feat(apim): decouple API from enable_ai_foundry, use templatefile policy"
```

---

### Task 4: Clear apim-subscriptions.tf

**Files:**
- Modify: `terraform/apim-subscriptions.tf`

- [ ] **Step 1: Replace with comment**

Replace entire file:

```hcl
# APIM subscriptions are managed dynamically by Admin Panel.
# Each agent gets a subscription created via `az apim subscription create`
# during the Admin Panel creation flow. See spec §5.2.
#
# The old static `for_each = var.agent_ids` approach is removed because
# agents are created/deleted at runtime, not at Terraform apply time.
```

- [ ] **Step 2: Validate**

Run: `cd terraform && terraform validate`
Expected: "Success! The configuration is valid."

- [ ] **Step 3: Commit**

```bash
git add terraform/apim-subscriptions.tf
git commit -m "refactor(apim): remove static subscriptions, managed by Admin Panel"
```

---

### Task 5: Create APIM policy template

**Files:**
- Create: `policies/ai-gateway.xml.tftpl`

- [ ] **Step 1: Create policy template**

Create `policies/ai-gateway.xml.tftpl`:

```xml
<!-- APIM AI Gateway Policy (rendered by Terraform templatefile) -->
<!-- Auth mode: ${auth_mode} -->
<policies>
  <inbound>
%{ if auth_mode == "api_key" ~}
    <!-- API Key mode: inject key from Named Value (backed by Key Vault) -->
    <set-header name="api-key" exists-action="override">
      <value>{{azure-openai-key}}</value>
    </set-header>
%{ endif ~}
%{ if auth_mode == "managed_identity" ~}
    <!-- Managed Identity mode: get bearer token for Cognitive Services -->
    <authentication-managed-identity
      resource="https://cognitiveservices.azure.com"
      output-token-variable-name="ai-token" />
    <set-header name="Authorization" exists-action="override">
      <value>@("Bearer " + (string)context.Variables["ai-token"])</value>
    </set-header>
%{ endif ~}

    <!-- Token rate limiting: 60K TPM per agent subscription -->
    <llm-token-limit
      counter-key="@(context.Subscription.Id)"
      tokens-per-minute="60000"
      estimate-prompt-tokens="true"
      remaining-tokens-variable-name="remainingTokens" />

    <!-- Token consumption metrics -->
    <llm-emit-token-metric namespace="AzureOpenAI">
      <dimension name="Subscription" value="@(context.Subscription.Id)" />
      <dimension name="Model" value="@(context.Request.Headers.GetValueOrDefault(&quot;model&quot;,&quot;unknown&quot;))" />
    </llm-emit-token-metric>

    <!-- Backend routing via pool (circuit breaker on individual backends) -->
    <set-backend-service backend-id="openai-backend-pool" />
  </inbound>

  <outbound>
    <base />
  </outbound>
</policies>
```

- [ ] **Step 2: Validate (covers Task 3 + Task 5 together)**

Run: `cd terraform && terraform validate`
Expected: "Success! The configuration is valid." (both `apim-api.tf` templatefile ref and `.tftpl` now exist)

- [ ] **Step 3: Commit**

```bash
git add policies/ai-gateway.xml.tftpl
git commit -m "feat(apim): add policy template with auth mode branching"
```

---

### Task 6: Create Backend Pool (azapi_resource)

**Files:**
- Create: `terraform/apim-backend.tf`

- [ ] **Step 1: Create backend resources**

Create `terraform/apim-backend.tf`:

```hcl
# Backend entity — single Azure OpenAI endpoint with circuit breaker
resource "azapi_resource" "apim_backend_openai" {
  count = var.enable_apim ? 1 : 0

  type      = "Microsoft.ApiManagement/service/backends@2024-06-01-preview"
  name      = "openai-backend-1"
  parent_id = azurerm_api_management.openclaw[0].id

  body = {
    properties = {
      description = "Azure OpenAI backend"
      protocol    = "http"
      url         = var.apim_backend_auth_mode == "managed_identity" && var.enable_ai_foundry ? (
        "https://${azurerm_cognitive_account.ai_foundry[0].custom_subdomain_name}.openai.azure.com"
      ) : var.aoai_endpoint

      # Backend credentials per auth mode (spec §4.3)
      credentials = var.apim_backend_auth_mode == "api_key" ? {
        header = {
          api-key = ["{{azure-openai-key}}"]  # APIM Named Value reference
        }
      } : {
        authorization = {
          scheme    = "managed-identity"
          parameter = "https://cognitiveservices.azure.com"
        }
      }

      circuitBreaker = {
        rules = [{
          name = "OpenAIBreakerRule"
          failureCondition = {
            count = 3
            errorReasons = [
              "Server errors"
            ]
            statusCodeRanges = [
              { min = 429, max = 429 },
              { min = 500, max = 503 }
            ]
            interval = "PT1M"
          }
          tripDuration     = "PT1M"
          acceptRetryAfter = true
        }]
      }
    }
  }
}

# Backend Pool — groups backends for load balancing (v1: single backend)
resource "azapi_resource" "apim_backend_pool" {
  count = var.enable_apim ? 1 : 0

  type      = "Microsoft.ApiManagement/service/backends@2024-06-01-preview"
  name      = "openai-backend-pool"
  parent_id = azurerm_api_management.openclaw[0].id

  body = {
    properties = {
      description = "Backend pool for Azure OpenAI endpoints"
      type        = "Pool"
      pool = {
        services = [{
          id       = "/backends/${azapi_resource.apim_backend_openai[0].name}"
          priority = 1
          weight   = 1
        }]
      }
    }
  }

  depends_on = [azapi_resource.apim_backend_openai]
}
```

- [ ] **Step 2: Validate**

Run: `cd terraform && terraform validate`
Expected: "Success! The configuration is valid."

- [ ] **Step 3: Commit**

```bash
git add terraform/apim-backend.tf
git commit -m "feat(apim): add Backend entity + Pool with circuit breaker (azapi)"
```

---

### Task 7: Create Named Value for API Key mode

**Files:**
- Create: `terraform/apim-named-values.tf`

- [ ] **Step 1: Create named values resource**

Create `terraform/apim-named-values.tf`:

```hcl
# APIM Named Value backed by Key Vault — stores Azure OpenAI API key
# Only created in API Key mode; MI mode doesn't need a key.
resource "azurerm_api_management_named_value" "aoai_key" {
  count = var.enable_apim && var.apim_backend_auth_mode == "api_key" ? 1 : 0

  name                = "azure-openai-key"
  resource_group_name = data.azurerm_resource_group.main.name
  api_management_name = azurerm_api_management.openclaw[0].name
  display_name        = "azure-openai-key"
  secret              = true

  value_from_key_vault {
    secret_id = "${azurerm_key_vault.openclaw.vault_uri}secrets/azure-openai-key"
  }
}
```

- [ ] **Step 2: Validate**

Run: `cd terraform && terraform validate`
Expected: "Success! The configuration is valid."

- [ ] **Step 3: Commit**

```bash
git add terraform/apim-named-values.tf
git commit -m "feat(apim): add Named Value (KV-backed) for Azure OpenAI API key"
```

---

### Task 8: Expand identity.tf — RBAC for APIM

**Files:**
- Modify: `terraform/identity.tf`

- [ ] **Step 1: Update existing APIM role assignment**

Replace the existing `apim_ai_user` resource (lines 8-15) with the new conditional version. Then append the new role assignments.

The old block (lines 8-15):
```hcl
# APIM Managed Identity -> AI Foundry (Cognitive Services OpenAI User)
resource "azurerm_role_assignment" "apim_ai_user" {
  count = var.enable_apim && var.enable_ai_foundry ? 1 : 0
  ...
}
```

Replace with three new blocks. The full replacement for lines 8-15, plus new blocks appended:

```hcl
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
```

- [ ] **Step 2: Validate**

Run: `cd terraform && terraform validate`
Expected: "Success! The configuration is valid."

- [ ] **Step 3: Commit**

```bash
git add terraform/identity.tf
git commit -m "feat(apim): add RBAC for APIM MI (KV reader, AOAI user) and Admin MI (APIM contributor)"
```

---

### Task 9: Expand outputs.tf

**Files:**
- Modify: `terraform/outputs.tf`

- [ ] **Step 1: Add new outputs**

Append after the existing `admin_identity_client_id` output (after line 47):

```hcl
output "apim_gateway_url" {
  description = "APIM gateway base URL for agent config"
  value       = var.enable_apim ? "https://${azurerm_api_management.openclaw[0].name}.azure-api.net" : ""
}

output "apim_api_id" {
  description = "Full ARM resource ID of the Azure OpenAI API in APIM (subscription scope)"
  value       = var.enable_apim ? azurerm_api_management_api.openai[0].id : ""
}
```

- [ ] **Step 2: Validate**

Run: `cd terraform && terraform validate`
Expected: "Success! The configuration is valid."

- [ ] **Step 3: Commit**

```bash
git add terraform/outputs.tf
git commit -m "feat(apim): add apim_gateway_url and apim_api_id outputs"
```

---

### Task 10: Full Terraform validation (enable_apim=false)

- [ ] **Step 1: Run full validation with APIM disabled**

```bash
cd terraform
terraform init -upgrade
terraform validate
terraform plan -var-file=terraform.tfvars -out=tfplan 2>&1 | tail -5
```

Expected: No errors. Plan should show no changes (APIM is still disabled in tfvars).

- [ ] **Step 2: Run validation with APIM enabled (plan only, no apply)**

```bash
cd terraform
terraform plan \
  -var-file=terraform.tfvars \
  -var="enable_apim=true" \
  -var="aoai_endpoint=https://test.openai.azure.com" \
  2>&1 | tail -20
```

Expected: Plan shows resources to create (APIM instance, DNS, API, backends, named value, RBAC). No errors.

- [ ] **Step 3: Commit any fixes**

If validation revealed issues, fix and commit. Otherwise, no action needed.

---

## Chunk 2: Helm Chart & Admin Panel

### Task 11: Add APIM section to Helm values

**Files:**
- Modify: `charts/openclaw/values.yaml`
- Modify: `charts/openclaw/ci/test-values.yaml`

- [ ] **Step 1: Add apim section to values.yaml**

Append after the `admin:` section (after line 61), before `images:`:

```yaml
# -- APIM AI Gateway (disabled by default)
apim:
  enabled: false
  gatewayUrl: ""
  apiPath: "openai"
  name: ""
  resourceGroup: ""
  apiId: ""
  model:
    id: "gpt-5.4"
    name: "GPT-5.4 (via APIM)"
```

- [ ] **Step 2: Add test values for APIM**

Append to `charts/openclaw/ci/test-values.yaml`:

```yaml
apim:
  enabled: true
  gatewayUrl: "https://test-apim.azure-api.net"
  apiPath: "openai"
  name: "test-apim"
  resourceGroup: "test-rg"
  apiId: "/subscriptions/00000000/resourceGroups/test-rg/providers/Microsoft.ApiManagement/service/test-apim/apis/azure-openai"
  model:
    id: "gpt-5.4"
    name: "GPT-5.4 (via APIM)"
```

- [ ] **Step 3: Validate**

Run: `helm lint charts/openclaw -f charts/openclaw/ci/test-values.yaml`
Expected: "1 chart(s) linted, 0 chart(s) failed"

- [ ] **Step 4: Commit**

```bash
git add charts/openclaw/values.yaml charts/openclaw/ci/test-values.yaml
git commit -m "feat(helm): add apim values section with test values"
```

---

### Task 12: Update Agent Template ConfigMap — APIM-aware SPC + init container

**Files:**
- Modify: `charts/openclaw/templates/agent-template-cm.yaml`

This is the most complex change. Three areas:

- [ ] **Step 1: Update SPC secrets — conditional APIM sub key vs Azure OpenAI key**

In `agent-template-cm.yaml`, replace lines 34-37 (the `azure-openai-key` SPC entry):

Old (lines 34-37):
```yaml
            - |
              objectName: azure-openai-key
              objectType: secret
              objectAlias: azure-openai-key
```

New:
```yaml
{{- if .Values.apim.enabled }}
            - |
              objectName: apim-sub-key-__AGENT_ID__
              objectType: secret
              objectAlias: apim-subscription-key
{{- else }}
            - |
              objectName: azure-openai-key
              objectType: secret
              objectAlias: azure-openai-key
{{- end }}
```

- [ ] **Step 2: Update init container — config build with APIM mode**

Replace lines 107-111 (the config assembly logic inside the init container `args` block).

Old (lines 107-111):
```
              FEISHU_ID=$(cat /secrets/feishu-app-id)
              FEISHU_SECRET=$(cat /secrets/feishu-app-secret)
              AOAI_KEY=$(cat /secrets/azure-openai-key)
              printf '%s\n' "{\"gateway\":{\"mode\":\"local\"},\"channels\":{\"feishu\":{\"enabled\":true,\"appId\":\"$FEISHU_ID\",\"appSecret\":\"$FEISHU_SECRET\"}},\"models\":{\"providers\":{\"azure-openai-direct\":{\"baseUrl\":\"$AOAI_ENDPOINT\",\"apiKey\":\"$AOAI_KEY\",\"api\":\"openai-responses\",\"headers\":{\"api-version\":\"2025-04-01-preview\"},\"models\":[{\"id\":\"gpt-5.4\",\"name\":\"GPT-5.4 (Direct Azure OpenAI)\"}]}}}}" > "$OPENCLAW_DIR/openclaw.json"
              echo "Config assembled from KV secrets"
```

New:
```
              FEISHU_ID=$(cat /secrets/feishu-app-id)
              FEISHU_SECRET=$(cat /secrets/feishu-app-secret)
{{- if .Values.apim.enabled }}
              APIM_KEY=$(cat /secrets/apim-subscription-key)
              printf '%s\n' "{\"gateway\":{\"mode\":\"local\"},\"channels\":{\"feishu\":{\"enabled\":true,\"appId\":\"$FEISHU_ID\",\"appSecret\":\"$FEISHU_SECRET\"}},\"models\":{\"providers\":{\"azure-apim\":{\"baseUrl\":\"{{ .Values.apim.gatewayUrl }}/{{ .Values.apim.apiPath }}\",\"apiKey\":\"$APIM_KEY\",\"api\":\"openai-responses\",\"headers\":{\"Ocp-Apim-Subscription-Key\":\"$APIM_KEY\",\"api-version\":\"2025-04-01-preview\"},\"models\":[{\"id\":\"{{ .Values.apim.model.id }}\",\"name\":\"{{ .Values.apim.model.name }}\"}]}}}}" > "$OPENCLAW_DIR/openclaw.json"
              echo "Config assembled (APIM mode)"
{{- else }}
              AOAI_KEY=$(cat /secrets/azure-openai-key)
              printf '%s\n' "{\"gateway\":{\"mode\":\"local\"},\"channels\":{\"feishu\":{\"enabled\":true,\"appId\":\"$FEISHU_ID\",\"appSecret\":\"$FEISHU_SECRET\"}},\"models\":{\"providers\":{\"azure-openai-direct\":{\"baseUrl\":\"$AOAI_ENDPOINT\",\"apiKey\":\"$AOAI_KEY\",\"api\":\"openai-responses\",\"headers\":{\"api-version\":\"2025-04-01-preview\"},\"models\":[{\"id\":\"gpt-5.4\",\"name\":\"GPT-5.4 (Direct Azure OpenAI)\"}]}}}}" > "$OPENCLAW_DIR/openclaw.json"
              echo "Config assembled from KV secrets"
{{- end }}
```

- [ ] **Step 3: Remove AOAI_ENDPOINT env from init container when APIM enabled**

Replace the init container env block (lines 112-114):

Old:
```yaml
            env:
            - name: AOAI_ENDPOINT
              value: {{ .Values.azure.openai.endpoint | quote }}
```

New:
```yaml
            env:
{{- if not .Values.apim.enabled }}
            - name: AOAI_ENDPOINT
              value: {{ .Values.azure.openai.endpoint | quote }}
{{- end }}
```

- [ ] **Step 4: Validate Helm template renders correctly for both modes**

```bash
# APIM enabled
helm template openclaw charts/openclaw -f charts/openclaw/ci/test-values.yaml | grep -A5 "apim-sub-key"

# APIM disabled (default values)
helm template openclaw charts/openclaw \
  --set azure.tenantId=test --set azure.acr.loginServer=test.azurecr.io \
  --set azure.keyvault.name=test-kv --set azure.openai.endpoint=https://test.openai.azure.com \
  --set identity.sandbox.clientId=test --set identity.admin.clientId=test \
  | grep -A5 "azure-openai-key"
```

Expected: APIM mode shows `apim-sub-key-__AGENT_ID__` in SPC; disabled mode shows `azure-openai-key`.

- [ ] **Step 5: Commit**

```bash
git add charts/openclaw/templates/agent-template-cm.yaml
git commit -m "feat(helm): APIM-aware agent template — SPC + init container branching"
```

---

### Task 13: Update Admin Deployment — inject APIM env vars

**Files:**
- Modify: `charts/openclaw/templates/admin-deployment.yaml`

- [ ] **Step 1: Add APIM environment variables**

In `admin-deployment.yaml`, after the existing `AGENT_TEMPLATE_PATH` env var (line 35), add:

```yaml
        {{- if .Values.apim.enabled }}
        - name: APIM_ENABLED
          value: "true"
        - name: APIM_NAME
          value: {{ .Values.apim.name | quote }}
        - name: APIM_RG
          value: {{ .Values.apim.resourceGroup | quote }}
        - name: APIM_API_ID
          value: {{ .Values.apim.apiId | quote }}
        {{- end }}
```

- [ ] **Step 2: Validate**

```bash
helm template openclaw charts/openclaw -f charts/openclaw/ci/test-values.yaml | grep -A10 "APIM_"
```

Expected: Shows `APIM_ENABLED`, `APIM_NAME`, `APIM_RG`, `APIM_API_ID` env vars.

- [ ] **Step 3: Commit**

```bash
git add charts/openclaw/templates/admin-deployment.yaml
git commit -m "feat(helm): inject APIM env vars into Admin Panel deployment"
```

---

### Task 14: Update Admin Panel server.js — APIM subscription lifecycle

**Files:**
- Modify: `admin/server.js`

- [ ] **Step 1: Add APIM config constants**

After the existing constants (line 13), add:

```javascript
const APIM_ENABLED = process.env.APIM_ENABLED === 'true';
const APIM_NAME = process.env.APIM_NAME || '';
const APIM_RG = process.env.APIM_RG || '';
const APIM_API_ID = process.env.APIM_API_ID || '';
```

- [ ] **Step 2: Update POST /api/agents — add APIM subscription step**

Replace the SSE creation flow (lines 121-149). The `send` function's `total` becomes dynamic. A new Step 2 (APIM subscription) is inserted between KV and K8s:

Replace lines 121-149 with:

```javascript
  const total = APIM_ENABLED ? 3 : 2;
  const send = (step, status, msg, extra = {}) => {
    res.write(`data: ${JSON.stringify({ step, total, status, msg, ...extra })}\n\n`);
  };

  let currentStep = 0;
  try {
    // Step 1: Store Feishu credentials in Key Vault
    currentStep = 1;
    send(1, 'running', 'Storing Feishu credentials in Key Vault...');
    await azLogin();
    await az('keyvault', 'secret', 'set', '--vault-name', KV_NAME,
      '--name', `feishu-app-id-${agentId}`, '--value', feishuAppId);
    await az('keyvault', 'secret', 'set', '--vault-name', KV_NAME,
      '--name', `feishu-app-secret-${agentId}`, '--value', feishuAppSecret);
    send(1, 'done', 'Feishu credentials stored in Key Vault');

    // Step 2 (APIM only): Create APIM subscription, store key in KV
    if (APIM_ENABLED) {
      currentStep = 2;
      send(2, 'running', 'Creating APIM subscription...');
      const subKey = await az('apim', 'subscription', 'create',
        '--resource-group', APIM_RG,
        '--service-name', APIM_NAME,
        '--subscription-id', `openclaw-agent-${agentId}`,
        '--display-name', `openclaw-agent-${agentId}`,
        '--scope', APIM_API_ID,
        '--query', 'primaryKey', '-o', 'tsv');
      if (!subKey || !subKey.trim()) {
        throw new Error('APIM subscription creation returned empty key');
      }
      await az('keyvault', 'secret', 'set', '--vault-name', KV_NAME,
        '--name', `apim-sub-key-${agentId}`, '--value', subKey.trim());
      send(2, 'done', 'APIM subscription created, key stored in KV');
    }

    // Step 2 or 3: Create K8s resources (SPC + PVC + Deployment)
    currentStep = total;
    send(total, 'running', 'Creating K8s resources (SPC + PVC + Deployment)...');
    await kubectlApplyStdin(renderAgentYaml(agentId));
    send(total, 'done', `Agent ${agentId} created successfully`, { done: true });
  } catch (err) {
    send(currentStep, 'error', `Creation failed: ${err.message}`);
    // Cleanup on failure
    if (currentStep >= total) {
      await kubectl('delete', 'deployment', `openclaw-agent-${agentId}`, '-n', NAMESPACE, '--ignore-not-found').catch(() => {});
      await kubectl('delete', 'pvc', `work-disk-${agentId}`, '-n', NAMESPACE, '--ignore-not-found').catch(() => {});
      await kubectl('delete', 'secretproviderclass', `spc-${agentId}`, '-n', NAMESPACE, '--ignore-not-found').catch(() => {});
    }
    if (APIM_ENABLED && currentStep >= 2) {
      await az('apim', 'subscription', 'delete',
        '--resource-group', APIM_RG, '--service-name', APIM_NAME,
        '--subscription-id', `openclaw-agent-${agentId}`, '-y').catch(() => {});
      await az('keyvault', 'secret', 'delete', '--vault-name', KV_NAME,
        '--name', `apim-sub-key-${agentId}`).catch(() => {});
    }
  }

  res.end();
```

> **Important:** `res.end()` must be preserved after the try/catch block (exists at line 151 in the original file). The replacement code above includes it.

- [ ] **Step 3: Update DELETE /api/agents/:id — add APIM cleanup**

In the delete handler, add APIM subscription deletion after KV deletion. Insert before `res.json({ ok: true, results })` (line 195):

After the existing KV deletion block (lines 182-188), add:

```javascript
    // Delete APIM subscription (if APIM enabled)
    if (APIM_ENABLED) {
      await azLogin();
      await az('apim', 'subscription', 'delete',
        '--resource-group', APIM_RG, '--service-name', APIM_NAME,
        '--subscription-id', `openclaw-agent-${agentId}`, '-y').catch(() => {});
      await az('keyvault', 'secret', 'delete', '--vault-name', KV_NAME,
        '--name', `apim-sub-key-${agentId}`).catch(() => {});
      results.push('APIM subscription + KV key deleted');
    }
```

- [ ] **Step 4: Commit**

```bash
git add admin/server.js
git commit -m "feat(admin): APIM subscription lifecycle in agent create/delete"
```

---

## Chunk 3: install.sh, Deployment & E2E Validation

### Task 15: Update install.sh — APIM args and values generation

**Files:**
- Modify: `scripts/install.sh`

- [ ] **Step 1: Add APIM args to parser**

In the defaults section (after line 14), add:

```bash
ENABLE_APIM=false
APIM_AUTH_MODE="api_key"
```

In the arg parser (after `--skip-images` case, line 23), add:

```bash
    --enable-apim)     ENABLE_APIM=true; shift ;;
    --apim-auth-mode)  APIM_AUTH_MODE="$2"; shift 2 ;;
```

Update the usage comment at the top (line 3):

```bash
# Usage: install.sh --aoai-key KEY --aoai-endpoint URL [--tfvars PATH] [--skip-terraform] [--skip-images] [--enable-apim] [--apim-auth-mode api_key|managed_identity]
```

- [ ] **Step 2: Pass APIM vars to Terraform**

In Step 1 (Terraform apply, line 45), add APIM vars:

Replace:
```bash
  terraform apply -var-file="$TFVARS" -auto-approve -input=false
```

With:
```bash
  terraform apply -var-file="$TFVARS" -auto-approve -input=false \
    -var="enable_apim=$ENABLE_APIM" \
    -var="apim_backend_auth_mode=$APIM_AUTH_MODE" \
    -var="aoai_endpoint=$AOAI_ENDPOINT"
```

After the `echo "  Extracting terraform outputs..."` line (line 53), add APIM output extraction:

```bash
APIM_GATEWAY_URL=$(terraform output -raw apim_gateway_url 2>/dev/null || echo "")
APIM_API_ID=$(terraform output -raw apim_api_id 2>/dev/null || echo "")
APIM_NAME_TF=$(terraform output -raw apim_name 2>/dev/null || echo "")
```

- [ ] **Step 3: Generate APIM values in Helm step**

In Step 6b (Helm values file generation, after line 181), add APIM section before the `EOF`:

```bash
if [[ "$ENABLE_APIM" == "true" && -n "$APIM_GATEWAY_URL" ]]; then
  cat >> "$VALUES_FILE" <<APIM_EOF
apim:
  enabled: true
  gatewayUrl: "$APIM_GATEWAY_URL"
  apiPath: "openai"
  name: "$APIM_NAME_TF"
  resourceGroup: "$RG"
  apiId: "$APIM_API_ID"
APIM_EOF
fi
```

- [ ] **Step 4: Add APIM hint to post-install output**

After the "Next steps:" section (line 200), add:

```bash
if [[ "$ENABLE_APIM" == "true" ]]; then
  echo "  APIM: $APIM_GATEWAY_URL (Internal VNet)"
  echo ""
  echo "  Note: APIM StandardV2 takes 30-45 min to deploy on first run."
  echo "  Agents created via Admin Panel will auto-use APIM mode."
fi
```

- [ ] **Step 5: Validate script syntax**

Run: `bash -n scripts/install.sh`
Expected: No output (no syntax errors)

Run: `shellcheck scripts/install.sh || true`
Expected: No new errors introduced.

- [ ] **Step 6: Commit**

```bash
git add scripts/install.sh
git commit -m "feat(scripts): add --enable-apim and --apim-auth-mode to install.sh"
```

---

### Task 16: Helm lint and template validation

- [ ] **Step 1: Lint with APIM enabled**

```bash
helm lint charts/openclaw -f charts/openclaw/ci/test-values.yaml
```

Expected: "1 chart(s) linted, 0 chart(s) failed"

- [ ] **Step 2: Template render with APIM enabled — verify key sections**

```bash
# Verify SPC has apim-sub-key
helm template openclaw charts/openclaw -f charts/openclaw/ci/test-values.yaml \
  | grep "apim-sub-key"

# Verify init container has APIM mode
helm template openclaw charts/openclaw -f charts/openclaw/ci/test-values.yaml \
  | grep "azure-apim"

# Verify admin has APIM env vars
helm template openclaw charts/openclaw -f charts/openclaw/ci/test-values.yaml \
  | grep "APIM_ENABLED"
```

Expected: All three greps return matches.

- [ ] **Step 3: Template render with APIM disabled — verify no APIM artifacts**

```bash
helm template openclaw charts/openclaw \
  --set azure.tenantId=t --set azure.acr.loginServer=a.azurecr.io \
  --set azure.keyvault.name=kv --set azure.openai.endpoint=https://test.openai.azure.com \
  --set identity.sandbox.clientId=s --set identity.admin.clientId=a \
  | grep "apim-sub-key" | wc -l
```

Expected: 0 (no APIM-related content when disabled).

- [ ] **Step 4: Commit any fixes**

If validation revealed issues, fix and commit.

---

### Task 17: Terraform Apply (APIM deployment)

> **Important:** This step takes ~30-45 minutes for APIM StandardV2. Run during off-peak hours if possible.

- [ ] **Step 1: Update terraform.tfvars for APIM deployment**

Update the real `aoai_endpoint` value in `terraform/terraform.tfvars`:

```hcl
enable_apim            = true
apim_backend_auth_mode = "api_key"
aoai_endpoint          = "<REAL_AZURE_OPENAI_ENDPOINT>"
```

> **Do NOT commit real endpoint to git.** Pass via `install.sh` args instead.

- [ ] **Step 2: Apply Terraform**

```bash
cd terraform
terraform apply -var-file=terraform.tfvars -auto-approve -input=false
```

Expected: APIM instance + DNS + API + Backend + Named Value + RBAC created. Takes 30-45 minutes.

- [ ] **Step 3: Verify APIM provisioning**

```bash
az apim show --name openclaw-apim --resource-group openclaw-rg --query "provisioningState" -o tsv
```

Expected: `Succeeded`

---

### Task 18: Helm upgrade with APIM enabled

- [ ] **Step 1: Run install.sh with APIM enabled**

```bash
./scripts/install.sh \
  --aoai-key "<REAL_KEY>" \
  --aoai-endpoint "<REAL_ENDPOINT>" \
  --skip-terraform --skip-images \
  --enable-apim
```

Or manual Helm upgrade:

```bash
# Generate values with APIM section and helm upgrade
```

- [ ] **Step 2: Verify ConfigMap updated**

```bash
kubectl get cm openclaw-agent-template -n openclaw -o yaml | grep "apim-sub-key"
```

Expected: Shows `apim-sub-key-__AGENT_ID__` in the SPC template.

- [ ] **Step 3: Verify Admin Panel has APIM env**

```bash
kubectl get deploy openclaw-admin -n openclaw -o yaml | grep -A1 "APIM_ENABLED"
```

Expected: `APIM_ENABLED: "true"`

---

### Task 19: E2E Validation — Create agent via APIM mode

- [ ] **Step 1: DNS resolution test**

```bash
kubectl run dns-test --rm -it --image=busybox --restart=Never -n openclaw -- \
  nslookup openclaw-apim.azure-api.net
```

Expected: Resolves to APIM private IP (10.0.8.x).

- [ ] **Step 2: Port-forward Admin Panel and create test agent**

```bash
kubectl port-forward svc/openclaw-admin 3000:3000 -n openclaw
```

Open http://localhost:3000, create a new agent (e.g., `apim-test`) with Feishu credentials.

Expected: 3-step SSE progress (KV → APIM subscription → K8s resources).

- [ ] **Step 3: Verify APIM subscription created**

```bash
az apim subscription show \
  --resource-group openclaw-rg \
  --service-name openclaw-apim \
  --subscription-id openclaw-agent-apim-test \
  --query "{state:state, displayName:displayName}" -o table
```

Expected: State=active, DisplayName=openclaw-agent-apim-test.

- [ ] **Step 4: Verify agent pod has APIM config**

```bash
kubectl exec deploy/openclaw-agent-apim-test -c openclaw -n openclaw -- \
  cat /home/node/.openclaw/openclaw.json | python3 -m json.tool | head -20
```

Expected: Shows `azure-apim` provider with `Ocp-Apim-Subscription-Key` header. No `azure-openai-key`.

- [ ] **Step 5: Verify APIM connectivity**

From the agent pod:
```bash
kubectl exec deploy/openclaw-agent-apim-test -c openclaw -n openclaw -- \
  curl -s -o /dev/null -w "%{http_code}" \
  -H "Ocp-Apim-Subscription-Key: $(kubectl exec deploy/openclaw-agent-apim-test -c openclaw -n openclaw -- cat /mnt/secrets/apim-subscription-key 2>/dev/null || echo 'KEY')" \
  "https://openclaw-apim.azure-api.net/openai/models?api-version=2025-04-01-preview"
```

Expected: HTTP 200.

- [ ] **Step 6: Feishu E2E test**

Send a message to the bot via Feishu. Verify it responds through the APIM gateway.

Check agent logs:
```bash
kubectl logs deploy/openclaw-agent-apim-test -c openclaw -n openclaw --tail=50
```

Expected: No timeout errors. Messages processed successfully.

- [ ] **Step 7: Verify existing agent (aks-demo) unaffected**

```bash
kubectl logs deploy/openclaw-agent-aks-demo -c openclaw -n openclaw --tail=10
```

Expected: Still running in direct mode, no errors.

---

### Task 20: E2E Validation — Delete agent and verify cleanup

- [ ] **Step 1: Delete test agent via Admin Panel**

Open http://localhost:3000, delete the `apim-test` agent (check both PVC and KV cleanup boxes).

- [ ] **Step 2: Verify APIM subscription deleted**

```bash
az apim subscription show \
  --resource-group openclaw-rg \
  --service-name openclaw-apim \
  --subscription-id openclaw-agent-apim-test 2>&1
```

Expected: Error — subscription not found (deleted).

- [ ] **Step 3: Verify KV secrets cleaned up**

```bash
az keyvault secret show --vault-name openclaw-kv-e2a78886 --name apim-sub-key-apim-test 2>&1
```

Expected: Error — secret not found (deleted).

- [ ] **Step 4: Commit any remaining changes**

If any files were modified during E2E (e.g., minor fixes), commit them with specific paths:

```bash
git status
# Only add specific modified files — do NOT use git add -A (could commit secrets/state files)
git add <specific-files>
git commit -m "fix(apim): E2E validation fixes"
```

---

### Task 21: Backward compatibility check (APIM disabled)

- [ ] **Step 1: Verify APIM-disabled template still works**

```bash
helm template openclaw charts/openclaw \
  --set azure.tenantId=t --set azure.acr.loginServer=a.azurecr.io \
  --set azure.keyvault.name=kv --set azure.openai.endpoint=https://test.openai.azure.com \
  --set identity.sandbox.clientId=s --set identity.admin.clientId=a \
  | grep "azure-openai-key"
```

Expected: Shows `azure-openai-key` in SPC (direct mode, no APIM).

- [ ] **Step 2: Verify aks-demo still healthy**

```bash
kubectl get deploy openclaw-agent-aks-demo -n openclaw
kubectl logs deploy/openclaw-agent-aks-demo -c openclaw -n openclaw --tail=5
```

Expected: 1/1 Ready, no errors.

- [ ] **Step 3: Update CLAUDE.md**

Update `CLAUDE.md` with:
- New §2.x for APIM decisions
- Updated §4 file structure
- New phase in §6
- Updated §12 cluster state
- Updated §14 session recovery points

- [ ] **Step 4: Final commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for APIM AI Gateway (phase 8)"
```
