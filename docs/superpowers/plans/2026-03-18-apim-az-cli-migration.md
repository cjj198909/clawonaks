# APIM Sub-Resources az CLI Migration Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create `scripts/install-v2.sh` — a new version of the install script where APIM sub-resources (Logger, Named Value, Backend, Backend Pool, API, Operation, Policy) are created via idempotent `az` CLI commands instead of Terraform, eliminating the "already exists" race condition that prevents one-shot deployment.

**Architecture:** Copy `install.sh` → `install-v2.sh`. Remove all APIM sub-resource Terraform files and replace the complex import/retry logic in Step 1 with a single `terraform apply` (no retry needed). Add a new Step 1b after Terraform that creates all APIM sub-resources via `az` CLI + `az rest`. Sub-resources are idempotent (check-then-create). Terraform still manages APIM service itself.

**Tech Stack:** bash, az CLI, Terraform (reduced scope), ARM REST API via `az rest`

---

### Task 1: Copy install.sh → install-v2.sh

**Files:**
- Create: `scripts/install-v2.sh` (copy of `scripts/install.sh`)

**Step 1: Copy**

```bash
cp scripts/install.sh scripts/install-v2.sh
chmod +x scripts/install-v2.sh
```

**Step 2: Verify copy exists**

```bash
ls -la scripts/install-v2.sh
```
Expected: file exists, executable

---

### Task 2: Remove APIM sub-resource Terraform files

These files contain the resources that race: Logger, Named Value, Backend, Backend Pool, API, Operation, Policy.
APIM service itself (`azurerm_api_management.openclaw`) stays in `apim.tf`.

**Files:**
- Delete resources from: `terraform/apim-api.tf`, `terraform/apim-backend.tf`, `terraform/apim-named-values.tf`
- Keep: `terraform/apim.tf` (Logger block also here — remove it), `terraform/apim-subscriptions.tf` (already empty)
- Modify: `terraform/outputs.tf` — remove `apim_api_id` output (no longer in state)

**Step 1: Remove `terraform/apim-api.tf` content** (replace with comment only)

```hcl
# APIM API, Operation, and Policy are now created by install-v2.sh via az CLI.
# See scripts/install-v2.sh Step 1b.
```

**Step 2: Remove `terraform/apim-backend.tf` content** (replace with comment only)

```hcl
# APIM Backends (openai-backend-1 and openai-backend-pool) are now created
# by install-v2.sh via az CLI. See scripts/install-v2.sh Step 1b.
```

**Step 3: Remove `terraform/apim-named-values.tf` content** (replace with comment only)

```hcl
# APIM Named Value (azure-openai-key) is now created by install-v2.sh via az CLI.
# See scripts/install-v2.sh Step 1b.
```

**Step 4: Remove Logger block from `terraform/apim.tf`**

Remove lines:
```hcl
resource "azurerm_api_management_logger" "insights" {
  count = var.enable_apim ? 1 : 0
  ...
}
```
Replace with:
```hcl
# APIM Logger is now created by install-v2.sh via az CLI.
```

**Step 5: Remove `apim_api_id` output from `terraform/outputs.tf`**

Remove:
```hcl
output "apim_api_id" {
  description = "Full ARM resource ID of the Azure OpenAI API in APIM (subscription scope)"
  value       = var.enable_apim ? azurerm_api_management_api.openai[0].id : ""
}
```

---

### Task 3: Simplify Step 1 Terraform logic in install-v2.sh

Replace the complex retry/import logic (lines ~69–185) with a single clean apply. Since APIM sub-resources no longer exist in Terraform, there's nothing to race.

**Files:**
- Modify: `scripts/install-v2.sh` lines 60–190

**Step 1: Replace the entire terraform apply block with:**

```bash
  # Single apply — no race condition possible because APIM sub-resources
  # are managed by az CLI in Step 1b, not Terraform.
  terraform apply "${TF_ARGS[@]}"
  rm -f "$TF_LOG" 2>/dev/null || true
  cd "$ROOT_DIR"
```

Remove: all `set +e`, `tee "$TF_LOG"`, `TF_EXIT`, `IMPORTED`, import loops, retry loops, `APIM_API_ID_CHECK` second-apply check.

Also remove the "inter-apply KV write" block (lines ~79–91) — KV write moves to Step 2 where it already exists.

---

### Task 4: Add Step 1b — APIM sub-resources via az CLI

Insert a new step immediately after the `cd "$ROOT_DIR"` at the end of Step 1 (terraform block), before the "Extract terraform outputs" section.

**Files:**
- Modify: `scripts/install-v2.sh`

**Step 1: Add the Step 1b function after terraform block:**

```bash
# ============================
# Step 1b/7: APIM Sub-Resources (az CLI — idempotent)
# ============================
if [[ "$ENABLE_APIM" == "true" && "$SKIP_TERRAFORM" == "false" ]]; then
  echo ""
  echo "=== Step 1b/7: APIM Sub-Resources ==="
  cd "$ROOT_DIR/terraform"

  # Get values needed for sub-resource creation
  APIM_NAME_STEP1B=$(terraform output -raw apim_name 2>/dev/null || echo "")
  KV_NAME_STEP1B=$(terraform output -raw keyvault_name 2>/dev/null || echo "")
  RG_STEP1B=$(terraform output -raw resource_group 2>/dev/null || echo "")
  AZ_SUB_STEP1B=$(az account show --query id -o tsv)
  APP_INSIGHTS_KEY=$(terraform output -raw app_insights_instrumentation_key 2>/dev/null || echo "")
  cd "$ROOT_DIR"

  APIM_BASE="https://management.azure.com/subscriptions/${AZ_SUB_STEP1B}/resourceGroups/${RG_STEP1B}/providers/Microsoft.ApiManagement/service/${APIM_NAME_STEP1B}"
  APIM_API_VER="?api-version=2024-06-01-preview"

  # Write KV secret first (Named Value references it)
  echo "  Writing azure-openai-key to KV..."
  for _attempt in 1 2 3; do
    if az keyvault secret set --vault-name "$KV_NAME_STEP1B" --name azure-openai-key \
        --value "$AOAI_KEY" --output none 2>/dev/null; then
      echo "  azure-openai-key stored in $KV_NAME_STEP1B"
      break
    fi
    [[ $_attempt -lt 3 ]] && echo "  KV write attempt $_attempt failed (RBAC). Retrying in 15s..." && sleep 15
  done

  # 1. Logger (App Insights)
  echo "  Creating APIM Logger..."
  LOGGER_EXISTS=$(az rest --method GET \
    --url "${APIM_BASE}/loggers/app-insights-logger${APIM_API_VER}" \
    --query "name" -o tsv 2>/dev/null || echo "")
  if [[ -z "$LOGGER_EXISTS" ]]; then
    az rest --method PUT \
      --url "${APIM_BASE}/loggers/app-insights-logger${APIM_API_VER}" \
      --body "{\"properties\":{\"loggerType\":\"applicationInsights\",\"description\":\"App Insights Logger\",\"credentials\":{\"instrumentationKey\":\"${APP_INSIGHTS_KEY}\"}}}" \
      --output none
    echo "  Logger created."
  else
    echo "  Logger already exists, skipping."
  fi

  # 2. Named Value (KV-backed)
  echo "  Creating APIM Named Value (azure-openai-key)..."
  KV_URI=$(az keyvault show --name "$KV_NAME_STEP1B" --query "properties.vaultUri" -o tsv 2>/dev/null || echo "")
  NV_EXISTS=$(az rest --method GET \
    --url "${APIM_BASE}/namedValues/azure-openai-key${APIM_API_VER}" \
    --query "name" -o tsv 2>/dev/null || echo "")
  if [[ -z "$NV_EXISTS" ]]; then
    az rest --method PUT \
      --url "${APIM_BASE}/namedValues/azure-openai-key${APIM_API_VER}" \
      --body "{\"properties\":{\"displayName\":\"azure-openai-key\",\"secret\":true,\"keyVault\":{\"secretIdentifier\":\"${KV_URI}secrets/azure-openai-key\"}}}" \
      --output none
    echo "  Named Value created."
  else
    echo "  Named Value already exists, skipping."
  fi

  # 3. Backend (single endpoint)
  echo "  Creating APIM Backend (openai-backend-1)..."
  BACKEND_EXISTS=$(az rest --method GET \
    --url "${APIM_BASE}/backends/openai-backend-1${APIM_API_VER}" \
    --query "name" -o tsv 2>/dev/null || echo "")
  if [[ -z "$BACKEND_EXISTS" ]]; then
    az rest --method PUT \
      --url "${APIM_BASE}/backends/openai-backend-1${APIM_API_VER}" \
      --body "{\"properties\":{\"description\":\"Azure OpenAI backend\",\"protocol\":\"http\",\"url\":\"${AOAI_ENDPOINT}\",\"circuitBreaker\":{\"rules\":[{\"name\":\"OpenAIBreakerRule\",\"failureCondition\":{\"count\":3,\"errorReasons\":[\"Server errors\"],\"statusCodeRanges\":[{\"min\":429,\"max\":429},{\"min\":500,\"max\":503}],\"interval\":\"PT1M\"},\"tripDuration\":\"PT1M\",\"acceptRetryAfter\":true}]}}}" \
      --output none
    echo "  Backend created."
  else
    echo "  Backend already exists, skipping."
  fi

  # 4. Backend Pool
  echo "  Creating APIM Backend Pool (openai-backend-pool)..."
  POOL_EXISTS=$(az rest --method GET \
    --url "${APIM_BASE}/backends/openai-backend-pool${APIM_API_VER}" \
    --query "name" -o tsv 2>/dev/null || echo "")
  if [[ -z "$POOL_EXISTS" ]]; then
    az rest --method PUT \
      --url "${APIM_BASE}/backends/openai-backend-pool${APIM_API_VER}" \
      --body "{\"properties\":{\"description\":\"Backend pool for Azure OpenAI endpoints\",\"type\":\"Pool\",\"pool\":{\"services\":[{\"id\":\"/backends/openai-backend-1\",\"priority\":1,\"weight\":1}]}}}" \
      --output none
    echo "  Backend Pool created."
  else
    echo "  Backend Pool already exists, skipping."
  fi

  # 5. API
  echo "  Creating APIM API (azure-openai)..."
  API_EXISTS=$(az rest --method GET \
    --url "${APIM_BASE}/apis/azure-openai${APIM_API_VER}" \
    --query "name" -o tsv 2>/dev/null || echo "")
  if [[ -z "$API_EXISTS" ]]; then
    az rest --method PUT \
      --url "${APIM_BASE}/apis/azure-openai${APIM_API_VER}" \
      --body "{\"properties\":{\"displayName\":\"Azure OpenAI\",\"path\":\"openai\",\"protocols\":[\"https\"],\"subscriptionRequired\":true,\"apiRevision\":\"1\"}}" \
      --output none
    echo "  API created."
  else
    echo "  API already exists, skipping."
  fi

  # 6. Operation (POST wildcard)
  echo "  Creating APIM Operation (post-wildcard)..."
  OP_EXISTS=$(az rest --method GET \
    --url "${APIM_BASE}/apis/azure-openai/operations/post-wildcard${APIM_API_VER}" \
    --query "name" -o tsv 2>/dev/null || echo "")
  if [[ -z "$OP_EXISTS" ]]; then
    az rest --method PUT \
      --url "${APIM_BASE}/apis/azure-openai/operations/post-wildcard${APIM_API_VER}" \
      --body "{\"properties\":{\"displayName\":\"POST Wildcard\",\"method\":\"POST\",\"urlTemplate\":\"/*\"}}" \
      --output none
    echo "  Operation created."
  else
    echo "  Operation already exists, skipping."
  fi

  # 7. Policy (from template file — render inline)
  echo "  Creating APIM Policy..."
  POLICY_XML=$(sed \
    -e "s/\${auth_mode}/${APIM_AUTH_MODE}/g" \
    -e "s/\${aoai_api_version}/${AOAI_API_VERSION}/g" \
    -e 's/%{ if auth_mode == "api_key" ~}//g' \
    -e 's/%{ endif ~}//g' \
    -e 's/%{ if auth_mode == "managed_identity" ~}//g' \
    "$ROOT_DIR/policies/ai-gateway.xml.tftpl")
  # Strip lines that don't belong to current auth mode
  if [[ "$APIM_AUTH_MODE" == "api_key" ]]; then
    # Remove managed_identity block lines
    POLICY_XML=$(echo "$POLICY_XML" | grep -v "authentication-managed-identity\|ai-token\|Bearer")
  else
    # Remove api_key block lines
    POLICY_XML=$(echo "$POLICY_XML" | grep -v "azure-openai-key\|set-header name=\"Authorization\" exists-action=\"delete\"")
  fi
  POLICY_BODY=$(jq -n --arg xml "$POLICY_XML" '{"properties":{"value":$xml,"format":"xml"}}')
  az rest --method PUT \
    --url "${APIM_BASE}/apis/azure-openai/policies/policy${APIM_API_VER}" \
    --body "$POLICY_XML_BODY" \
    --output none 2>/dev/null || \
  az rest --method PUT \
    --url "${APIM_BASE}/apis/azure-openai/policies/policy${APIM_API_VER}" \
    --body "$POLICY_BODY" \
    --output none
  echo "  Policy created."

  echo "  APIM sub-resources ready."
fi
```

**Step 2: Add `AOAI_API_VERSION` variable** to the arg-parsing section at top of file (near `APIM_AUTH_MODE`):

```bash
AOAI_API_VERSION="2025-04-01-preview"
```

---

### Task 5: Add `app_insights_instrumentation_key` Terraform output

Step 1b needs the instrumentation key to create the Logger.

**Files:**
- Modify: `terraform/outputs.tf`

**Step 1: Add output:**

```hcl
output "app_insights_instrumentation_key" {
  value     = azurerm_application_insights.openclaw.instrumentation_key
  sensitive = true
}
```

---

### Task 6: Remove APIM_API_ID_CHECK from install-v2.sh outputs section

Since `apim_api_id` is no longer a Terraform output, the line that reads it needs updating.

**Files:**
- Modify: `scripts/install-v2.sh`

**Step 1: Find and update the outputs extraction section:**

Remove:
```bash
APIM_API_ID=$(terraform output -raw apim_api_id 2>/dev/null || echo "")
```

Replace with:
```bash
APIM_API_ID="${APIM_BASE}/apis/azure-openai"  # constructed, not from TF state
```

Where `APIM_BASE` is constructed from `APIM_NAME_TF` and subscription/RG — or just set to empty since it's not used downstream in the script.

---

### Task 7: Verify install-v2.sh smoke test still works

The APIM smoke test (Step 3) uses `APIM_NAME_TF` which comes from `terraform output -raw apim_name`. This output still exists (APIM service stays in Terraform), so no change needed.

**Step 1: Verify `apim_name` output still in `terraform/outputs.tf`:**

```bash
grep "apim_name\|apim_gateway_url" terraform/outputs.tf
```
Expected: both outputs still present.

---

### Task 8: Test on current environment (--skip-terraform)

Run with existing deployed resources to verify Step 1b idempotency:

**Step 1: Run install-v2.sh skipping terraform:**

```bash
./scripts/install-v2.sh \
  --aoai-key "KEY" \
  --aoai-endpoint "https://..." \
  --enable-apim \
  --skip-terraform --skip-images --skip-apim-test
```

Expected output:
```
=== Step 1b/7: APIM Sub-Resources ===
  azure-openai-key stored in ...
  Logger already exists, skipping.
  Named Value already exists, skipping.
  Backend already exists, skipping.
  Backend Pool already exists, skipping.
  API already exists, skipping.
  Operation already exists, skipping.
  Policy created.
  APIM sub-resources ready.
```

**Step 2: Run APIM smoke test:**

```bash
./scripts/install-v2.sh \
  --aoai-key "KEY" \
  --aoai-endpoint "https://..." \
  --enable-apim \
  --skip-terraform --skip-images
```

Expected: `✅ APIM smoke test PASSED (HTTP 401)`

---

### Task 9: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

Update §3.5 and §5.3 to note:
- `install-v2.sh` is the new preferred script
- APIM sub-resources now managed by `install-v2.sh` az CLI, not Terraform
- `install.sh` kept as legacy reference
