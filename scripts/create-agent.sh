#!/bin/bash
# DEPRECATED (2026-03-14): v1 agent creation script based on StatefulSet + APIM.
# Replaced by Admin Panel (admin/server.js). Do not use.
set -euo pipefail

AGENT_ID="${1:?Usage: create-agent.sh <agent-id> [namespace]}"
NAMESPACE="${2:-openclaw}"

# 1. Get current replicas count
CURRENT=$(kubectl get sts openclaw-agent -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
NEW_ORDINAL=$CURRENT
NEW_REPLICAS=$((CURRENT + 1))

echo "=== Creating agent '$AGENT_ID' at ordinal $NEW_ORDINAL ==="

# 2. Update ConfigMap: add ordinal->agent-id mapping
kubectl patch configmap agent-mapping -n "$NAMESPACE" \
  --type merge -p "{\"data\":{\"agent-${NEW_ORDINAL}\": \"${AGENT_ID}\"}}"

# 3. Create APIM subscription
APIM_NAME=$(cd terraform && terraform output -raw apim_name 2>/dev/null || echo "openclaw-apim")
RG=$(cd terraform && terraform output -raw resource_group 2>/dev/null || echo "openclaw-rg")
SUBSCRIPTION_KEY=$(az apim subscription create \
  --resource-group "$RG" \
  --service-name "$APIM_NAME" \
  --display-name "openclaw-agent-${AGENT_ID}" \
  --scope "/apis" \
  --query primaryKey -o tsv)

# 4. Store APIM key in Key Vault
KV_NAME=$(cd terraform && terraform output -raw keyvault_name 2>/dev/null || echo "openclaw-kv")
az keyvault secret set --vault-name "$KV_NAME" --name "apim-key-${AGENT_ID}" --value "$SUBSCRIPTION_KEY"

# 5. Generate openclaw.json and upload to Azure Files via temp pod
APIM_URL=$(cd terraform && terraform output -raw apim_private_url)

cat > "/tmp/openclaw-${AGENT_ID}.json" <<EOFCONFIG
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

# Upload config to Azure Files via temp pod (storage has no public access)
kubectl run "upload-config-${AGENT_ID}" --rm -i --restart=Never -n "$NAMESPACE" \
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
  }" < "/tmp/openclaw-${AGENT_ID}.json"

rm -f "/tmp/openclaw-${AGENT_ID}.json"

# 6. Scale StatefulSet
kubectl scale sts openclaw-agent -n "$NAMESPACE" --replicas="$NEW_REPLICAS"

echo "=== Agent '$AGENT_ID' created as openclaw-agent-${NEW_ORDINAL} ==="
echo "Monitor: kubectl logs -f openclaw-agent-${NEW_ORDINAL} -c openclaw -n $NAMESPACE"
