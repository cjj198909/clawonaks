# OpenClaw on AKS Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy OpenClaw AI Agent on AKS with Kata VM isolation, APIM AI Gateway (VNet internal), split storage (Disk + Files), and Feishu WebSocket integration — all infrastructure as code via Terraform.

**Architecture:** Three-subnet VNet (AKS / APIM / Private Endpoints). Zero inbound public ports — Feishu connects via outbound WebSocket. All AI model calls route through APIM (Internal mode) → Private Endpoint → AI Foundry. AKS API Server remains public for kubectl/CI-CD management.

**Tech Stack:** Terraform (AzureRM provider), AKS 1.30, Kata Containers, Azure APIM StandardV2, Azure AI Foundry, Azure Files NFS, Azure Disk, Key Vault, ACR, Log Analytics, Container Insights, Docker, kubectl

**Spec document:** `DESIGN.md` (in repo root)

---

## Chunk 1: Terraform Foundation

### Task 1: Project Scaffold

**Files:**
- Create: `terraform/main.tf`
- Create: `terraform/variables.tf`
- Create: `terraform/versions.tf`
- Create: `.gitignore`

This task sets up the project directory structure, Terraform providers, backend config, and input variables referenced by all subsequent Terraform files.

- [ ] **Step 1: Create full directory structure**

```bash
mkdir -p terraform docker k8s/storage k8s/sandbox k8s/security policies scripts
```

- [ ] **Step 2: Create `.gitignore`**

```gitignore
# Terraform
terraform/.terraform/
terraform/*.tfstate
terraform/*.tfstate.backup
terraform/*.tfplan
terraform/.terraform.lock.hcl
terraform/terraform.tfvars

# Deploy (templated K8s manifests with real values — never commit)
deploy/

# IDE
.vscode/
.idea/

# OS
.DS_Store
```

- [ ] **Step 3: Create `terraform/versions.tf`**

Pin the AzureRM provider and Terraform version. Use AzureRM ~> 4.0 (latest stable as of 2026-03).

```hcl
terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}
```

- [ ] **Step 4: Create `terraform/main.tf`**

Provider config + resource group data source. Use `azurerm_resource_group` data source (assume RG already exists — safer than auto-creating).

```hcl
provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "main" {
  name = var.resource_group
}
```

> **Decision:** Use `data` source for resource group (pre-existing) rather than `resource` (auto-create). This prevents accidental deletion on `terraform destroy`. If you prefer auto-create, switch to `resource "azurerm_resource_group"`.

> **IMPORTANT — applies to ALL subsequent tasks:** DESIGN.md uses `var.resource_group` in every Terraform resource block. Since we use a data source, you MUST replace all `resource_group_name = var.resource_group` with `resource_group_name = data.azurerm_resource_group.main.name` when copying code from DESIGN.md. Also use `var.location` for location (unchanged) and reference `data.azurerm_resource_group.main.location` if you prefer consistency.

- [ ] **Step 5: Create `terraform/variables.tf`**

All input variables used across all `.tf` files. Define them all upfront so subsequent tasks don't need to revisit this file.

```hcl
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
```

- [ ] **Step 6: Validate Terraform scaffold**

```bash
cd terraform && terraform init && terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "chore: scaffold project structure and terraform foundation"
```

---

### Task 2: Network Layer (VNet + Subnets + NSG)

**Files:**
- Create: `terraform/network.tf`

Three subnets: AKS (10.0.0.0/22), APIM (10.0.8.0/24 with delegation), PE (10.0.12.0/24). NSG on APIM subnet restricts inbound to AKS subnet only + APIM management plane.

- [ ] **Step 1: Create `terraform/network.tf`**

Copy the VNet, 3 subnets (aks/apim/pe), NSG, and NSG-subnet association from `DESIGN.md` §3.1 lines 90-174. Key points:
- APIM subnet needs `Microsoft.ApiManagement/service` delegation
- NSG rules: allow AKS→APIM:443 (priority 100), allow ApiManagement→VNet:3443 (priority 110), deny-all (priority 4096)

Ref: `DESIGN.md` lines 87-175

- [ ] **Step 2: Validate**

```bash
cd terraform && terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add terraform/network.tf
git commit -m "feat(terraform): add VNet, subnets, and APIM NSG"
```

---

### Task 3: Monitoring (Log Analytics + App Insights)

**Files:**
- Create: `terraform/monitoring.tf`

Monitoring must be created BEFORE AKS (because AKS references `log_analytics_workspace_id` in its `oms_agent` block).

- [ ] **Step 1: Create `terraform/monitoring.tf`**

Ref: `DESIGN.md` lines 943-971. Creates:
- `azurerm_log_analytics_workspace` (PerGB2018, 30-day retention)
- `azurerm_application_insights` (web type, linked to LA workspace)
- `azurerm_api_management_logger` (links APIM→App Insights) — **Note:** This resource references APIM which doesn't exist yet. Move it to Task 7 (APIM task) or use `depends_on`. Recommended: keep the logger in `apim.tf` instead.

So for this file, only create:
```hcl
resource "azurerm_log_analytics_workspace" "openclaw" { ... }
resource "azurerm_application_insights" "openclaw" { ... }
```

- [ ] **Step 2: Validate**

```bash
cd terraform && terraform validate
```

- [ ] **Step 3: Commit**

```bash
git add terraform/monitoring.tf
git commit -m "feat(terraform): add Log Analytics workspace and App Insights"
```

---

### Task 4: Storage Account + Key Vault + ACR

**Files:**
- Create: `terraform/storage.tf`
- Create: `terraform/keyvault.tf`
- Create: `terraform/acr.tf`

These are independent PaaS resources with no cross-dependencies. They will later be referenced by Private Endpoints and AKS RBAC.

- [ ] **Step 1: Create `terraform/storage.tf`**

Storage Account for Azure Files (Premium, NFS-capable):
```hcl
resource "azurerm_storage_account" "openclaw" {
  name                     = "openclawstorage"  # must be globally unique
  resource_group_name      = data.azurerm_resource_group.main.name
  location                 = var.location
  account_tier             = "Premium"
  account_replication_type = "LRS"
  account_kind             = "FileStorage"

  # Private endpoint only — no public access
  public_network_access_enabled = false

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }
}

resource "azurerm_storage_share" "openclaw" {
  name                 = "openclaw-data"
  storage_account_id   = azurerm_storage_account.openclaw.id
  enabled_protocol     = "NFS"
  quota                = 100  # GB, Premium NFS minimum is 100
}
```

> **Note:** Premium FileStorage with NFS requires minimum 100 GiB provisioned (Azure limitation). DESIGN.md says 5Gi in PVC, but the underlying share must be ≥100 GiB. The pre-created share here is for the CSI driver to mount statically (via PV) rather than dynamically provisioning new shares. Update the PVC in the StatefulSet YAML to match this 100Gi share, or switch to dynamic provisioning (remove this share and let the CSI driver create one).

- [ ] **Step 2: Create `terraform/keyvault.tf`**

Ref: `DESIGN.md` lines 918-937. Key Vault with RBAC auth, public access disabled.

- [ ] **Step 3: Create `terraform/acr.tf`**

Ref: `DESIGN.md` lines 567-583. ACR Basic SKU. **Note:** The `aks_acr` role assignment references AKS kubelet identity — move that to Task 8 (Identity) since AKS doesn't exist yet. For now, just create the ACR resource.

```hcl
resource "azurerm_container_registry" "openclaw" {
  name                = "openclawacr"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = false
}
```

- [ ] **Step 4: Validate**

```bash
cd terraform && terraform validate
```

- [ ] **Step 5: Commit**

```bash
git add terraform/storage.tf terraform/keyvault.tf terraform/acr.tf
git commit -m "feat(terraform): add Storage Account, Key Vault, and ACR"
```

---

### Task 5: AKS Cluster + Sandbox Node Pool

**Files:**
- Create: `terraform/aks.tf`
- Create: `terraform/nodepool.tf`

AKS with Azure CNI, System Assigned Identity, OIDC + Workload Identity enabled. Sandbox pool uses Kata VM isolation with 0-3 autoscaling.

- [ ] **Step 1: Create `terraform/aks.tf`**

Ref: `DESIGN.md` lines 180-215. Key points:
- `kubernetes_version = "1.30"`
- `os_sku = "AzureLinux"` (required for Kata)
- `oidc_issuer_enabled = true` and `workload_identity_enabled = true`
- `network_plugin = "azure"`, `service_cidr = "10.1.0.0/16"`
- `oms_agent` block references `azurerm_log_analytics_workspace.openclaw.id` (created in Task 3)

**CRITICAL (not in DESIGN.md):** Enable the Secrets Store CSI driver add-on — required for `SecretProviderClass` to work:
```hcl
  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }
```
Without this, `kubectl apply` of `feishu-secret-provider.yaml` will fail with CRD not found.

- [ ] **Step 2: Create `terraform/nodepool.tf`**

Ref: `DESIGN.md` lines 220-243. Key points:
- `workload_runtime = "KataVmIsolation"`
- `os_sku = "AzureLinux"`
- `enable_auto_scaling = true`, `min_count = 0`, `max_count = 3`
- Node labels: `openclaw.io/role = sandbox`
- Node taints: `openclaw.io/sandbox=true:NoSchedule`

- [ ] **Step 3: Validate**

```bash
cd terraform && terraform validate
```

- [ ] **Step 4: Commit**

```bash
git add terraform/aks.tf terraform/nodepool.tf
git commit -m "feat(terraform): add AKS cluster and Kata sandbox node pool"
```

---

### Task 6: Private Endpoints + DNS Zones

**Files:**
- Create: `terraform/private-endpoints.tf`

Three Private Endpoints (AI Foundry, Azure Files, Key Vault) + three Private DNS Zones + VNet links.

- [ ] **Step 1: Create `terraform/private-endpoints.tf`**

Ref: `DESIGN.md` lines 365-464. Contains:
- `azurerm_private_endpoint` × 3 (ai_foundry, storage_files, keyvault)
- `azurerm_private_dns_zone` × 3 (cognitiveservices, file.core, vaultcore)
- `azurerm_private_dns_zone_virtual_network_link` × 3

**Also need:** AI Foundry (Cognitive Account) resource — not defined in DESIGN.md but referenced by Private Endpoints. Create as `terraform/ai-foundry.tf` (separate file for clarity):
```hcl
resource "azurerm_cognitive_account" "ai_foundry" {
  name                  = "openclaw-ai"
  location              = var.location
  resource_group_name   = data.azurerm_resource_group.main.name
  kind                  = "OpenAI"
  sku_name              = "S0"
  custom_subdomain_name = "openclaw-ai"

  public_network_access_enabled = false

  network_acls {
    default_action = "Deny"
  }
}

resource "azurerm_cognitive_deployment" "gpt5" {
  name                 = "gpt-5"
  cognitive_account_id = azurerm_cognitive_account.ai_foundry.id

  model {
    format  = "OpenAI"
    name    = "gpt-5"     # adjust to actual available model name
    version = "latest"
  }

  sku {
    name     = "Standard"
    capacity = 60          # 60K TPM
  }
}
```

> **Note:** The actual GPT-5 model name may differ. Adjust `model.name` to whatever is available in your region at deploy time.

- [ ] **Step 2: Validate**

```bash
cd terraform && terraform validate
```

- [ ] **Step 3: Commit**

```bash
git add terraform/private-endpoints.tf terraform/ai-foundry.tf
git commit -m "feat(terraform): add Private Endpoints, DNS zones, and AI Foundry"
```

---

### Task 7: APIM AI Gateway

**Files:**
- Create: `terraform/apim.tf`
- Create: `terraform/apim-api.tf`
- Create: `terraform/apim-subscriptions.tf`
- Create: `policies/ai-gateway.xml`

APIM is the most complex Terraform resource. Internal VNet mode, DNS zone, API import, policy, per-agent subscriptions, and the App Insights logger that was deferred from Task 3.

- [ ] **Step 1: Create `terraform/apim.tf`**

Ref: `DESIGN.md` lines 312-361. Contains:
- `azurerm_api_management` (StandardV2, Internal VNet mode)
- `azurerm_private_dns_zone` for `azure-api.net`
- `azurerm_private_dns_a_record` pointing to APIM private IP
- `azurerm_private_dns_zone_virtual_network_link` for APIM
- `azurerm_api_management_logger` (moved from monitoring.tf)

> **Warning:** APIM provisioning takes 20-45 minutes. Plan accordingly during `terraform apply`.

- [ ] **Step 2: Create `terraform/apim-api.tf`**

Import the Azure OpenAI API spec into APIM:
```hcl
resource "azurerm_api_management_api" "openai" {
  name                = "azure-openai"
  resource_group_name = data.azurerm_resource_group.main.name
  api_management_name = azurerm_api_management.openclaw.name
  revision            = "1"
  display_name        = "Azure OpenAI"
  path                = "openai"
  protocols           = ["https"]
  service_url         = "https://${azurerm_cognitive_account.ai_foundry.custom_subdomain_name}.openai.azure.com"
  subscription_required = true
}

# Apply the AI Gateway policy
resource "azurerm_api_management_api_policy" "openai" {
  api_name            = azurerm_api_management_api.openai.name
  api_management_name = azurerm_api_management.openclaw.name
  resource_group_name = data.azurerm_resource_group.main.name
  xml_content         = file("${path.module}/../policies/ai-gateway.xml")
}
```

- [ ] **Step 3: Create `policies/ai-gateway.xml`**

Ref: `DESIGN.md` lines 469-503. Managed Identity auth + 60K TPM limit + token metrics + backend routing.

- [ ] **Step 4: Create `terraform/apim-subscriptions.tf`**

Ref: `DESIGN.md` lines 507-519. `for_each = var.agent_ids`.

- [ ] **Step 5: Validate**

```bash
cd terraform && terraform validate
```

- [ ] **Step 6: Commit**

```bash
git add terraform/apim.tf terraform/apim-api.tf terraform/apim-subscriptions.tf policies/ai-gateway.xml
git commit -m "feat(terraform): add APIM AI Gateway with policy and subscriptions"
```

---

### Task 8: Identity + RBAC

**Files:**
- Create: `terraform/identity.tf`

All role assignments and Workload Identity federation. Placed AFTER Task 7 because `apim_ai_user` references APIM's Managed Identity principal.

- [ ] **Step 1: Create `terraform/identity.tf`**

```hcl
# AKS kubelet → ACR pull
resource "azurerm_role_assignment" "aks_acr" {
  scope                = azurerm_container_registry.openclaw.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.openclaw.kubelet_identity[0].object_id
}

# APIM Managed Identity → AI Foundry (Cognitive Services OpenAI User)
resource "azurerm_role_assignment" "apim_ai_user" {
  scope                = azurerm_cognitive_account.ai_foundry.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_api_management.openclaw.identity[0].principal_id
}

# Workload Identity: User-Assigned MI for sandbox pods
resource "azurerm_user_assigned_identity" "sandbox" {
  name                = "openclaw-sandbox-identity"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location
}

resource "azurerm_federated_identity_credential" "sandbox" {
  name                = "openclaw-sandbox-fedcred"
  resource_group_name = data.azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.sandbox.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.openclaw.oidc_issuer_url
  subject             = "system:serviceaccount:openclaw:openclaw-sandbox"
}

# Sandbox pods → Key Vault Secrets User
# NOTE: Use .principal_id (object ID), NOT .id (resource ID)
resource "azurerm_role_assignment" "sandbox_kv_reader" {
  scope                = azurerm_key_vault.openclaw.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.sandbox.principal_id
}
```

- [ ] **Step 2: Validate**

```bash
cd terraform && terraform validate
```

- [ ] **Step 3: Commit**

```bash
git add terraform/identity.tf
git commit -m "feat(terraform): add RBAC assignments and Workload Identity"
```

---

### Task 9: Terraform Outputs + Full Validation

**Files:**
- Create: `terraform/outputs.tf`
- Create: `terraform/terraform.tfvars.example`

- [ ] **Step 1: Create `terraform/outputs.tf`**

```hcl
output "aks_fqdn" {
  value = azurerm_kubernetes_cluster.openclaw.fqdn
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.openclaw.name
}

output "acr_name" {
  value = azurerm_container_registry.openclaw.name
}

output "acr_login_server" {
  value = azurerm_container_registry.openclaw.login_server
}

output "apim_private_url" {
  value = "https://${azurerm_api_management.openclaw.name}.azure-api.net"
}

output "apim_private_ip" {
  value = azurerm_api_management.openclaw.private_ip_addresses[0]
}

output "keyvault_name" {
  value = azurerm_key_vault.openclaw.name
}

output "sandbox_identity_client_id" {
  value = azurerm_user_assigned_identity.sandbox.client_id
}

# Used by scripts
output "resource_group" {
  value = data.azurerm_resource_group.main.name
}

output "apim_name" {
  value = azurerm_api_management.openclaw.name
}

output "storage_account_name" {
  value = azurerm_storage_account.openclaw.name
}
```

- [ ] **Step 2: Create `terraform/terraform.tfvars.example`**

```hcl
resource_group = "openclaw-rg"
location       = "eastasia"
cluster_name   = "openclaw-aks"
admin_email    = "admin@example.com"
agent_ids      = ["alice"]
```

- [ ] **Step 3: Full validate + format check**

```bash
cd terraform && terraform fmt -check -recursive && terraform validate
```

Expected: All files formatted, configuration valid.

- [ ] **Step 4: Terraform plan (dry run)**

```bash
cd terraform && cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with real values
terraform plan -out=tfplan
```

Review the plan output: should show ~25-30 resources to create, 0 to change, 0 to destroy.

- [ ] **Step 5: Commit**

```bash
git add terraform/outputs.tf terraform/terraform.tfvars.example
git commit -m "feat(terraform): add outputs and tfvars example — all TF files complete"
```

---

## Chunk 2: Container Images + Kubernetes Manifests

### Task 10: Docker Images

**Files:**
- Create: `docker/Dockerfile`
- Create: `docker/persist-sync/Dockerfile`

Two images: the main OpenClaw sandbox and the lightweight persist-sync sidecar.

- [ ] **Step 1: Create `docker/Dockerfile` (OpenClaw sandbox)**

Ref: `DESIGN.md` lines 585-601.

```dockerfile
FROM node:22-slim

# Install OpenClaw + common tools
RUN npm install -g openclaw@latest && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      git python3 curl ca-certificates imagemagick && \
    rm -rf /var/lib/apt/lists/*

# Non-root user
USER 1000
WORKDIR /home/node/.openclaw/workspace

ENTRYPOINT ["openclaw", "gateway", "run"]
```

- [ ] **Step 2: Create `docker/persist-sync/Dockerfile` (sidecar)**

```dockerfile
FROM alpine:3.20

RUN apk add --no-cache inotify-tools coreutils

USER 1000

# No ENTRYPOINT — command defined in StatefulSet YAML
```

- [ ] **Step 3: Validate Docker builds locally (syntax check)**

```bash
docker build --check docker/
docker build --check docker/persist-sync/
```

> If `--check` not available, use `docker build --no-cache -t test-sandbox docker/ && docker rmi test-sandbox` to verify build succeeds.

- [ ] **Step 4: Commit**

```bash
git add docker/
git commit -m "feat(docker): add OpenClaw sandbox and persist-sync sidecar Dockerfiles"
```

---

### Task 11: Kubernetes Manifests — Namespace + Storage

**Files:**
- Create: `k8s/namespaces.yaml`
- Create: `k8s/storage/disk-storageclass.yaml`
- Create: `k8s/storage/files-storageclass.yaml`

- [ ] **Step 1: Create `k8s/namespaces.yaml`**

Ref: `DESIGN.md` lines 898-907. Namespace with Pod Security Standard `restricted`.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openclaw
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
```

- [ ] **Step 2: Create `k8s/storage/disk-storageclass.yaml`**

Ref: `DESIGN.md` lines 250-262. Premium LRS, WaitForFirstConsumer.

- [ ] **Step 3: Create `k8s/storage/files-storageclass.yaml`**

Ref: `DESIGN.md` lines 266-282. Premium LRS NFS via Private Endpoint.

- [ ] **Step 4: Dry-run validate**

```bash
kubectl apply --dry-run=client -f k8s/namespaces.yaml
kubectl apply --dry-run=client -f k8s/storage/
```

- [ ] **Step 5: Commit**

```bash
git add k8s/namespaces.yaml k8s/storage/
git commit -m "feat(k8s): add namespace and storage classes"
```

---

### Task 12: Kubernetes Manifests — Security + Secrets

**Files:**
- Create: `k8s/sandbox/service-account.yaml`
- Create: `k8s/sandbox/feishu-secret-provider.yaml`
- Create: `k8s/security/netpol-sandbox.yaml`

> **Note:** `k8s/security/pod-security.yaml` is NOT created as a separate file. The namespace with PSS labels is already defined in `k8s/namespaces.yaml` (Task 11). DESIGN.md §3.8.1 shows the same content — we avoid duplication by keeping it in one place.

- [ ] **Step 1: Create `k8s/sandbox/service-account.yaml`**

Workload Identity requires a K8s ServiceAccount annotated with the User-Assigned MI client ID:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: openclaw-sandbox
  namespace: openclaw
  annotations:
    azure.workload.identity/client-id: "<sandbox_identity_client_id>"  # from terraform output
  labels:
    azure.workload.identity/use: "true"
```

- [ ] **Step 2: Create `k8s/sandbox/feishu-secret-provider.yaml`**

Ref: `DESIGN.md` lines 1125-1156. SecretProviderClass for Feishu credentials from Key Vault.

- [ ] **Step 3: Create `k8s/security/netpol-sandbox.yaml`**

Ref: `DESIGN.md` lines 1185-1218. Egress-only NetworkPolicy: allow 443 (any), APIM subnet, DNS.

- [ ] **Step 4: Dry-run validate**

```bash
kubectl apply --dry-run=client -f k8s/sandbox/service-account.yaml
kubectl apply --dry-run=client -f k8s/sandbox/feishu-secret-provider.yaml
kubectl apply --dry-run=client -f k8s/security/netpol-sandbox.yaml
```

- [ ] **Step 5: Commit**

```bash
git add k8s/sandbox/service-account.yaml k8s/sandbox/feishu-secret-provider.yaml k8s/security/netpol-sandbox.yaml
git commit -m "feat(k8s): add ServiceAccount, SecretProviderClass, and NetworkPolicy"
```

---

### Task 13: Kubernetes Manifests — StatefulSet (Core)

**Files:**
- Create: `k8s/sandbox/agent-statefulset.yaml`

This is the most complex K8s manifest. Contains: StatefulSet, init containers (setup-workspace + persist-sync sidecar), main container, ConfigMap, PVCs.

- [ ] **Step 1: Create `k8s/sandbox/agent-statefulset.yaml`**

Ref: `DESIGN.md` lines 612-857. This single file contains:
- StatefulSet `openclaw-agent` with:
  - `runtimeClassName: kata-vm-isolation`
  - initContainer `setup-workspace` (ordinal→agent-id mapping, restore from Azure Files)
  - Native Sidecar `persist-sync` (inotifywait + atomic cp + SIGTERM trap)
  - Main container `openclaw` (with Feishu env vars from secretKeyRef)
  - `volumeClaimTemplates` for Azure Disk (work-disk, 5Gi)
- PVC `openclaw-files` (Azure Files, ReadWriteMany, 5Gi)
- ConfigMap `agent-mapping` (ordinal→agent-id)

Key items to **adapt** from DESIGN.md:
- Add Feishu env vars (`FEISHU_APP_ID`, `FEISHU_APP_SECRET`) from `feishu-credentials` secret
- Add `feishu-secrets` CSI volume to the volumes list
- Remove `containerPort: 3000` from main container (no inbound needed with WS mode)
- Ensure `securityContext` is compatible with PSS `restricted` (add `seccompProfile`, `allowPrivilegeEscalation: false`, etc.)

- [ ] **Step 2: Validate restricted PSS compatibility**

The `restricted` Pod Security Standard requires:
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  seccompProfile:
    type: RuntimeDefault
containers:
- securityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop: ["ALL"]
    readOnlyRootFilesystem: false  # OpenClaw needs to write
```

Ensure ALL containers (init, sidecar, main) have these fields.

- [ ] **Step 3: Dry-run validate**

```bash
kubectl apply --dry-run=client -f k8s/sandbox/agent-statefulset.yaml
```

- [ ] **Step 4: Commit**

```bash
git add k8s/sandbox/agent-statefulset.yaml
git commit -m "feat(k8s): add Agent StatefulSet with persist-sync sidecar and agent mapping"
```

---

## Chunk 3: Scripts + Deployment + Validation

### Task 14: Operational Scripts

**Files:**
- Create: `scripts/install.sh`
- Create: `scripts/create-agent.sh`
- Create: `scripts/build-image.sh`
- Create: `scripts/destroy.sh`

- [ ] **Step 1: Create `scripts/install.sh`**

Ref: `DESIGN.md` lines 1031-1075. One-shot deployment: terraform apply → build images → get kubeconfig → deploy K8s resources.

Key addition vs DESIGN.md:
- Also build the persist-sync sidecar image
- Apply feishu-secret-provider after substituting terraform outputs
- Store APIM subscription key and Feishu credentials in Key Vault

- [ ] **Step 2: Create `scripts/build-image.sh`**

```bash
#!/bin/bash
set -euo pipefail

ACR_NAME="${1:?Usage: build-image.sh <acr-name>}"

echo "=== Building OpenClaw sandbox image ==="
az acr build --registry "$ACR_NAME" --image openclaw-sandbox:latest docker/

echo "=== Building persist-sync sidecar image ==="
az acr build --registry "$ACR_NAME" --image persist-sync:latest docker/persist-sync/

echo "=== Done ==="
az acr repository list --name "$ACR_NAME" -o table
```

- [ ] **Step 3: Create `scripts/create-agent.sh`**

Ref: `DESIGN.md` lines 862-892. Patch ConfigMap → init storage → create APIM subscription → scale StatefulSet.

Flesh out the "TODO" for APIM subscription creation AND openclaw.json generation (gap in DESIGN.md):
```bash
# Create APIM subscription via az CLI
APIM_NAME=$(cd ../terraform && terraform output -raw apim_name 2>/dev/null || echo "openclaw-apim")
RG=$(cd ../terraform && terraform output -raw resource_group 2>/dev/null || echo "openclaw-rg")
SUBSCRIPTION_KEY=$(az apim subscription create \
  --resource-group "$RG" \
  --service-name "$APIM_NAME" \
  --display-name "openclaw-agent-${AGENT_ID}" \
  --scope "/apis" \
  --query primaryKey -o tsv)

# Store APIM key in Key Vault
KV_NAME=$(cd ../terraform && terraform output -raw keyvault_name 2>/dev/null || echo "openclaw-kv")
az keyvault secret set --vault-name "$KV_NAME" --name "apim-key-${AGENT_ID}" --value "$SUBSCRIPTION_KEY"

# Generate openclaw.json config and upload to Azure Files
# (Ref: DESIGN.md §3.5.5 — this is NOT done in the spec, but required for the agent to work)
APIM_URL=$(cd ../terraform && terraform output -raw apim_private_url)
STORAGE_ACCOUNT=$(cd ../terraform && terraform output -raw storage_account_name 2>/dev/null || echo "openclawstorage")
SHARE_NAME="openclaw-data"

cat > /tmp/openclaw-${AGENT_ID}.json <<EOFCONFIG
{
  "models": {
    "providers": {
      "azure-apim": {
        "baseUrl": "${APIM_URL}/openai/v1",
        "apiKey": "${SUBSCRIPTION_KEY}",
        "api": "openai-responses",
        "headers": {
          "Ocp-Apim-Subscription-Key": "${SUBSCRIPTION_KEY}",
          "api-version": "2025-04-01-preview"
        },
        "authHeader": false,
        "models": [
          {
            "id": "gpt-5",
            "name": "GPT-5 (via APIM)",
            "reasoning": true,
            "input": ["text", "image"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 200000,
            "maxTokens": 16384
          }
        ]
      }
    }
  }
}
EOFCONFIG

# Upload to Azure Files via a temp pod (since storage has no public access)
kubectl run upload-config --rm -it --restart=Never -n openclaw \
  --image=busybox:1.36 \
  --overrides="{
    \"spec\": {
      \"containers\": [{
        \"name\": \"upload\",
        \"image\": \"busybox:1.36\",
        \"command\": [\"sh\", \"-c\", \"mkdir -p /persist/${AGENT_ID}/config && cat > /persist/${AGENT_ID}/config/openclaw.json\"],
        \"stdin\": true,
        \"volumeMounts\": [{\"name\": \"files\", \"mountPath\": \"/persist\"}]
      }],
      \"volumes\": [{\"name\": \"files\", \"persistentVolumeClaim\": {\"claimName\": \"openclaw-files\"}}]
    }
  }" < /tmp/openclaw-${AGENT_ID}.json
```

- [ ] **Step 4: Create `scripts/destroy.sh`**

```bash
#!/bin/bash
set -euo pipefail

echo "⚠️  This will destroy ALL OpenClaw resources"
read -p "Type 'yes' to confirm: " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Aborted."; exit 1; }

echo "=== Deleting K8s resources ==="
kubectl delete namespace openclaw --ignore-not-found

echo "=== Destroying Terraform infrastructure ==="
cd terraform
# Uses terraform.tfvars for all variable values (including admin_email which has no default)
terraform destroy -auto-approve

echo "=== Done ==="
```

- [ ] **Step 5: Make scripts executable + shellcheck**

```bash
chmod +x scripts/*.sh
shellcheck scripts/*.sh
```

Fix any shellcheck warnings.

- [ ] **Step 6: Commit**

```bash
git add scripts/
git commit -m "feat(scripts): add install, create-agent, build-image, destroy scripts"
```

---

### Task 15: Terraform Apply — Provision Infrastructure

**Prerequisites:** Azure subscription with sufficient quota, `az login` done, resource group exists.

- [ ] **Step 1: Create terraform.tfvars with real values**

```bash
cd terraform
cat > terraform.tfvars <<'EOF'
resource_group = "openclaw-rg"
location       = "eastasia"
cluster_name   = "openclaw-aks"
admin_email    = "your-email@example.com"
agent_ids      = ["alice"]
EOF
```

- [ ] **Step 2: Terraform init + plan**

```bash
terraform init
terraform plan -out=tfplan
```

Review output carefully. Expect ~30 resources.

- [ ] **Step 3: Terraform apply**

```bash
terraform apply tfplan
```

> **This will take 30-60 minutes** (APIM alone is 20-45 min). Monitor progress.

- [ ] **Step 4: Save outputs**

```bash
terraform output -json > ../outputs.json
echo "AKS: $(terraform output -raw aks_name)"
echo "ACR: $(terraform output -raw acr_name)"
echo "APIM: $(terraform output -raw apim_private_url)"
```

- [ ] **Step 5: Verify resources in Azure Portal**

Spot-check:
- Resource Group shows all resources
- AKS cluster is running, has system + sandbox node pools
- APIM is provisioned in Internal mode
- Private Endpoints show "Succeeded" connection status
- Key Vault has no public access
- Storage Account NFS share exists

---

### Task 16: Build + Push Docker Images

- [ ] **Step 1: Build and push to ACR**

```bash
ACR_NAME=$(cd terraform && terraform output -raw acr_name)
scripts/build-image.sh "$ACR_NAME"
```

- [ ] **Step 2: Verify images in ACR**

```bash
az acr repository list --name "$ACR_NAME" -o table
az acr repository show-tags --name "$ACR_NAME" --repository openclaw-sandbox -o table
az acr repository show-tags --name "$ACR_NAME" --repository persist-sync -o table
```

Expected: Both `openclaw-sandbox:latest` and `persist-sync:latest` exist.

- [ ] **Step 3: Commit** (if any Dockerfile adjustments were needed)

```bash
git add -A && git diff --cached --quiet || git commit -m "fix(docker): adjust Dockerfiles based on build feedback"
```

---

### Task 17: Deploy Kubernetes Resources

- [ ] **Step 1: Get kubeconfig**

```bash
RG=$(cd terraform && terraform output -raw resource_group 2>/dev/null || echo "openclaw-rg")
CLUSTER=$(cd terraform && terraform output -raw aks_name)
az aks get-credentials --resource-group "$RG" --name "$CLUSTER" --overwrite-existing
kubectl cluster-info
```

- [ ] **Step 2: Template K8s manifests with Terraform outputs**

Copy source YAML to a `deploy/` directory, then substitute placeholders there. This keeps source files clean with placeholders intact (never commit `deploy/`):

```bash
mkdir -p deploy
cp -r k8s/* deploy/

CLIENT_ID=$(cd terraform && terraform output -raw sandbox_identity_client_id)
TENANT_ID=$(az account show --query tenantId -o tsv)
ACR_SERVER=$(cd terraform && terraform output -raw acr_login_server)

# Substitute in deploy copies (NOT in source k8s/ files)
sed -i "s|<sandbox_identity_client_id>|$CLIENT_ID|" deploy/sandbox/service-account.yaml
sed -i "s|<workload-identity-client-id>|$CLIENT_ID|" deploy/sandbox/feishu-secret-provider.yaml
sed -i "s|<tenant-id>|$TENANT_ID|" deploy/sandbox/feishu-secret-provider.yaml
sed -i "s|openclawacr.azurecr.io|$ACR_SERVER|g" deploy/sandbox/agent-statefulset.yaml
```

> **IMPORTANT:** All subsequent `kubectl apply` commands use `deploy/` not `k8s/`. Add `deploy/` to `.gitignore`.
> **Better approach for v2:** Use Helm or Kustomize for templating.

- [ ] **Step 3: Deploy namespace + storage**

```bash
kubectl apply -f deploy/namespaces.yaml
kubectl apply -f deploy/storage/
```

- [ ] **Step 4: Deploy security + secrets**

```bash
kubectl apply -f deploy/security/
kubectl apply -f deploy/sandbox/service-account.yaml
kubectl apply -f deploy/sandbox/feishu-secret-provider.yaml
```

- [ ] **Step 5: Store Feishu credentials in Key Vault**

```bash
KV_NAME=$(cd terraform && terraform output -raw keyvault_name)
az keyvault secret set --vault-name "$KV_NAME" --name "feishu-app-id" --value "<your-feishu-app-id>"
az keyvault secret set --vault-name "$KV_NAME" --name "feishu-app-secret" --value "<your-feishu-app-secret>"
```

- [ ] **Step 6: Deploy StatefulSet**

```bash
kubectl apply -f deploy/sandbox/agent-statefulset.yaml
```

- [ ] **Step 7: Verify Pod startup**

```bash
# Wait for sandbox node to scale up (may take 3-5 min from 0)
kubectl get nodes -w

# Watch pod status
kubectl get pods -n openclaw -w

# Check events for errors
kubectl describe pod openclaw-agent-0 -n openclaw
```

Expected: Pod `openclaw-agent-0` reaches `Running` state with all containers ready.

---

### Task 18: End-to-End Validation

- [ ] **Step 1: Verify Agent Pod health**

```bash
# All containers running?
kubectl get pod openclaw-agent-0 -n openclaw -o jsonpath='{.status.containerStatuses[*].name}:{.status.containerStatuses[*].ready}'

# Agent logs — should show OpenClaw gateway startup
kubectl logs openclaw-agent-0 -c openclaw -n openclaw --tail=50

# Persist-sync logs — should show agent-id detection
kubectl logs openclaw-agent-0 -c persist-sync -n openclaw --tail=20
```

- [ ] **Step 2: Verify Feishu WebSocket connection**

```bash
# Look for WebSocket connection log
kubectl logs openclaw-agent-0 -c openclaw -n openclaw | grep -i "feishu\|websocket\|connected"
```

Expected: Log line showing successful WS connection to feishu.

- [ ] **Step 3: Verify APIM internal connectivity from Pod**

```bash
# Exec into the pod and test APIM endpoint
kubectl exec openclaw-agent-0 -c openclaw -n openclaw -- \
  curl -s -o /dev/null -w "%{http_code}" \
  https://openclaw-apim.azure-api.net/status-0123456789abcdef
```

Expected: HTTP 200 or 401 (means APIM is reachable; 401 = no subscription key provided, which is correct).

- [ ] **Step 4: Verify persist-sync is working**

```bash
# Create a test file in the agent workspace
kubectl exec openclaw-agent-0 -c openclaw -n openclaw -- \
  sh -c 'echo "test" > /home/node/.openclaw/workspace/MEMORY.md'

# Wait ~10 seconds for inotifywait to trigger sync
sleep 10

# Check Azure Files has the file
kubectl exec openclaw-agent-0 -c persist-sync -n openclaw -- \
  ls -la /persist/alice/workspace/MEMORY.md
```

Expected: File exists in the persist path.

- [ ] **Step 5: Send a test message in Feishu**

In the Feishu app, send a message to the bot. Check agent logs for processing:

```bash
kubectl logs -f openclaw-agent-0 -c openclaw -n openclaw
```

Expected: Agent receives message via WS, processes it, sends reply.

- [ ] **Step 6: Final commit — any deploy-time fixes**

```bash
git add -A && git diff --cached --quiet || git commit -m "fix: deploy-time adjustments from E2E validation"
```

---

## Summary

| Phase | Tasks | Est. Time | Key Dependency |
|-------|-------|-----------|----------------|
| Terraform Foundation | 1-9 | ~3 hours coding | None |
| Terraform Apply | 15 | ~1 hour (mostly waiting) | Tasks 1-9 complete |
| Docker Images | 10, 16 | ~30 min | ACR provisioned |
| K8s Manifests | 11-13 | ~1.5 hours | None (code only) |
| K8s Deploy | 17 | ~30 min | AKS + images + manifests |
| Scripts | 14 | ~1 hour | None (code only) |
| E2E Validation | 18 | ~30 min | Everything deployed |

**Total estimated:** ~8 hours (with ~1.5 hours of Azure provisioning wait time)

**Parallelism:** Tasks 10-14 (Docker + K8s manifests + scripts) can be developed in parallel with Tasks 1-9 (Terraform), since they are pure code with no runtime dependency. Only the deploy/validation steps (15-18) require sequential execution.
