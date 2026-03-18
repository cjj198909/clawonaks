#!/bin/bash
# One-command deployment of OpenClaw on AKS.
# Usage: install.sh --aoai-key KEY --aoai-endpoint URL [--tfvars PATH] [--skip-terraform] [--skip-images] [--enable-apim] [--apim-auth-mode api_key|managed_identity] [--skip-apim-test]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# --- Defaults ---
TFVARS="$ROOT_DIR/terraform/terraform.tfvars"
SKIP_TERRAFORM=false
SKIP_IMAGES=false
AOAI_KEY=""
AOAI_ENDPOINT=""
ENABLE_APIM=false
APIM_AUTH_MODE="api_key"
SKIP_APIM_TEST=false

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --aoai-key)      AOAI_KEY="$2"; shift 2 ;;
    --aoai-endpoint) AOAI_ENDPOINT="$2"; shift 2 ;;
    --tfvars)        TFVARS="$2"; shift 2 ;;
    --skip-terraform) SKIP_TERRAFORM=true; shift ;;
    --skip-images)   SKIP_IMAGES=true; shift ;;
    --enable-apim)     ENABLE_APIM=true; shift ;;
    --apim-auth-mode)  APIM_AUTH_MODE="$2"; shift 2 ;;
    --skip-apim-test)  SKIP_APIM_TEST=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Prereq checks ---
for cmd in az terraform helm kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found"; exit 1; }
done
[[ -z "$AOAI_KEY" ]] && { echo "ERROR: --aoai-key is required"; exit 1; }
[[ -z "$AOAI_ENDPOINT" ]] && { echo "ERROR: --aoai-endpoint is required"; exit 1; }
az account show >/dev/null 2>&1 || { echo "ERROR: Not logged in to Azure. Run 'az login' first."; exit 1; }
[[ -f "$TFVARS" ]] || { echo "ERROR: terraform.tfvars not found at $TFVARS"; exit 1; }

# --- Resource group pre-check ---
RG_NAME=$(grep -E '^\s*resource_group\s*=' "$TFVARS" | sed 's/.*=\s*//' | tr -d '"' | xargs)
RG_LOCATION=$(grep -E '^\s*location\s*=' "$TFVARS" | sed 's/.*=\s*//' | tr -d '"' | xargs)
if [[ -n "$RG_NAME" ]] && ! az group show --name "$RG_NAME" &>/dev/null; then
  echo "  Resource group '$RG_NAME' does not exist. Creating in $RG_LOCATION..."
  az group create --name "$RG_NAME" --location "${RG_LOCATION:-westus2}" --output none
  echo "  Resource group created."
else
  echo "  Resource group '$RG_NAME' already exists."
fi

# ============================
# Step 1/7: Terraform
# ============================
if [[ "$SKIP_TERRAFORM" == "false" ]]; then
  echo ""
  echo "=== Step 1/7: Terraform Init & Apply ==="
  cd "$ROOT_DIR/terraform"
  terraform init -input=false
  TF_VAR_ARGS=(-var-file="$TFVARS" -input=false \
    -var="enable_apim=$ENABLE_APIM" \
    -var="apim_backend_auth_mode=$APIM_AUTH_MODE" \
    -var="aoai_endpoint=$AOAI_ENDPOINT")
  TF_ARGS=("${TF_VAR_ARGS[@]}" -auto-approve)
  TF_LOG=$(mktemp /tmp/tf-apply-XXXXXX)

  # First apply — APIM sub-resources may fail with "Resource already exists"
  # when Azure creates them but the provider fails to write TF state.
  # Also, APIM Named Value may fail if KV secret doesn't exist yet (chicken-and-egg).
  set +e
  terraform apply "${TF_ARGS[@]}" 2>&1 | tee "$TF_LOG"
  TF_EXIT=${PIPESTATUS[0]}
  set -e

  # After first apply, KV exists in state — write AOAI key so Named Value can resolve.
  # This must happen between apply cycles because Named Value references the KV secret.
  if [[ "$ENABLE_APIM" == "true" ]]; then
    KV_NAME_EARLY=$(terraform output -raw keyvault_name 2>/dev/null || echo "")
    if [[ -n "$KV_NAME_EARLY" ]]; then
      echo "  Writing azure-openai-key to KV (needed for APIM Named Value)..."
      for _attempt in 1 2 3; do
        if az keyvault secret set --vault-name "$KV_NAME_EARLY" --name azure-openai-key --value "$AOAI_KEY" --output none 2>/dev/null; then
          echo "  azure-openai-key stored in $KV_NAME_EARLY"
          break
        fi
        [[ $_attempt -lt 3 ]] && sleep 15
      done
    fi
  fi

  if [[ $TF_EXIT -ne 0 && "$ENABLE_APIM" == "true" ]]; then
    # Auto-import orphaned resources (created in Azure, missing from TF state)
    # NOTE: Uses sed instead of grep -P for macOS compatibility
    IMPORTED=0
    while IFS= read -r addr; do
      # Escape [] for grep (TF addresses contain [0])
      escaped_addr=$(echo "$addr" | sed 's/\[/\\[/g; s/\]/\\]/g')
      # Extract Azure resource ID from the same error block as "with <addr>,".
      # azurerm: ID is 1-2 lines BEFORE; azapi: ID is 3-5 lines AFTER.
      id=$(grep -B3 -A6 "with ${escaped_addr}," "$TF_LOG" | grep -o '"/subscriptions/[^"]*"' | head -1 | tr -d '"')
      if [[ -n "$id" ]]; then
        echo "  Importing orphaned resource: $addr -> $id"
        terraform import "${TF_VAR_ARGS[@]}" "$addr" "$id" && ((IMPORTED++)) || true
      fi
    done < <(sed -n 's/.*with \([^,]*\),.*/\1/p' "$TF_LOG" | grep -v '^$')

    if [[ $IMPORTED -gt 0 ]]; then
      echo "  Imported $IMPORTED resource(s). Re-applying..."
      terraform apply "${TF_ARGS[@]}"
    else
      # No importable resources, but might be a transient error (e.g. Named Value
      # polling failure after KV secret was just written). Retry once.
      echo "  No importable resources found."
      echo "  Waiting 30s for RBAC propagation (APIM MI → KV)..."
      sleep 30
      echo "  Retrying apply (KV secret now available)..."
      set +e
      terraform apply "${TF_ARGS[@]}" 2>&1 | tee "$TF_LOG"
      TF_EXIT_RETRY=${PIPESTATUS[0]}
      set -e
      if [[ $TF_EXIT_RETRY -ne 0 ]]; then
        # Retry may hit "already exists" if Named Value was partially created.
        # Run one more import cycle before giving up.
        IMPORTED_R=0
        while IFS= read -r addr; do
          escaped_addr=$(echo "$addr" | sed 's/\[/\\[/g; s/\]/\\]/g')
          id=$(grep -B3 -A6 "with ${escaped_addr}," "$TF_LOG" | grep -o '"/subscriptions/[^"]*"' | head -1 | tr -d '"')
          if [[ -n "$id" ]]; then
            echo "  Importing orphaned resource: $addr -> $id"
            terraform import "${TF_VAR_ARGS[@]}" "$addr" "$id" && ((IMPORTED_R++)) || true
          fi
        done < <(sed -n 's/.*with \([^,]*\),.*/\1/p' "$TF_LOG" | grep -v '^$')

        if [[ $IMPORTED_R -gt 0 ]]; then
          echo "  Imported $IMPORTED_R resource(s). Final re-apply..."
          terraform apply "${TF_ARGS[@]}"
        else
          echo "  ERROR: Terraform apply failed after retry."
          rm -f "$TF_LOG"
          exit $TF_EXIT_RETRY
        fi
      fi
    fi
  elif [[ $TF_EXIT -ne 0 ]]; then
    rm -f "$TF_LOG"
    exit $TF_EXIT
  fi

  # APIM sub-resources may not be created in the first apply (APIM takes 30+ min,
  # sub-resources are deferred). Run a second apply + import cycle if needed.
  if [[ "$ENABLE_APIM" == "true" ]]; then
    APIM_API_ID_CHECK=$(terraform output -raw apim_api_id 2>/dev/null || echo "")
    if [[ -z "$APIM_API_ID_CHECK" ]]; then
      echo "  APIM sub-resources missing from state. Running second apply..."
      set +e
      terraform apply "${TF_ARGS[@]}" 2>&1 | tee "$TF_LOG"
      TF_EXIT2=${PIPESTATUS[0]}
      set -e

      if [[ $TF_EXIT2 -ne 0 ]]; then
        # Import any "already exists" resources and re-apply
        IMPORTED=0
        while IFS= read -r addr; do
          escaped_addr=$(echo "$addr" | sed 's/\[/\\[/g; s/\]/\\]/g')
          id=$(grep -B3 -A6 "with ${escaped_addr}," "$TF_LOG" | grep -o '"/subscriptions/[^"]*"' | head -1 | tr -d '"')
          if [[ -n "$id" ]]; then
            echo "  Importing orphaned resource: $addr -> $id"
            terraform import "${TF_VAR_ARGS[@]}" "$addr" "$id" && ((IMPORTED++)) || true
          fi
        done < <(sed -n 's/.*with \([^,]*\),.*/\1/p' "$TF_LOG" | grep -v '^$')

        if [[ $IMPORTED -gt 0 ]]; then
          echo "  Imported $IMPORTED resource(s). Final apply..."
          terraform apply "${TF_ARGS[@]}"
        else
          echo "  ERROR: Second Terraform apply failed with no importable resources."
          rm -f "$TF_LOG"
          exit $TF_EXIT2
        fi
      fi
    fi
  fi
  rm -f "$TF_LOG"
  cd "$ROOT_DIR"
else
  echo ""
  echo "=== Step 1/7: Terraform (SKIPPED) ==="
fi

# --- Extract terraform outputs ---
echo "  Extracting terraform outputs..."
cd "$ROOT_DIR/terraform"
ACR_NAME=$(terraform output -raw acr_name)
ACR_SERVER=$(terraform output -raw acr_login_server)
AKS_NAME=$(terraform output -raw aks_name)
KV_NAME=$(terraform output -raw keyvault_name)
RG=$(terraform output -raw resource_group)
STORAGE_ACCOUNT=$(terraform output -raw storage_account_name)
SANDBOX_MI_CLIENT_ID=$(terraform output -raw sandbox_identity_client_id)
ADMIN_MI_CLIENT_ID=$(terraform output -raw admin_identity_client_id)
TENANT_ID=$(az account show --query tenantId -o tsv)
APIM_GATEWAY_URL=$(terraform output -raw apim_gateway_url 2>/dev/null || echo "")
APIM_API_ID=$(terraform output -raw apim_api_id 2>/dev/null || echo "")
APIM_NAME_TF=$(terraform output -raw apim_name 2>/dev/null || echo "")
cd "$ROOT_DIR"

echo "  ACR: $ACR_SERVER"
echo "  AKS: $AKS_NAME"
echo "  KV:  $KV_NAME"

# ============================
# Step 2/7: Azure OpenAI Key → KV
# ============================
echo ""
echo "=== Step 2/7: Store Azure OpenAI Key in Key Vault ==="
for attempt in 1 2 3; do
  if az keyvault secret set --vault-name "$KV_NAME" --name azure-openai-key --value "$AOAI_KEY" --output none 2>/dev/null; then
    echo "  azure-openai-key stored in $KV_NAME"
    break
  fi
  if [[ $attempt -lt 3 ]]; then
    echo "  KV write attempt $attempt failed (RBAC propagation). Retrying in 15s..."
    sleep 15
  else
    echo "  ERROR: Failed to write to Key Vault after 3 attempts."
    echo "  Run manually: az keyvault secret set --vault-name $KV_NAME --name azure-openai-key --value <KEY>"
    exit 1
  fi
done

# ============================
# Step 3/7: APIM Endpoint Smoke Test
# ============================
if [[ "$ENABLE_APIM" == "true" && "$SKIP_APIM_TEST" == "false" ]]; then
  echo ""
  echo "=== Step 3/7: APIM Endpoint Smoke Test ==="
  AZ_SUB_ID=$(az account show --query id -o tsv)
  TEST_SUB_NAME="install-smoke-test"
  TEST_SUB_URL="https://management.azure.com/subscriptions/${AZ_SUB_ID}/resourceGroups/${RG}/providers/Microsoft.ApiManagement/service/${APIM_NAME_TF}/subscriptions/${TEST_SUB_NAME}?api-version=2024-06-01-preview"

  echo "  Creating temporary APIM subscription..."
  set +e
  TEST_SUB_RESULT=$(az rest --method PUT --url "$TEST_SUB_URL" \
    --body '{"properties":{"displayName":"Install Smoke Test","scope":"/apis","state":"active"}}' 2>&1)
  TEST_SUB_EXIT=$?
  set -e

  if [[ $TEST_SUB_EXIT -ne 0 ]]; then
    echo "  ⚠️  Could not create test subscription. APIM may still be provisioning."
    echo "  $TEST_SUB_RESULT"
    echo "  Skipping APIM test. Re-run with --skip-terraform --skip-images to retry later."
  else
    # Fetch subscription key via listSecrets (PUT response doesn't include keys)
    TEST_SECRETS_URL="https://management.azure.com/subscriptions/${AZ_SUB_ID}/resourceGroups/${RG}/providers/Microsoft.ApiManagement/service/${APIM_NAME_TF}/subscriptions/${TEST_SUB_NAME}/listSecrets?api-version=2024-06-01-preview"
    TEST_SECRETS=$(az rest --method POST --url "$TEST_SECRETS_URL" 2>/dev/null || echo "")
    TEST_KEY=$(echo "$TEST_SECRETS" | grep -o '"primaryKey"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"//')

    if [[ -z "$TEST_KEY" ]]; then
      echo "  ⚠️  Test subscription created but no key returned. Skipping test."
      az rest --method DELETE --url "$TEST_SUB_URL" 2>/dev/null || true
    else
      APIM_TEST_URL="https://${APIM_NAME_TF}.azure-api.net/openai/responses"
      APIM_TEST_PASSED=false
      RESPONSE_FILE=$(mktemp /tmp/apim-test-XXXXXX.json)

      for attempt in 1 2 3; do
        echo "  Testing APIM endpoint (attempt $attempt/3): POST $APIM_TEST_URL"
        set +e
        HTTP_CODE=$(curl -s -o "$RESPONSE_FILE" -w "%{http_code}" \
          --max-time 30 \
          -X POST "$APIM_TEST_URL" \
          -H "Content-Type: application/json" \
          -H "Ocp-Apim-Subscription-Key: ${TEST_KEY}" \
          -d '{"model":"gpt-5.4","input":"say ok","max_output_tokens":5}')
        set -e

        if [[ $HTTP_CODE -ge 200 && $HTTP_CODE -lt 500 ]]; then
          echo "  ✅ APIM smoke test PASSED (HTTP $HTTP_CODE)"
          if [[ $HTTP_CODE -eq 404 ]]; then
            echo "     (Backend 404 = model deployment may not exist, but APIM routing works)"
          fi
          APIM_TEST_PASSED=true
          break
        else
          echo "  ⚠️  APIM returned HTTP $HTTP_CODE"
          [[ -s "$RESPONSE_FILE" ]] && head -5 "$RESPONSE_FILE" && echo ""
          if [[ $attempt -lt 3 ]]; then
            echo "  Retrying in 30s (KV Named Value sync / RBAC propagation)..."
            sleep 30
          fi
        fi
      done

      # Cleanup temp subscription
      echo "  Cleaning up test subscription..."
      az rest --method DELETE --url "$TEST_SUB_URL" 2>/dev/null || true
      rm -f "$RESPONSE_FILE"

      if [[ "$APIM_TEST_PASSED" != "true" ]]; then
        echo ""
        echo "  ❌ APIM smoke test FAILED after 3 attempts."
        echo "  Common causes:"
        echo "    - HTTP 500: Named Value cannot read KV secret (RBAC propagation ~5-10 min)"
        echo "    - HTTP 502: Backend Azure OpenAI endpoint unreachable"
        echo "    - HTTP 404 from APIM: API operation not matched"
        echo ""
        echo "  Options:"
        echo "    1. Wait a few minutes and re-run: --skip-terraform --skip-images"
        echo "    2. Check APIM in Azure Portal"
        echo "    3. Skip test: --skip-apim-test"
        exit 1
      fi
    fi
  fi
else
  echo ""
  if [[ "$ENABLE_APIM" == "true" ]]; then
    echo "=== Step 3/7: APIM Smoke Test (SKIPPED — --skip-apim-test) ==="
  else
    echo "=== Step 3/7: APIM Smoke Test (SKIPPED — APIM not enabled) ==="
  fi
fi

# ============================
# Step 4/7: Kata Nodepool
# ============================
echo ""
echo "=== Step 4/7: Kata VM Isolation Nodepool ==="
if az aks nodepool show --resource-group "$RG" --cluster-name "$AKS_NAME" --name sandboxv6 &>/dev/null; then
  echo "  Sandbox nodepool already exists, skipping."
else
  echo "  Creating sandbox nodepool (this may take 10-15 minutes)..."
  az aks nodepool add \
    --resource-group "$RG" \
    --cluster-name "$AKS_NAME" \
    --name sandboxv6 \
    --node-vm-size Standard_D4s_v6 \
    --node-count 1 \
    --os-type Linux \
    --os-sku AzureLinux \
    --workload-runtime KataVmIsolation \
    --enable-cluster-autoscaler \
    --min-count 0 \
    --max-count 3 \
    --labels openclaw.io/role=sandbox \
    --node-taints openclaw.io/sandbox=true:NoSchedule
  echo "  Sandbox nodepool created."
fi

# ============================
# Step 5/7: Docker Images
# ============================
if [[ "$SKIP_IMAGES" == "false" ]]; then
  echo ""
  echo "=== Step 5/7: Build & Push Docker Images ==="
  az acr build --registry "$ACR_NAME" --image openclaw-agent:latest "$ROOT_DIR/docker/"
  az acr build --registry "$ACR_NAME" --image persist-sync:latest "$ROOT_DIR/docker/persist-sync/"
  az acr build --registry "$ACR_NAME" --image openclaw-admin:latest "$ROOT_DIR/admin/"
else
  echo ""
  echo "=== Step 5/7: Docker Images (SKIPPED) ==="
fi

# ============================
# Step 6/7: Kubeconfig
# ============================
echo ""
echo "=== Step 6/7: Get Kubeconfig ==="
az aks get-credentials --resource-group "$RG" --name "$AKS_NAME" --overwrite-existing

# ============================
# Step 7/7: Helm Install
# ============================
echo ""
echo "=== Step 7a/7: Adopt existing resources into Helm ==="

adopt_resource() {
  local kind="$1" name="$2" ns="${3:-}"
  local args=("$kind" "$name")
  [[ -n "$ns" ]] && args+=("-n" "$ns")

  if kubectl get "${args[@]}" &>/dev/null; then
    echo "  Adopting $kind/$name into Helm release..."
    kubectl annotate "${args[@]}" \
      meta.helm.sh/release-name=openclaw \
      meta.helm.sh/release-namespace=openclaw --overwrite
    kubectl label "${args[@]}" \
      app.kubernetes.io/managed-by=Helm --overwrite
  fi
}

# Cluster-scoped
adopt_resource namespace openclaw
adopt_resource pv openclaw-nfs-pv
adopt_resource storageclass openclaw-disk
adopt_resource storageclass openclaw-files
# Namespaced (openclaw)
adopt_resource pvc openclaw-shared-data openclaw
adopt_resource serviceaccount openclaw-sandbox openclaw
adopt_resource networkpolicy sandbox-egress openclaw
adopt_resource serviceaccount openclaw-admin openclaw
adopt_resource role openclaw-admin openclaw
adopt_resource rolebinding openclaw-admin openclaw
adopt_resource deployment openclaw-admin openclaw
adopt_resource service openclaw-admin openclaw

echo ""
echo "=== Step 7b/7: Helm Upgrade --Install ==="
VALUES_FILE=$(mktemp /tmp/openclaw-values-XXXXXX.yaml)
trap 'rm -f "$VALUES_FILE"' EXIT
cat > "$VALUES_FILE" <<EOF
azure:
  tenantId: "$TENANT_ID"
  acr:
    loginServer: "$ACR_SERVER"
  keyvault:
    name: "$KV_NAME"
  openai:
    endpoint: "${AOAI_ENDPOINT%/openai}/openai/v1"
  storage:
    accountName: "$STORAGE_ACCOUNT"
    resourceGroup: "$RG"
    nfsVolumeHandle: "${RG}#${STORAGE_ACCOUNT}#openclaw-data"
identity:
  sandbox:
    clientId: "$SANDBOX_MI_CLIENT_ID"
  admin:
    clientId: "$ADMIN_MI_CLIENT_ID"
EOF

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

helm upgrade --install openclaw "$ROOT_DIR/charts/openclaw" \
  -f "$VALUES_FILE" \
  --namespace openclaw \
  --create-namespace

rm -f "$VALUES_FILE"

echo ""
echo "=== Installation Complete ==="
echo ""
echo "  AKS:   $AKS_NAME"
echo "  ACR:   $ACR_SERVER"
echo "  KV:    $KV_NAME"
echo ""
echo "Next steps:"
echo "  1. kubectl port-forward svc/openclaw-admin 3000:3000 -n openclaw"
echo "  2. Open http://localhost:3000 to create agents"
if [[ "$ENABLE_APIM" == "true" ]]; then
  echo ""
  echo "  APIM: $APIM_GATEWAY_URL (Internal VNet)"
  echo ""
  echo "  Note: APIM StandardV2 takes 30-45 min to deploy on first run."
  echo "  Agents created via Admin Panel will auto-use APIM mode."
fi
