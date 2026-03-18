#!/bin/bash
set -euo pipefail
APIM_API_ID="/subscriptions/55a5740e-376a-4d19-9be9-ae2be9c3731e/resourceGroups/openclaw-rg/providers/Microsoft.ApiManagement/service/openclaw-apim/apis/azure-openai"
kubectl set env deploy/openclaw-admin -n openclaw "APIM_API_ID=${APIM_API_ID}"
echo "Done. APIM_API_ID set to: $APIM_API_ID"
